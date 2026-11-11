# frozen_string_literal: true

module Quartermaster
  # The /api/state payload: every item as the board and chat view render
  # it, the inbox, the chat view's attention list, the dev server, live panes
  # and the background jobs' outcomes. Also what the page polls between builds
  # (pulse), and the dev-server status cache the PRs view and its actions share.
  class GuiState
    # The benchmark runs (BenchmarkRun) the state's busy run and the
    # benchmark actions read; tests pass one with a stub spawner.
    attr_reader :benchmarks

    # pf_off: why this GUI may not drive the dev server (PfFence), nil when it may.
    # pr_fetcher: how a branch's PR state is asked (PrStatus's fetcher; nil asks gh).
    def initialize(runner:, tmux:, caffeinate:, jobs:, terminal_token:, notifier: nil, pf_off: nil, benchmarks: nil, pr_fetcher: nil)
      @runner = runner
      @pr_fetcher = pr_fetcher
      @benchmarks = benchmarks || BenchmarkRun.new(runner: runner, tmux: tmux)
      @pf_off = pf_off
      @notifier = notifier
      @tmux = tmux
      @caffeinate = caffeinate
      @jobs = jobs
      @terminal_token = terminal_token
      # Per-session token tallies, kept in memory across state builds so an
      # unchanged session costs one stat (UsageLedger).
      @usage_ledger = UsageLedger.new
    end

    # "3h ago" for a timestamp, a date past ten days, nil when unparseable.
    def self.relative_when(ts)
      return nil unless ts

      seconds = Time.now - Time.parse(ts)
      return "just now" if seconds < 60
      return "#{(seconds / 60).to_i}m ago" if seconds < 3600
      return "#{(seconds / 3600).to_i}h ago" if seconds < 86_400

      days = (seconds / 86_400).to_i
      days <= 10 ? "#{days}d ago" : Time.parse(ts).to_date.to_s
    rescue StandardError
      nil
    end

    def build
      # Before any read: a hook write landing mid-build then moves the next pulse.
      pulse_now = pulse
      log = SessionLog.new
      # background: expired PR states are served as-is and refetched on
      # threads, so a state build never blocks on gh. "refreshing" tells the
      # page to poll until those fetches have landed.
      pr_status = PrStatus.new(fetcher: @pr_fetcher, background: true)
      attention = Attention.new(session_log: log, pr_status: pr_status)
      live_ids = log.sessions.select(&:live?).map(&:id)
      project_map = ProjectMap.new
      config = ProjectConfig.current
      # One `git worktree list` per project root per state build, not per item.
      worktrees = Hash.new { |cache, root| cache[root] = Quartermaster.branch_worktrees(root) }
      pf = pf_status
      panes = @tmux.sessions
      # Read once: the busy run and every item's finished runs come from it.
      bench_runs = BenchmarkRun.all
      context = { log: log, attention: attention, live_ids: live_ids, project_map: project_map, bench_runs: bench_runs,
                  worktrees: worktrees, pr_status: pr_status, pf: pf, panes: panes, prices: PriceTable.load,
                  aside_counts: log.sessions.filter_map(&:aside_for).tally }
      work_items = WorkItem.all
      items = work_items.map { |item| item_payload(item, context) }
      building = active_build_agents(work_items, log)
      @usage_ledger.save
      {
        "items" => items,
        "inbox" => inbox_payload(log, panes),
        "projects" => (project_map.known_projects + [ProjectMap::NO_PROJECT]).uniq,
        # Where a bare issue number starts, and the loose-chat dialog's presets (config.yml).
        "defaultProject" => config.default_project,
        "looseStarters" => config.loose_starters.values.map(&:to_h),
        "attention" => chat_attention(log),
        # Live loose chats (LooseChat), automation edit chats (AutomationEditChats) and run chats (RunChats):
        # the chats list's Loose, Automations and Runs groups.
        "loose" => loose_chats(panes, log),
        "pulse" => pulse_now,
        "refreshing" => pr_status.refreshing?,
        "distilling" => @jobs.distilling_slugs,
        "distilled" => @jobs.take_distilled,
        "pf" => pf_payload(pf, config.dev_server),
        "jobs" => @jobs.running,
        # Items with a build task running or in review: only they get the button.
        "buildActive" => building.keys,
        # The newest build-progress estimate per slug, shown with the board,
        # holding only the tasks still active.
        "buildProgress" => live_progress(building),
        # Live tmux sessions: item chats (named by slug) and bin/update runs.
        "panes" => panes,
        # Same-origin only, like the page: lets a page from before a GUI restart reattach.
        "terminalToken" => @terminal_token,
        "asideModels" => Aside::MODELS,
        "caffeinate" => @caffeinate.status,
        # The live benchmark run, machine-wide ({id, slug, branch, state}) or nil: every 🏁 shows it busy.
        "benchmark" => @benchmarks.busy(bench_runs),
        # The page shows those flagged "page" it hasn't shown yet (TurnNotifier).
        "notifications" => @notifier ? @notifier.recent : [],
        # The header chip: the account's limits as the status line last wrote them.
        "rateLimits" => RateLimits.new.payload,
        # The header's error badge: qm.log errors since the user last marked them seen.
        "errors" => ErrorLog.new.summary,
        # The Todos tab: open todos in order, then the 20 newest done and every done one on an item (GuiTodoActions.payload).
        "todos" => GuiTodoActions.payload(items: work_items.to_h { |item| [item.slug, item] }),
        "finished" => @jobs.take_finished
      }
    end

    # What the chat view polls about once a second while it is on screen:
    # file sizes, so the page fetches a full state only when a hook appended
    # an event (a turn changed), a session started or ended, or a mid-turn
    # chat's transcript grew (an Esc interrupt fires no hook). The transcripts
    # watched are the last state build's working/blocked chats. A page-side
    # poll, not a liveness timer — nothing on the server depends on it.
    # Auto caffeinate flips its child on a server thread, after the hook
    # write that caused it; the held flag makes that a pulse of its own, and
    # todos.json's signature does the same for a `qm todo add`.
    def pulse
      sizes = ([EventLog.new.path, SessionLog.new.path] + (@mid_turn_transcripts || [])).map do |path|
        File.size(path)
      rescue SystemCallError
        0
      end
      (sizes + [@caffeinate.status["on"] ? 1 : 0, Drafts.signature, IssueDrafts.signature, @notifier&.seq.to_i,
                TodoList.new.signature]).join(":")
    end

    # The part of the pulse a page off the chat view watches: turns changed
    # (hook events), a notification was raised, drafts arrived (a page
    # overlay's annotations land without any hook) or issue drafts changed. Transcript growth only
    # matters to the chat view's mid-turn rows.
    def events_pulse
      size = File.size?(EventLog.new.path).to_i
      "#{size}:#{Drafts.signature}:#{IssueDrafts.signature}:#{@notifier&.seq.to_i}"
    end

    # Off the chat view only whose move it is matters: the tab title's count,
    # the notifications to show and each item's draft count. No items, so it
    # stays cheap per pulse.
    def attention_payload
      log = SessionLog.new
      { "attention" => chat_attention(log), "notifications" => @notifier ? @notifier.recent : [],
        "loose" => loose_chats(@tmux.sessions, log), "draftCounts" => Drafts.counts }
    end

    def loose_chats(panes, log)
      LooseChat.new(tmux: @tmux, session_log: log).chats(panes) + AutomationEditChats.new(session_log: log).chats(panes) +
        RunChats.new(session_log: log).chats(panes)
    end

    # The dev server serves one checkout at a time, so status is global, not
    # per item. Cached briefly: without its status URL the fallback spawns
    # `<command> status`, and the chat view can build state every second.
    PF_STATUS_TTL_SECONDS = 2

    def pf_status
      cached = @pf_cache
      return cached[:status] if cached && Time.now - cached[:at] < PF_STATUS_TTL_SECONDS

      status = Pf.new(runner: @runner).status
      @pf_cache = { status: status, at: Time.now }
      status
    rescue StandardError => e
      Quartermaster.log_error("gui-pf-status", e)
      nil
    end

    # A dev-server action just changed what it serves.
    def forget_pf_status
      @pf_cache = nil
    end

    def served?(pf, paths)
      return false unless pf&.running && pf.root

      same_checkout?(pf.root, paths)
    end

    # The linked branch whose checkout pf serves, or nil: the rail's 🖥 and
    # the stale-server warning (docs/areas/stacks.md).
    def served_branch(pf, checkouts)
      return nil unless pf&.running && pf.root

      target = real_path(pf.root)
      checkouts.find { |_branch, path| real_path(path) == target }&.first
    end

    # The items with one of their branches checked out at path — by the same
    # mapping that marks an item served, so a page overlay's annotations
    # reach the items its page shows as served.
    def items_checked_out_at(path)
      project_map = ProjectMap.new
      worktrees = Hash.new { |cache, root| cache[root] = Quartermaster.branch_worktrees(root) }
      WorkItem.all.select { |item| same_checkout?(path, item_checkouts(item, project_map, worktrees).values) }
    end

    private

    def same_checkout?(path, paths)
      target = real_path(path)
      paths.any? { |candidate| real_path(candidate) == target }
    end

    # The chat view's left list, already in attention order (ChatAttention):
    # the page only renders it.
    # slug → the "run/agent" keys of its build's active tasks (BuildProgress),
    # only for items with a live session: the rest can run no build.
    def active_build_agents(work_items, log)
      progress = BuildProgress.new(session_log: log)
      work_items.each_with_object({}) do |item, building|
        keys = progress.active_agents(item).map(&:key)
        building[item.slug] = keys unless keys.empty?
      end
    end

    # A finished task's line goes, and the whole estimate once nothing it
    # covered is still going.
    def live_progress(building)
      @jobs.progress.each_with_object({}) do |(slug, estimate), live|
        active = building[slug]
        next unless active

        agents = estimate["agents"]
        if agents&.any?
          agents = agents.select { |a| active.include?(a["agent"]) }
          next if agents.empty?

          estimate = estimate.merge("agents" => agents)
        end
        live[slug] = estimate
      end
    end

    def chat_attention(log)
      entries = ChatAttention.new(session_log: log).entries
      @mid_turn_transcripts = entries.select { |entry| %w[working blocked].include?(entry.state) }
                                     .filter_map { |entry| log.session_for(entry.session_id)&.transcript }
      entries.map do |entry|
        { "slug" => entry.slug, "session" => entry.session_id, "state" => entry.state,
          "since" => entry.since&.utc&.iso8601, "tool" => entry.tool, "snoozed" => entry.snoozed ? true : false,
          "waitingOn" => entry.waiting_on,
          "contextTokens" => entry.context_tokens,
          "cacheWarmUntil" => entry.cache_warm_until&.utc&.iso8601,
          "lastAssistantAt" => entry.last_assistant_at&.utc&.iso8601,
          "ctxLevel" => ContextMeter.level(entry.context_tokens),
          "rotate" => ContextMeter.rotate_offer(entry.context_tokens, entry.last_assistant_at) }
      end
    end

    # command: nil when no project configures a dev server — the page then
    # shows no badge.
    def pf_payload(status, server)
      payload = if status
                  status.to_h.merge("worktree" => status.root && File.basename(status.root),
                                    "short" => status.root && Quartermaster.shorten_home(status.root))
                else
                  { "running" => false }
                end
      payload["command"] = server&.command
      @pf_off ? payload.merge("off" => @pf_off) : payload
    end

    def item_payload(item, context)
      project_map = context[:project_map]
      attention = context[:attention]
      # First, so the payload's branches already include auto-linked ones.
      GhStack.sync(item, project_map: project_map)
      checkouts = item_checkouts(item, project_map, context[:worktrees])
      worktrees = checkouts.transform_values { |path| Quartermaster.shorten_home(path) }
      pr_states = pr_states(item, context[:pr_status])
      sessions = Quartermaster.item_sessions(item, session_log: context[:log]).map do |s|
        { "id" => s.id, "tier" => s.tier,
          "when" => GuiState.relative_when(s.last_ts) || "—",
          "prompt" => s.first_prompt }
      end
      benchmarkable = BenchmarkRun.enabled?(item)
      item.to_h.merge(
        "updated" => attention.activity_at(item).to_date.to_s,
        "live" => (item.to_h["session_ids"] & context[:live_ids]).any?,
        "badges" => attention.entries_for(item).map { |e| { "type" => e.badge, "label" => e.message } },
        # The card's one-liner should say where the item stands, so prefer an open
        # item, then the newest note that isn't pure mechanics.
        "note" => item.headline_note&.to_h,
        # The notes a new session of this item is told about: the chat view's digest.
        "injected" => item.injectable_notes.map(&:position),
        "worktrees" => worktrees,
        # Every stack and loose branch with its layer facts.
        "chains" => chains_payload(item, project_map, pr_states, pr_links(item, context[:pr_status]), worktrees),
        "prStates" => pr_states,
        "benchmarkable" => benchmarkable,
        # Per branch, the newest done run ({id, finishedAt}): the 🏁 marker. {} unless benchmarkable.
        "benchmarked" => benchmarkable ? BenchmarkRun.finished_by_branch(context[:bench_runs], item.slug) : {},
        "served" => served?(context[:pf], checkouts.values),
        "servedBranch" => served_branch(context[:pf], checkouts),
        "pane" => context[:panes].include?(item.slug),
        "aside" => context[:panes].include?(Aside.session_name(item.slug)),
        # The Aside button's count; the asides themselves load with the drawer.
        "asideCount" => context[:aside_counts].fetch(item.slug, 0),
        "boardRows" => item.board ? BoardMirror.shared.rows_for(item) : [],
        # The chat history reloads when this or the earlier sessions change.
        "rotations" => item.rotations.size,
        "sessionList" => sessions,
        "usage" => usage_payload(item, context),
        # Diff comments and page annotations waiting to be sent (Drafts).
        "drafts" => drafts_payload(item),
        # The Issues button's count and each file's version (IssueDrafts); nil without any.
        "issues" => issues_payload(item)
      )
    end

    def chains_payload(item, project_map, pr_states, pr_links, worktrees)
      GhStack.chains(item, project_map: project_map, pr_states: pr_states, pr_links: pr_links).each do |chain|
        chain["layers"].each { |layer| layer["worktree"] = worktrees[layer["branch"]] }
      end
    end

    def issues_payload(item)
      issues = IssueDrafts.new(item.slug)
      return nil unless Dir.exist?(issues.dir)

      summary = issues.summary
      summary["count"].zero? ? nil : summary
    rescue StandardError => e
      Quartermaster.log_error("gui-issues", e)
      nil
    end

    def drafts_payload(item)
      Drafts.new(item.slug).entries
    rescue StandardError => e
      Quartermaster.log_error("gui-drafts", e)
      []
    end

    # Tokens and API-equivalent cost (docs/areas/side-panel.md); nil for an item without
    # sessions. A failure here must never cost the whole state build.
    def usage_payload(item, context)
      usage = ItemUsage.for(item, session_log: context[:log], ledger: @usage_ledger, prices: context[:prices])
      return nil if usage.empty?

      payload = usage.to_h
      payload["sessions"].each { |row| row["when"] = GuiState.relative_when(row["when"]) || "—" }
      payload
    rescue StandardError => e
      Quartermaster.log_error("gui-usage", e)
      nil
    end

    # branch → checkout path for the item's branches that are checked out
    # somewhere in the project repo (main checkout or a linked worktree).
    def item_checkouts(item, project_map, worktrees)
      root = project_map.root_for(item.project)
      return {} unless root

      by_branch = worktrees[root]
      item.branches.filter_map do |branch|
        path = by_branch[branch]
        [branch, path] if path && File.directory?(path)
      end.to_h
    end

    # PR state per linked branch, from the cache (expired entries refetch in
    # the background). Resolved items skip it: nobody looks at their stack,
    # and every expired entry would cost a gh call.
    def pr_states(item, pr_status)
      return {} if item.state == "resolved"

      (item.branches - WorkItem::MAINLINE_BRANCHES).to_h { |b| [b, pr_status.state_for(item, b)] }.compact
    end

    # Cache reads only: pr_states already queued any refresh.
    def pr_links(item, pr_status)
      return {} if item.state == "resolved"

      (item.branches - WorkItem::MAINLINE_BRANCHES).to_h { |b| [b, pr_status.link_for(item, b)] }.compact
    end

    def real_path(path)
      File.realpath(File.expand_path(path))
    rescue SystemCallError
      File.expand_path(path)
    end

    # A loose chat still open in its pane is listed under Loose, not here.
    def inbox_payload(log, panes)
      open_loose = panes.filter_map { |name| LooseChat.id_of(name) }
      log.inbox.reject { |s| open_loose.include?(s.loose_id) }.sort_by(&:last_ts).reverse.map do |session|
        { "id" => session.id,
          "prompt" => session.first_prompt || "(no prompt captured)",
          "when" => GuiState.relative_when(session.last_ts) || "—",
          "cwd" => Quartermaster.shorten_home(session.cwd || "?") }
      end
    end
  end
end
