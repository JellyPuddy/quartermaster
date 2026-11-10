# frozen_string_literal: true

module Quartermaster
  # What qm knows about a pull request from the PRs view: the project whose
  # checkout it belongs to, the work item holding its branch, its review item.
  # The GUI's PRs payload and its PR actions share one, so the repo → project
  # map is worked out once per GUI.
  class PrItems
    # "Owner/Name" → the configured project whose main checkout's origin it
    # is. Remotes don't change under a running GUI, so it is worked out once.
    def project_for_repo(repo, project_map)
      @repo_projects ||= project_map.known_projects.to_h do |project|
        [Quartermaster.github_repo(project_map.root_for(project)).to_s.downcase, project]
      end
      @repo_projects[repo.to_s.downcase]
    end

    # The item holding the PR's branch, an unresolved one first.
    def pr_item(pr, project, items)
      items.select { |item| item.project == project && item.branches.include?(pr["head"]) }
           .min_by { |item| item.state == "resolved" ? 1 : 0 }
    end

    # Found by slug prefix, not title: the PR's title may change on GitHub.
    def review_item(pr, items)
      prefix = WorkItem.slugify("Review #{pr_label(pr)}")
      items.find { |item| item.slug == prefix || item.slug.start_with?("#{prefix}-") }
    end

    REVIEW_DESCRIPTION = %r{\AReview of pull request (https://github\.com/([^/\s]+/[^/\s]+)/pull/(\d+))}

    # A Review item's own PR, read from the description gui_pr_review gives
    # it: { "url", "repo", "number" }, or nil for any other item.
    def review_pr(item)
      m = REVIEW_DESCRIPTION.match(item.description.to_s.strip)
      m && item.title.to_s.start_with?("Review ") ? { "url" => m[1], "repo" => m[2], "number" => m[3].to_i } : nil
    end

    def find_or_create_item(title, **options)
      slug = WorkItem.slugify(title)
      File.exist?(WorkItem.path_for(slug)) ? WorkItem.find(slug) : WorkItem.create(title, **options)
    end

    # A Review item's first prompt: the review skill on the PR, and where
    # its findings go — qm drafts the user curates and posts, not GitHub (D15).
    def review_kickoff(skill, pr, slug)
      "#{skill} #{pr["url"]}\n\nRecord each finding as a qm draft with `qm draft add #{slug} …` " \
        "(see `qm draft add --help`) instead of posting to GitHub; the user curates and posts them. When done, record " \
        "your overall verdict and a short summary with `qm draft add #{slug} --summary --verdict approve|comment|request-changes " \
        "--body …`."
    end

    def pr_label(pr) = "#{pr["repo"].to_s.split("/").last}##{pr["number"]}"

    def pr_summary(pr) = "#{pr["url"]} by @#{pr["author"]}: `#{pr["head"]}` → `#{pr["base"]}`"
  end
end
