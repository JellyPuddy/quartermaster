# frozen_string_literal: true

module Quartermaster
  # Worktree hygiene (docs/areas/worktrees.md): plan which worktrees, test
  # databases and local branches can go, then remove the chosen ones.
  #
  # The plan is data a checklist renders: one Entry per worktree or branch,
  # with a status (ok / warn / blocked), the reasons for it, and whether it
  # starts ticked. Only ok entries start ticked. A warn entry (dirty,
  # untracked files, commits found nowhere else) runs only when the caller
  # forces it by id; a blocked one (the dev server serves it, a live session sits in it,
  # git has it locked, it is checked out somewhere that stays) never runs.
  #
  # Plan with #plan_item (one item's worktrees and branches) or #plan_sweep
  # (every .claude/worktrees worktree and worktree-* branch of every known
  # repo), then #execute. Both also list issue drafts (IssueDrafts): an item's
  # own, or in a sweep every set whose item is resolved or gone. One created on GitHub
  # is ok; one never created is a warn, so it needs force; never blocked. Execution
  # trusts the plan's checks: a caller showing the plan re-plans right before. Remotes are never touched.
  class Cleanup
    Entry = Struct.new(:id, :kind, :repo, :path, :branch, :item, :status, :reasons, :notes,
                       :ticked, :db_names, :db_status, :requires, :title, keyword_init: true) do
      def worktree? = kind == "worktree"
      def branch? = kind == "branch"
      def issue_draft? = kind == "issue-draft"
      def ok? = status == "ok"
      def warn? = status == "warn"
      def blocked? = status == "blocked"
      def gone? = worktree? && !File.directory?(path)

      def to_h
        { "id" => id, "kind" => kind, "repo" => repo, "path" => path, "branch" => branch, "item" => item,
          "status" => status, "reasons" => reasons, "notes" => notes, "ticked" => ticked,
          "db_names" => db_names, "db_status" => db_status, "requires" => requires, "title" => title }
      end
    end

    Plan = Struct.new(:scope, :entries, :notes, keyword_init: true) do
      def worktrees = entries.select(&:worktree?)
      def branches = entries.select(&:branch?)
      def issue_drafts = entries.select(&:issue_draft?)
      def empty? = entries.empty?

      # One line for a resolve dialog or a CLI echo: "2 worktrees, 1 branch —
      # 2 ready, 1 needs a look".
      def summary
        return "nothing to clean up" if empty?

        counts = [count(worktrees.size, "worktree"), count(branches.size, "branch"),
                  count(issue_drafts.size, "issue draft")].compact.join(", ")
        ready = entries.count(&:ticked)
        look = entries.count(&:warn?)
        blocked = entries.count(&:blocked?)
        detail = ["#{ready} ready", look.positive? && "#{look} need#{look == 1 ? "s" : ""} a look",
                  blocked.positive? && "#{blocked} blocked"].select { |part| part }.join(", ")
        "#{counts} — #{detail}"
      end

      def to_h
        { "scope" => scope, "summary" => summary, "notes" => notes, "entries" => entries.map(&:to_h) }
      end

      private

      def count(number, noun)
        return nil if number.zero?

        "#{number} #{number == 1 ? noun : "#{noun}#{noun.end_with?("h") ? "es" : "s"}"}"
      end
    end

    # What happened to one entry: removed, skipped (with why) or failed.
    Outcome = Struct.new(:id, :kind, :result, :message, keyword_init: true) do
      def removed? = result == "removed"
      def to_h = { "id" => id, "kind" => kind, "result" => result, "message" => message }
    end

    WORKTREES_DIR = TargetWorktree::WORKTREES_DIR
    SWEEP_BRANCH_PREFIX = "worktree-"
    COMMITS_SHOWN = 3

    def initialize(project_map: ProjectMap.new, runner: CommandRunner.new, session_log: SessionLog.new,
                   pr_status: PrStatus.new, pf: nil)
      @project_map = project_map
      @runner = runner
      @session_log = session_log
      @pr_status = pr_status
      @pf = pf || Pf.new(runner: runner, server: project_map.dev_server)
    end

    # The item's worktrees — by its branches, its temp branches and the cwds
    # of its sessions — plus its local branches whose PR merged and its temp
    # branches. Never the main checkout.
    def plan_item(item)
      issues = issue_entries(item.slug)
      root = @project_map.root_for(item.project)
      unless root && File.directory?(root)
        return Plan.new(scope: item.slug, entries: issues, notes: ["no repo root configured for '#{item.project}'"])
      end

      repo = GitRepo.new(root)
      listing = repo.worktrees
      trunk = repo.trunk_refs
      own = item.branches + item.temp_branches
      cwds = item.sessions.filter_map { |s| @session_log.session_for(s["id"])&.cwd }.map { |c| normalize(c) }
      others = open_items.reject { |i| i.slug == item.slug }

      worktree_entries = listing.drop(1).filter_map do |wt|
        next unless own.include?(wt.branch) || cwds.any? { |cwd| within?(cwd, wt.path) }

        bases = (item.branches - [wt.branch]) + upstream(wt.branch) + trunk
        worktree_entry(repo, wt, bases, item: item.slug, test_db: @project_map.settings_for(item.project).test_db,
                                         warn_owners: owners(others, wt, item.project))
      end

      checked_out = listing.select(&:branch).to_h { |wt| [wt.branch, wt] }
      merged = (item.branches - WorkItem::MAINLINE_BRANCHES).select do |b|
        repo.branch?(b) && @pr_status.state_for(item, b) == "MERGED"
      end
      branch_entries = merged.map do |b|
        bases = upstream(b) + (item.branches - [b]) + trunk
        branch_entry(repo, b, bases, "PR merged", item.slug, checked_out, worktree_entries,
                     warn_owners: branch_owners(others, b, item.project))
      end
      branch_entries += (item.temp_branches - item.branches).select { |b| repo.branch?(b) }.map do |b|
        bases = item.branches.flat_map { |ib| [ib, *upstream(ib)] } + trunk
        branch_entry(repo, b, bases, "temp branch", item.slug, checked_out, worktree_entries,
                     warn_owners: branch_owners(others, b, item.project))
      end

      Plan.new(scope: item.slug, entries: worktree_entries + branch_entries + issues, notes: [])
    end

    # Every `.claude/worktrees/*` worktree and `worktree-*` branch across the
    # repos qm knows, checked against the trunk and every other local branch.
    # Anything an unresolved item still claims is listed but never pre-ticked.
    def plan_sweep
      entries = []
      notes = []
      items = open_items
      @project_map.known_projects.map { |p| [p, @project_map.root_for(p)] }
                  .uniq { |_p, root| root && normalize(root) }.each do |project, root|
        next unless root && File.directory?(root)

        repo = GitRepo.new(root)
        listing = repo.worktrees
        next notes << "#{project}: #{Quartermaster.shorten_home(root)} is not a git repo" if listing.empty?

        trunk = repo.trunk_refs
        locals = repo.local_branches
        candidates = locals.select { |b| b.start_with?(SWEEP_BRANCH_PREFIX) }
        keepers = locals - candidates
        dir = File.join(normalize(listing.first.path), WORKTREES_DIR)
        claimers = items.select { |i| i.project == project }

        worktree_entries = listing.drop(1).select { |wt| within?(wt.path, dir) }.map do |wt|
          bases = trunk + (keepers - [wt.branch]) + upstream(wt.branch)
          entry = worktree_entry(repo, wt, bases, item: nil, test_db: @project_map.settings_for(project).test_db)
          protect(entry, owners(claimers, wt, project))
        end
        checked_out = listing.select(&:branch).to_h { |wt| [wt.branch, wt] }
        branch_entries = candidates.map do |b|
          entry = branch_entry(repo, b, trunk + keepers, "worktree branch", nil, checked_out, worktree_entries)
          protect(entry, branch_owners(claimers, b, project))
        end
        entries.concat(worktree_entries + branch_entries)
      end
      Plan.new(scope: "sweep", entries: entries + swept_issue_entries(items), notes: notes)
    end

    # Removes the selected entries (ids) of a plan; a warn entry also needs
    # its id in force, which implies selecting it. Worktrees go first — their
    # test DBs, then `git worktree remove` — so a branch that was checked out
    # there can be deleted after. Returns one Outcome per entry acted on.
    #
    # on_start: called with (entry, index, total) before an entry is worked
    # on, on_outcome: with (outcome, index, total) once it is done; index is
    # 1-based over the entries acted on, so a caller can show progress.
    def execute(plan, selected:, force: [], on_start: nil, on_outcome: nil)
      wanted = (selected + force).uniq
      todo = (plan.worktrees + plan.branches + plan.issue_drafts).select { |entry| wanted.include?(entry.id) }
      outcomes = {}
      todo.each.with_index(1) do |entry, index|
        on_start&.call(entry, index, todo.size)
        outcomes[entry.id] = guarded(entry, force) do
          if entry.worktree? then remove_worktree(entry, force.include?(entry.id))
          elsif entry.branch? then delete_branch(entry, outcomes)
          else delete_issue_draft(entry)
          end
        end
        on_outcome&.call(outcomes[entry.id], index, todo.size)
      end
      outcomes.values
    end

    # Entry ids for what a user typed: an id, a worktree path, a branch name,
    # or an issue draft's path or SLUG/FILE.
    def self.resolve_ids(plan, keys)
      keys.flat_map do |key|
        matches = plan.entries.select do |e|
          e.id == key || (e.worktree? && same_path?(e.path, key)) || (e.branch? && e.branch == key) ||
            (e.issue_draft? && (same_path?(e.path, key) || "#{e.item}/#{File.basename(e.path)}" == key))
        end
        raise ArgumentError, "no cleanup entry matches '#{key}'" if matches.empty?

        matches.map(&:id)
      end
    end

    def self.same_path?(left, right)
      File.expand_path(left) == File.expand_path(right) ||
        (File.exist?(right) && File.exist?(left) && File.realpath(left) == File.realpath(right))
    end

    private

    def worktree_entry(repo, wt, bases, item:, test_db:, warn_owners: [])
      blocked = []
      warn = []
      notes = []
      blocked << (wt.locked.to_s.empty? ? "locked by git" : "locked: #{wt.locked}") if wt.locked?
      blocked << "the dev server serves it" if served?(wt.path)
      live_sessions_in(wt.path).each { |id| blocked << "live session #{id[0, 8]} works here" }
      db_names = []
      db_status = "n/a"
      if wt.prunable? || !File.directory?(wt.path)
        notes << "directory already gone (git worktree prune)"
      else
        warn.concat(repo.dirt(wt.path))
        if wt.head
          warn << lost_reason(repo.unpreserved_commits(wt.head, bases, squash_into: squash_targets(repo, wt.branch)))
        end
        db_names, db_status, db_note = test_databases(test_db, wt.path) if test_db
        notes << db_note if db_note
      end
      warn.compact!
      warn.concat(warn_owners.map { |slug| "also used by open item '#{slug}'" })
      build("worktree", "worktree:#{wt.path}", repo, path: wt.path, branch: wt.branch, item: item,
                                                       blocked: blocked, warn: warn, notes: notes,
                                                       db_names: db_names, db_status: db_status)
    end

    def branch_entry(repo, branch, bases, why, item, checked_out, worktree_entries, warn_owners: [])
      blocked = []
      requires = nil
      if (wt = checked_out[branch])
        holder = worktree_entries.find { |e| e.path == wt.path }
        if holder
          requires = holder.id
        else
          blocked << "checked out at #{Quartermaster.shorten_home(wt.path)}"
        end
      end
      warn = [lost_reason(repo.unpreserved_commits(branch, bases.reject { |b| b == branch },
                                                   squash_into: squash_targets(repo, branch)))].compact
      warn.concat(warn_owners.map { |slug| "also linked to open item '#{slug}'" })
      entry = build("branch", "branch:#{repo.root}##{branch}", repo, path: nil, branch: branch, item: item,
                                                                      blocked: blocked, warn: warn, notes: [why],
                                                                      db_names: nil, db_status: nil)
      entry.requires = requires
      # Deleting it waits on its worktree going first, so it starts ticked
      # only when that worktree does.
      entry.ticked &&= holder.nil? || holder.ticked
      entry
    end

    def build(kind, id, repo, path:, branch:, item:, blocked:, warn:, notes:, db_names:, db_status:)
      status = if blocked.any? then "blocked" elsif warn.any? then "warn" else "ok" end
      Entry.new(id: id, kind: kind, repo: repo.root, path: path, branch: branch, item: item, status: status,
                reasons: blocked + warn, notes: notes, ticked: status == "ok",
                db_names: db_names, db_status: db_status, requires: nil)
    end

    # One entry per issue file of the item, broken ones included: deleting
    # takes the file's unsent issue comments along, so those are counted.
    def issue_entries(slug)
      drafts = IssueDrafts.new(slug)
      return [] if drafts.files.empty?

      data = drafts.read
      unsent = drafts.unsent_comments
      issues = data["issues"].map { |issue| [issue["file"], issue["title"], issue["number"], nil] }
      broken = data["errors"].map { |error| [error["file"], error["file"], nil, "doesn't parse: #{error["error"]}"] }
      (issues + broken).sort_by(&:first).map do |file, title, number, problem|
        comments = unsent[file].to_i
        comments_note = comments.positive? ? "#{comments} unsent comment#{comments == 1 ? "" : "s"}" : nil
        warn = number ? [] : [problem || "never created on GitHub", comments_note].compact
        notes = number ? ["##{number}", comments_note].compact : []
        Entry.new(id: "issue:#{slug}/#{file}", kind: "issue-draft", repo: nil, path: File.join(drafts.dir, file),
                  branch: nil, item: slug, status: warn.any? ? "warn" : "ok", reasons: warn, notes: notes,
                  ticked: warn.empty?, db_names: nil, db_status: nil, requires: nil, title: title)
      end
    end

    # Issue sets whose item is resolved or gone; an unresolved item's are
    # listed but never pre-ticked.
    def swept_issue_entries(open)
      slugs = Dir.glob(File.join(IssueDrafts::DIR, "*")).select { |dir| File.directory?(dir) }
                 .map { |dir| File.basename(dir) }.grep(Drafts::SLUG).sort
      open_slugs = open.map(&:slug)
      slugs.flat_map do |slug|
        issue_entries(slug).map { |entry| protect(entry, open_slugs.include?(slug) ? [slug] : []) }
      end
    end

    def delete_issue_draft(entry)
      existed = IssueDrafts.new(entry.item).delete(File.basename(entry.path))
      Outcome.new(id: entry.id, kind: entry.kind, result: "removed", message: existed ? "deleted" : "already gone")
    rescue SystemCallError, ArgumentError => e
      failed(entry, "deleting it failed: #{e.message}")
    end

    # Listed, never pre-ticked: an unresolved item still claims it.
    def protect(entry, slugs)
      return entry if slugs.empty?

      entry.ticked = false
      entry.notes += slugs.map { |slug| "belongs to unresolved item '#{slug}'" }
      entry
    end

    def lost_reason(commits)
      return "couldn't check its commits (git log failed)" if commits.nil?
      return nil if commits.empty?

      shown = commits.first(COMMITS_SHOWN).map { |sha, subject| "#{sha[0, 7]} #{subject}" }.join("; ")
      more = commits.size > COMMITS_SHOWN ? "; …" : ""
      "#{commits.size} commit#{commits.size == 1 ? "" : "s"} found nowhere else (#{shown}#{more})"
    end

    # What `<test_db> drop PATH --dry-run` would drop (the project's test_db command). The naming
    # rule lives in that tool; when it is missing or fails, the answer is "unknown", not
    # an error — a cleanup without DB names still beats none.
    def test_databases(test_db, path)
      result = @runner.call([test_db, "drop", path, "--dry-run"])
      return [result.out.split("\n").map(&:strip).reject(&:empty?), "ok", nil] if result.success?

      why = [result.err, result.out].map(&:strip).find { |t| !t.empty? } || "exit status non-zero"
      [nil, "unknown", "test DBs unknown: #{why.lines.first.strip}"]
    end

    def guarded(entry, force)
      if entry.blocked?
        skip(entry, "blocked: #{entry.reasons.join("; ")}")
      elsif entry.warn? && !force.include?(entry.id)
        skip(entry, "needs force: #{entry.reasons.join("; ")}")
      else
        yield
      end
    end

    def remove_worktree(entry, forced)
      root = entry.repo
      return run(entry, %w[git worktree prune], root, "pruned") if entry.gone?

      if entry.db_status == "ok" && entry.db_names.any? && (test_db = test_db_of(root))
        result = @runner.call([test_db, "drop", entry.path])
        # The worktree stays, so a retry finds the same entry again.
        return failed(entry, "dropping test DBs failed: #{message(result)}") unless result.success?
      end
      argv = ["git", "worktree", "remove", *(forced ? ["--force"] : []), entry.path]
      dbs = entry.db_names&.any? ? " and test DBs #{entry.db_names.join(", ")}" : ""
      run(entry, argv, root, "removed#{dbs}")
    end

    # `git branch -D` only once the branch provably isn't checked out
    # anywhere any more (its own worktree, if any, went first).
    def delete_branch(entry, outcomes)
      if entry.requires && !outcomes[entry.requires]&.removed?
        return skip(entry, "its worktree stays, so the branch stays checked out")
      end

      holder = GitRepo.new(entry.repo).worktrees.find { |wt| wt.branch == entry.branch }
      return skip(entry, "checked out at #{Quartermaster.shorten_home(holder.path)}") if holder

      outcome = run(entry, ["git", "branch", "-D", entry.branch], entry.repo, "deleted")
      forget_temp_branch(entry) if outcome.removed?
      outcome
    end

    # A deleted temp branch has nothing left to point at.
    def forget_temp_branch(entry)
      project = @project_map.known_projects.find { |p| @project_map.root_for(p) == entry.repo }
      WorkItem.all.each do |item|
        next unless item.project == project && item.temp_branches.include?(entry.branch)

        item.unlink_temp_branch(entry.branch)
      end
    end

    def run(entry, argv, chdir, done)
      result = @runner.call(argv, chdir: chdir)
      return failed(entry, "#{argv.first(3).join(" ")} failed: #{message(result)}") unless result.success?

      Outcome.new(id: entry.id, kind: entry.kind, result: "removed", message: done)
    end

    def skip(entry, why) = Outcome.new(id: entry.id, kind: entry.kind, result: "skipped", message: why)
    def failed(entry, why) = Outcome.new(id: entry.id, kind: entry.kind, result: "failed", message: why)

    def message(result)
      [result.err, result.out].map(&:strip).find { |t| !t.empty? } || "exit status non-zero"
    end

    def open_items
      @open_items ||= WorkItem.all.reject { |i| i.state == "resolved" }
    end

    # Open items (other than the one being cleaned) whose branches, temp
    # branches or session cwds point at this worktree.
    def owners(items, wt, project)
      items.select do |i|
        next false unless i.project == project

        (wt.branch && (i.branches + i.temp_branches).include?(wt.branch)) ||
          i.sessions.any? { |s| (cwd = @session_log.session_for(s["id"])&.cwd) && within?(normalize(cwd), wt.path) }
      end.map(&:slug)
    end

    def branch_owners(items, branch, project)
      items.select { |i| i.project == project && (i.branches + i.temp_branches).include?(branch) }.map(&:slug)
    end

    def upstream(branch)
      branch ? ["origin/#{branch}"] : []
    end

    # Where a squash merge of this head can have landed: GitHub squashes a
    # PR into the trunk, and the head's own upstream may hold a squash too.
    # Squash-checking every keeper branch cost two git calls per keeper.
    def squash_targets(repo, branch)
      repo.trunk_refs + upstream(branch)
    end

    def test_db_of(root) = @project_map.settings_for(@project_map.project_for(root)).test_db

    def served?(path)
      @served = @pf.status unless defined?(@served)
      @served&.running && @served.root && normalize(@served.root) == normalize(path)
    end

    def live_sessions_in(path)
      @live ||= @session_log.sessions.select(&:live?).select(&:cwd)
      @live.select { |s| within?(normalize(s.cwd), path) }.map(&:id)
    end

    def within?(path, dir)
      path = normalize(path)
      dir = normalize(dir)
      path == dir || path.start_with?("#{dir}/")
    end

    def normalize(path)
      File.realpath(File.expand_path(path))
    rescue SystemCallError
      File.expand_path(path)
    end
  end
end
