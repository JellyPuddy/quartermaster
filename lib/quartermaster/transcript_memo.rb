# frozen_string_literal: true

module Quartermaster
  # Where each session's transcript is and what its first prompt says, kept
  # for the life of the process: qm gui rebuilds every Session on each state
  # build, and without this every build globs all project dirs for each
  # expired transcript and rereads each live one from the start. A found path
  # holds while the file exists; a miss holds only for a session that is not
  # live (a live one's transcript may still appear), and likewise a first
  # prompt that is not there yet. Keyed by session id and transcript path,
  # which only grow with real use, so the hashes stay unbounded.
  module TranscriptMemo
    MISSING = :missing
    PATHS = {}
    PROMPTS = {}

    module_function

    def transcript(session_id, live:)
      known = PATHS[session_id]
      return known if known.is_a?(String) && File.exist?(known)
      return nil if known == MISSING && !live

      found = yield
      if found then PATHS[session_id] = found
      elsif live then PATHS.delete(session_id)
      else PATHS[session_id] = MISSING
      end
      found
    end

    def first_prompt(transcript_path, live:)
      known = PROMPTS[transcript_path]
      return known if known || (!live && PROMPTS.key?(transcript_path))

      prompt = yield
      PROMPTS[transcript_path] = prompt if prompt || !live
      prompt
    end

    def clear
      PATHS.clear
      PROMPTS.clear
    end
  end
end
