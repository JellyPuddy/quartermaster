# frozen_string_literal: true

module Quartermaster
  # prompt-snapshots.jsonl, appended by hooks/snapshot-worktree.sh at every
  # prompt: the session's git worktree as a tree object, taken just before
  # Claude Code writes the prompt to the transcript. One line per prompt, so
  # it is read whole; append-only, so a torn last line is only a write in
  # progress and is skipped.
  #
  # A snapshot is {"tree", "at", "cwd", "toplevel", "prompt", "prompt_at"}:
  # prompt is the first line of the prompt it was taken for (clipped), nil
  # when the transcript has none for it — it is gone, or the prompt was a
  # command qm doesn't show as one — and the snapshot is then known by "at".
  class PromptSnapshots
    PROMPT_CHARS = 80
    TREE = /\A\h{40}(\h{24})?\z/
    # The hook's "at" is whole seconds and taken a moment after the prompt's
    # transcript timestamp, so a prompt counts from this long before it.
    SLACK = 3

    def self.path = File.join(ROOT, "prompt-snapshots.jsonl")

    def initialize(path: self.class.path, session_log: SessionLog.new)
      @path = path
      @session_log = session_log
    end

    # The session's snapshots, oldest first, each labelled with its prompt.
    # transcript: overrides the transcript the session log knows of.
    def for_session(session_id, transcript: nil)
      snapshots = read(session_id)
      return snapshots if snapshots.empty?

      transcript ||= Quartermaster.locate_transcript(session_id, @session_log.session_for(session_id)&.transcript)
      label(snapshots, prompts(transcript))
    end

    private

    def read(session_id)
      return [] unless File.exist?(@path)

      File.foreach(@path).filter_map do |line|
        entry = parse(line)
        next unless entry && entry["session_id"] == session_id

        { "tree" => entry["tree"], "at" => entry["at"], "cwd" => entry["cwd"], "toplevel" => entry["toplevel"],
          "prompt" => nil, "prompt_at" => nil }
      end
    rescue SystemCallError
      []
    end

    def parse(line)
      entry = JSON.parse(line)
      return nil unless entry.is_a?(Hash) && entry["tree"].to_s.match?(TREE) && time(entry["at"])

      entry
    rescue JSON::ParserError
      nil
    end

    # [{"text", "ts", "time"}] for what the user typed, in transcript order.
    def prompts(transcript)
      return [] unless transcript && File.exist?(transcript)

      File.foreach(transcript).filter_map do |line|
        entry = JSON.parse(line)
        next unless entry.is_a?(Hash) && entry["type"] == "user" && !entry["isSidechain"] && !entry["isCompactSummary"]

        text = Quartermaster.prompt_text(entry)
        at = time(entry["timestamp"])
        next unless text && at && !text.start_with?(TranscriptVitals::INTERRUPT_MARK)

        { "text" => text, "ts" => entry["timestamp"], "time" => at }
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError
      []
    end

    # Each snapshot owns the prompts from its own "at" up to the next
    # snapshot's (both less SLACK), and takes the first of them. Windows never
    # overlap, so a snapshot whose prompt isn't in the transcript stays
    # unlabelled instead of taking the next snapshot's prompt.
    def label(snapshots, prompts)
      starts = snapshots.map { |s| time(s["at"]) - SLACK }
      snapshots.each_with_index do |snapshot, i|
        from = starts[i]
        upto = starts[i + 1]
        prompt = prompts.find { |p| p["time"] >= from && (upto.nil? || p["time"] < upto) }
        next unless prompt

        snapshot["prompt"] = Quartermaster.clip(prompt["text"].lines.first.to_s.strip, PROMPT_CHARS)
        snapshot["prompt_at"] = prompt["ts"]
      end
    end

    def time(value)
      value.is_a?(String) ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
    end
  end
end
