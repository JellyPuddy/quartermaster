# frozen_string_literal: true

module Quartermaster
  # Token totals per session — its transcript plus its sub-agent transcripts
  # (`<transcript dir>/<session id>/subagents/**/*.jsonl`, workflow agents
  # included) — kept permanently in `usage-cache.json`. Claude Code prunes
  # transcripts after a few weeks; the ledger is what still knows what an
  # expired session spent.
  #
  # Each file's TranscriptUsage state is stored keyed by path, and checked by
  # size + mtime. A session whose main transcript hasn't changed since the
  # last look costs one stat: sub-agents only write while their session runs,
  # and the main transcript records every agent's result, so an unchanged
  # main transcript means nothing below it moved either.
  class UsageLedger
    FILE = "usage-cache.json"
    VERSION = 1

    def initialize(path = File.join(ROOT, FILE))
      @path = path
      @mutex = Mutex.new
      @data = nil
      @dirty = false
    end

    # { "buckets" =>, "agents" => n, "known" => bool } for a Session. known is
    # false only when there is no transcript and no record of one: an expired
    # session nobody tallied while it existed, which the item's figure can
    # then only be a lower bound of.
    def session_usage(session)
      @mutex.synchronize do
        entry = sessions[session.id]
        transcript = session.transcript
        entry = refresh(session.id, transcript, entry) if transcript
        next { "buckets" => {}, "agents" => 0, "known" => session.live? } unless entry

        files = entry["files"].values
        { "buckets" => files.reduce({}) { |acc, state| TranscriptUsage.merge(acc, TranscriptUsage.totals(state)) },
          "agents" => files.size - 1, "known" => true }
      end
    end

    # Writes the ledger when a lookup changed it; atomic, and merged over what
    # another qm process saved meanwhile (its sessions aren't dropped).
    def save
      @mutex.synchronize do
        return unless @dirty

        on_disk = read_file["sessions"]
        payload = { "v" => VERSION, "sessions" => on_disk.merge(sessions) }
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.#{Process.pid}.tmp"
        File.write(tmp, JSON.generate(payload))
        File.rename(tmp, @path)
        @dirty = false
      end
    rescue StandardError => e
      Quartermaster.log_error("usage-ledger", e)
    end

    private

    def sessions
      @data ||= read_file
      @data["sessions"]
    end

    def read_file
      data = File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
      data = {} unless data.is_a?(Hash) && data["sessions"].is_a?(Hash)
      { "v" => VERSION, "sessions" => {} }.merge(data)
    rescue StandardError
      { "v" => VERSION, "sessions" => {} }
    end

    def refresh(session_id, transcript, entry)
      stat = File.stat(transcript)
      signature = [transcript, stat.size, stat.mtime.to_f]
      return entry if entry && entry["main"] == signature

      files = entry ? entry["files"].dup : {}
      ([transcript] + subagent_transcripts(transcript, session_id)).each do |path|
        files[path] = TranscriptUsage.scan(path, files[path])
      rescue SystemCallError
        next # vanished between the glob and the read; keep what was recorded
      end
      @dirty = true
      sessions[session_id] = { "main" => signature, "files" => files }
    rescue SystemCallError
      entry
    end

    def subagent_transcripts(transcript, session_id)
      Dir[File.join(File.dirname(transcript), session_id, "subagents", "**", "*.jsonl")].sort
    end
  end
end
