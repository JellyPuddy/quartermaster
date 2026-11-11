# frozen_string_literal: true

module Quartermaster
  # The GUI's issue start (IssueStart, docs/areas/issues.md): issue-preview
  # only reads GitHub, so Gui runs it off the action mutex; issue-start makes
  # the item. GuiActions hands both here, with its pane opener for the chat
  # of an item that already holds the issue.
  class GuiIssueActions
    COMMANDS = %w[issue-preview issue-start].freeze

    def initialize(runner:, jobs:, tmux:, pane:)
      @runner = runner
      @jobs = jobs
      @tmux = tmux
      @pane = pane
    end

    def dispatch(cmd, args)
      case cmd
      when "issue-preview" then ok.merge("issue" => issue_start.preview(args["number"], project(args)))
      when "issue-start" then start(args)
      end
    end

    private

    def ok = { "ok" => true }

    # Start work on a GitHub issue. An item already holding it gets its chat
    # opened instead ("existing"; an epic only answers, it has no chat).
    # An epic issue starts as an epic unless as_epic is false: made at once,
    # no worktree, no chat. Otherwise the worktree (a fetch, git worktree add,
    # maybe a test DB) is made on a background job keyed by the new item's
    # slug, which then opens the chat with the kickoff prompt. from: the
    # drafting item's slug, noted with what the issue became.
    def start(args)
      preview = issue_start.preview(args["number"], project(args))
      return existing(preview) if preview["existing"]

      from = presence(args["from"])
      WorkItem.find(from) if from
      as_epic = args["as_epic"].nil? ? preview["epic"] : [true, "true", "1"].include?(args["as_epic"])
      return start_epic(preview, from) if as_epic

      slug = preview["slug"]
      @jobs.background(slug, "starting ##{preview["number"]}…") do
        started = issue_start.start(preview, from: from, progress: ->(label) { @jobs.relabel(slug, label) },
                                             as_epic: false)
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
      item = issue_start.start(preview, from: from, as_epic: true)[:item]
      ok.merge("slug" => item.slug, "epic" => true, "issue" => preview,
               "message" => "##{preview["number"]} started as epic #{item.slug}")
    end

    def issue_start = IssueStart.new(runner: @runner)

    def project(args) = presence(args["project"]) || ProjectConfig.current.default_project || ProjectMap::NO_PROJECT

    def presence(value) = value.to_s.strip.empty? ? nil : value.to_s
  end
end
