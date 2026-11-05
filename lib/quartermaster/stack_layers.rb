# frozen_string_literal: true

module Quartermaster
  # The layers of the gh-stack a diffed branch sits in, for the diff pane's
  # layered commit list and file circles (docs/areas/diff.md): per layer its
  # commits (parent..branch, newest first), its own +/− and files
  # (parent...branch), and for each commit the lower layer — or the trunk —
  # that already holds a `git cherry` equivalent of it (a squash merge's
  # leftover on a stack needing a restack). Never a diff body: only the
  # selected branch's diff is ever built.
  #
  # Tips resolve as GhStack.chains resolves them (straight from the common
  # git dir; branches local first, the trunk origin first), and every git
  # answer is cached keyed on the tip shas involved (GhStack.fact), so a
  # reload with unchanged refs spawns no git here.
  class StackLayers
    MAX_COMMITS = 200

    # `git`: (path, *args) → stdout or nil, as BranchDiff#raw_git answers.
    def initialize(root, git:)
      @root = root
      @git = git
    end

    # {"trunk", "layers" => [{branch, n, add, del, commits}], "fileLayers"
    # => {path => [layer index]}} for the stack holding `branch`, else nil.
    # Layer indexes are 0-based, bottom first, as "layers" lists them.
    def call(branch)
      stacks = GhStack.for_root(@root)
      stack = branch && stacks.stacks_for([branch]).first
      return nil unless stack

      path = GhStack.file_for(@root)
      refs = path && GhStack::RefTips.new(File.dirname(path), @root, Quartermaster.method(:git))
      trunk = stack.trunk || stacks.default_trunk(refs)
      trunk_sha = refs&.first("origin/#{trunk}", trunk)&.last
      tips = stack.map { |entry| refs&.first(entry.branch, "origin/#{entry.branch}")&.last }
      upstreams = [[trunk, trunk_sha]] + stack.map(&:branch).zip(tips)
      file_layers = {}
      layers = stack.each_with_index.map do |entry, i|
        parent_sha = tips[0...i].compact.last || trunk_sha
        layer = layer_for(entry.branch, parent_sha, tips[i], upstreams.first(i + 1))
        layer.delete("files").each { |file| (file_layers[file] ||= []) << i }
        layer
      end
      { "trunk" => trunk, "layers" => layers, "fileLayers" => file_layers }
    end

    private

    def layer_for(branch, parent_sha, sha, upstreams)
      unless parent_sha && sha
        return { "branch" => branch, "n" => 0, "add" => 0, "del" => 0, "commits" => [], "files" => [] }
      end

      log = commits(parent_sha, sha)
      stat = numstat(parent_sha, sha)
      also = also_in(parent_sha, sha, upstreams)
      { "branch" => branch, "n" => log[:count], "add" => stat[:add], "del" => stat[:del],
        "commits" => log[:commits].map { |c| c.merge("alsoIn" => also[c["sha"]]) }, "files" => stat[:files] }
    end

    # parent..sha newest first, the newest MAX_COMMITS of them, and how many
    # there are in all.
    def commits(parent_sha, sha)
      GhStack.fact([@root, :layer_log, parent_sha, sha]) do
        out = @git.call(@root, "log", "--shortstat", "--format=%x1e%H%x1f%h%x1f%s", "#{parent_sha}..#{sha}") || ""
        all = out.split("\x1e").filter_map do |record|
          line, stat = record.split("\n", 2)
          full, short, subject = line.to_s.strip.split("\x1f", 3)
          next unless full

          { "sha" => full, "short" => short, "subject" => subject.to_s,
            "add" => stat.to_s[/(\d+) insertion/, 1].to_i, "del" => stat.to_s[/(\d+) deletion/, 1].to_i }
        end
        { count: all.size, commits: all.first(MAX_COMMITS) }
      end
    end

    # The layer's own change: from its merge-base with the parent, so a
    # parent that moved on doesn't show reversed. Renames off, so a renamed
    # file's new path is listed as the diff body names it.
    def numstat(parent_sha, sha)
      GhStack.fact([@root, :layer_numstat, parent_sha, sha]) do
        out = @git.call(@root, "diff", "--numstat", "-z", "--no-renames", "#{parent_sha}...#{sha}", "--") || ""
        stat = { add: 0, del: 0, files: [] }
        out.split("\0").each do |record|
          add, del, file = record.split("\t", 3)
          next unless file

          stat[:add] += add.to_i
          stat[:del] += del.to_i
          stat[:files] << file
        end
        stat
      end
    end

    # sha → the first upstream (the trunk, then the lowest layer up) whose
    # own commits hold a patch-equivalent of it; only commits of this layer
    # appear. One `git cherry` per lower layer and the trunk.
    def also_in(parent_sha, sha, upstreams)
      upstreams.reverse.each_with_object({}) do |(name, upstream), also|
        next unless upstream

        cherry(upstream, sha, parent_sha).each { |commit| also[commit] = name }
      end
    end

    def cherry(upstream, sha, limit)
      GhStack.fact([@root, :layer_cherry, upstream, sha, limit]) do
        out = @git.call(@root, "cherry", upstream, sha, limit) || ""
        out.lines.filter_map { |line| line[/\A- (\h+)/, 1] }
      end
    end
  end
end
