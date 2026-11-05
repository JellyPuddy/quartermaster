# frozen_string_literal: true

module Quartermaster
  # Which checkout "work on this item" means — shared by the dev server and the IDE so
  # the dev server and the IDE always land in the same place:
  #   1. the item's gh-stack top, in whatever worktree has it checked out;
  #   2. no stack: the last linked branch that has a worktree (the
  #      Launcher#start_cwd rule), the other worktrees offered as alternatives;
  #   3. a target branch with no worktree gets a fresh one under
  #      <repo>/.claude/worktrees/ — an existing worktree is never switched to
  #      another branch, since it may hold someone's (or some agent's) work.
  class TargetWorktree
    Target = Struct.new(:path, :branch, :create, :alternatives, :warning, keyword_init: true) do
      def create? = create

      def to_h
        { "path" => path, "branch" => branch, "create" => create, "warning" => warning,
          "alternatives" => alternatives.map { |branch, path| { "branch" => branch, "path" => path } } }
      end
    end

    WORKTREES_DIR = File.join(".claude", "worktrees")

    def initialize(project_map: ProjectMap.new, runner: CommandRunner.new)
      @project_map = project_map
      @runner = runner
    end

    # Says where, and whether that worktree must be created first; creates
    # nothing. It does auto-link the item's stack branches (GhStack#link_into)
    # so the stack top is known. An explicit worktree wins outright; a
    # selected branch (one the item links: the side panel's selection)
    # replaces the default pick, keeping rule 3 for a branch without one.
    def resolve(item, worktree: nil, branch: nil)
      return explicit(worktree) if worktree

      root = @project_map.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root

      stacks = GhStack.for_root(root)
      stacks.link_into(item)
      checked_out = Quartermaster.branch_worktrees(root).select { |_branch, path| File.directory?(path) }
      with_worktree = item.branches.reverse.filter_map { |b| [b, checked_out[b]] if checked_out[b] }

      if branch
        selected_target(root, item, branch, checked_out, with_worktree)
      elsif (stack = stacks.stack_for(item.branches))
        stack_target(root, stack, checked_out, with_worktree)
      elsif with_worktree.any?
        branch, path = with_worktree.first
        Target.new(path: path, branch: branch, create: false, alternatives: with_worktree.drop(1))
      elsif (branch = item.branches.reverse.find { |b| !WorkItem::MAINLINE_BRANCHES.include?(b) })
        Target.new(path: new_worktree_path(root, branch), branch: branch, create: true, alternatives: [])
      else
        Target.new(path: root, branch: nil, create: false, alternatives: [])
      end
    end

    # Resolve, creating the worktree when the target has none yet. A project
    # with a test_db command also gets `<test_db> prepare` run there, or the
    # first dev-server switch / test run there fails.
    def materialize(item, worktree: nil, branch: nil)
      target = resolve(item, worktree: worktree, branch: branch)
      return target unless target.create?

      root = @project_map.root_for(item.project)
      add_worktree(root, target.branch, target.path)
      prepare_test_db(item.project, target.path)
      target
    end

    # A PR's branch rather than an item's: its existing worktree, else a new
    # one — the same never-switch-a-worktree rule as for items. base: a ref to
    # start the branch from when it doesn't exist locally yet (a new issue
    # branch off origin's default), instead of tracking origin's same-named
    # branch.
    def materialize_branch(project, branch, base: nil)
      root = @project_map.root_for(project)
      raise ArgumentError, "no repo root configured for project '#{project}'" unless root

      path = Quartermaster.branch_worktrees(root)[branch]
      return Target.new(path: path, branch: branch, create: false, alternatives: []) if path && File.directory?(path)

      target = Target.new(path: new_worktree_path(root, branch), branch: branch, create: true, alternatives: [])
      add_worktree(root, branch, target.path, base: base)
      prepare_test_db(project, target.path)
      target
    end

    # Branch names hold slashes (issue/123-foo); the worktree directory is
    # one flat segment, matching what `claude --worktree` produces.
    def self.slug_for(branch)
      branch.gsub(%r{[^A-Za-z0-9._-]+}, "-").gsub(/\A-+|-+\z/, "")
    end

    # A selected branch must be one the item links: the selection names a
    # checkout to create or serve, so an arbitrary ref is refused.
    def self.require_linked(item, branch)
      return if item.branches.include?(branch)

      raise ArgumentError, "branch #{branch} is not linked to '#{item.slug}'"
    end

    private

    def explicit(worktree)
      path = File.expand_path(worktree)
      raise ArgumentError, "no such worktree: #{path}" unless File.directory?(path)

      Target.new(path: path, branch: nil, create: false, alternatives: [])
    end

    def selected_target(root, item, branch, checked_out, with_worktree)
      self.class.require_linked(item, branch)
      alternatives = with_worktree.reject { |b, _| b == branch }
      if (path = checked_out[branch])
        return Target.new(path: path, branch: branch, create: false, alternatives: alternatives)
      end

      Target.new(path: new_worktree_path(root, branch), branch: branch, create: true, alternatives: alternatives)
    end

    def stack_target(root, stack, checked_out, with_worktree)
      top = stack.last.branch
      alternatives = with_worktree.reject { |b, _| b == top }
      if checked_out[top]
        return Target.new(path: checked_out[top], branch: top, create: false, alternatives: alternatives)
      end

      siblings = stack.filter_map { |e| "#{e.branch} (#{Quartermaster.shorten_home(checked_out[e.branch])})" if checked_out[e.branch] }
      warning = if siblings.any?
                  "stack top #{top} has no worktree; only #{siblings.join(", ")} does — " \
                    "a new worktree is created for the top instead of checking it out there"
                end
      Target.new(path: new_worktree_path(root, top), branch: top, create: true,
                 alternatives: alternatives, warning: warning)
    end

    def new_worktree_path(root, branch)
      File.join(root, WORKTREES_DIR, self.class.slug_for(branch))
    end

    # The local branch when there is one; otherwise a new branch from base,
    # untracked (its upstream is its own once pushed, never base); otherwise a
    # new local branch tracking origin's (fetched first when this clone has
    # never seen it).
    def add_worktree(root, branch, path, base: nil)
      if Quartermaster.git(root, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
        run!(["git", "worktree", "add", path, branch], "git worktree add", chdir: root)
      elsif base
        run!(["git", "worktree", "add", "--no-track", "-b", branch, path, base], "git worktree add", chdir: root)
      else
        unless Quartermaster.git(root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{branch}")
          run!(["git", "fetch", "origin", branch], "git fetch", chdir: root)
        end
        run!(["git", "worktree", "add", "--track", "-b", branch, path, "origin/#{branch}"], "git worktree add", chdir: root)
      end
    end

    # A retry finds the worktree already there and skips this step, so the
    # failure has to say the worktree exists and still needs it.
    def prepare_test_db(project, path)
      return unless (command = @project_map.settings_for(project).test_db)

      run!([command, "prepare"], "#{command} prepare", chdir: path)
    rescue ArgumentError => e
      raise ArgumentError, "created worktree #{Quartermaster.shorten_home(path)}, then #{e.message}; " \
                           "run `#{command} prepare` there before using it"
    end

    def run!(argv, label, chdir:)
      result = @runner.call(argv, chdir: chdir)
      return result if result.success?

      message = [result.err, result.out].map(&:strip).find { |text| !text.empty? } || "exit status non-zero"
      raise ArgumentError, "#{label} failed: #{message}"
    end
  end
end
