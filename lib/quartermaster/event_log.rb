# frozen_string_literal: true

module Quartermaster
  # events.jsonl, appended by hooks/record-event.sh on every prompt, tool call,
  # permission request and turn end. It grows forever, so it is never re-read
  # whole: each session's turn is folded into a small summary, persisted with
  # the byte offset it covers (events-fold.json), and every read folds only
  # the bytes appended since.
  #
  # A turn is {"state", "since", "tool", "stop_ts", "prompt_ts", "last_ts"}:
  # state is working | blocked | your_turn, since is when it entered that state.
  class EventLog
    FOLD_VERSION = 1
    # The fold is rewritten on every read that finds new bytes, so sessions
    # quiet this long drop out of it (they read as no turn, like a fresh chat).
    FORGET_AFTER = 30 * 24 * 3600

    def path = File.join(ROOT, "events.jsonl")
    def fold_path = File.join(ROOT, "events-fold.json")

    # session_id => turn hash. Memoised per instance on top of the persisted
    # fold, so a polling caller re-reads only the new tail each call.
    def turns
      @fold ||= load_fold
      stat = File.stat(path)
      @fold = empty_fold(stat.ino) if stat.ino != @fold["inode"] || stat.size < @fold["offset"]
      fold_new_bytes(stat.size) if stat.size > @fold["offset"]
      @fold["sessions"]
    rescue Errno::ENOENT
      {}
    end

    def turn_for(session_id) = turns[session_id]

    # The newest event's ts, from the file's last few KB; touches no fold.
    def last_ts
      tail = File.open(path, "rb") do |f|
        f.seek([f.size - 8192, 0].max)
        f.read
      end
      tail.force_encoding(Encoding::UTF_8).scrub.lines.reverse_each do |line|
        event = JSON.parse(line)
        return event["ts"] if event.is_a?(Hash) && event["ts"]
      rescue JSON::ParserError
        next
      end
      nil
    rescue Errno::ENOENT
      nil
    end

    # One event folded into its session's turn. Only the order of events
    # matters (spike, 2026-10-21): UserPromptSubmit and PostToolUse mean
    # working, PermissionRequest (permissions and AskUserQuestion alike) means
    # blocked, Stop ends every turn. The *Failure variants stand in for their
    # success events: an approved tool that fails fires PostToolUseFailure
    # (the block is still resolved), a turn ended by an API error fires
    # StopFailure (it is still the user's move). A sub-agent's tool call only resolves a
    # permission it was blocked on — background sub-agents keep running after
    # the main turn's Stop, and that is still the user's turn.
    def self.apply(sessions, event)
      id = event["session_id"]
      return unless id.is_a?(String) && !id.empty?

      ts = event["ts"]
      tool = event["tool"].to_s.empty? ? nil : event["tool"]
      agent = !event["agent"].to_s.empty?
      turn = sessions[id] ||= {}
      case event["event"]
      when "UserPromptSubmit"
        enter(turn, "working", ts, force: true)
        turn["prompt_ts"] = ts
      when "PostToolUse", "PostToolUseFailure"
        if agent
          return unless turn["state"] == "blocked"

          enter(turn, turn["before_block"] || "working", ts)
        else
          enter(turn, "working", ts)
        end
      when "PermissionRequest"
        turn["before_block"] = turn["state"] unless turn["state"] == "blocked"
        enter(turn, "blocked", ts)
      when "Stop", "StopFailure"
        enter(turn, "your_turn", ts)
        turn["stop_ts"] = ts
      else
        sessions.delete(id) if turn.empty?
        return
      end
      turn["tool"] = tool
      turn["last_ts"] = ts
    end

    def self.enter(turn, state, ts, force: false)
      turn["since"] = ts if force || turn["state"] != state
      turn["state"] = state
    end
    private_class_method :enter

    private

    def fold_new_bytes(size)
      chunk = File.open(path, "rb") do |f|
        f.seek(@fold["offset"])
        f.read(size - @fold["offset"])
      end
      # A line still being appended has no newline yet: leave it for next time.
      complete = chunk.byteslice(0, (chunk.rindex("\n") || -1) + 1)
      return if complete.empty?

      complete.force_encoding(Encoding::UTF_8).each_line do |line|
        event = Quartermaster.json_object(line)
        self.class.apply(@fold["sessions"], event) if event
      end
      @fold["offset"] += complete.bytesize
      save_fold
    end

    def load_fold
      fold = JSON.parse(File.read(fold_path))
      fold["v"] == FOLD_VERSION ? fold : empty_fold
    rescue StandardError
      empty_fold
    end

    def empty_fold(inode = nil)
      { "v" => FOLD_VERSION, "inode" => inode, "offset" => 0, "sessions" => {} }
    end

    # Write-then-rename: concurrent readers each save a self-consistent fold,
    # and whichever lands last is still correct for its offset.
    def save_fold
      cutoff = (Time.now - FORGET_AFTER).utc.iso8601
      @fold["sessions"].reject! { |_, turn| turn["last_ts"].to_s < cutoff }
      tmp = "#{fold_path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.write(tmp, JSON.generate(@fold))
      File.rename(tmp, fold_path)
    rescue StandardError => e
      Quartermaster.log_error("event-fold", e)
    end
  end
end
