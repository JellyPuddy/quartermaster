# frozen_string_literal: true

module Quartermaster
  # The GUI's issue start (IssueStart, docs/areas/issues.md): issue-preview
  # only reads GitHub, so Gui runs it off the action mutex; issue-start makes
  # the item; links-refresh reads any item's issue again for its missing
  # links; epic-sub-issues reads its sub-issues. GuiActions hands them here, with its pane opener for the chat of
  # an item that already holds the issue.
  class GuiIssueActions
    COMMANDS = %w[issue-preview issue-start links-refresh epic-sub-issues].freeze

    def initialize(runner:, jobs:, tmux:, pane:)
      @runner = runner
      @jobs = jobs
      @tmux = tmux
      @pane = pane
    end

    def dispatch(cmd, slug, args)
      case cmd
      when "issue-preview" then ok.merge("issue" => issue_start.preview(args["number"], project(args)))
      when "issue-start" then start(args)
      when "links-refresh" then refresh_links(slug)
      when "epic-sub-issues" then ok.merge("sub_issues" => issue_start.sub_issues(args["epic"].to_s))
      end
    end

    private

    def ok = { "ok" => true }

    # ↻ links: the item's issue read again on a job keyed by the item, adding
    # the links it lacks (IssueStart#refresh_links).
    def refresh_links(slug)
      item = WorkItem.find(slug)
      @jobs.background(item.slug, "refreshing links…") do
        added = issue_start.refresh_links(item)
        { "ok" => true,
          "message" => "#{item.slug}: #{added.empty? ? "no links to add" : "added #{added.map { |l| l["label"] }.join(", ")}"}" }
      end
    end

    # Start work on a GitHub issue. An item already holding it gets its chat
    # opened instead ("existing"; an epic only answers, it has no chat).
    # An epic issue starts as an epic unless as_epic is false: made at once,
    # no worktree, no chat. Otherwise the worktree (a fetch, git worktree add,
    # maybe a test DB) is made on a background job keyed by the new item's
    # slug, which then opens the chat with the kickoff prompt. from: the
    # drafting item's slug, noted with what the issue became. epic: the epic
    # the new item sits in (a sub-issue started from the epic's view).
    def start(args)
      preview = issue_start.preview(args["number"], project(args))
      return existing(preview) if preview["existing"]

      from = presence(args["from"])
      WorkItem.find(from) if from
      epic = presence(args["epic"])
      as_epic = args["as_epic"].nil? ? preview["epic"] && !epic : [true, "true", "1"].include?(args["as_epic"])
      WorkItem.check_epic_target!(epic, kind: as_epic ? WorkItemEpic::EPIC_KIND : nil, slug: preview["slug"]) if epic
      return start_epic(preview, from) if as_epic

      slug = preview["slug"]
      @jobs.background(slug, "starting ##{preview["number"]}…") do
        started = issue_start.start(preview, from: from, progress: ->(label) { @jobs.relabel(slug, label) },
                                             as_epic: false, epic: epic)
        item = started[:item]
        plan = Launcher.new.chat_plan(item, fresh: true, prompt: IssueStart.kickoff(preview["number"]))
        @tmux.open(item.slug, cwd: plan[:cwd], argv: plan[:argv], env: plan[:env]) unless plan[:mode] == :live
        { "ok" => true, "slug" => item.slug, "branch" => preview["branch"], "path" => started[:target].path,
          "message" => "##{preview["number"]} started as #{item.slug} in #{Quartermaster.shorten_home(started[:target].path)}" }
      end.merge("slug" => slug, "issue" => preview)
    end

    def existing(preview)
      item = WorkItem.find(preview["existing"]["slug"])
      item.update_state("in_progress") if item.state == "resolved"
      reply = { "slug" => item.slug, "existing" => true, "issue" => preview }
      return ok.merge(reply, "epic" => true) if item.epic?

      @pane.call(item.slug, fresh: false).merge(reply)
    end

    def start_epic(preview, from)
      started = issue_start.start(preview, from: from, as_epic: true)
      slug = started[:item].slug
      ok.merge("slug" => slug, "epic" => true, "issue" => preview, "attached" => started[:attached],
               "skipped" => started[:skipped], "message" => epic_message(preview["number"], slug, started))
    end

    def epic_message(number, slug, started)
      parts = ["##{number} started as epic #{slug}"]
      parts << "joined: #{started[:attached].join(", ")}" unless started[:attached].empty?
      parts << "left out: #{IssueStart.skipped_text(started[:skipped])}" unless started[:skipped].empty?
      parts.join(" · ")
    end

    def issue_start = IssueStart.new(runner: @runner)

    def project(args) = presence(args["project"]) || ProjectConfig.current.default_project || ProjectMap::NO_PROJECT

    def presence(value) = value.to_s.strip.empty? ? nil : value.to_s
  end
end
