# frozen_string_literal: true

module Quartermaster
  # The diff pane's "Since prompt" scope: what changed in the chat's worktree
  # since one of its session's prompts. The "before" is the tree the
  # UserPromptSubmit hook recorded (PromptSnapshots); the "now" is the same
  # worktree written as a tree the same way — through a throwaway copy of its
  # index, so the real index, refs and working tree stay untouched — and the
  # two trees are diffed like any other scope (UnifiedDiff).
  #
  # Work done elsewhere — a sub-agent's worktree — shows through the branches
  # that moved since the prompt, read from git's reflogs: each local branch of
  # the chat's repo with a reflog entry after the prompt, diffed from where it
  # stood at the prompt (or where it started, when created after it) to its
  # tip. Only commits: other worktrees' uncommitted work is out of reach.
  #
  # A rebase since the prompt (the chat's branch, or a moved branch, now
  # sitting on a newer base) would show every upstream change it brought in.
  # So the prompt's state is replayed onto the new base first — a three-way
  # merge-tree of the old base, the new base and the prompt's tree, which only
  # writes objects — and that is diffed instead, leaving the chat's own
  # changes. On by default; `rebase: false` shows the plain diff, and a replay
  # that conflicts falls back to it with a notice naming the files.
  #
  # The session is the chat's current one: the item's live session running in
  # its tmux pane, else any live one, else the newest. Nothing to show (no
  # snapshots yet, a pruned tree, a vanished worktree) is a "notice" beside an
  # empty file list, never an error, so the prompt picker stays usable.
  #
  # "oldRev" names the tree actually diffed from as a full sha — the
  # snapshot, or its replay onto the new base — for FileAtRevision; a
  # notice carries none.
  class PromptDiff
    def initialize(tmux: Tmux.new, session_log: SessionLog.new, snapshots: nil,
                   lineage: ->(pid) { Quartermaster.process_lineage(pid) }, project_map: ProjectMap.new)
      @tmux = tmux
      @project_map = project_map
      @session_log = session_log
      @snapshots = snapshots || PromptSnapshots.new(session_log: session_log)
      @lineage = lineage
    end

    # prompt: "<session id>:<n>", the n-th (1-based) snapshot of that session;
    # anything else — or a session that is no longer the chat's — means the
    # last prompt. moved: one of the listed moved branches to diff instead of
    # the chat's folder; anything else means the folder. rebase: whether to
    # hide what a rebase since the prompt brought in.
    def call(item, prompt: nil, moved: nil, rebase: true)
      session = chat_session(item)
      snapshots = session ? @snapshots.for_session(session.id) : []
      result = { "scope" => "prompt", "branches" => [], "session" => session&.id, "prompts" => prompt_list(session, snapshots),
                 "movedBranches" => [], "movedBranch" => nil, "files" => [], "truncated" => false,
                 "lineLimit" => BranchDiff::MAX_LINES }
      return result.merge(empty_notice(session)) if snapshots.empty?

      n = picked(session, snapshots, prompt)
      snapshot = snapshots[n - 1]
      path = snapshot["toplevel"] || snapshot["cwd"]
      result.merge!("prompt" => "#{session.id}:#{n}", "path" => path, "short" => Quartermaster.shorten_home(path.to_s),
                    "base" => { "ref" => base_label(snapshot), "kind" => "prompt", "sha" => snapshot["tree"] })
      branches = moved_branches(path, snapshot["at"])
      result["movedBranches"] = branches.map { |b| b.slice("branch", "commits") }
      branch = branches.find { |b| b["branch"] == moved }
      rebasing = { hide: rebase, root: @project_map.root_for(item.project) }
      branch ? moved_diff_into(result, path, branch, rebasing) : diff_into(result, path, snapshot, rebasing)
    end

    private

    def chat_session(item)
      sessions = Quartermaster.item_sessions(item, session_log: @session_log).select(&:captured?)
      live = sessions.select(&:live?)
      pane = @tmux.live?(item.slug) && @tmux.pane_pid(item.slug)
      (pane && live.find { |s| s.pid && @lineage.call(s.pid).include?(pane) }) || live.first || sessions.first
    end

    # The picker's entries, newest first.
    def prompt_list(session, snapshots)
      snapshots.each_with_index.map do |s, i|
        { "id" => "#{session.id}:#{i + 1}", "prompt" => s["prompt"], "at" => s["prompt_at"] || s["at"] }
      end.reverse
    end

    def picked(session, snapshots, prompt)
      id, n = prompt.to_s.split(":", 2)
      n = Integer(n.to_s, 10, exception: false)
      id == session.id && n&.between?(1, snapshots.size) ? n : snapshots.size
    end

    def empty_notice(session)
      return { "notice" => "This item has no captured chat session to diff from." } unless session

      { "notice" => "No prompt snapshots for this chat's session yet: they start with the next prompt once the " \
                    "snapshot hook is installed (qm install-hooks), and only in a git worktree." }
    end

    def base_label(snapshot)
      snapshot["prompt"] ? "before “#{snapshot["prompt"]}”" : "before the prompt at #{snapshot["at"]}"
    end

    def diff_into(result, path, snapshot, rebasing)
      before = snapshot["tree"]
      shown = Quartermaster.shorten_home(path.to_s)
      return result.merge("notice" => "#{shown} is gone — nothing to diff.") unless path && File.directory?(path)
      unless git(path, "cat-file", "-e", "#{before}^{tree}")
        return result.merge("notice" => "That prompt's snapshot is gone: git pruned it " \
                                        "(unreferenced objects go after about two weeks).")
      end

      now = tree_now(path)
      return result.merge("notice" => "Could not snapshot #{shown} as it is now.") unless now

      head = git(path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")&.strip
      branch = git(path, "symbolic-ref", "--quiet", "--short", "HEAD")&.strip
      before, rebase = unrebased(path, branch, head_at(path, snapshot["at"]), head, before, **rebasing)
      parser = UnifiedDiff.new(BranchDiff::MAX_LINES)
      files = parser.parse(git(path, "diff", "--no-color", "--no-ext-diff", "-M", before, now, "--") || "")
      result.merge("files" => files, "truncated" => parser.truncated, "oldRev" => before).merge(rebase)
    end

    # Where the worktree's HEAD stood at `at`: the newest entry of its own
    # HEAD reflog at or before it.
    def head_at(path, at)
      since = Time.iso8601(at.to_s).to_i
      reflogs(path, ["HEAD"]).fetch("HEAD", []).find { |_, t| t <= since }&.first
    rescue ArgumentError
      nil
    end

    # [the tree to diff from, payload keys]: `before` replayed onto the new
    # base when the branch (old_head → new_head) moved onto a newer one, and
    # hiding is on. No rebase: `before` and no keys. root: the item's project
    # root, where its gh-stack lives.
    def unrebased(path, branch, old_head, new_head, before, hide:, root:)
      move = old_head && new_head && old_head != new_head && base_move(path, branch, old_head, new_head, root)
      return [before, {}] unless move

      count = git(path, "rev-list", "--count", "#{move[:from]}..#{move[:to]}").to_i
      info = { "onto" => move[:ref], "commits" => count, "hidden" => false }
      return [before, { "rebase" => info }] unless hide

      tree, conflicts = replay(path, move[:from], move[:to], before)
      return [tree, { "rebase" => info.merge("hidden" => true) }] if tree

      files = conflicts.empty? ? "git merge-tree failed" : "#{conflicts.uniq.join(", ")} conflict"
      [before, { "rebase" => info, "rebaseNotice" => "Couldn't hide the rebase: #{files}." }]
    end

    # The base the branch sits on — its gh-stack parent, else the first trunk
    # ref — whose merge-base with the branch moved forward between old_head
    # and new_head: {ref, from, to}. A candidate that holds new_head (the
    # branch itself, or its commits landed there) says nothing about upstream.
    def base_move(path, branch, old_head, new_head, root)
      candidates(path, branch, root).each do |ref|
        from = git(path, "merge-base", ref, old_head)&.strip
        to = git(path, "merge-base", ref, new_head)&.strip
        next unless from && to && from != to && to != new_head
        next unless git(path, "merge-base", "--is-ancestor", from, to)

        return { ref: ref, from: from, to: to }
      end
      nil
    end

    def candidates(path, branch, root)
      parent = branch && root && File.directory?(root) && GhStack.for_root(root).parent_of(branch)
      refs = (parent ? [parent, "origin/#{parent}"] : []) + GitRepo::TRUNK_REFS
      refs.reject { |ref| branch && [branch, "origin/#{branch}"].include?(ref) }
          .select { |ref| git(path, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}") }
    end

    # `before` with the base's move (from → to) applied: [tree, conflicts].
    # merge-tree --write-tree writes objects only, never a ref, index or
    # worktree. A conflict gives [nil, paths]; any other failure [nil, []].
    def replay(path, from, to, before)
      out, _err, status = Open3.capture3(GIT_ENV, "git", "-c", "core.quotepath=off", "-C", path, "merge-tree",
                                         "--write-tree", "--name-only", "--no-messages", "--merge-base=#{from}", to, before)
      lines = out.force_encoding(Encoding::UTF_8).scrub("?").split("\n")
      return [lines.first, []] if status.success? && lines.first
      return [nil, []] unless status.exitstatus == 1

      [nil, lines.drop(1).take_while { |l| !l.empty? }]
    end

    # Every local branch whose reflog has an entry after `at`, most recently
    # moved first: {branch, commits, from, to}. `from` is the newest entry at
    # or before `at` — what `<branch>@{<at>}` resolves to — or, for a branch
    # created after `at`, its first entry (where it started). A branch
    # without a reflog never shows.
    def moved_branches(path, at)
      return [] unless path && File.directory?(path)

      since = Time.iso8601(at.to_s).to_i
      refs = (git(path, "for-each-ref", "--format=%(refname)", "refs/heads") || "").split("\n")
      return [] if refs.empty?

      reflogs(path, refs).filter_map do |ref, entries|
        next unless entries.first[1] > since

        from = (entries.find { |_, t| t <= since } || entries.last)[0]
        to = git(path, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")&.strip
        next unless to

        count = git(path, "rev-list", "--count", "#{from}..#{to}").to_i
        { "branch" => ref.delete_prefix("refs/heads/"), "commits" => count, "from" => from, "to" => to,
          "moved" => entries.first[1] }
      end.sort_by { |b| -b["moved"] }
    rescue ArgumentError
      []
    end

    # ref → [[sha, unix time], …], newest first: every branch's reflog in one
    # walk. Git itself skips refs without a reflog.
    def reflogs(path, refs)
      log = git(path, "log", "--walk-reflogs", "--date=unix", "--format=%H %gD", *refs) || ""
      log.each_line.with_object({}) do |line, logs|
        sha, selector = line.strip.split(" ", 2)
        ref, _, time = selector.to_s.rpartition("@{")
        time = Integer(time.delete_suffix("}"), 10, exception: false)
        (logs[ref] ||= []) << [sha, time] if time && refs.include?(ref)
      end
    end

    def moved_diff_into(result, path, branch, rebasing)
      name = branch["branch"]
      before, rebase = unrebased(path, name, branch["from"], branch["to"], "#{branch["from"]}^{tree}", **rebasing)
      parser = UnifiedDiff.new(BranchDiff::MAX_LINES)
      files = parser.parse(git(path, "diff", "--no-color", "--no-ext-diff", "-M", before, branch["to"], "--") || "")
      result.merge("movedBranch" => name, "branch" => name, "files" => files, "truncated" => parser.truncated,
                   "oldRev" => git(path, "rev-parse", "--verify", "--quiet", before)&.strip,
                   "base" => { "ref" => "#{name} at the prompt", "kind" => "prompt-branch", "sha" => branch["from"] })
            .merge(rebase)
    end

    # The worktree as a tree object, written the way hooks/snapshot-worktree.sh
    # does: tracked and untracked files, ignored ones left out.
    def tree_now(path)
      index = git(path, "rev-parse", "--path-format=absolute", "--git-path", "index")&.strip
      return nil unless index

      Dir.mktmpdir("qm-prompt-diff") do |dir|
        tmp = File.join(dir, "index")
        FileUtils.cp(index, tmp) if File.file?(index)
        env = { "GIT_INDEX_FILE" => tmp }
        git(path, "add", "-A", env: env) && git(path, "write-tree", env: env)&.strip
      end
    rescue SystemCallError
      nil
    end

    # Unstripped and scrubbed so the payload always serializes; nil on failure.
    GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil }.freeze

    def git(path, *args, env: {})
      env = GIT_ENV.merge(env)
      out, _err, status = Open3.capture3(env, "git", "-c", "core.quotepath=off", "-C", path, *args)
      status.success? ? out.force_encoding(Encoding::UTF_8).scrub("?") : nil
    end
  end
end
