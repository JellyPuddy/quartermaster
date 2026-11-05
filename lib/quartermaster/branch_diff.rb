# frozen_string_literal: true

module Quartermaster
  # What an item's branch changes, for the chat view's diff pane. Read-only
  # git in the branch's worktree (a ref-only branch's: the project root) —
  # never a checkout or a fetch.
  #
  # Branch: the one checked out where the item's chat runs (its tmux pane,
  # else where a new chat would start), or one of the item's linked branches
  # that has a worktree, or — "checkout" false — one that has none but exists
  # as a ref (refs/heads/<b>, else origin/<b>). A ref-only branch is read
  # from the project root against that ref where a checkout uses HEAD, never
  # from the root's working tree or index: its "branch" scope is committed
  # work only, and "uncommitted" (and the prompt scope, require_checkout)
  # are refused. Base: the branch's gh-stack parent when it sits in a
  # stack above another branch, else its merge-base with the first trunk ref
  # that exists (GitRepo::TRUNK_REFS). Scope "branch" is base → working tree,
  # so uncommitted and untracked work shows too; "commits" is base → HEAD,
  # committed work only (what the PR shows), optionally narrowed to a
  # contiguous run of the branch's commits; "uncommitted" is HEAD → working
  # tree only. In "branch" each line and file also says whether it is
  # committed yet (UncommittedMarks). "pr" is the branch's open pull request
  # as GitHub diffs it (PrRevisions: its fetched head against the merge-base
  # with origin/<base>), with the PR's commits to narrow it like "commits";
  # a Review item always has it — its own PR, even with no worktree — and
  # opens on it.
  #
  # Every payload names its old side as diffed in "oldRev", a full sha (the
  # base, HEAD, the selected run's parent or the PR's merge-base): the pane
  # reads unchanged lines around a hunk from it (FileAtRevision), since
  # context is the same on both sides and the old side is always in git.
  class BranchDiff
    SCOPES = %w[branch commits uncommitted pr].freeze
    MAX_COMMITS = 200
    SHA = /\A\h{4,64}\z/
    MAX_LINES = 20_000
    MAX_UNTRACKED = 200
    MAX_UNTRACKED_BYTES = 1_000_000

    def initialize(project_map: ProjectMap.new, tmux: Tmux.new, launcher: nil, runner: CommandRunner.new, pr_revisions: nil)
      @project_map = project_map
      @tmux = tmux
      @launcher = launcher || Launcher.new(project_map: project_map)
      @pr_revisions = pr_revisions || PrRevisions.new(runner: runner)
    end

    # from/to (commits and pr scopes): abbreviated or full shas of commits in
    # base..HEAD (the PR's commits), from at or before to; one alone means
    # that one commit. fresh (pr scope): look the PR up and fetch it anew
    # rather than reuse what PrRevisions' memo remembers.
    #
    # base (branch and commits scopes): a lower branch of the diffed one's
    # stack, or that stack's trunk, to diff the span of layers from there
    # instead of from the stack parent; anything else is ignored.
    def call(item, branch: nil, scope: nil, from: nil, to: nil, fresh: false, base: nil)
      review = @pr_revisions.review?(item)
      scope = review ? "pr" : "branch" if scope.nil? || scope.empty?
      raise ArgumentError, "scope must be one of: #{SCOPES.join(", ")}" unless SCOPES.include?(scope)

      root = @project_map.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root && File.directory?(root)

      GhStack.for_root(root).link_into(item)
      choices = choices_for(item, root)
      # A Review item's PR needs no worktree: the main checkout fetches it.
      choice = scope == "pr" && review && choices.empty? && branch.to_s.empty? ? nil : pick(choices, branch, item)
      path, branch = choice ? choice.values_at("path", "branch") : [root, nil]
      checkout = choice ? choice["checkout"] : false
      refuse_without_checkout(branch, scope) unless checkout
      head = checkout ? "HEAD" : choice && ref_head(root, choice)
      parser = UnifiedDiff.new(MAX_LINES)
      result = { "branch" => branch, "path" => path, "short" => Quartermaster.shorten_home(path), "scope" => scope,
                 "checkout" => checkout,
                 "branches" => choices.map { |c| c.merge("short" => Quartermaster.shorten_home(c["path"])) } }
      repo = Quartermaster.github_repo(root)
      result.merge!(layers_for(root, branch)) unless scope == "uncommitted"
      if scope == "pr"
        result.merge!(pr_scope(item, repo, path, branch, from, to, parser, fresh))
        return result.merge("prAvailable" => true, "truncated" => parser.truncated, "lineLimit" => MAX_LINES)
      end

      base =
        if scope == "uncommitted" then { "ref" => "HEAD", "kind" => "head" }
        else span_base(root, path, branch, head, base) || base_for(root, path, branch, head)
        end
      result.merge!("base" => base, "prAvailable" => !@pr_revisions.find(item, repo, branch, cached_only: true).nil?)
      files =
        case scope
        when "branch"
          result["oldRev"] = base["sha"]
          checkout ? branch_files(path, base["sha"], parser) : parser.parse(committed_diff(path, base["sha"], head))
        when "uncommitted"
          result["oldRev"] = git(path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}")
          parser.parse(working_tree_diff(path, "HEAD", untracked_diff(path)))
        else
          commits = branch_commits(path, base["sha"], head)
          range = commit_range(path, commits, from, to)
          result.merge!("commits" => commits.last(MAX_COMMITS), "commitCount" => commits.size, "range" => range,
                        "messages" => commit_messages(path, commits, range))
          result["oldRev"] = range ? parent_of(path, range["from"]) : base["sha"]
          parser.parse(committed_diff(path, result["oldRev"], range ? range["to"] : head))
        end
      result.merge("files" => files, "truncated" => parser.truncated, "lineLimit" => MAX_LINES)
    end

    # The branch `call` would show (BranchStats measures it): its checkout or
    # the project root, the ref naming it, its tip as a sha and the same base.
    def tip(item, branch: nil)
      root = @project_map.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root && File.directory?(root)

      GhStack.for_root(root).link_into(item)
      choice = pick(choices_for(item, root), branch, item)
      raise ArgumentError, "no branch to measure: #{Quartermaster.shorten_home(choice["path"])} is detached" unless choice["branch"]

      path = choice["path"]
      head = choice["checkout"] ? git(path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}") : ref_head(root, choice)
      raise ArgumentError, "#{choice["branch"]} has no commits yet" unless head

      { "root" => root, "path" => path, "branch" => choice["branch"], "ref" => choice["ref"] || choice["branch"],
        "head" => head, "base" => base_for(root, path, choice["branch"], head) }
    end

    # The top of the checkout the item's chat runs in (or would start in), or
    # nil when that is no git checkout.
    def chat_checkout(item) = checkout_root(chat_cwd(item))

    # The branch checked out where the item's chat runs, or nil (detached
    # HEAD, or no git checkout).
    def chat_branch(item)
      path = chat_checkout(item)
      path && git(path, "symbolic-ref", "--quiet", "--short", "HEAD")
    end

    # The prompt scope (PromptDiff) diffs the chat's folder, which is no
    # ref-only branch's: refused when the requested branch is one.
    def require_checkout(item, branch)
      return if branch.to_s.empty?

      root = @project_map.root_for(item.project)
      return unless root && File.directory?(root)

      choice = choices_for(item, root).find { |c| c["branch"] == branch }
      refuse_without_checkout(branch, "prompt") if choice && !choice["checkout"]
    end

    private

    def choices_for(item, root)
      chat_path = chat_checkout(item)
      chat_branch = chat_path && git(chat_path, "symbolic-ref", "--quiet", "--short", "HEAD")
      branch_choices(item, root, chat_path, chat_branch)
    end

    def refuse_without_checkout(branch, scope)
      return unless %w[uncommitted prompt].include?(scope)

      raise ArgumentError, "#{branch || "this item"} is not checked out anywhere: Uncommitted and Since prompt need a checkout"
    end

    # A ref-only branch's tip, resolved once per load so every git call of
    # it reads the same commit.
    def ref_head(root, choice)
      full = choice["ref"] == choice["branch"] ? "refs/heads/#{choice["branch"]}" : "refs/remotes/origin/#{choice["branch"]}"
      git(root, "rev-parse", "--verify", "--quiet", "#{full}^{commit}") ||
        raise(ArgumentError, "#{choice["ref"]} no longer names a commit")
    end

    # Where the item's chat runs: its live pane's directory, else where a new
    # chat would start.
    def chat_cwd(item)
      (@tmux.live?(item.slug) && @tmux.pane_path(item.slug)) || @launcher.start_cwd(item)
    end

    def checkout_root(cwd)
      cwd && git(cwd, "rev-parse", "--show-toplevel")
    end

    # The chat's checkout first, then the item's other linked branches that
    # have a worktree, newest link first, then those that have none but
    # exist as a ref, newest link first.
    def branch_choices(item, root, chat_path, chat_branch)
      worktrees = Quartermaster.branch_worktrees(root).select { |_b, path| File.directory?(path) }
      choices = []
      if chat_path && in_repo?(chat_path, root)
        choices << { "branch" => chat_branch, "path" => chat_path, "chat" => true, "checkout" => true }
      end
      item.branches.reverse_each do |b|
        next unless worktrees[b]
        next if choices.any? { |c| c["branch"] == b }

        choices << { "branch" => b, "path" => worktrees[b], "chat" => false, "checkout" => true }
      end
      item.branches.reverse_each do |b|
        next if choices.any? { |c| c["branch"] == b }
        next unless (ref = branch_ref(root, b))

        choices << { "branch" => b, "path" => root, "chat" => false, "checkout" => false, "ref" => ref }
      end
      choices
    end

    # The branch's local ref, else its origin one, as git names it short.
    def branch_ref(root, branch)
      return branch if ref?(root, "refs/heads/#{branch}")

      "origin/#{branch}" if ref?(root, "refs/remotes/origin/#{branch}")
    end

    # A requested branch, else the newest linked issue/ branch with a
    # checkout, else the first checkout, and only without any checkout the
    # first ref-only branch.
    def pick(choices, branch, item)
      if branch && !branch.empty?
        choice = choices.find { |c| c["branch"] == branch }
        raise ArgumentError, "#{branch} is not a linked branch of this item with a worktree or a ref" unless choice

        return choice
      end
      checkouts = choices.select { |c| c["checkout"] }
      choice = newest_issue_branch(checkouts, item) || checkouts.first || choices.first
      raise ArgumentError, "nothing to diff: no linked branch of the item is checked out anywhere or exists as a ref" unless choice

      choice
    end

    # The item's most recently linked issue/... branch that has a worktree,
    # the chat's own one included.
    def newest_issue_branch(choices, item)
      issue_branches = item.branches.select { |b| b.start_with?("issue/") }
      choices.select { |c| issue_branches.include?(c["branch"]) }
             .max_by { |c| issue_branches.index(c["branch"]) }
    end

    # A chat started outside the project's repo (home, another repo) has no
    # diff worth showing against this repo's trunk.
    def in_repo?(path, root)
      common = ->(dir) { (out = git(dir, "rev-parse", "--git-common-dir")) && File.realpath(File.expand_path(out, dir)) }
      common.call(path) == common.call(root)
    rescue SystemCallError
      false
    end

    def base_for(root, path, branch, head)
      parent = branch && GhStack.for_root(root).parent_of(branch)
      parent_ref = parent && [parent, "origin/#{parent}"].find { |ref| ref?(path, ref) }
      if parent_ref && (sha = git(path, "merge-base", parent_ref, head))
        return { "ref" => parent_ref, "kind" => "stack", "sha" => sha }
      end

      trunk = GitRepo.new(path).trunk_refs.first
      raise ArgumentError, "no base to diff against: none of #{GitRepo::TRUNK_REFS.join(", ")} exists" unless trunk

      sha = git(path, "merge-base", trunk, head)
      raise ArgumentError, "#{branch || "HEAD"} shares no history with #{trunk}" unless sha

      { "ref" => trunk, "kind" => "trunk", "sha" => sha }
    end

    # A stack span (docs/areas/diff.md): `base` names a branch below this one in its
    # stack — resolved local first — or the stack's trunk — origin first, as
    # the trunk base is — and the diff runs from its merge-base with the
    # branch. nil (ignored) for anything else.
    def span_base(root, path, branch, head, base)
      return nil if base.to_s.empty? || branch.nil?

      stack = GhStack.for_root(root).stacks_for([branch]).first
      return nil unless stack

      names = stack.map(&:branch)
      below = names.index(base)
      trunk = stack.trunk || GitRepo.new(path).trunk_refs.first&.delete_prefix("origin/")
      refs =
        if below && below < names.index(branch) then [base, "origin/#{base}"]
        elsif base == trunk then ["origin/#{base}", base]
        end
      ref = refs&.find { |r| ref?(path, r) }
      sha = ref && git(path, "merge-base", ref, head)
      sha && { "ref" => ref, "kind" => "stack-span", "branch" => base, "sha" => sha }
    end

    # The stack's layers and which of them touch each file (StackLayers),
    # for a branch in a stack; nothing otherwise.
    def layers_for(root, branch)
      layers = StackLayers.new(root, git: method(:raw_git)).call(branch)
      return {} unless layers

      { "layers" => layers["layers"], "layerTrunk" => layers["trunk"], "fileLayers" => layers["fileLayers"] }
    end

    def ref?(path, ref) = !git(path, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}").nil?

    # The PR's diff, commits and selected run as the "commits" scope serves
    # the branch's. `anchor` is the commit a review comment on this view
    # anchors to: the run's last commit (GitHub has no range anchor), else
    # the PR's head.
    def pr_scope(item, repo, path, branch, from, to, parser, fresh)
      pr = @pr_revisions.find(item, repo, branch, fresh: fresh)
      raise ArgumentError, "#{branch || "this item"} has no open pull request" unless pr
      unless repo.to_s.casecmp?(pr["repo"].to_s)
        raise ArgumentError, "#{pr["url"]} is not in this project's repo (its origin is #{repo || "unknown"})"
      end

      revs = @pr_revisions.fetch(path, pr, fresh: fresh)
      head = revs["headSha"]
      commits = branch_commits(path, revs["baseSha"], head)
      range = commit_range(path, commits, from, to)
      from_sha = range ? parent_of(path, range["from"]) : revs["baseSha"]
      files = parser.parse(committed_diff(path, from_sha, range ? range["to"] : head, ReviewAnchors::GITHUB_HUNKS))
      mark_unanchorable(path, revs["baseSha"], range["to"], from_sha, files) if range
      { "reviewRoutes" => review_routes(item, path, pr, revs),
        "base" => { "ref" => revs["baseRef"], "kind" => "pr", "sha" => revs["baseSha"] },
        "pr" => { "repo" => pr["repo"], "number" => pr["number"], "url" => pr["url"], "title" => pr["title"],
                  "headSha" => head, "baseSha" => revs["baseSha"] },
        "commits" => commits.last(MAX_COMMITS), "commitCount" => commits.size, "range" => range,
        "messages" => commit_messages(path, commits, range), "anchor" => range ? range["to"] : head,
        "oldRev" => from_sha, "files" => files }
    end

    # Where each of the item's GitHub drafts on this PR would post now
    # (ReviewPlan), re-anchoring the ones a push moved: what the pane needs
    # to show outdated drafts as cards (D10, D11). Local git only.
    def review_routes(item, path, pr, revs)
      drafts = Drafts.new(item.slug)
      entries = drafts.entries.select do |entry|
        entry["kind"] == "github-comment" && entry["repo"].to_s.casecmp?(pr["repo"].to_s) && entry["number"] == pr["number"].to_i
      end
      return {} if entries.empty?

      PendingReview.reanchor(ReviewPlan.new(path, base_ref: revs["baseRef"], head: revs["headSha"]), entries, drafts)
    end

    # A selected run shows parent(from)..to, but GitHub takes a comment
    # anchored to `to` only on lines of base..to (F1): each shown line it
    # won't take gets "gh" => false, so the editor can say so before saving
    # (D8). The whole PR's view is base..head itself, so it needs no marks.
    def mark_unanchorable(path, base, commit, view_base, files)
      anchors = ReviewAnchors.new(path, base: base, commit: commit)
      files.each do |file|
        file["hunks"].each do |hunk|
          hunk["lines"].each do |line|
            side, number = line["t"] == "-" ? ["old", line["o"]] : ["new", line["n"]]
            line["gh"] = false unless anchors.anchorable?(file["path"], side, number, line["s"], view_base: view_base)
          end
        end
      end
    end

    # Every commit in base..head, oldest first, with its lines added and
    # removed (0 for a merge, whose log shows no diff).
    def branch_commits(path, base, head = "HEAD")
      out = raw_git(path, "log", "--reverse", "--shortstat", "--format=%x1e%H%x1f%h%x1f%cI%x1f%s", "#{base}..#{head}") || ""
      out.split("\x1e").filter_map do |record|
        line, stat = record.split("\n", 2)
        sha, short, time, subject = line.to_s.strip.split("\x1f", 4)
        next unless sha

        { "sha" => sha, "short" => short, "time" => time, "subject" => subject.to_s,
          "add" => stat.to_s[/(\d+) insertion/, 1].to_i, "del" => stat.to_s[/(\d+) deletion/, 1].to_i }
      end
    end

    # The selected run of commits, or nil for all of them. Only shas naming
    # commits of this branch get through: nothing else reaches a diff.
    def commit_range(path, commits, from, to)
      from = from.to_s.strip
      to = to.to_s.strip
      return nil if from.empty? && to.empty?

      from = to if from.empty?
      to = from if to.empty?
      first, last = [from, to].map do |sha|
        raise ArgumentError, "#{sha.inspect} is not a commit sha" unless SHA.match?(sha)

        full = git(path, "rev-parse", "--verify", "--quiet", "#{sha}^{commit}")
        commits.find { |c| c["sha"] == full } || raise(ArgumentError, "#{sha} is not a commit of this branch")
      end
      unless first == last || raw_git(path, "merge-base", "--is-ancestor", first["sha"], last["sha"])
        raise ArgumentError, "#{first["short"]} does not come before #{last["short"]}"
      end

      label = first == last ? first["short"] : "#{first["short"]}..#{last["short"]}"
      { "from" => first["sha"], "to" => last["sha"], "label" => label }
    end

    # The full message of each commit in the selected run, oldest first; none
    # without a selection. One `git show` for the run, its records split on
    # control characters a commit message doesn't carry.
    def commit_messages(path, commits, range)
      return [] unless range

      first = commits.index { |c| c["sha"] == range["from"] }
      last = commits.index { |c| c["sha"] == range["to"] }
      shas = commits[first..last].map { |c| c["sha"] }
      out = raw_git(path, "show", "-s", "--format=%H%x1f%h%x1f%an%x1f%aI%x1f%B%x1e", *shas) || ""
      out.split("\x1e").filter_map do |record|
        sha, short, author, date, body = record.sub(/\A\n+/, "").split("\x1f", 5)
        { "sha" => sha, "short" => short, "author" => author, "date" => date, "body" => body.to_s.rstrip } if body
      end
    end

    # A root commit's changes are everything it adds to the empty tree.
    def parent_of(path, sha)
      git(path, "rev-parse", "--verify", "--quiet", "#{sha}^") || git(path, "hash-object", "-t", "tree", "/dev/null")
    end

    def committed_diff(path, from, to, *options)
      raw_git(path, "diff", "--no-color", "--no-ext-diff", "-M", *options, from, to, "--") || ""
    end

    # Base → working tree, each line marked by whether it is committed yet
    # (UncommittedMarks): base → HEAD and HEAD → working tree tell, the
    # untracked files read once for both working-tree diffs.
    def branch_files(path, base, parser)
      untracked = untracked_diff(path)
      files = parser.parse(working_tree_diff(path, base, untracked))
      committed = UnifiedDiff.parse(committed_diff(path, base, "HEAD"), max_lines: MAX_LINES)
      uncommitted = UnifiedDiff.parse(working_tree_diff(path, "HEAD", untracked), max_lines: MAX_LINES)
      UncommittedMarks.apply(files, committed: committed, uncommitted: uncommitted)
    end

    # Tracked changes against `from`, then the untracked files.
    def working_tree_diff(path, from, untracked)
      (raw_git(path, "diff", "--no-color", "--no-ext-diff", "-M", from, "--") || "") + untracked
    end

    # Every untracked (not ignored) file as an added one.
    def untracked_diff(path)
      untracked = (raw_git(path, "ls-files", "--others", "--exclude-standard", "-z") || "").split("\0")
      untracked.first(MAX_UNTRACKED).filter_map do |file|
        full = File.join(path, file)
        next unless File.file?(full) && File.size(full) <= MAX_UNTRACKED_BYTES

        raw_git(path, "diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", file, ok: [0, 1])
      end.join
    end

    def git(path, *args) = Quartermaster.git(path, *args)

    # Unstripped, and with invalid bytes scrubbed so the payload always
    # serializes. `ok`: the exit statuses that still mean an answer
    # (`diff --no-index` exits 1 when the files differ).
    def raw_git(path, *args, ok: [0])
      out, _err, status = Open3.capture3("git", "-c", "core.quotepath=off", "-C", path, *args)
      ok.include?(status.exitstatus) ? out.force_encoding(Encoding::UTF_8).scrub("?") : nil
    end
  end
end
