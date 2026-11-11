# frozen_string_literal: true

# Shared by the issue-start tests: a scripted gh and a Widget project whose
# origin is acme/widget on GitHub.
require_relative "test_helper"

# gh is scripted and `git fetch` stubbed; only `git worktree add` runs for
# real, against a throwaway repo whose origin/main is a local ref.
class IssueRunner < FakeRunner
  def call(argv, chdir: nil)
    return super unless argv.first(2) == %w[git worktree]

    @calls << { argv: argv, chdir: chdir }
    Quartermaster::CommandRunner.new.call(argv, chdir: chdir)
  end
end

module IssueStartHelpers
  include StackRepoHelpers

  ISSUE_URL = "https://github.com/acme/widget/issues/123"

  NOTION_URL = "https://app.notion.com/p/Export-epic-3e6b2d0ad7f681a2"
  NOTES_BOT = { "author" => { "login" => "notes-bot" }, "body" => "Epic created in Notion: #{NOTION_URL}" }.freeze
  SUB_ISSUES = [{ "number" => 124, "title" => "Empty rows", "state" => "OPEN", "url" => "#{ISSUE_URL.chomp("123")}124" },
                { "number" => 125, "title" => "Frozen header", "state" => "CLOSED",
                  "url" => "#{ISSUE_URL.chomp("123")}125" }].freeze

  # Widget's epic settings: which GitHub issue types are epics.
  EPIC_SETTINGS = { "issue_types" => %w[Project Epic] }.freeze
  # Widget's issue-link settings: the tracker link's template, whose comment
  # carries the Notion link and its label.
  LINK_SETTINGS = { "tracker_url" => "https://tracker.example/ws/{repo}/{number}",
                    "notion_author" => "notes-bot", "notion_label" => "Notion page" }.freeze
  TRACKER = { "label" => "Tracker", "url" => "https://tracker.example/ws/acme/widget/123" }.freeze

  # gh api graphql's answer, shaped like GitHub's (issueType null when unset).
  def issue_runner(state: "OPEN", title: "Export breaks on empty rows", known: true, type: nil, sub_issues: [], comments: [],
                   body: "")
    issue = { "number" => 123, "title" => title, "state" => state, "url" => ISSUE_URL, "body" => body,
              "issueType" => type && { "name" => type }, "subIssues" => { "nodes" => sub_issues },
              "comments" => { "nodes" => comments } }
    view = if known
             [JSON.generate("data" => { "repository" => { "issue" => issue } }), "", true]
           else
             ["", "GraphQL: Could not resolve to an issue with the number of 123. (repository.issue)", false]
           end
    IssueRunner.new(%w[gh api graphql] => view, %w[gh repo view] => ["main\n", "", true],
                    ["curl"] => ["", "", false], %w[pf status] => ["", "", false])
  end

  def epic_runner(**rest) = issue_runner(type: "Project", sub_issues: SUB_ISSUES,
                                         comments: [{ "author" => { "login" => "someone" }, "body" => "https://notion.so/not-this" },
                                                    NOTES_BOT], **rest)

  # A repo whose origin is acme/widget on GitHub, configured as project
  # "Widget" (and "WebApp", configured with a test-DB command). epics and
  # links: Widget's epics and issue_links settings.
  def with_widget_repo(epics: nil, links: nil)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      system("git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/widget.git")
      system("git", "-C", repo, "update-ref", "refs/remotes/origin/main", "HEAD")
      Quartermaster.ensure_setup
      widget = { "root" => repo, "epics" => epics, "issue_links" => links }.compact
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Widget" => widget, "WebApp" => featured_project(repo) } }.to_yaml)
      yield repo
    end
  end

  def starter(runner) = Quartermaster::IssueStart.new(runner: runner)
end
