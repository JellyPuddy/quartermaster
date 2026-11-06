# frozen_string_literal: true

module Quartermaster
  # A PR's review runs in a chat of its own — a separate item, so it never
  # lands in the PR's own chat — with the review skill as its first prompt.
  # The item links no branch: auto-matching a branch to two items is
  # ambiguous. It starts in the main checkout; the skill reads the PR from
  # GitHub. The GUI's Review button and the pr-review automation flow share
  # it; nothing here needs a GUI.
  class PrReviewStart
    # project_map: nil reads config.yml afresh on every call, as a long-lived
    # GUI must; items: how to list the work items.
    def initialize(tmux:, pr_items:, project_map: nil, items: -> { WorkItem.all })
      @tmux = tmux
      @pr_items = pr_items
      @project_map = project_map
      @items = items
    end

    # The PR's Review item, made when it has none.
    def item_for(pr)
      @pr_items.review_item(pr, @items.call) ||
        @pr_items.find_or_create_item("Review #{@pr_items.pr_label(pr)}: #{pr["title"]}", project: project_for(pr),
                                      description: "Review of pull request #{@pr_items.pr_summary(pr)}.")
    end

    # Whether the PR's Review chat runs, in a pane or outside one. Starts and
    # creates nothing.
    def live?(pr)
      item = @pr_items.review_item(pr, @items.call)
      !item.nil? && (@tmux.live?(item.slug) || launcher.chat_plan(item, fresh: true)[:mode] == :live)
    end

    # Opens the Review item's chat: { "slug", "attached" => true } when its
    # pane already runs, else { "slug", "mode" => "start" }. extra_argv goes
    # before the kickoff prompt, which stays the last argument; kickoff_suffix
    # is appended to the kickoff as a paragraph of its own.
    def start(pr, extra_argv: [], kickoff_suffix: nil)
      item = item_for(pr)
      return { "slug" => item.slug, "attached" => true } if @tmux.live?(item.slug)

      item.update_state("in_progress") if item.state == "resolved"
      plan = launcher.chat_plan(item, fresh: true)
      raise ArgumentError, "#{item.slug} has a chat running outside the GUI — review from there, or end it first" if plan[:mode] == :live

      @tmux.open(item.slug, cwd: plan[:cwd], argv: [*plan[:argv], *extra_argv, kickoff(pr, item.slug, kickoff_suffix)], env: plan[:env])
      { "slug" => item.slug, "mode" => "start" }
    end

    private

    def kickoff(pr, slug, suffix)
      skill = project_map.settings_for(project_for(pr)).review_skill
      text = @pr_items.review_kickoff(skill, pr, slug)
      suffix.to_s.strip.empty? ? text : "#{text}\n\n#{suffix.strip}"
    end

    def project_for(pr) = @pr_items.project_for_repo(pr["repo"], project_map) || ProjectMap::NO_PROJECT

    def project_map = @project_map || ProjectMap.new

    def launcher = Launcher.new(project_map: project_map)
  end
end
