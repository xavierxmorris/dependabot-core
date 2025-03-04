# frozen_string_literal: true

require "excon"
require "toml-rb"
require "open3"
require "dependabot/errors"
require "dependabot/shared_helpers"
require "dependabot/python/file_parser"
require "dependabot/python/file_updater/pyproject_preparer"
require "dependabot/python/update_checker"
require "dependabot/python/version"
require "dependabot/python/requirement"
require "dependabot/python/native_helpers"
require "dependabot/python/python_versions"
require "dependabot/python/authed_url_builder"

# rubocop:disable Metrics/ClassLength
module Dependabot
  module Python
    class UpdateChecker
      # This class does version resolution for pyproject.toml files.
      class PoetryVersionResolver
        GIT_REFERENCE_NOT_FOUND_REGEX =
          /'git'.*pypoetry-git-(?<name>.+?).{8}','checkout','(?<tag>.+?)'/.
          freeze
        GIT_DEPENDENCY_UNREACHABLE_REGEX =
          /Command '\['git', 'clone', '(?<url>.+?)'.* exit status 128/.
          freeze

        attr_reader :dependency, :dependency_files, :credentials

        def initialize(dependency:, dependency_files:, credentials:)
          @dependency               = dependency
          @dependency_files         = dependency_files
          @credentials              = credentials
        end

        def latest_resolvable_version(requirement: nil)
          version_string =
            fetch_latest_resolvable_version_string(requirement: requirement)

          version_string.nil? ? nil : Python::Version.new(version_string)
        end

        def resolvable?(version:)
          @resolvable ||= {}
          return @resolvable[version] if @resolvable.key?(version)

          if fetch_latest_resolvable_version_string(requirement: "==#{version}")
            @resolvable[version] = true
          else
            @resolvable[version] = false
          end
        rescue SharedHelpers::HelperSubprocessFailed => e
          raise unless e.message.include?("SolverProblemError")

          @resolvable[version] = false
        end

        private

        # rubocop:disable Metrics/MethodLength
        def fetch_latest_resolvable_version_string(requirement:)
          @latest_resolvable_version_string ||= {}
          if @latest_resolvable_version_string.key?(requirement)
            return @latest_resolvable_version_string[requirement]
          end

          @latest_resolvable_version_string[requirement] ||=
            SharedHelpers.in_a_temporary_directory do
              SharedHelpers.with_git_configured(credentials: credentials) do
                write_temporary_dependency_files(updated_req: requirement)

                if python_version && !pre_installed_python?(python_version)
                  run_poetry_command("pyenv install -s #{python_version}")
                  run_poetry_command(
                    "pyenv exec pip install -r "\
                    "#{NativeHelpers.python_requirements_path}"
                  )
                end

                # Shell out to Poetry, which handles everything for us.
                run_poetry_command(poetry_update_command)

                updated_lockfile =
                  if File.exist?("poetry.lock") then File.read("poetry.lock")
                  else File.read("pyproject.lock")
                  end
                updated_lockfile = TomlRB.parse(updated_lockfile)

                fetch_version_from_parsed_lockfile(updated_lockfile)
              rescue SharedHelpers::HelperSubprocessFailed => e
                handle_poetry_errors(e)
              end
            end
        end
        # rubocop:enable Metrics/MethodLength

        def fetch_version_from_parsed_lockfile(updated_lockfile)
          version =
            updated_lockfile.fetch("package", []).
            find { |d| d["name"] && normalise(d["name"]) == dependency.name }&.
            fetch("version")

          return version unless version.nil? && dependency.top_level?

          raise "No version in lockfile!"
        end

        def handle_poetry_errors(error)
          if error.message.gsub(/\s/, "").match?(GIT_REFERENCE_NOT_FOUND_REGEX)
            message = error.message.gsub(/\s/, "")
            name = message.match(GIT_REFERENCE_NOT_FOUND_REGEX).
                   named_captures.fetch("name")
            raise GitDependencyReferenceNotFound, name
          end

          if error.message.match?(GIT_DEPENDENCY_UNREACHABLE_REGEX)
            url = error.message.match(GIT_DEPENDENCY_UNREACHABLE_REGEX).
                  named_captures.fetch("url")
            raise GitDependenciesNotReachable, url
          end

          raise unless error.message.include?("SolverProblemError") ||
                       error.message.include?("PackageNotFound")

          check_original_requirements_resolvable

          # If the original requirements are resolvable but the new version
          # would break Python version compatibility the update is blocked
          return if error.message.include?("support the following Python")

          # If any kind of other error is now occuring as a result of our change
          # then we want to hear about it
          raise
        end

        # Using `--lock` avoids doing an install.
        # Using `--no-interaction` avoids asking for passwords.
        def poetry_update_command
          "pyenv exec poetry update #{dependency.name} --lock --no-interaction"
        end

        def check_original_requirements_resolvable
          return @original_reqs_resolvable if @original_reqs_resolvable

          SharedHelpers.in_a_temporary_directory do
            SharedHelpers.with_git_configured(credentials: credentials) do
              write_temporary_dependency_files(update_pyproject: false)

              run_poetry_command(poetry_update_command)

              @original_reqs_resolvable = true
            rescue SharedHelpers::HelperSubprocessFailed => e
              raise unless e.message.include?("SolverProblemError") ||
                           e.message.include?("PackageNotFound")

              msg = clean_error_message(e.message)
              raise DependencyFileNotResolvable, msg
            end
          end
        end

        def clean_error_message(message)
          # Redact any URLs, as they may include credentials
          message.gsub(/http.*?(?=\s)/, "<redacted>")
        end

        def write_temporary_dependency_files(updated_req: nil,
                                             update_pyproject: true)
          dependency_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, file.content)
          end

          # Overwrite the .python-version with updated content
          File.write(".python-version", python_version) if python_version

          # Overwrite the pyproject with updated content
          if update_pyproject
            File.write(
              "pyproject.toml",
              updated_pyproject_content(updated_requirement: updated_req)
            )
          else
            File.write("pyproject.toml", sanitized_pyproject_content)
          end
        end

        def python_version
          pyproject_object = TomlRB.parse(pyproject.content)
          poetry_object = pyproject_object.dig("tool", "poetry")

          requirement =
            poetry_object&.dig("dependencies", "python") ||
            poetry_object&.dig("dev-dependencies", "python")

          unless requirement
            return python_version_file_version || runtime_file_python_version
          end

          requirements =
            Python::Requirement.requirements_array(requirement)

          version = PythonVersions::SUPPORTED_VERSIONS_TO_ITERATE.find do |v|
            requirements.any? { |r| r.satisfied_by?(Python::Version.new(v)) }
          end
          return version if version

          msg = "Dependabot detected the following Python requirement "\
                "for your project: '#{requirement}'.\n\nCurrently, the "\
                "following Python versions are supported in Dependabot: "\
                "#{PythonVersions::SUPPORTED_VERSIONS.join(', ')}."
          raise DependencyFileNotResolvable, msg
        end

        def python_version_file_version
          file_version = python_version_file&.content&.strip

          return unless file_version
          return unless pyenv_versions.include?("#{file_version}\n")

          file_version
        end

        def runtime_file_python_version
          return unless runtime_file

          runtime_file.content.match(/(?<=python-).*/)&.to_s&.strip
        end

        def pyenv_versions
          @pyenv_versions ||= run_poetry_command("pyenv install --list")
        end

        def pre_installed_python?(version)
          PythonVersions::PRE_INSTALLED_PYTHON_VERSIONS.include?(version)
        end

        def updated_pyproject_content(updated_requirement:)
          content = pyproject.content
          content = sanitize_pyproject_content(content)
          content = add_private_sources(content)
          content = freeze_other_dependencies(content)
          content = set_target_dependency_req(content, updated_requirement)
          content
        end

        def sanitized_pyproject_content
          content = pyproject.content
          content = sanitize_pyproject_content(content)
          content = add_private_sources(content)
          content
        end

        def sanitize_pyproject_content(pyproject_content)
          Python::FileUpdater::PyprojectPreparer.
            new(pyproject_content: pyproject_content).
            sanitize
        end

        def add_private_sources(pyproject_content)
          Python::FileUpdater::PyprojectPreparer.
            new(pyproject_content: pyproject_content).
            replace_sources(credentials)
        end

        def freeze_other_dependencies(pyproject_content)
          Python::FileUpdater::PyprojectPreparer.
            new(pyproject_content: pyproject_content, lockfile: lockfile).
            freeze_top_level_dependencies_except([dependency])
        end

        def set_target_dependency_req(pyproject_content, updated_requirement)
          return pyproject_content unless updated_requirement

          pyproject_object = TomlRB.parse(pyproject_content)
          poetry_object = pyproject_object.dig("tool", "poetry")

          %w(dependencies dev-dependencies).each do |type|
            names = poetry_object[type]&.keys || []
            pkg_name = names.find { |nm| normalise(nm) == dependency.name }
            next unless pkg_name

            if poetry_object.dig(type, pkg_name).is_a?(Hash)
              poetry_object[type][pkg_name]["version"] = updated_requirement
            else
              poetry_object[type][pkg_name] = updated_requirement
            end
          end

          # If this is a sub-dependency, add the new requirement
          unless dependency.requirements.find { |r| r[:file] == pyproject.name }
            poetry_object[subdep_type] ||= {}
            poetry_object[subdep_type][dependency.name] = updated_requirement
          end

          TomlRB.dump(pyproject_object)
        end

        def subdep_type
          category =
            TomlRB.parse(lockfile.content).fetch("package", []).
            find { |dets| normalise(dets.fetch("name")) == dependency.name }.
            fetch("category")

          category == "dev" ? "dev-dependencies" : "dependencies"
        end

        def pyproject
          dependency_files.find { |f| f.name == "pyproject.toml" }
        end

        def pyproject_lock
          dependency_files.find { |f| f.name == "pyproject.lock" }
        end

        def poetry_lock
          dependency_files.find { |f| f.name == "poetry.lock" }
        end

        def lockfile
          poetry_lock || pyproject_lock
        end

        def python_version_file
          dependency_files.find { |f| f.name == ".python-version" }
        end

        def runtime_file
          dependency_files.find { |f| f.name.end_with?("runtime.txt") }
        end

        def run_poetry_command(command)
          start = Time.now
          command = SharedHelpers.escape_command(command)
          stdout, process = Open3.capture2e(command)
          time_taken = Time.now - start

          # Raise an error with the output from the shell session if Pipenv
          # returns a non-zero status
          return if process.success?

          raise SharedHelpers::HelperSubprocessFailed.new(
            message: stdout,
            error_context: {
              command: command,
              time_taken: time_taken,
              process_exit_value: process.to_s
            }
          )
        end

        # See https://www.python.org/dev/peps/pep-0503/#normalized-names
        def normalise(name)
          name.downcase.gsub(/[-_.]+/, "-")
        end
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength
