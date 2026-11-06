# frozen_string_literal: true

module Quartermaster
  class SessionLog
    def path
      File.join(ROOT, "sessions.jsonl")
    end

    def append(event)
      Quartermaster.ensure_setup
      File.open(path, "a") do |f|
        f.flock(File::LOCK_EX)
        f.puts(JSON.generate({ "v" => EVENT_VERSION }.merge(event)))
      end
      @events = @sessions = nil # a write invalidates this instance's reads
      true # a truthy success signal — callers use `append && ok` (e.g. gui dismiss)
    end

    # Memoised per instance: one log read serves a whole request/command,
    # however many sessions it asks about.
    def events
      @events ||= read_events
    end

    def last_start_for(session_id)
      events.reverse.find { |e| e["event"] == "start" && e["session_id"] == session_id }
    end

    def sessions
      @sessions ||= events.group_by { |e| e["session_id"] }.filter_map do |session_id, session_events|
        start = session_events.select { |e| e["event"] == "start" }.last
        next unless start

        last = session_events.reject { |e| e["event"] == "dismissed" }.last
        Session.new(id: session_id, start_event: start, last_event: last,
                    live: last["event"] == "start" && alive?(start["pid"]))
      end
    end

    def session_for(session_id)
      sessions.find { |s| s.id == session_id }
    end

    def dismiss(session_id)
      append("event" => "dismissed", "session_id" => session_id, "ts" => Time.now.iso8601)
    end

    def dismissed_ids
      events.select { |e| e["event"] == "dismissed" }.map { |e| e["session_id"] }
    end

    # The inbox: captured sessions no work item claims and nobody dismissed —
    # the triage surface for deciding what deserves tracking. Asides are
    # throwaway by design and never land here.
    def inbox
      claimed = WorkItem.all.flat_map { |item| item.sessions.map { |s| s["id"] } }
      dismissed = dismissed_ids
      sessions.reject do |session|
        session.launched_for || session.aside_for || claimed.include?(session.id) || dismissed.include?(session.id)
      end
    end

    private

    def read_events
      return [] unless File.exist?(path)

      File.readlines(path).filter_map { |line| Quartermaster.json_object(line) }
    end

    def alive?(pid)
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    rescue StandardError
      false
    end
  end
end
