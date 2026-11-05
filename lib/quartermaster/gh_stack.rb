# frozen_string_literal: true

module Quartermaster
  # The stacks the gh-stack extension records in a repo's common git dir
  # (`<repo>/.git/gh-stack`, shared by every worktree). Read-only: gh-stack
  # owns the file. A missing, unreadable or unfamiliar file reads as "no
  # stacks" — qm must keep working whatever the extension does next.
  class GhStack
    Entry = Struct.new(:branch, :pr_number, :pr_url, keyword_init: true) do
      def to_h = { "branch" => branch, "pr_number" => pr_number, "pr_url" => pr_url }
    end

    # One stack's entries, bottom → top, plus the trunk gh-stack recorded for
    # it (nil when the file names none).
    class Stack < Array
      attr_reader :trunk

      def initialize(entries, trunk = nil)
        super(entries)
        @trunk = trunk
      end
    end

    FILE_NAME = "gh-stack"

    # A state build asks once per item; the git call and the JSON parse are
    # paid once per repo and again only when the file's mtime moves.
    COMMON_DIRS = {}
    PARSED = {}
    CACHE_MUTEX = Mutex.new

    def self.for_root(root)
      path = file_for(root)
      mtime = path && File.exist?(path) ? File.mtime(path) : nil
      return new([]) unless mtime

      CACHE_MUTEX.synchronize do
        cached = PARSED[path]
        return cached[:stack] if cached && cached[:mtime] == mtime

        stack = new(parse(File.read(path)))
        PARSED[path] = { mtime: mtime, stack: stack }
        stack
      end
    rescue StandardError => e
      Quartermaster.log_error("gh-stack", e)
      new([])
    end

    # A root that isn't a git repo is cached too (as false), or every state
    # build would spawn git once per item of that project.
    def self.file_for(root)
      common = CACHE_MUTEX.synchronize { COMMON_DIRS[root] }
      if common.nil?
        out = Quartermaster.git(root, "rev-parse", "--git-common-dir")
        common = out ? File.expand_path(out, root) : false
        CACHE_MUTEX.synchronize { COMMON_DIRS[root] = common }
      end
      common ? File.join(common, FILE_NAME) : nil
    end

    # Bottom → top, as gh-stack stores them. Anything not shaped like a
    # stack of named branches is skipped rather than trusted.
    def self.parse(json)
      data = JSON.parse(json)
      return [] unless data.is_a?(Hash) && data["stacks"].is_a?(Array)

      data["stacks"].filter_map do |stack|
        next unless stack.is_a?(Hash) && stack["branches"].is_a?(Array)

        entries = stack["branches"].filter_map do |b|
          next unless b.is_a?(Hash) && b["branch"].is_a?(String) && !b["branch"].empty?

          pr = b["pullRequest"].is_a?(Hash) ? b["pullRequest"] : {}
          Entry.new(branch: b["branch"], pr_number: pr["number"], pr_url: pr["url"])
        end
        trunk = stack["trunk"]["branch"] if stack["trunk"].is_a?(Hash) && stack["trunk"]["branch"].is_a?(String)
        entries.empty? ? nil : Stack.new(entries, trunk)
      end
    rescue JSON::ParserError
      []
    end

    # What a state build (GUI payload, `qm show`) calls per item: auto-link
    # the item's stack branches, then hand back that stack (bottom → top) or
    # nil. Never raises — a stack panel is not worth a failed page load.
    def self.sync(item, project_map: ProjectMap.new)
      root = project_map.root_for(item.project)
      return nil unless root && File.directory?(root)

      stacks = for_root(root)
      stacks.link_into(item)
      stacks.stack_for(item.branches)
    rescue StandardError => e
      Quartermaster.log_error("gh-stack-sync", e)
      nil
    end

    # The item's branches as chains, each a hash the GUI state
    # payload carries as is: every stack holding one of them, newest-linked
    # first, then each other non-mainline branch alone ("loose"),
    # newest-linked first. `pr_states`: branch → PR state, and `pr_links`:
    # branch → {"number", "url"}, as PrStatus has them. Never raises; []
    # without a repo.
    def self.chains(item, project_map: ProjectMap.new, pr_states: {}, pr_links: {}, git: Quartermaster.method(:git))
      root = project_map.root_for(item.project)
      return [] unless root && File.directory?(root)

      path = file_for(root)
      refs = path && RefTips.new(File.dirname(path), root, git)
      for_root(root).chains(item.branches, root: root, refs: refs, pr_states: pr_states, pr_links: pr_links, git: git)
    rescue StandardError => e
      Quartermaster.log_error("gh-stack-chains", e)
      []
    end

    # The layer facts git answers, keyed on the tip shas involved: an
    # unchanged repo answers from here without spawning git. Bounded, since
    # every new tip pair adds a key.
    FACTS = {}
    FACTS_LIMIT = 5_000

    def self.fact(key)
      CACHE_MUTEX.synchronize { return FACTS[key] if FACTS.key?(key) }
      value = yield
      CACHE_MUTEX.synchronize do
        FACTS.clear if FACTS.size >= FACTS_LIMIT
        FACTS[key] = value
      end
    end

    # Tip shas of local and origin branches, read straight from the common
    # git dir (loose ref files, then packed-refs, parsed once per mtime and
    # size), so a state build spawns no git for them. A reftable repo has
    # neither and asks git instead.
    class RefTips
      PACKED = {}
      SHA = /\A\h{40}(\h{24})?\z/

      def initialize(common_dir, root, git)
        @common = common_dir
        @root = root
        @git = git
      end

      # [ref, sha] for the first of the refs that exists, else nil.
      def first(*refs)
        refs.each do |ref|
          sha = sha_for(ref)
          return [ref, sha] if sha
        end
        nil
      end

      def sha_for(ref)
        full = ref.start_with?("origin/") ? "refs/remotes/#{ref}" : "refs/heads/#{ref}"
        return @git.call(@root, "rev-parse", "--verify", "--quiet", "#{full}^{commit}") if reftable?

        loose(full) || packed[full]
      end

      private

      def reftable? = File.directory?(File.join(@common, "reftable"))

      def loose(full)
        path = File.join(@common, full)
        return nil unless File.file?(path)

        sha = File.read(path).strip
        sha.match?(SHA) ? sha : nil
      rescue SystemCallError
        nil
      end

      def packed
        path = File.join(@common, "packed-refs")
        stat = File.stat(path)
        key = [stat.mtime, stat.size]
        cached = CACHE_MUTEX.synchronize { PACKED[path] }
        return cached[:refs] if cached && cached[:key] == key

        refs = File.foreach(path).each_with_object({}) do |line, map|
          sha, name = line.split(" ", 2)
          map[name.strip] = sha if name && sha.match?(SHA)
        end
        CACHE_MUTEX.synchronize { PACKED[path] = { key: key, refs: refs } }
        refs
      rescue SystemCallError
        {}
      end
    end

    attr_reader :stacks

    def initialize(stacks)
      @stacks = stacks
    end

    def chains(branches, root:, refs:, pr_states: {}, pr_links: {}, git: Quartermaster.method(:git))
      own = branches - WorkItem::MAINLINE_BRANCHES
      newest = ->(stack) { stack.map { |e| own.index(e.branch) || -1 }.max }
      stacks = stacks_for(own).each_with_index.sort_by { |stack, i| [-newest.call(stack), i] }.map(&:first)
      stacked = stacks.flat_map { |stack| stack.map(&:branch) }
      trunk = default_trunk(refs)
      stacks.map { |stack| stack_chain(stack, root, refs, pr_states, pr_links, git) } +
        (own.reverse - stacked).map do |branch|
          state = pr_states[branch]
          link = pr_links[branch] || {}
          { "kind" => "loose", "trunk" => trunk,
            "layers" => [{ "branch" => branch, "pr_number" => link["number"], "pr_url" => link["url"],
                           "prState" => state, "merged" => state == "MERGED" }] }
        end
    end

    # Layer facts. ahead counts parent..branch; needsRestack
    # (the parent's tip is not in the branch) is checked only above another
    # stack branch — the trunk always moves, so the bottom is never flagged.
    # merged is the PR's word: a squash merge leaves nothing in git to tell.
    # Branches resolve locally, else from origin; the trunk from origin
    # first, as the diff pane's base does. A PR gh-stack hasn't recorded
    # comes from PrStatus.
    def stack_chain(stack, root, refs, pr_states, pr_links, git)
      trunk = stack.trunk || default_trunk(refs)
      layers = stack.each_with_index.map do |entry, i|
        parent = i.zero? ? trunk : stack[i - 1].branch
        parent_refs = i.zero? ? ["origin/#{parent}", parent] : [parent, "origin/#{parent}"]
        parent_sha = refs&.first(*parent_refs)&.last
        sha = refs&.first(entry.branch, "origin/#{entry.branch}")&.last
        state = pr_states[entry.branch]
        link = entry.pr_number ? {} : pr_links[entry.branch] || {}
        { "branch" => entry.branch, "pr_number" => entry.pr_number || link["number"],
          "pr_url" => entry.pr_url || link["url"],
          "prState" => state, "parent" => parent,
          "ahead" => parent_sha && sha ? ahead(root, parent_sha, sha, git) : nil,
          "needsRestack" => !i.zero? && parent_sha && sha ? !ancestor?(root, parent_sha, sha, git) : false,
          "merged" => state == "MERGED" }
      end
      { "kind" => "stack", "trunk" => trunk, "layers" => layers }
    end

    def default_trunk(refs)
      found = refs&.first(*GitRepo::TRUNK_REFS)
      found ? found.first.delete_prefix("origin/") : "main"
    end

    # Every stack holding any of these branches, in stack-file order.
    def stacks_for(branches)
      @stacks.select { |stack| stack.any? { |e| branches.include?(e.branch) } }
    end

    # The branch just below this one in its stack; nil for the bottom branch
    # (whose parent is trunk) or one in no stack.
    def parent_of(branch)
      stack = stacks_for([branch]).first
      index = stack&.index { |e| e.branch == branch }
      index&.positive? ? stack[index - 1].branch : nil
    end

    # The stack an item works on: the one holding its most recently linked
    # stacked branch (an item can straddle two stacks after a re-stack).
    def stack_for(branches)
      branches.reverse_each do |branch|
        found = @stacks.find { |stack| stack.any? { |e| e.branch == branch } }
        return found if found
      end
      nil
    end

    def ahead(root, from, to, git)
      GhStack.fact([root, :ahead, from, to]) { git.call(root, "rev-list", "--count", "#{from}..#{to}")&.to_i }
    end

    # git exits 1 for "no" and on errors alike; with shas we resolved
    # ourselves an error is unlikely enough to read as "no".
    def ancestor?(root, older, newer, git)
      GhStack.fact([root, :ancestor, older, newer]) { !git.call(root, "merge-base", "--is-ancestor", older, newer).nil? }
    end

    # Links every branch of the item's stacks to it. Cheap and write-free when
    # nothing is missing; WorkItem#link_branches re-checks under the lock, so
    # racing callers can't duplicate. Returns the branches added.
    def link_into(item)
      missing = stacks_for(item.branches).flatten.map(&:branch).uniq - item.branches
      return [] if missing.empty?

      item.link_branches(missing)
    end
  end
end
