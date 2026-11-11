# frozen_string_literal: true

module Quartermaster
  # The links an epic started from a GitHub issue carries, derived from the
  # issue (as IssueStart#fetch reads it) and the project's issue settings
  # (ProjectSettings::Epics): a Tracker link from the URL template, and the
  # first Notion URL in a comment by the configured author. Each is skipped
  # when its setting or its source is missing. Only http(s) URLs come out,
  # the ones WorkItem#set_link takes.
  class IssueLinks
    TRACKER_LABEL = "Tracker"
    NOTION_URL = %r{https?://(?:[\w-]+\.)*notion\.(?:so|com)/[^\s)>\]]+}i

    def initialize(settings)
      @settings = settings
    end

    # [{"label", "url"}] for the issue in repo ("owner/name").
    def for(issue, repo)
      [tracker(issue, repo), notion(issue)].compact.select { |link| link["url"].match?(WorkItemEpic::LINK_URL) }
    end

    private

    def tracker(issue, repo)
      return nil unless (template = @settings.tracker_url)

      owner, name = repo.to_s.split("/", 2)
      values = { "repo" => repo.to_s, "owner" => owner.to_s, "name" => name.to_s, "number" => issue["number"].to_s }
      { "label" => TRACKER_LABEL, "url" => template.gsub(/\{(repo|owner|name|number)\}/) { values.fetch(Regexp.last_match(1)) } }
    end

    def notion(issue)
      return nil unless (author = @settings.notion_author)

      url = Array(issue.dig("comments", "nodes")).filter_map do |comment|
        comment.is_a?(Hash) && comment.dig("author", "login") == author && comment["body"].to_s[NOTION_URL]
      end.first
      url && { "label" => @settings.notion_label, "url" => url }
    end
  end
end
