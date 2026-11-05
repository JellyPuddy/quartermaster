# frozen_string_literal: true

module Quartermaster
  # Every item's issue drafts in one list, for the GUI's Issues view: one
  # entry per work item whose issues directory holds a draft or a broken
  # file. In progress first, then fridge, then resolved; within a state the
  # item whose files changed last first. Without the issue bodies.
  class IssueIndex
    ISSUE_FIELDS = %w[file title kind number created].freeze

    def initialize(project_map: ProjectMap.new)
      @project_map = project_map
      @repos = {}
    end

    def entries
      slugs.filter_map { |slug| entry(slug) }
           .sort_by { |e| [STATES.index(e["state"]) || STATES.size, -e["changed_at"].to_f, e["slug"]] }
           .map { |e| e.merge("changed_at" => Time.at(e["changed_at"]).utc.iso8601) }
    end

    private

    def slugs
      Dir.glob(File.join(IssueDrafts::DIR, "*")).select { |path| File.directory?(path) }
         .map { |path| File.basename(path) }.grep(Drafts::SLUG).sort
    end

    # nil for a directory without drafts or without its work item.
    def entry(slug)
      drafts = IssueDrafts.new(slug)
      return nil if drafts.files.empty?

      item = WorkItem.find(slug)
      data = drafts.read
      { "slug" => slug, "title" => item.title, "state" => item.state, "repo" => repo(item.project),
        "changed_at" => changed_at(drafts),
        "issues" => data["issues"].map { |issue| issue.slice(*ISSUE_FIELDS) }, "errors" => data["errors"] }
    rescue ArgumentError
      nil
    end

    def changed_at(drafts)
      drafts.files.filter_map do |name|
        File.mtime(File.join(drafts.dir, name)).to_r
      rescue SystemCallError
        nil
      end.max || 0
    end

    # The repo the Issues pane links numbers into (Gui#issues_payload),
    # looked up once per project.
    def repo(project)
      @repos.fetch(project) do
        root = @project_map.root_for(project)
        @repos[project] = root && Quartermaster.github_repo(root)
      end
    end
  end
end
