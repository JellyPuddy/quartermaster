# frozen_string_literal: true

module Quartermaster
  # Any GitHub issue as a work item with its own worktree: preview it
  # (read-only — one gh api graphql call), then start it: an
  # `issue/<n>-<title>` branch off freshly fetched origin, its worktree, the
  # item linked to it. The chat itself is the caller's (the GUI's pane, or
  # the CLI's instructions), with #kickoff as its first prompt. An issue whose
  # type the project lists as an epic type starts as an epic item instead: no
  # branch, worktree or chat, its IssueLinks set. qm only reads GitHub:
  # nothing is assigned, labelled or moved.
  class IssueStart
    BRANCH_SLUG_MAX = 40
    LIST_MAX = 100

    QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          issue(number: $number) {
            number title state url
            issueType { name }
            subIssues(first: #{LIST_MAX}) { nodes { number title state url } }
            comments(first: #{LIST_MAX}) { nodes { author { login } body } }
          }
        }
      }
    GRAPHQL

    def initialize(project_map: ProjectMap.new, runner: CommandRunner.new)
      @project_map = project_map
      @runner = runner
    end

    def self.kickoff(number)
      "Read issue ##{number} (`gh issue view #{number} --comments`), summarise the problem, then " \
        "run a grilling session (the grilling skill) with me on how to solve it. Don't change code yet."
    end

    # "#1234", "1234" → 1234; anything else is refused before gh runs.
    def self.number(value)
      text = value.to_s.strip.delete_prefix("#")
      raise ArgumentError, "an issue number is required, not '#{value}'" unless text.match?(/\A[1-9]\d*\z/)

      text.to_i
    end

    # What Start would do, as the JSON the GUI shows: the issue, the project,
    # and either the item that already holds it ("existing") or the branch it
    # would create or reuse. A closed issue is still startable ("closed").
    # epic: its type is one of the project's epic types; links: what an epic
    # started from it would carry; sub_issues: GitHub's child issues
    # ({number, title, state, url}).
    def preview(number, project)
      number = self.class.number(number)
      root, repo = repo_for(project)
      issue = fetch_issue(root, repo, number)
      existing = existing_item(project, number, url: issue["url"])
      reuse = existing ? nil : reusable_branch(root, number)
      settings = @project_map.settings_for(project).epics
      {
        "number" => number, "title" => issue["title"].to_s, "state" => issue["state"].to_s.downcase,
        "closed" => issue["state"].to_s.casecmp?("closed"), "url" => issue["url"].to_s,
        "project" => project, "repo" => repo,
        "branch" => existing ? nil : reuse || branch_name(number, issue["title"].to_s),
        "reuse_branch" => !reuse.nil?,
        "slug" => existing ? existing.slug : WorkItem.slugify(item_title(number, issue["title"].to_s)),
        "existing" => existing && { "slug" => existing.slug, "title" => existing.title, "state" => existing.state,
                                    "epic" => existing.epic? },
        "epic" => settings.epic_type?(issue.dig("issueType", "name")),
        "links" => IssueLinks.new(settings).for(issue, repo),
        "sub_issues" => sub_issues(issue)
      }
    end

    # The links an epic started from the project's issue #number would carry
    # (IssueLinks), read from GitHub now.
    def links_for(project, number)
      root, repo = repo_for(project)
      IssueLinks.new(@project_map.settings_for(project).epics).for(fetch_issue(root, repo, self.class.number(number)), repo)
    end

    # Creates the worktree first, then the item: a retry after a failed item
    # step finds the branch unlinked and reuses it. from: the item the issue
    # was drafted in, which gets a note saying what it became. progress:
    # called with a short label before each slow step. as_epic (default: the
    # preview's epic) makes an epic item carrying the preview's links instead,
    # with no worktree (target nil).
    def start(preview, from: nil, progress: nil, as_epic: nil)
      raise ArgumentError, "##{preview["number"]} is already #{preview["existing"]["slug"]}" if preview["existing"]

      project = preview["project"]
      title = item_title(preview["number"], preview["title"])
      slug = WorkItem.slugify(title)
      raise ArgumentError, "work item '#{slug}' already exists" if File.exist?(WorkItem.path_for(slug))
      return start_epic(preview, title, from) if as_epic.nil? ? preview["epic"] : as_epic

      root, repo = repo_for(project)
      target = TargetWorktree.new(project_map: @project_map, runner: @runner)
      worktree = if preview["reuse_branch"]
                   progress&.call("opening the worktree…")
                   target.materialize_branch(project, preview["branch"])
                 else
                   default = default_branch(root, repo)
                   progress&.call("fetching origin/#{default}…")
                   run!(["git", "fetch", "origin", default], "git fetch", chdir: root)
                   progress&.call("creating the worktree…")
                   target.materialize_branch(project, preview["branch"], base: "origin/#{default}")
                 end

      item = WorkItem.create(title, project: project, description: description(preview))
      item.link_branch(preview["branch"])
      note_started(from, preview, item)
      { item: WorkItem.find(item.slug), target: worktree }
    end

    # The item that already holds the issue: one of the project's items with
    # an issue/<n> branch linked, or any item whose description carries the
    # issue's URL. An unresolved one wins, then one holding the branch.
    def existing_item(project, number, url: nil, items: WorkItem.all)
      url_pattern = url && !url.empty? && /#{Regexp.escape(url)}(?!\d)/
      items.filter_map do |item|
        by_branch = item.project == project && item.branches.any? { |b| issue_branch?(b, number) }
        next unless by_branch || (url_pattern && item.description.match?(url_pattern))

        [item.state == "resolved" ? 1 : 0, by_branch ? 0 : 1, item]
      end.min_by { |resolved, by_url, _| [resolved, by_url] }&.last
    end

    private

    def item_title(number, title) = "#{title} (##{number})"

    def description(preview) = "#{preview["url"]}\n\n#{preview["title"]}"

    def start_epic(preview, title, from)
      front = { "kind" => WorkItemEpic::EPIC_KIND }
      front["links"] = preview["links"] unless Array(preview["links"]).empty?
      item = WorkItem.create(title, project: preview["project"], description: description(preview), front: front)
      note_started(from, preview, item)
      { item: item, target: nil }
    end

    def note_started(from, preview, item)
      WorkItem.find(from).add_note("##{preview["number"]} started as #{item.slug}", kind: "history") if from
    end

    def sub_issues(issue)
      Array(issue.dig("subIssues", "nodes")).filter_map do |sub|
        sub.slice("number", "title", "state", "url") if sub.is_a?(Hash) && sub["number"]
      end
    end

    # issue/<n>-<slug of the title>, the slug cut at a word boundary so the
    # branch (and its worktree directory) stays readable.
    def branch_name(number, title)
      words = WorkItem.slug_words(title).split("-")
      slug = words.each_with_object([]) do |word, kept|
        break kept if kept.any? && (kept + [word]).join("-").length > BRANCH_SLUG_MAX

        kept << word
      end.join("-")
      slug.empty? ? "issue/#{number}" : "issue/#{number}-#{slug}"
    end

    def issue_branch?(branch, number)
      branch == "issue/#{number}" || branch.start_with?("issue/#{number}-")
    end

    # A local issue/<n>-* branch no item links: earlier work on the issue,
    # picked up rather than started over beside it.
    def reusable_branch(root, number)
      listing = Quartermaster.git(root, "for-each-ref", "--format=%(refname:short)", "refs/heads/issue/").to_s
      linked = WorkItem.all.flat_map(&:branches)
      listing.split("\n").find { |branch| issue_branch?(branch, number) && !linked.include?(branch) }
    end

    def repo_for(project)
      root = @project_map.root_for(project)
      raise ArgumentError, "no repo root configured for project '#{project}'" unless root

      repo = Quartermaster.github_repo(root)
      raise ArgumentError, "project '#{project}' has no GitHub origin remote — qm can't tell which repo its issues are in" unless repo

      [root, repo]
    end

    # The issue with its type, sub-issues and comments, in one read.
    def fetch_issue(root, repo, number)
      owner, name = repo.split("/", 2)
      result = @runner.call(["gh", "api", "graphql", "-H", "GraphQL-Features: issue_types,sub_issues",
                             "-f", "owner=#{owner}", "-f", "name=#{name}", "-F", "number=#{number}", "-f", "query=#{QUERY}"],
                            chdir: root)
      unless result.success?
        message = [result.err, result.out].map(&:strip).find { |text| !text.empty? } || "gh api graphql failed"
        raise ArgumentError, "no issue ##{number} in #{repo}: #{message}"
      end
      issue = JSON.parse(result.out).dig("data", "repository", "issue")
      raise ArgumentError, "no issue ##{number} in #{repo}" unless issue.is_a?(Hash)

      issue
    rescue JSON::ParserError
      raise ArgumentError, "gh api graphql for ##{number} did not answer JSON"
    end

    # origin/HEAD when this clone knows it, else GitHub's answer.
    def default_branch(root, repo)
      ref = Quartermaster.git(root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
      return ref.delete_prefix("origin/") if ref && !ref.empty?

      result = @runner.call(["gh", "repo", "view", repo, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"],
                            chdir: root)
      name = result.out.to_s.strip
      raise ArgumentError, "can't tell #{repo}'s default branch: #{result.err.strip}" unless result.success? && !name.empty?

      name
    end

    def run!(argv, label, chdir:)
      result = @runner.call(argv, chdir: chdir)
      return result if result.success?

      message = [result.err, result.out].map(&:strip).find { |text| !text.empty? } || "exit status non-zero"
      raise ArgumentError, "#{label} failed: #{message}"
    end
  end
end
