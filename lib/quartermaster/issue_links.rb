# frozen_string_literal: true

module Quartermaster
  # The links an item started from a GitHub issue carries, derived from the
  # issue (as IssueStart#fetch reads it) and the project's issue-link
  # settings (ProjectSettings::IssueLinkSettings): a Tracker link from the URL
  # template, the first Notion URL in a comment by the configured author, and
  # one link per heading rule from the issue body. Each is skipped when its
  # setting or its source is missing. Only http(s) URLs come out, the ones
  # WorkItem#set_link takes, each label and URL once (the first wins).
  class IssueLinks
    TRACKER_LABEL = "Tracker"
    NOTION_URL = %r{https?://(?:[\w-]+\.)*notion\.(?:so|com)/[^\s)>\]]+}i
    HTML_COMMENT = /<!--.*?(?:-->|\z)/m
    HEADING = /^ {0,3}\#{1,6}(?:[ \t]+(.*?))?[ \t#]*$/
    BODY_URL = %r{https?://[^\s)<>\]]+}i

    def initialize(settings)
      @settings = settings
    end

    # [{"label", "url"}] for the issue in repo ("owner/name").
    def for(issue, repo)
      candidates = [tracker(issue, repo), notion(issue), *headings(issue)].compact
      candidates.select { |link| link["url"].match?(WorkItemEpic::LINK_URL) }.each_with_object([]) do |link, kept|
        kept << link unless kept.any? { |own| own["label"] == link["label"] || own["url"] == link["url"] }
      end
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

    # Per rule: the first URL in the section under the first heading (any
    # level) whose text holds the rule's word, any case, up to the next
    # heading; HTML comments count as absent.
    def headings(issue)
      rules = Array(@settings.headings)
      return [] if rules.empty?

      sections = body_sections(issue["body"].to_s)
      rules.filter_map do |word, label|
        section = sections.find { |title, _| title.downcase.include?(word.downcase) }
        url = section && section[1][BODY_URL]
        url && { "label" => label, "url" => url }
      end
    end

    # [[heading text, the lines under it]] in body order.
    def body_sections(body)
      body.gsub(HTML_COMMENT, "").each_line.with_object([]) do |line, sections|
        if (heading = line.chomp.match(HEADING))
          sections << [heading[1].to_s, +""]
        elsif sections.any?
          sections.last[1] << line
        end
      end
    end
  end
end
