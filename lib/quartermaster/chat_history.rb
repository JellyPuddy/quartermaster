# frozen_string_literal: true

module Quartermaster
  # An item's earlier sessions as one continuous history above its live chat
  # (docs/areas/chats.md): every session that isn't running, oldest first,
  # with a divider wherever a context rotation handed over to a fresh
  # session. The page loads it lazily — the timeline first, then a page of
  # entries at a time from the newest end as the user scrolls up — because
  # transcripts reach many megabytes.
  #
  # A session whose transcript Claude Code has pruned falls back to its
  # distilled snapshot, or says that nothing survived.
  class ChatHistory
    PAGE_SIZE = 60
    CACHE_SIZE = 12

    # cache: shared across requests by the GUI; parsed transcripts are keyed
    # by path, size and mtime, so a transcript that grew is parsed again.
    def initialize(session_log: SessionLog.new, cache: {}, cache_lock: Mutex.new)
      @session_log = session_log
      @cache = cache
      @cache_lock = cache_lock
    end

    # [{"type" => "session", ...} | {"type" => "divider", ...}], oldest first.
    # A divider sorts by when the rotation happened: after the session it
    # ended, before the fresh one it started.
    def timeline(item)
      sessions = earlier_sessions(item).map { |session| session_segment(item, session) }
      dividers = item.rotations.map { |rotation| divider_segment(item, rotation) }
      (sessions + dividers).each_with_index.sort_by { |segment, i| [moment(segment["at"]), i] }.map(&:first)
    end

    # One page of a session's entries, ending just before `before` (the
    # newest page when nil). "before" in the answer is the cursor for the
    # next older page, nil once the start is reached.
    def page(item, session_id, before: nil, limit: PAGE_SIZE)
      session = earlier_sessions(item).find { |s| s.id == session_id }
      raise ArgumentError, "#{session_id} is not an earlier session of #{item.slug}" unless session

      entries = entries_for(item, session)
      stop = before ? before.clamp(0, entries.size) : entries.size
      start = [stop - limit, 0].max
      { "entries" => entries[start...stop], "before" => start.positive? ? start : nil, "total" => entries.size }
    end

    private

    # Everything the item lists but the live chats: what runs now is on the
    # terminal (or in a Warp tab), not history yet.
    def earlier_sessions(item)
      Quartermaster.item_sessions(item, session_log: @session_log).reject(&:live?)
    end

    def session_segment(item, session)
      source = if session.transcript then "transcript"
               elsif item.snapshot_for?(session.id) then "snapshot"
               else "none"
               end
      { "type" => "session", "id" => session.id, "at" => session.started_ts, "last" => session.last_ts,
        "tier" => session.tier, "source" => source }
    end

    def divider_segment(item, rotation)
      notes = item.notes.to_h { |note| [note.position, note] }
      carried = Array(rotation["carried"]).filter_map { |position| notes[position]&.to_h }
      { "type" => "divider", "at" => rotation["at"], "from" => rotation["from"], "via" => rotation["via"],
        "decisions" => rotation["decisions"].to_i, "open" => rotation["open"].to_i, "notes" => carried }
    end

    def entries_for(item, session)
      path = session.transcript
      return cached(path) || [] if path

      snapshot = item.snapshots.find { |s| s["session"] == session.id }
      if snapshot
        [{ "kind" => "snapshot", "text" => snapshot["text"], "ts" => snapshot["stamp"] }]
      else
        [{ "kind" => "event", "text" => "Transcript expired and was never distilled — nothing of this session survives.",
           "ts" => session.last_ts }]
      end
    end

    # Session stamps carry a local offset and rotation stamps are UTC, so
    # order by the instant, not the string. Uncaptured sessions sort first.
    def moment(ts)
      ts ? Time.parse(ts).to_f : 0.0
    rescue ArgumentError
      0.0
    end

    def cached(path)
      stat = File.stat(path)
      key = [path, stat.size, stat.mtime.to_f]
      hit = @cache_lock.synchronize { @cache[key] }
      return hit if hit

      entries = TranscriptHistory.entries(path)
      @cache_lock.synchronize do
        @cache.delete(@cache.keys.find { |k| k[0] == path })
        @cache.shift while @cache.size >= CACHE_SIZE
        @cache[key] = entries if entries
      end
      entries
    rescue SystemCallError
      nil
    end
  end
end
