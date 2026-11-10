# frozen_string_literal: true

module Quartermaster
  # The review-summary kind of Drafts: the overall verdict and summary
  # suggested for one PR — by Claude (`qm draft add --summary`), or the
  # user's once they edit it. One per PR (repo, number); it is no GitHub
  # comment, so posting the pending review leaves it in the tray, and a
  # submitted review takes it along (forget_review_summary).
  module ReviewSummaryDrafts
    VERDICTS = %w[approve comment request-changes].freeze

    # Fields: repo ("owner/name"), number, verdict (one of VERDICTS, or
    # none), author ("user" unless "claude"). A put on the PR's summary
    # replaces it whole, a blank comment removes it; a block gets the one
    # it would replace (or nil) under the file's lock and may refuse by
    # raising. Returns the stored entry, or nil when it was removed.
    def put_review_summary(raw, &guard)
      raise ArgumentError, "a review summary must be an object" unless raw.is_a?(Hash)
      raise ArgumentError, "'#{raw["repo"]}' is not an owner/name repo" unless raw["repo"].is_a?(String) && raw["repo"].match?(Drafts::REPO)

      number = Integer(raw["number"].to_s, exception: false)
      raise ArgumentError, "a review summary needs its pull request's number" unless number&.positive?

      verdict = raw["verdict"]
      unless verdict.nil? || VERDICTS.include?(verdict)
        raise ArgumentError, "'#{verdict}' is no verdict: a verdict must be approve, comment or request-changes"
      end

      fields = { "repo" => raw["repo"], "number" => number, "verdict" => verdict,
                 "author" => Drafts::AUTHORS.include?(raw["author"]) ? raw["author"] : "user" }.compact
      comment = raw["comment"].to_s
      update do |list|
        existing = list.find { |entry| summary_of?(entry, fields["repo"], number) }
        guard&.call(existing)
        if comment.strip.empty?
          list.delete(existing)
          next nil
        end
        next new_entry("review-summary", comment, fields).tap { |added| list << added } unless existing

        before = existing.dup
        existing.delete("verdict")
        existing.merge!(fields, "comment" => comment)
        next existing if existing == before

        existing.merge!("rev" => existing["rev"].to_i + 1, "updatedAt" => @now.call.utc.iso8601)
      end
    end

    def review_summary(repo, number)
      entries.find { |entry| summary_of?(entry, repo, number.to_i) }
    end

    # The PR's summary goes — only while at rev, when given. True when it went.
    def forget_review_summary(repo, number, rev: nil)
      update do |list|
        list.reject! { |entry| summary_of?(entry, repo, number.to_i) && (rev.nil? || entry["rev"] == rev) } ? true : false
      end
    end

    private

    def summary_of?(entry, repo, number)
      entry["kind"] == "review-summary" && entry["repo"].to_s.casecmp?(repo.to_s) && entry["number"] == number
    end
  end
end
