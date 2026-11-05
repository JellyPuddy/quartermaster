# frozen_string_literal: true

module Quartermaster
  class ProjectMap
    NO_PROJECT = "No project"

    # roots: name → root path or settings mapping, as under config.yml's
    # `projects:` (tests inject it); default the configured projects.
    def initialize(roots: nil)
      @config = roots ? ProjectConfig.new("projects" => roots) : configured
      @roots = @config.roots
    end

    def project_for(cwd)
      return NO_PROJECT unless cwd

      path = normalize(cwd)
      direct = @roots.find { |_name, root| within?(path, normalize(root)) }
      return direct.first if direct

      common_dir = git_common_dir(path)
      if common_dir
        via_worktree = @roots.find { |_name, root| within?(common_dir, normalize(root)) }
        return via_worktree.first if via_worktree
      end

      NO_PROJECT
    end

    def root_for(project)
      @roots[project]
    end

    def known_projects
      @roots.keys
    end

    def settings_for(project) = @config.settings(project)

    def dev_server = @config.dev_server

    def ide(project) = @config.ide(project)

    def ide!(project) = @config.ide!(project)

    private

    def configured
      Quartermaster.ensure_setup
      ProjectConfig.current
    rescue StandardError
      ProjectConfig.new(nil)
    end

    # Symlinked paths (macOS /var -> /private/var, git returning realpaths) must
    # compare equal, so both sides of every prefix check go through realpath.
    def normalize(path)
      File.realpath(File.expand_path(path))
    rescue StandardError
      File.expand_path(path)
    end

    def within?(path, root)
      path == root || path.start_with?("#{root}/")
    end

    def git_common_dir(path)
      out = Quartermaster.git(path, "rev-parse", "--git-common-dir")
      out && normalize(File.expand_path(out, path))
    end
  end
end
