# frozen_string_literal: true

module Quartermaster
  # The GUI's POST /api/action: each web action mapped to the WorkItem,
  # Launcher, Workspace, Tmux or Rotation operation the CLI uses too, so the
  # two surfaces can't drift. Gui runs it under the action mutex; anything
  # that takes seconds hands off to GuiJobs.
  class GuiActions
    # Network-bound and touching no qm state (a thread's resolve changes
    # only GitHub, a review preview only reads), or the benchmark ones with
    # their own locks (BenchmarkRun, TodoList), so Gui runs them off the action mutex.
    UNLOCKED = (%w[issue-preview pr-thread-resolve review-preview] + GuiBenchmarkActions::COMMANDS +
                GuiTodoActions::COMMANDS).freeze

    def initialize(runner:, tmux:, caffeinate:, jobs:, state:, pr_items:)
      @runner = runner
      @tmux = tmux
      @caffeinate = caffeinate
      @jobs = jobs
      @state = state
      @pr_items = pr_items
    end

    # Maps a web action to the underlying model/launcher operation. SystemExit
    # is rescued because a couple of shared ops (Launcher#resume on a live
    # session) reach for abort — in the server that must become a JSON error,
    # never a dead process.
    def dispatch(payload)
      cmd = payload["cmd"]
      slug = payload["slug"]
      args = payload["args"] || {}
      case cmd
      when "resume" then gui_resume(slug, args["session"])
      when "resume-session" then gui_resume_session(args["session"])
      when "start" then Launcher.new.start(WorkItem.find(slug)) && ok
      when "state" then gui_state(slug, args["state"])
      when "move" then WorkItem.find(slug).move_to(args["project"]) && ok
      when "note" then gui_note(slug, args["text"], args["kind"])
      when "retag" then gui_retag(slug, args["position"], args["kind"])
      when "describe" then WorkItem.find(slug).describe(args["text"].to_s) && ok
      when "retitle" then gui_retitle(slug, args["title"])
      when "delete" then ItemDeletion.new(runner: @runner, tmux: @tmux).gui_reply(slug.to_s, force: args["force"] == true)
      when "pr" then gui_pr(slug, args["branch"])
      when "distill" then gui_distill(slug, args["session"], args["force"] == true)
      when "snooze" then gui_snooze(slug, args["duration"])
      when "ack" then gui_ack(slug)
      when "new" then gui_new(args)
      when "attach" then gui_attach(slug, args["session"])
      when "detach" then WorkItem.find(slug).detach_session(args["session"]) && ok
      when "item-from-session" then gui_item_from_session(args["session"], args["title"])
      when "dismiss" then SessionLog.new.dismiss(args["session"]) && ok
      when "work-on" then workspace_job(slug, :work_on, "working on it…", args)
      when "pf-switch" then workspace_job(slug, :switch_pf, "switching the dev server…", args)
      when "ide" then workspace_job(slug, :open_ide, "opening #{ProjectConfig.current.ide!(WorkItem.find(slug).project).label}…", args)
      when "terminal" then workspace_job(slug, :open_terminal, "opening a terminal…", args)
      when "adopt" then gui_adopt(slug, args["worktree"])
      when "restack" then gui_restack(slug, presence(args["branch"]))
      when "pf-stop" then gui_pf_stop
      when "pf-mode" then WorkItem.find(slug).update_pf_mode(args["mode"].to_s) && ok
      when "run-update" then gui_run_update(args["path"])
      when "pane-start" then gui_pane(slug, fresh: true)
      when "pane-resume" then gui_pane(slug, fresh: false, session_id: presence(args["session"]))
      when "pane-warp" then gui_pane_warp(slug)
      when "automation-chat" then AutomationChat.new(tmux: @tmux).open(slug)
      when "rotate" then gui_rotate(slug, args)
      when "aside-open" then gui_aside_open(slug, args["model"])
      when "aside-close" then gui_aside_close(slug)
      when "aside-promote" then ok.merge("note" => aside.promote(WorkItem.find(slug), session_id: presence(args["session"])))
      when "aside-reopen" then gui_aside_reopen(slug, args["session"])
      when "page-annotations" then gui_page_annotations(args)
      when "drafts-load" then gui_drafts_load(slug, args["text"])
      when "diff-viewed" then gui_diff_viewed(slug, args)
      when "draft-put" then gui_draft_put(slug, args)
      when "draft-move" then gui_draft_move(slug, args["id"].to_s, args["to"])
      when "review-post" then gui_review_post(slug, args)
      when "thread-reply-put" then ok.merge("draft" => drafts_of(slug).put_thread_reply(args.merge("author" => "user")))
      when "pr-thread-resolve" then gui_thread_resolve(args)
      when "review-preview" then gui_review_preview(slug, args)
      when "draft-place" then gui_draft_place(slug, args)
      when "issue-comment-put" then ok.merge("draft" => drafts_of(slug).put_issue_comment(args))
      when "draft-edit" then ok.merge("draft" => drafts_of(slug).edit(args["id"].to_s, args["comment"]))
      when "draft-delete" then ok.merge("deleted" => drafts_of(slug).delete(args["id"].to_s))
      when "drafts-discard" then gui_drafts_discard(slug, args["ids"])
      when "drafts-send" then gui_drafts_send(slug, args)
      when "issues-clear-created" then ok.merge("cleared" => IssueDrafts.new(WorkItem.find(slug).slug).delete_created)
      when "issue-acknowledge" then ok.merge("acknowledged" => IssueDrafts.new(WorkItem.find(slug).slug).acknowledge(args["file"]))
      when "issues-create" then gui_issues_create(slug, args["files"])
      when "build-progress" then gui_build_progress(slug)
      when "branch-stats-commentary" then gui_branch_stats_commentary(slug, args["branch"])
      when "board-answer" then gui_board_answer(slug, args["doc_id"], args["text"])
      when "issue-preview" then ok.merge("issue" => issue_start.preview(args["number"], issue_project(args)))
      when "issue-start" then gui_issue_start(args)
      when "pr-chat" then gui_pr_chat(args["url"])
      when "pr-review" then gui_pr_review(args["url"])
      when "pr-pf" then pr_workspace_job(args["url"], pf: true)
      when "pr-ide" then pr_workspace_job(args["url"], pf: false)
      when "pr-unrequire" then gui_pr_unrequire(args["url"], args["ref"])
      when "cleanup" then gui_cleanup(args)
      when "caffeinate" then gui_caffeinate(args["mode"])
      when "errors-seen" then ok.merge("errors" => ErrorLog.new.tap(&:mark_seen).summary)
      when *GuiBenchmarkActions::COMMANDS then GuiBenchmarkActions.new(benchmarks: @state.benchmarks, jobs: @jobs).dispatch(cmd, slug, args)
      when *GuiTodoActions::COMMANDS then GuiTodoActions.new.dispatch(cmd, args)
      when "todo-to-item" then GuiTodoActions.new.to_item(args, tmux: @tmux)
      else GuiLooseActions.new(tmux: @tmux, jobs: @jobs).dispatch(cmd, args) || { "ok" => false, "error" => "unknown action '#{cmd}'" }
      end
    rescue SystemExit
      { "ok" => false, "error" => "operation aborted" }
    rescue Quartermaster::AlreadyDistilledError => e
      # The page turns this into a confirm dialog and retries with force: true.
      { "ok" => false, "needs_confirmation" => true, "error" => e.message }
    rescue ArgumentError => e
      { "ok" => false, "error" => e.message }
    rescue StandardError => e
      Quartermaster.log_error("gui-action", e)
      { "ok" => false, "error" => e.message }
    end

    # The checklist a cleanup or sweep dialog shows. Read-only and seconds
    # long (git per worktree, a test-DB dry run each), so like ask it stays
    # off the action mutex.
    def cleanup_plan(scope)
      cleanup = new_cleanup
      plan = scope == "sweep" ? cleanup.plan_sweep : cleanup.plan_item(WorkItem.find(scope.to_s))
      { "ok" => true, "plan" => plan_payload(plan) }
    rescue StandardError => e
      Quartermaster.log_error("gui-cleanup-plan", e) unless e.is_a?(ArgumentError)
      { "ok" => false, "error" => e.message }
    end

    # Any live session, linked or not, mid-turn or with background jobs
    # out. A blocked one waits on the user and can sleep through it.
    def sessions_busy?(log = SessionLog.new)
      attention = ChatAttention.new(session_log: log)
      log.sessions.select(&:live?).any? { |session| %w[working waiting].include?(attention.turn_for(session)[:state]) }
    end

    private

    # Plans under the action mutex — the guards (no transcript, already
    # snapshotted → needs_confirmation) answer immediately — then distills on
    # a thread. add_snapshot takes the work-item flock itself, so the write is
    # safe against actions dispatched meanwhile. The page shows the item as
    # distilling until the state build reports the outcome.
    def gui_distill(slug, session_id, force)
      item, sessions = Quartermaster.distill_plan(slug, session_id: session_id, force: force)
      return { "ok" => false, "error" => "'#{slug}' is already being distilled" } unless @jobs.start_distill(slug, sessions.size)

      Thread.new { run_distill(item, sessions) }
      { "ok" => true, "background" => true, "sessions" => sessions.size }
    end

    # One headless haiku call over every active sub-agent of the item's
    # running Workflow runs. Seconds long, so a background job under its own
    # key: a rotation or pf job on the slug must not block it, nor it them.
    # The outcome, failures included, replaces the item's previous estimate.
    def gui_build_progress(slug)
      item = WorkItem.find(slug)
      @jobs.background(BuildProgress.job_key(item.slug), "estimating build progress…") do
        result = begin
          BuildProgress.new.call(item)
        rescue StandardError => e
          Quartermaster.log_error("gui-build-progress", e) unless e.is_a?(ArgumentError)
          { "ok" => false, "taken_at" => Time.now.iso8601, "error" => e.message }
        end
        @jobs.store_progress(item.slug, result)
        result["ok"] ? { "ok" => true, "message" => "#{item.slug}: build progress updated" } : result
      end
    end

    # The branch stats modal's "What stands out" (BranchStats#comment): one
    # headless haiku call, a background job per branch.
    def gui_branch_stats_commentary(slug, branch)
      stats = BranchStats.new(runner: @runner, tmux: @tmux)
      target = stats.target(WorkItem.find(slug), branch: branch)
      @jobs.background(BranchStats.job_key(target), "reading #{target["branch"]}'s stats…") { stats.comment(target) }
    end

    def run_distill(item, sessions)
      sessions.each { |session| Quartermaster.distill_session(item, session) }
      @jobs.finish_distill(item.slug, "ok" => true, "sessions" => sessions.size)
    rescue StandardError => e
      Quartermaster.log_error("gui-distill", e)
      @jobs.finish_distill(item.slug, "ok" => false, "error" => e.message)
    end

    def ok = { "ok" => true }

    # Start/Resume from the chat view: the item's chat in its tmux session.
    # One live chat per item — an existing pane is simply shown again, and a
    # session running outside the GUI (a Warp tab) refuses until it ends; then
    # Resume takes it over in the pane.
    def gui_pane(slug, fresh:, session_id: nil)
      item = WorkItem.find(slug)
      return ok.merge("attached" => true) if @tmux.live?(slug)

      plan = Launcher.new.chat_plan(item, fresh: fresh, session_id: session_id)
      if plan[:mode] == :live
        return { "ok" => false, "error" => "#{slug} has a chat running outside the GUI — take it over here once it ends" }
      end

      @tmux.open(slug, cwd: plan[:cwd], argv: plan[:argv], env: plan[:env])
      ok.merge("mode" => plan[:mode].to_s)
    end

    # The aside drawer: its own tmux session beside the item's chat. An open
    # one is just shown again (the model it already runs keeps running).
    def gui_aside_open(slug, model)
      item = WorkItem.find(slug)
      started = aside.open(item, model: model.to_s)
      ok.merge("session" => Aside.session_name(slug), "attached" => !started)
    end

    def gui_aside_reopen(slug, session_id)
      aside.reopen(WorkItem.find(slug), session_id.to_s)
      ok.merge("session" => Aside.session_name(slug))
    end

    # Closing kills the aside; one already gone is closed too.
    def gui_aside_close(slug)
      aside.close(WorkItem.find(slug))
      ok
    end

    def aside = Aside.new(tmux: @tmux)

    # A context rotation, only ever on the user's click (or `qm rotate` / the /rotate
    # skill he typed): refusals (mid-turn, outside the GUI) answer at once; the
    # hand-off waits on the chat's wrap-up turn, so it runs as the item's job.
    # close: no fresh start; finish: close, then resolve; self: the chat asked
    # (`qm rotate --self`), so the hand-off waits for its current turn to end.
    def gui_rotate(slug, args)
      item = WorkItem.find(slug)
      rotation = Rotation.new(tmux: @tmux)
      plan = rotation.plan(item, close: args["close"] == true, finish: args["finish"] == true,
                                 by_chat: args["self"] == true, session_id: presence(args["session"]))
      label = if plan.mode == :self then plan.close ? "closing after this turn…" : "rotating after this turn…"
              elsif plan.finish then "finishing: final wrap-up…"
              elsif plan.close then "wrapping up to close…"
              elsif plan.mode == :wrap_up then "rotating: wrapping up…"
              else "rotating: distilling…"
              end
      relabel = ->(waiting) { @jobs.relabel(slug, waiting) }
      @jobs.background(slug, label) { rotation.run(item, plan, relabel: relabel) }.merge("mode" => plan.mode.to_s, "close" => plan.close)
    end

    def gui_pane_warp(slug)
      raise ArgumentError, "#{slug} has no chat pane to open" unless @tmux.live?(slug)

      Launcher.new.attach_in_warp(slug, @tmux)
      ok
    end

    # Resolving answers with the item's cleanup plan, so the page can offer
    # "Resolve and clean up N worktrees?". A failing plan must not fail the
    # resolve — it just isn't offered. PR states come from the cache only.
    def gui_state(slug, state)
      item = WorkItem.find(slug)
      item.update_state(state)
      return ok unless state == "resolved"

      plan = begin
        new_cleanup.plan_item(item)
      rescue StandardError => e
        Quartermaster.log_error("cleanup-offer", e)
        nil
      end
      plan.nil? || plan.empty? ? ok : ok.merge("cleanup" => plan_payload(plan))
    end

    # PR states from the cache only, so a plan never waits on gh.
    def new_cleanup
      Cleanup.new(runner: @runner, pr_status: PrStatus.new(background: true), pf: Pf.new(runner: @runner))
    end

    def plan_payload(plan)
      hash = plan.to_h
      hash["entries"].each { |entry| entry["short"] = Quartermaster.shorten_home(entry["path"]) if entry["path"] }
      hash
    end

    # Executes on a thread against a fresh plan: what the dialog showed may be
    # minutes old, and Cleanup#execute trusts the plan's checks — a worktree
    # that turned dirty or got served since is skipped, not removed.
    def gui_cleanup(args)
      scope = args["scope"].to_s
      selected = Array(args["selected"]).map(&:to_s)
      force = Array(args["force"]).map(&:to_s)
      raise ArgumentError, "nothing selected to clean up" if (selected + force).empty?

      item = WorkItem.find(scope) unless scope == "sweep"
      @jobs.background(scope, "cleaning up…") do
        cleanup = new_cleanup
        plan = item ? cleanup.plan_item(item) : cleanup.plan_sweep
        progress = ->(_entry, index, total) { @jobs.relabel(scope, "cleaning up #{index}/#{total}…") }
        outcomes = cleanup.execute(plan, selected: selected, force: force, on_start: progress)
        cleanup_result(outcomes)
      end
    end

    def cleanup_result(outcomes)
      counts = outcomes.group_by(&:result).map { |result, list| "#{list.size} #{result}" }
      failed = outcomes.reject { |o| o.result == "removed" }
      summary = counts.empty? ? "nothing to do" : counts.join(", ")
      result = { "ok" => outcomes.none? { |o| o.result == "failed" }, "message" => "cleanup: #{summary}",
                 "outcomes" => outcomes.map(&:to_h) }
      return result if result["ok"]

      result.merge("error" => "cleanup: #{summary} — #{failed.map { |o| "#{o.id.sub(/\A\w+:/, "")}: #{o.message}" }.join("; ")}")
    end

    # Work on this / Switch the dev server / Open in the IDE / Terminal: a worktree may have
    # to be created (git worktree add + test DB prepare) and a switch takes seconds, so
    # each runs on a thread. The dev server is one shared server, so only one job
    # driving it (pf: true) runs at a time across all items.
    def workspace_job(slug, action, label, args)
      item = WorkItem.find(slug)
      options = { worktree: presence(args["worktree"]), branch: presence(args["branch"]) }
      TargetWorktree.require_linked(item, options[:branch]) if options[:branch]
      pf_action = %i[work_on switch_pf].include?(action)
      options[:mode] = presence(args["mode"]) if pf_action
      uses_pf = pf_action && item.dev_server ? true : false
      @jobs.background(slug, label, pf: uses_pf) do
        report = Workspace.new(runner: @runner).public_send(action, item, **options.compact)
        { "ok" => true, "message" => "#{slug}: #{report.steps.join("; ")}", "warning" => report.target.warning,
          "switched" => report.mode ? true : false, "path" => report.target.path }
      ensure
        @state.forget_pf_status if uses_pf
      end
    end

    # Adopt hands the worktree to the /adopt-worktree skill in the item's
    # chat rather than redoing it in qm: the skill owns the flow (exiting an
    # EnterWorktree session, the issue rename, moving the IDE off the
    # worktree). A chat in the pane gets it typed once it is the user's turn;
    # without one, a fresh chat starts with it as its first prompt — in the
    # main checkout, so the session doesn't sit in the directory it deletes.
    def gui_adopt(slug, worktree)
      item = WorkItem.find(slug)
      root = ProjectMap.new.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root

      main = File.expand_path(root)
      path = File.expand_path(worktree.to_s)
      raise ArgumentError, "#{Quartermaster.shorten_home(path)} is the main checkout — nothing to adopt" if path == main

      branch = Quartermaster.branch_worktrees(main).key(path)
      raise ArgumentError, "#{Quartermaster.shorten_home(path)} is not a worktree of #{item.project}" unless branch

      prompt = "/adopt-worktree #{path}"
      return gui_type_into_chat(item, prompt) if @tmux.live?(slug)

      plan = Launcher.new.chat_plan(item, fresh: true)
      raise ArgumentError, "#{slug} has a chat running outside the GUI — adopt from there, or end it first" if plan[:mode] == :live

      @tmux.open(slug, cwd: main, argv: [*plan[:argv], prompt], env: plan[:env])
      ok.merge("mode" => "start", "branch" => branch)
    end

    # The ⟳ chip (docs/areas/stacks.md), only ever on the user's click: the item's chat
    # restacks with gh-stack — qm itself never runs git or gh for it. Typed
    # only once it is his turn and no background work is out (its report
    # would land on top of the prompt); without a pane, a fresh chat starts
    # with it, as adopt does. `branch` picks the stack when the item
    # straddles several; else its first.
    def gui_restack(slug, branch)
      item = WorkItem.find(slug)
      stacks = GhStack.chains(item).select { |chain| chain["kind"] == "stack" }
      chain = branch ? stacks.find { |c| c["layers"].any? { |l| l["branch"] == branch } } : stacks.first
      raise ArgumentError, branch ? "#{branch} is in none of #{slug}'s stacks" : "#{slug} has no stack to restack" unless chain

      prompt = restack_prompt(chain)
      if @tmux.live?(slug)
        refuse_waiting(item)
        return gui_type_into_chat(item, prompt)
      end

      plan = Launcher.new.chat_plan(item, fresh: true, prompt: prompt)
      raise ArgumentError, "#{slug} has a chat running outside the GUI — restack from there, or end it first" if plan[:mode] == :live

      @tmux.open(slug, cwd: plan[:cwd], argv: plan[:argv], env: plan[:env])
      ok.merge("mode" => "start")
    end

    # One line: typed into a pane, each newline would submit.
    def restack_prompt(chain)
      branches = chain["layers"].map { |layer| layer["branch"] }
      behind = chain["layers"].select { |layer| layer["needsRestack"] }.map { |layer| layer["branch"] }
      status = behind.empty? ? "no layer is flagged as behind its parent" : "behind their parent: #{behind.join(", ")}"
      "Restack the gh-stack #{chain["trunk"]} ← #{branches.join(" ← ")} (bottom → top; #{status}) " \
        "with `gh stack rebase` (see the gh-stack skill). Resolve the conflicts it hits, " \
        "or stop and report any you can't resolve safely."
    end

    def gui_type_into_chat(item, text)
      refuse_mid_turn(item)
      raise ArgumentError, "could not type into #{item.slug}'s chat" unless @tmux.send_text(item.slug, text)

      sleep(Rotation::TYPE_SETTLE)
      raise ArgumentError, "could not type into #{item.slug}'s chat" unless @tmux.send_enter(item.slug)

      ok.merge("attached" => true)
    end

    # A page overlay's annotations, relayed by its dev server (no
    # Origin), become drafts of the item checked out where it serves — never
    # typed into a chat, so no page script can reach one. The page knows only
    # that checkout; of several items there, the one first in the chat view's
    # attention order (live chats first, then the most recently active). No
    # chat needs to be open.
    def gui_page_annotations(args)
      root = args["root"].to_s.strip
      raise ArgumentError, "no checkout root given" if root.empty?

      item = annotation_target(root)
      Drafts.new(item.slug).add_annotations(args["annotations"], url: args["url"], title: args["title"])
      ok.merge("slug" => item.slug)
    end

    def annotation_target(root)
      items = @state.items_checked_out_at(root)
      raise ArgumentError, "no work item has #{Quartermaster.shorten_home(File.expand_path(root))} checked out" if items.empty?

      attention = ChatAttention.new
      items.min_by { |item| attention.entry_for(item).sort_key }
    end

    def drafts_of(slug) = Drafts.new(WorkItem.find(slug).slug)

    # A diff comment, or a GitHub draft once GitHub would take it at its
    # commit (D8): the page offers Ask chat or a file comment before it gets
    # here, so a refusal is the guard, said as an error.
    def gui_draft_put(slug, args)
      item = WorkItem.find(slug)
      refuse_unanchorable(item, args) if args["kind"] == "github-comment" && !args["comment"].to_s.strip.empty?
      ok.merge("draft" => Drafts.new(item.slug).put_diff_comment(args))
    end

    # The draft's chip: to the review (checked like a put) or to the chat.
    def gui_draft_move(slug, id, to)
      item = WorkItem.find(slug)
      drafts = Drafts.new(item.slug)
      if to == "github"
        entry = drafts.find(id) or raise ArgumentError, "no draft #{id} on #{item.slug}"
        refuse_unanchorable(item, entry.merge("subject" => entry["subject"] || "line")) if entry["number"]
      end
      ok.merge("draft" => drafts.move(id, to))
    end

    def refuse_unanchorable(item, entry)
      root = ProjectMap.new.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root && File.directory?(root)

      refusal = ReviewAnchors.refusal(root, entry)
      raise ArgumentError, refusal if refusal
    end

    # The confirmation's numbers before "Post as pending review" (D4): a gh
    # query and a fetch, so off the action mutex.
    def gui_review_preview(slug, args)
      item = WorkItem.find(slug)
      review, entries = review_drafts(item, args)
      ok.merge("preview" => review.preview(entries))
    end

    # Posts the PR's GitHub drafts (those the tray showed) into the user's
    # pending review as the item's background job: a GitHub call per draft.
    def gui_review_post(slug, args)
      item = WorkItem.find(slug)
      review, entries = review_drafts(item, args)
      @jobs.background(item.slug, "posting to #{review.label}…") do
        result = review.post(entries, Drafts.new(item.slug))
        review_post_result(review, result)
      end
    end

    def review_post_result(review, result)
      parts = ["#{result["posted"]} added to your pending review on #{review.label} — submit it on GitHub"]
      parts << "#{result["outdated"]} outdated, not posted" if result["outdated"].positive?
      out = { "ok" => result["failed"].empty?, "message" => parts.join(" · "), "review" => true }
      out["error"] = "#{parts.join(" · ")} · #{result["failed"].size} failed and stay in the tray: " \
                     "#{result["failed"].first}" unless result["failed"].empty?
      if result["fallbacks"].positive?
        out["warning"] = "#{result["fallbacks"]} couldn't go on their old commit and became file comments quoting their line"
      end
      out
    end

    def review_drafts(item, args)
      root = ProjectMap.new.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root && File.directory?(root)

      review = PendingReview.new(root, repo: args["repo"].to_s, number: args["number"], runner: @runner)
      entries = Drafts.new(item.slug).entries.select do |entry|
        PendingReview::POSTED_KINDS.include?(entry["kind"]) && entry["repo"].to_s.casecmp?(review.repo) &&
          entry["number"] == review.number
      end
      entries = entries.select { |entry| args["ids"].include?(entry["id"]) } if args["ids"].is_a?(Array)
      raise ArgumentError, "no review drafts for #{review.label}" if entries.empty?

      [review, entries]
    end

    # The outdated card (D10): "line" puts the draft on a line of the PR's
    # head clicked in the diff, "file" makes it a file comment there (both
    # checked like a put), "commit" pins it to its old commit (ReviewPlan).
    def gui_draft_place(slug, args)
      item = WorkItem.find(slug)
      drafts = Drafts.new(item.slug)
      entry = drafts.find(args["id"].to_s) or raise ArgumentError, "no draft #{args["id"]} on #{item.slug}"
      raise ArgumentError, "only a review draft has a place on GitHub" unless entry["kind"] == "github-comment"

      fields =
        case args["how"]
        when "commit" then { "pin" => "commit" }
        when "line", "file"
          anchor = { "commit" => args["commit"], "base" => args["base"], "range" => nil, "pin" => nil,
                     "start_line" => nil, "start_side" => nil }
          if args["how"] == "line"
            anchor.merge(args.slice("path", "side", "line", "code"), "subject" => "line")
          else
            anchor.merge("subject" => "file")
          end
        else raise ArgumentError, "a draft is placed on a line, the file or its commit, not #{args["how"].inspect}"
        end
      placed = entry.merge(fields).compact
      refuse_unanchorable(item, placed) unless args["how"] == "commit"
      ok.merge("draft" => drafts.relocate(entry["id"], fields, bump: true))
    end

    # The diff pane's viewed checkbox on one file: its path and the digest of
    # its diff as shown (ViewedMarks).
    def gui_diff_viewed(slug, args)
      ok.merge("viewed" => ViewedMarks.new(WorkItem.find(slug).slug).set(args["path"], args["digest"], args["viewed"] == true))
    end

    # What a page overlay copied (ClipboardAnnotations), loaded by the 📋
    # button into the item whose toolbar it sits in: owners get `code` from
    # the checkout that item's chat runs in, and a payload already loaded is
    # refused (Drafts#add_annotations).
    def gui_drafts_load(slug, text)
      item = WorkItem.find(slug)
      payload = ClipboardAnnotations.parse(text)
      annotations = ClipboardAnnotations.quote(payload["annotations"], BranchDiff.new(tmux: @tmux).chat_checkout(item))
      added = Drafts.new(item.slug).add_annotations(annotations, url: payload["url"], title: payload["title"],
                                                                 load_id: payload["id"])
      ok.merge("loaded" => added.size, "ids" => added.map { |entry| entry["id"] })
    end

    # Resolve or unresolve a review thread on GitHub at once (D12/F6): no
    # confirmation, no pending review. The page refetches the threads after.
    def gui_thread_resolve(args)
      resolved = ReviewThreads.new(runner: @runner).resolve(args["repo"], args["number"], args["thread"],
                                                            resolved: args["resolve"] != false)
      ok.merge("resolved" => resolved)
    end

    # Every chat draft (or those of the ids the tray showed) as one message: the
    # diff comments' section in path:line order, the tray's, then the
    # annotations' in arrival order, then the issue comments'. Only the entries sent
    # go — one added or edited while the paste ran stays (Drafts#remove).
    def gui_drafts_send(slug, args)
      item = WorkItem.find(slug)
      raise ArgumentError, "#{slug} has no chat open in the GUI" unless @tmux.live?(slug)

      drafts = Drafts.new(item.slug)
      # GitHub drafts and thread replies wait for the pending review, never the chat.
      entries = drafts.entries.select { |entry| Drafts::CHAT_KINDS.include?(entry["kind"]) }
      entries = entries.select { |entry| args["ids"].include?(entry["id"]) } if args["ids"].is_a?(Array)
      raise ArgumentError, "no drafts to send" if entries.empty?

      paste_into_chat(item, drafts_message(item, entries, branch: args["branch"], base: args["base"]))
      drafts.remove(entries.to_h { |entry| [entry["id"], entry["rev"]] })
      ok.merge("sent" => entries.size)
    end

    # The annotations' header names the page most were captured on, and the
    # newest batch's page stands in for the one they were sent from. Issue
    # comments are checked against the issue files as they are now.
    def drafts_message(item, entries, branch:, base:)
      by_kind = entries.group_by { |entry| entry["kind"] }
      comments = Array(by_kind["diff-comment"])
      annotations = Array(by_kind["annotation"])
      issue_comments = Array(by_kind["issue-comment"])
      comments = comments.each_with_index.sort_by { |entry, index| [entry["path"].to_s, entry["line"].to_i, index] }.map(&:first)
      sections = []
      sections << DiffComments.message(comments, branch: branch, base: base) unless comments.empty?
      unless annotations.empty?
        paged = annotations.map { |entry| entry["page"].to_s.strip.empty? ? entry.merge("page" => entry["url"]) : entry }
        sections << PageAnnotations.message(paged, url: annotations.last["url"], title: annotations.last["title"])
      end
      sections << issue_comments_message(item, issue_comments) unless issue_comments.empty?
      raise ArgumentError, "no drafts of a kind this qm can send" if sections.empty?

      sections.join("\n\n")
    end

    def issue_comments_message(item, entries)
      issue_drafts = IssueDrafts.new(item.slug)
      data = issue_drafts.read
      issues = data["issues"].to_h { |issue| [issue["file"], issue] }
      IssueComments.message(entries, issues: issues, broken: data["errors"].map { |error| error["file"] },
                                     dir: Quartermaster.shorten_home(issue_drafts.dir))
    end

    # Create on GitHub: asks the chat to create the given drafted issues (or
    # every one not created yet) per the /draft-issues skill — qm never runs
    # gh itself. Refused like drafts-send, and for a file that isn't an open
    # draft (missing, broken or already created).
    def gui_issues_create(slug, files)
      item = WorkItem.find(slug)
      raise ArgumentError, "#{slug} has no chat open in the GUI" unless @tmux.live?(slug)

      issue_drafts = IssueDrafts.new(item.slug)
      data = issue_drafts.read
      uncreated = data["issues"].reject { |issue| issue["created"] }
      chosen = if files.is_a?(Array)
                 raise ArgumentError, "no issue drafts chosen" if files.empty?

                 files.map do |file|
                   uncreated.find { |issue| issue["file"] == file } or raise ArgumentError, unopen_reason(file, data)
                 end.uniq
               else
                 uncreated
               end
      raise ArgumentError, "no issue drafts left to create" if chosen.empty?

      paste_into_chat(item, issues_create_message(chosen, Quartermaster.shorten_home(issue_drafts.dir)))
      ok.merge("requested" => chosen.map { |issue| issue["file"] })
    end

    def unopen_reason(file, data)
      return "#{file} is already created on GitHub" if data["issues"].any? { |issue| issue["file"] == file }
      return "#{file} doesn't parse — fix it first" if data["errors"].any? { |error| error["file"] == file }

      "no issue draft #{file}"
    end

    def issues_create_message(issues, dir)
      count = "#{issues.size} drafted issue#{"s" unless issues.size == 1}"
      list = issues.map { |issue| "- #{issue["file"]} — #{issue["title"]}" }
      ["Create #{count} on GitHub, per the /draft-issues skill's create step. The files are in #{dir}:",
       list.join("\n"),
       "Then add `number: <n>` to each created file's frontmatter."].join("\n\n")
    end

    def gui_drafts_discard(slug, ids)
      drafts = drafts_of(slug)
      revs = ids.is_a?(Array) ? drafts.entries.select { |entry| ids.include?(entry["id"]) }.to_h { |entry| [entry["id"], entry["rev"]] } : nil
      ok.merge("discarded" => drafts.remove(revs))
    end

    # Pasted rather than typed: the message spans lines, and each typed
    # newline would submit.
    def paste_into_chat(item, text)
      refuse_mid_turn(item)
      raise ArgumentError, "could not paste into #{item.slug}'s chat" unless @tmux.paste(item.slug, text)

      sleep(Rotation::TYPE_SETTLE)
      raise ArgumentError, "could not submit in #{item.slug}'s chat" unless @tmux.send_enter(item.slug)
    end

    def refuse_mid_turn(item)
      session = Quartermaster.item_sessions(item).find(&:live?)
      state = session && ChatAttention.new.turn_for(session)[:state]
      raise ArgumentError, "#{item.slug}'s chat is mid-turn (#{state}) — try again once it is your turn" if %w[working blocked].include?(state)
    end

    # Background work out (ChatAttention's `waiting`): the turn has ended,
    # but its report would land on top of a typed prompt.
    def refuse_waiting(item)
      session = Quartermaster.item_sessions(item).find(&:live?)
      turn = session && ChatAttention.new.turn_for(session)
      return unless turn && turn[:state] == "waiting"

      raise ArgumentError, "#{item.slug}'s chat is waiting on background work (#{turn[:waiting_on].join(", ")}) — " \
                           "try again once it has reported back"
    end

    # The PRs tab's ✕ on a prerequisite chip: the same store the CLI writes.
    # Adding stays CLI-only — an agent knows what its PR waits on, the tab
    # doesn't.
    def gui_pr_unrequire(url, ref)
      raise ArgumentError, "#{url} has no prerequisite #{ref}" unless PrPrerequisites.new.remove(url.to_s, ref.to_s)

      ok
    end

    # A PR's chat is the chat of the work item holding its branch; a PR no
    # item has yet gets one, branch linked, so its next chat finds it again.
    def gui_pr_chat(url)
      pr = PrInbox.new.find(url)
      project = @pr_items.project_for_repo(pr["repo"], ProjectMap.new) || ProjectMap::NO_PROJECT
      item = @pr_items.pr_item(pr, project, WorkItem.all) ||
             @pr_items.find_or_create_item("#{@pr_items.pr_label(pr)}: #{pr["title"]}", project: project, branch: pr["head"],
                                           description: "Pull request #{@pr_items.pr_summary(pr)}.")
      gui_pane(item.slug, fresh: false).merge("slug" => item.slug)
    end

    def gui_pr_review(url)
      ok.merge(PrReviewStart.new(tmux: @tmux, pr_items: @pr_items).start(PrInbox.new.find(url)))
    end

    # Start work on a GitHub issue. An item already holding it gets its chat
    # opened instead ("existing"); otherwise the worktree (a fetch, git
    # worktree add, maybe a test DB) is made on a background job keyed by the
    # new item's slug, which then opens the chat with the kickoff prompt. from:
    # the drafting item's slug, noted with what the issue became.
    def gui_issue_start(args)
      preview = issue_start.preview(args["number"], issue_project(args))
      if (existing = preview["existing"])
        item = WorkItem.find(existing["slug"])
        item.update_state("in_progress") if item.state == "resolved"
        return gui_pane(item.slug, fresh: false).merge("slug" => item.slug, "existing" => true, "issue" => preview)
      end

      from = presence(args["from"])
      WorkItem.find(from) if from
      slug = preview["slug"]
      @jobs.background(slug, "starting ##{preview["number"]}…") do
        started = issue_start.start(preview, from: from, progress: ->(label) { @jobs.relabel(slug, label) })
        item = started[:item]
        plan = Launcher.new.chat_plan(item, fresh: true, prompt: IssueStart.kickoff(preview["number"]))
        @tmux.open(item.slug, cwd: plan[:cwd], argv: plan[:argv], env: plan[:env]) unless plan[:mode] == :live
        { "ok" => true, "slug" => item.slug, "branch" => preview["branch"], "path" => started[:target].path,
          "message" => "##{preview["number"]} started as #{item.slug} in #{Quartermaster.shorten_home(started[:target].path)}" }
      end.merge("slug" => slug, "issue" => preview)
    end

    def issue_start = IssueStart.new(runner: @runner)

    def issue_project(args) = presence(args["project"]) || ProjectConfig.current.default_project || ProjectMap::NO_PROJECT

    # The dev server / the IDE on the PR's own branch (a new worktree when none has it).
    # The job is keyed by the PR's item when it has one, so the item's other
    # workspace actions wait on it like on their own.
    def pr_workspace_job(url, pf:)
      pr = PrInbox.new.find(url)
      project = @pr_items.project_for_repo(pr["repo"], ProjectMap.new)
      raise ArgumentError, "#{pr["repo"]} is not a project qm knows: run `qm config set projects.<name>.root <its checkout>`" unless project

      label = pf ? "switching the dev server…" : "opening #{ProjectConfig.current.ide!(project).label}…"
      item = @pr_items.pr_item(pr, project, WorkItem.all)
      @jobs.background(item&.slug || @pr_items.pr_label(pr), label, pf: pf) do
        workspace = Workspace.new(runner: @runner)
        report = if pf
                   workspace.switch_pf_to_branch(project, pr["head"], mode: item&.pf_mode)
                 else
                   workspace.open_ide_on_branch(project, pr["head"])
                 end
        { "ok" => true, "message" => "#{@pr_items.pr_label(pr)}: #{report.steps.join("; ")}",
          "switched" => report.mode ? true : false, "path" => report.target.path }
      ensure
        @state.forget_pf_status if pf
      end
    end

    def gui_pf_stop
      @jobs.background("pf", "stopping the dev server…", pf: true) do
        { "ok" => true, "message" => Workspace.new(runner: @runner).stop_pf }
      ensure
        @state.forget_pf_status
      end
    end

    # After a switch: bin/update in a tmux session of its own, which the page
    # shows in a terminal dialog. Migrations stay manual — bin/update is
    # the user's to watch, so the session waits for Enter once it finishes
    # instead of vanishing with its output.
    def gui_run_update(path)
      path = File.expand_path(path.to_s)
      raise ArgumentError, "no bin/update in #{Quartermaster.shorten_home(path)}" unless File.executable?(File.join(path, "bin", "update"))

      name = "bin-update-#{File.basename(path).gsub(/[^A-Za-z0-9_-]/, "-")}"
      script = 'bin/update; echo; echo "[bin/update exited $?, Enter closes]"; read _'
      @tmux.open(name, cwd: path, argv: ["sh", "-c", script])
      ok.merge("session" => name)
    end

    # The ☕ toggle, and `qm caffeinate on|off|auto|status` from the CLI, which
    # POSTs here like the page does (a local process sends no Origin, the same
    # pass curl gets).
    def gui_caffeinate(mode)
      status = case mode
               when "on" then @caffeinate.on
               when "off" then @caffeinate.off
               when "auto" then @caffeinate.auto(sessions_busy?)
               when "status", nil then @caffeinate.status
               else raise ArgumentError, "caffeinate: mode must be on, off, auto or status"
               end
      ok.merge("caffeinate" => status)
    end

    def gui_board_answer(slug, doc_id, text)
      BoardMirror.shared.answer(WorkItem.find(slug), doc_id.to_s, text.to_s)
      ok
    end

    def presence(value) = value.to_s.strip.empty? ? nil : value.to_s

    def gui_resume(slug, session_id)
      item = WorkItem.find(slug)
      launcher = Launcher.new
      if launcher.resume_plan(item, session_id: session_id)[:mode] == :live
        return { "ok" => false, "error" => "that session is running right now — switch to its Warp tab" }
      end

      launcher.resume(item, session_id: session_id)
      ok
    end

    # Resume for a session with no work item (the inbox's session sheet). The
    # plan's dead ends become JSON errors here so the button never kills the
    # server through Launcher's aborts.
    def gui_resume_session(session_id)
      launcher = Launcher.new
      case launcher.session_resume_plan(session_id)[:mode]
      when :live then { "ok" => false, "error" => "that session is running right now — switch to its Warp tab" }
      when :gone then { "ok" => false, "error" => "no surviving transcript to resume" }
      else
        launcher.resume_session(session_id)
        ok
      end
    end

    def gui_note(slug, text, kind)
      text = text.to_s.strip
      raise ArgumentError, "note text is empty" if text.empty?

      WorkItem.find(slug).add_note(text, kind: kind.to_s.empty? ? DEFAULT_NOTE_KIND : kind)
      ok
    end

    def gui_retag(slug, position, kind)
      WorkItem.find(slug).update_note_kind(Integer(position, exception: false) || 0, kind)
      ok
    end

    def gui_retitle(slug, title)
      title = title.to_s.strip
      raise ArgumentError, "title is empty" if title.empty?

      WorkItem.find(slug).retitle(title)
      ok
    end

    def gui_pr(slug, branch)
      PrStatus.new.open_web(WorkItem.find(slug), branch: branch)
      ok
    end

    def gui_snooze(slug, duration)
      WorkItem.find(slug).snooze(duration)
      ok
    end

    def gui_ack(slug)
      ids = Attention.new.acknowledge_all(WorkItem.find(slug))
      { "ok" => true, "acked" => ids.size }
    end

    def gui_new(args)
      title = args["title"].to_s.strip
      raise ArgumentError, "title is required" if title.empty?

      description = args["description"].to_s.strip
      item = WorkItem.create(title, project: args["project"] || ProjectMap::NO_PROJECT,
                                    description: description.empty? ? nil : description)
      { "ok" => true, "slug" => item.slug }
    end

    def gui_item_from_session(session_id, title)
      title = title.to_s.strip
      raise ArgumentError, "title is required" if title.empty?

      item, vacated = WorkItem.from_session(session_id, title: title)
      pane_follows({ "ok" => true, "slug" => item.slug, "detached" => vacated }, session_id, vacated, item.slug)
    end

    def gui_attach(slug, session_id)
      vacated = WorkItem.find(slug).claim_session(session_id)
      pane_follows({ "ok" => true, "detached" => vacated }, session_id, vacated, slug)
    end

    # A chat pane running the moved session follows it to the new item
    # (docs/areas/chats.md); a pane that can't follow is reported in `warning`.
    def pane_follows(reply, session_id, vacated, slug)
      warning = PaneFollowsSession.new(tmux: @tmux).move(session_id, from: vacated, to: slug)
      warning ? reply.merge("warning" => warning) : reply
    end
  end
end
