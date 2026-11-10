# frozen_string_literal: true

module Quartermaster
  # The tray's and diff bar's GitHub review actions (PendingReview,
  # docs/areas/review.md): preview the pending review, post the drafts into
  # it, submit it with a verdict. GuiActions hands every review-* command
  # here; review-preview only reads, so Gui runs it off the action mutex,
  # and post and submit run as the item's GuiJobs job.
  class GuiReviewActions
    COMMANDS = %w[review-preview review-post review-submit].freeze

    VERDICT_WORDS = { "APPROVE" => "Approved", "COMMENT" => "Commented on",
                      "REQUEST_CHANGES" => "Requested changes on" }.freeze

    def initialize(runner:, jobs:, pr_items:)
      @runner = runner
      @jobs = jobs
      @pr_items = pr_items
    end

    def dispatch(cmd, slug, args)
      item = WorkItem.find(slug)
      case cmd
      when "review-preview" then preview(item, args)
      when "review-post" then post(item, args)
      when "review-submit" then submit(item, args)
      end
    end

    private

    def ok = { "ok" => true }

    # The confirmation's numbers before "Post as pending review" (D4), and the
    # verdict form's (submit: true — no drafts needed, the PR's summary
    # draft along): a gh query and a fetch, so off the action mutex.
    def preview(item, args)
      submitting = args["submit"] == true
      review, entries = review_drafts(item, args, allow_none: submitting)
      preview = review.preview(entries)
      preview["summary"] = Drafts.new(item.slug).review_summary(review.repo, review.number) if submitting
      ok.merge("preview" => preview)
    end

    # Posts the PR's GitHub drafts (those the tray showed) into the user's
    # pending review as the item's background job: a GitHub call per draft.
    def post(item, args)
      review, entries = review_drafts(item, args)
      @jobs.background(item.slug, "posting to #{review.label}…") do
        post_result(review, review.post(entries, Drafts.new(item.slug)))
      end
    end

    def post_result(review, result)
      parts = ["#{result["posted"]} added to your pending review on #{review.label} — submit it on GitHub"]
      parts << "#{result["outdated"]} outdated, not posted" if result["outdated"].positive?
      out = { "ok" => result["failed"].empty?, "message" => parts.join(" · "), "review" => true }
      out["error"] = "#{parts.join(" · ")} · #{result["failed"].size} failed and stay in the tray: " \
                     "#{result["failed"].first}" unless result["failed"].empty?
      out.merge(fallback_warning(result))
    end

    # The verdict form's Submit (submit plan D3, D7): the drafts it listed go
    # into the pending review, which is then submitted; the PR's summary
    # draft (as it stood at the click) leaves the tray, and a Review item of
    # the PR gets the verdict as a note and is resolved. What needs no
    # GitHub is refused before the job; the rest PendingReview#submit checks.
    def submit(item, args)
      event = PendingReview.event(args["event"])
      PendingReview.check_body(event, args["body"])
      review, entries = review_drafts(item, args, allow_none: true)
      drafts = Drafts.new(item.slug)
      summary_rev = drafts.review_summary(review.repo, review.number)&.dig("rev")
      @jobs.background(item.slug, "submitting your review on #{review.label}…") do
        result = review.submit(entries, drafts, event: event, body: args["body"].to_s)
        next abort_result(review, result) unless result["submitted"]

        drafts.forget_review_summary(review.repo, review.number, rev: summary_rev) if summary_rev
        submitted_result(review, result).tap { |out| record_on_review_item(item, review, out) }
      end
    end

    def submitted_result(review, result)
      verdict = "#{VERDICT_WORDS.fetch(result["submitted"])} #{review.label}"
      comments = result["comments"]
      parts = [verdict]
      parts << "#{comments} comment#{"s" unless comments == 1}" if comments.positive?
      parts << "#{result["outdated"]} outdated, not posted (still in the tray)" if result["outdated"].positive?
      noted = comments.positive? ? "#{verdict} (#{comments} comment#{"s" unless comments == 1})" : verdict
      { "ok" => true, "message" => parts.join(" · "), "review" => true, "noted" => noted }
        .merge(fallback_warning(result))
    end

    def abort_result(review, result)
      failed = result["failed"]
      posted = result["posted"].positive? ? "#{result["posted"]} went into your pending review · " : ""
      { "ok" => false, "review" => true,
        "error" => "Nothing submitted on #{review.label}: #{posted}#{failed.size} failed and " \
                   "#{failed.size == 1 ? "stays" : "stay"} in the tray: #{failed.first}" }
        .merge(fallback_warning(result))
    end

    def fallback_warning(result)
      return {} unless result["fallbacks"].positive?

      { "warning" => "#{result["fallbacks"]} couldn't go on their old commit and became file comments quoting their line" }
    end

    # The PR's Review item (the acting item when it is one, else any item
    # whose description names the PR) keeps the verdict and is done. The
    # review is already submitted, so a failure here is a warning, not an error.
    def record_on_review_item(item, review, out)
      noted = out.delete("noted")
      target = ([item] + WorkItem.all).find do |candidate|
        pr = @pr_items.review_pr(candidate)
        pr && pr["repo"].casecmp?(review.repo) && pr["number"] == review.number
      end
      return unless target

      target.add_note("Submitted review: #{noted}", kind: "history")
      target.update_state("resolved") unless target.state == "resolved"
    rescue StandardError => e
      Quartermaster.log_error("review-submit", e)
      out["warning"] = [out["warning"], "the review item wasn't updated: #{e.message}"].compact.join(" · ")
    end

    def review_drafts(item, args, allow_none: false)
      root = ProjectMap.new.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root && File.directory?(root)

      review = PendingReview.new(root, repo: args["repo"].to_s, number: args["number"], runner: @runner)
      entries = Drafts.new(item.slug).entries.select do |entry|
        PendingReview::POSTED_KINDS.include?(entry["kind"]) && entry["repo"].to_s.casecmp?(review.repo) &&
          entry["number"] == review.number
      end
      entries = entries.select { |entry| args["ids"].include?(entry["id"]) } if args["ids"].is_a?(Array)
      raise ArgumentError, "no review drafts for #{review.label}" if entries.empty? && !allow_none

      [review, entries]
    end
  end
end
