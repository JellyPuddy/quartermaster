# frozen_string_literal: true

module Quartermaster
  # What needs the user's attention: transcripts about to be pruned un-distilled,
  # in-progress items gone quiet, merged PRs on unresolved items.
  class Attention
    WARN_WINDOW_DAYS = 7
    STALE_AFTER_DAYS = 10

    # One thing needing attention. `badge` is the GUI chip type — owned here so
    # a new kind can't ship without one (fetch raises instead of mislabelling).
    Entry = Struct.new(:slug, :kind, :message, :session_id, keyword_init: true) do
      BADGES = { "degrade" => "degrading", "stale" => "stale", "pr_merged" => "merged" }.freeze

      def badge = BADGES.fetch(kind)
    end

    def initialize(session_log: SessionLog.new, pr_status: PrStatus.new, project_map: ProjectMap.new,
                   retention_days: Quartermaster.transcript_retention_days, now: Time.now)
      @session_log = session_log
      @pr_status = pr_status
      @project_map = project_map
      @retention_days = retention_days
      @now = now
    end

    def entries
      WorkItem.all.reject { |i| i.state == "resolved" }.flat_map { |item| entries_for(item) }
    end

    def entries_for(item)
      [*degradations(item), staleness(item), pr_merged(item)].compact
    end

    # Acknowledge the item's current degradation warnings — or one session's,
    # when given. Returns the session ids acked.
    def acknowledge_all(item, session_id: nil)
      ids = session_id ? [session_id] : degradations(item).map(&:session_id)
      ids.each { |id| item.ack_degrade(id) }
      ids
    end

    def degradations(item)
      item.sessions.filter_map do |attached|
        next if attached["ack_degrade"]
        next if item.snapshot_for?(attached["id"])

        session = @session_log.session_for(attached["id"])
        next if session.nil? || session.live?
        next unless session.transcript

        days_left = (((File.mtime(session.transcript) + (@retention_days * 86_400)) - @now) / 86_400).floor
        next if days_left > WARN_WINDOW_DAYS

        Entry.new(slug: item.slug, kind: "degrade", session_id: session.id,
                  message: "transcript expires in #{days_left}d")
      end
    end

    def staleness(item)
      return nil unless item.state == "in_progress"
      return nil if item.snoozed_at?(@now.to_date)

      days_quiet = ((@now - activity_at(item)) / 86_400).floor
      return nil if days_quiet < STALE_AFTER_DAYS

      Entry.new(slug: item.slug, kind: "stale", message: "no activity for #{days_quiet}d")
    end

    # For a stack, a merged bottom PR means nothing yet — nudge only when
    # every linked branch's PR is merged. A PR-less branch that no longer
    # exists locally or on origin (typically the old name of a renamed branch)
    # is ignored; a merged PR's deleted branch still counts via its PR state.
    def pr_merged(item)
      states = item.branches.to_h { |b| [b, @pr_status.state_for(item, b)] }
      states = states.reject { |branch, state| state.nil? && branch_gone?(item, branch) }
      return nil if states.empty?
      return nil unless states.each_value.all? { |state| state == "MERGED" }

      message = states.size > 1 ? "all #{states.size} PRs merged — resolve?" : "PR merged — resolve?"
      Entry.new(slug: item.slug, kind: "pr_merged", message: message)
    end

    def branch_gone?(item, branch)
      root = @project_map.root_for(item.project)
      return false unless root

      ["refs/heads/#{branch}", "refs/remotes/origin/#{branch}"].none? do |ref|
        system("git", "-C", root, "rev-parse", "--verify", "--quiet", ref,
               out: File::NULL, err: File::NULL)
      end
    end

    # When the item last saw movement — newest of the file itself and its
    # sessions' last events. Doubles as the board's sort key and staleness
    # input; a deliberate pairing, so a staleness change reorders the board.
    def activity_at(item)
      times = [File.mtime(WorkItem.path_for(item.slug))]
      item.sessions.each do |attached|
        session = @session_log.session_for(attached["id"])
        times << Time.parse(session.last_ts) if session&.last_ts
      end
      times.max
    end
  end
end
