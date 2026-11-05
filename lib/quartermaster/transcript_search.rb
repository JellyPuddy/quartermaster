# frozen_string_literal: true

module Quartermaster
  # Finds the sessions whose conversation mentions a phrase: what the user typed
  # or what Claude answered, never tool calls or their output (those would
  # drown every search in file contents). On demand and index-free — rg picks
  # the candidate transcripts, then each candidate's lines are parsed to keep
  # only real conversation hits. Asides are left out like everywhere else.
  # Shared by `qm grep` and the GUI.
  class TranscriptSearch
    # Newest sessions first; past this many a broad phrase is better narrowed
    # than paged through, and the rest are only counted.
    MAX_SESSIONS = 60
    SNIPPET_BEFORE = 60
    SNIPPET_AFTER = 140
    # Where Homebrew puts rg: a GUI started from a launcher may not have it on PATH.
    RG_FALLBACK_DIRS = %w[/opt/homebrew/bin /usr/local/bin].freeze

    def initialize(runner: CommandRunner.new, dir: TRANSCRIPTS_DIR, session_log: SessionLog.new, items: WorkItem.all)
      @runner = runner
      @dir = dir
      @session_log = session_log
      @items = items
    end

    # { "query", "groups" => [{ "slug", "title", "state", "sessions" => [...] }], "more" }
    # Groups are work items by their newest hit, the unlinked group (slug nil)
    # last; "more" counts candidate transcripts left unread past MAX_SESSIONS.
    def call(query)
      query = query.to_s.strip
      raise ArgumentError, "query is empty" if query.empty?

      @matcher = Regexp.new(Regexp.escape(query), Regexp::IGNORECASE)
      # Transcript lines are JSON, so the phrase appears there escaped.
      @line_matcher = Regexp.new(Regexp.escape(JSON.generate(query)[1..-2]), Regexp::IGNORECASE)
      asides = @session_log.sessions.select(&:aside_for).to_set(&:id)
      candidates = candidate_files(query).reject { |path| asides.include?(File.basename(path, ".jsonl")) }
      hits = []
      read = 0
      candidates.each do |path|
        break if hits.size >= MAX_SESSIONS

        read += 1
        hit = scan(path)
        hits << hit if hit
      end
      { "query" => query, "groups" => group(hits), "more" => candidates.size - read }
    end

    private

    # Transcripts sit at <dir>/<project>/<id>.jsonl; deeper files are
    # sub-agent runs, which aren't the user's conversation. Newest first.
    def candidate_files(query)
      return [] unless File.directory?(@dir)

      result = @runner.call([rg, "--files-with-matches", "--ignore-case", "--fixed-strings", "--max-depth", "2",
                             "--glob", "*.jsonl", "--", JSON.generate(query)[1..-2], @dir])
      # rg exits 1 for "no match", with nothing on stderr; 2 for an error, which may
      # be one unreadable transcript next to real matches.
      failed = !result.success? && !result.err.strip.empty? && result.out.strip.empty?
      raise ArgumentError, "rg failed: #{result.err.strip}" if failed

      result.out.lines.map(&:chomp).reject(&:empty?).sort_by { |path| -(File.mtime(path).to_f rescue 0) }
    end

    def rg
      dirs = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR) + RG_FALLBACK_DIRS
      dirs.map { |dir| File.join(dir, "rg") }.find { |path| File.executable?(path) } || "rg"
    end

    def scan(path)
      id = File.basename(path, ".jsonl")
      first_ts = nil
      found = nil
      count = 0
      File.foreach(path) do |line|
        first_ts ||= line[/"timestamp":"([^"]+)"/, 1]
        next unless @line_matcher.match?(line)

        entry = parse(line)
        next unless entry.is_a?(Hash) && !entry["isSidechain"]

        role, text = conversation_text(entry)
        next unless text && (at = text.index(@matcher))

        count += 1
        found ||= { "role" => role, "ts" => entry["timestamp"], **snippet(text, at) }
      end
      return nil unless found

      session = @session_log.session_for(id)
      { "id" => id, "date" => session&.started_ts || first_ts, "hits" => count, "transcript" => path,
        "cwd" => session&.cwd, **found }
    rescue SystemCallError
      nil
    end

    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def conversation_text(entry)
      case entry["type"]
      when "user"
        text = Quartermaster.prompt_text(entry) unless entry["isCompactSummary"]
        text && ["user", text]
      when "assistant"
        content = entry.dig("message", "content")
        content = [{ "type" => "text", "text" => content }] if content.is_a?(String)
        text = Array(content).filter_map { |b| b["text"] if b.is_a?(Hash) && b["type"] == "text" }.join("\n")
        text.empty? ? nil : ["assistant", text]
      end
    end

    def snippet(text, at)
      len = @matcher.match(text, at)[0].size
      from = [at - SNIPPET_BEFORE, 0].max
      to = [at + len + SNIPPET_AFTER, text.size].min
      { "before" => (from.positive? ? "…" : "") + squash(text[from...at]),
        "match" => text[at, len],
        "after" => squash(text[(at + len)...to]) + (to < text.size ? "…" : "") }
    end

    def squash(text) = text.gsub(/\s+/, " ")

    def group(hits)
      owners = {}
      @items.each { |item| item.sessions.each { |s| owners[s["id"]] ||= item } }
      by_item = hits.group_by { |hit| owners[hit["id"]] }
      groups = by_item.map do |item, sessions|
        { "slug" => item&.slug, "title" => item ? item.title : "unlinked", "state" => item&.state,
          "sessions" => sessions.sort_by { |s| s["date"].to_s }.reverse }
      end
      linked, unlinked = groups.partition { |g| g["slug"] }
      linked.sort_by { |g| g["sessions"].first["date"].to_s }.reverse + unlinked
    end
  end
end
