# frozen_string_literal: true

# The cast's transcripts, sessions.jsonl and events.jsonl — what the hooks
# and Claude Code would have written. Live sessions get their start event
# from the chats step, once their tmux chat (and so their pid) exists.
DemoWorld.step("sessions") do |world|
  cast = world.cast
  log = []
  cast.sessions.each do |session|
    dir = File.join(world.transcripts_dir, DemoWorld::Transcript.project_dir(session.cwd))
    path = File.join(dir, "#{session.id}.jsonl")
    session.transcript.write(dir)
    next if session.live?

    log << DemoWorld::SessionEvents.start(world, session, path, pid: nil)
    log << { "v" => 1, "event" => "end", "session_id" => session.id, "reason" => "prompt_input_exit",
             "duration_s" => (session.end_at - session.start_at).round, "commits" => [], "diff_stat" => "",
             "ts" => session.end_at.iso8601 }
  end
  world.append_jsonl(File.join(world.qm_root, "sessions.jsonl"), log.sort_by { |e| e["ts"] })
  events = cast.sessions.reject(&:aside).flat_map { |s| s.transcript.events }.sort_by { |e| e["ts"] }
  world.append_jsonl(File.join(world.qm_root, "events.jsonl"), events)
end

module DemoWorld
  # sessions.jsonl start events, in the shape HookHandler#session_started writes.
  module SessionEvents
    def self.start(world, session, transcript_path, pid:)
      event = { "v" => 1, "event" => "start", "session_id" => session.id, "source" => "startup", "cwd" => session.cwd,
                "transcript_path" => transcript_path, "branch" => session.branch, "pid" => pid,
                "project" => session.project, "ts" => session.start_at.iso8601 }
      if session.aside
        event["aside"] = session.aside
      else
        event["head"] = head(world, session)
        event["work_item"] = session.item if session.item && session.live?
      end
      event
    end

    def self.head(world, session)
      return nil unless session.branch && File.directory?(session.cwd)

      world.git!(session.cwd, "rev-parse", "HEAD").strip
    rescue RuntimeError
      nil
    end
  end
end
