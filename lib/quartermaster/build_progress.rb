# frozen_string_literal: true

module Quartermaster
  # How far along each sub-agent of an item's running Workflow runs is, as a
  # cheap model reads it from their live transcripts. Only ever on the user's
  # click: the board shows what the agents chose to report, this answers
  # "and now?" in between.
  #
  # Where a run lives, for an orchestrator session whose transcript is
  # `<proj>/<sid>.jsonl`:
  # - `<proj>/<sid>/subagents/workflows/<runId>/agent-<id>.jsonl` (+ `.meta.json`)
  #   per sub-agent, written as it works;
  # - `…/<runId>/journal.jsonl`: `started` {key, agentId, label, phase} when an
  #   agent launches, `result` or `failed` with the same key when it ends;
  # - `<proj>/<sid>/workflows/<runId>.json`, written only once the run ends.
  # A run counts as running while that file is absent (or carries no terminal
  # status) and its session is live — a crashed session leaves an
  # unterminated journal behind forever.
  class BuildProgress
    PROMPT = <<~PROMPT
      You estimate the progress of AI coding sub-agents that are working right
      now. Stdin holds one block per agent: its label, the task brief it was
      given, and its recent activity (oldest first; its tool calls and what it
      said). For each agent, estimate how far it is through its task as a
      percentage, and say in one short plain sentence what it is doing now
      (e.g. "core change committed, fixing 2 failing tests"). Judge by what the
      brief asks for versus what the activity shows done; never mention tool
      call counts. Answer every agent, using its label exactly as given.
    PROMPT

    ANSWER_SCHEMA = {
      "type" => "object", "required" => ["agents"],
      "properties" => {
        "agents" => { "type" => "array", "items" => {
          "type" => "object", "required" => %w[label percent doing],
          "properties" => { "label" => { "type" => "string" }, "percent" => { "type" => "integer" },
                            "doing" => { "type" => "string" } }
        } }
      }
    }.freeze

    # label: the workflow's own (`build:alpha`), the model's key; task: what
    # The user reads (`alpha · building`).
    Agent = Struct.new(:run_id, :agent_id, :label, :task, :phase, :transcript, keyword_init: true) do
      # Which agent an estimate line belongs to, across state builds.
      def key = "#{run_id}/#{agent_id}"
    end

    # Run statuses that are still going; anything else in a run's result
    # file is an end (completed, failed, cancelled, …).
    LIVE_STATUSES = [nil, "", "running", "pending"].freeze
    BRIEF_CHARS = 2_000
    # Enough of an agent's transcript tail for its recent activity: its
    # lines run to tens of KB (attachments, request blobs), so a byte window
    # is cheaper than reading megabytes and still holds dozens of turns.
    TAIL_BYTES = 200_000
    ACTIVITIES = 20
    ACTIVITY_CHARS = 200
    # The workflow harness's framing ahead of a computed task: boilerplate
    # that would eat the brief's budget.
    HARNESS_PREAMBLE = /\A\s*\[Workflow harness[^\]\n]*\].*?text follows:\s*/m
    # Tool inputs that say what a call is for, most telling first.
    INPUT_KEYS = %w[description command file_path pattern path query prompt action url skill].freeze

    # The GUI job's key: per item, apart from the item's own slug-keyed jobs.
    def self.job_key(slug) = "progress:#{slug}"

    # An agent in the user's terms: the task it works on and its phase. nil for
    # the workflow's internal helpers (queue#n, checkers): they are no task,
    # so they are neither shown nor estimated.
    def self.task_name(label)
      case label
      when /\Abuild:(.+)\z/ then "#{$1} · building"
      when /\Areview:(.+)\z/ then "#{$1} · reviewing"
      when "integrate" then "integrating"
      when /\Aqueue#/, /check/i then nil
      else label
      end
    end

    # model: ->(prompt, stdin) { [stdout, stderr, status] } — the headless
    # claude seam, replaced in tests.
    def initialize(session_log: SessionLog.new, model: nil, now: Time.now)
      @log = session_log
      @model = model || method(:headless_claude)
      @now = now
    end

    # { "ok", "taken_at", "agents" => [{task, run, percent, doing}], "raw", "message" }.
    # Nothing running answers without a model call.
    def call(item)
      agents = active_agents(item)
      taken = @now.iso8601
      return { "ok" => true, "taken_at" => taken, "agents" => [], "message" => "nothing running" } if agents.empty?

      out, err, status = @model.call(PROMPT, agents.map { |a| condense(a) }.join("\n\n"))
      raise ArgumentError, "claude -p failed: #{err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip}" unless status.success?

      estimates = parse(out)
      return { "ok" => true, "taken_at" => taken, "agents" => [], "raw" => answer_text(out) } unless estimates

      { "ok" => true, "taken_at" => taken, "agents" => lines(agents, estimates) }
    end

    # Every still-working sub-agent of every running run of the item's sessions.
    def active_agents(item)
      item.sessions.flat_map do |entry|
        session = @log.session_for(entry["id"])
        next [] unless session&.live? && session.transcript

        session_dir = session.transcript.delete_suffix(".jsonl")
        Dir[File.join(session_dir, "subagents", "workflows", "*")].sort.flat_map do |run_dir|
          next [] unless File.directory?(run_dir)

          run_id = File.basename(run_dir)
          running?(session_dir, run_id) ? run_agents(run_dir, run_id) : []
        end
      end
    end

    # One agent's block of the model's input: label, brief, recent activity.
    def condense(agent)
      started = first_timestamp(agent.transcript)
      head = "## #{agent.label} (run #{agent.run_id}#{", phase #{agent.phase}" if agent.phase}" \
             "#{", working for #{((@now - started) / 60).round} min" if started})"
      activity = recent_activity(agent.transcript)
      [head, "Brief:", clip(brief(agent.transcript), BRIEF_CHARS), "Recent activity:",
       activity.empty? ? "(none yet)" : activity.map { |a| "- #{a}" }.join("\n")].join("\n")
    end

    private

    def running?(session_dir, run_id)
      result = File.join(session_dir, "workflows", "#{run_id}.json")
      return true unless File.exist?(result)

      LIVE_STATUSES.include?(JSON.parse(File.read(result))["status"])
    rescue JSON::ParserError
      true # half-written: the run is ending right now
    end

    # The journal says who launched and who ended; without one, an agent
    # whose transcript ends in its StructuredOutput hand-back is done.
    def run_agents(run_dir, run_id)
      journal = File.join(run_dir, "journal.jsonl")
      open = File.exist?(journal) ? open_from_journal(journal) : open_from_transcripts(run_dir)
      open.filter_map do |agent_id, started|
        transcript = File.join(run_dir, "agent-#{agent_id}.jsonl")
        next unless File.exist?(transcript)

        meta = read_json(File.join(run_dir, "agent-#{agent_id}.meta.json")) || {}
        label = started["label"] || meta["description"] || agent_id
        task = self.class.task_name(label)
        next unless task

        Agent.new(run_id: run_id, agent_id: agent_id, transcript: transcript, label: label, task: task,
                  phase: started["phase"] || meta["workflowPhase"])
      end
    end

    def open_from_journal(journal)
      open = {}
      File.foreach(journal) do |line|
        entry = JSON.parse(line) rescue next
        case entry["type"]
        when "started" then open[entry["key"]] = entry
        when "result", "failed" then open.delete(entry["key"])
        end
      end
      open.values.select { |e| e["agentId"].to_s != "" }.to_h { |e| [e["agentId"], e] }
    end

    def open_from_transcripts(run_dir)
      Dir[File.join(run_dir, "agent-*.jsonl")].sort.filter_map do |path|
        next if handed_back?(path)

        [File.basename(path, ".jsonl").delete_prefix("agent-"), {}]
      end.to_h
    end

    def handed_back?(path)
      last = tail_entries(path).reverse.find { |e| e["type"] == "assistant" }
      tool_uses(last).any? { |use| use["name"] == "StructuredOutput" }
    end

    # The task the agent was given: its last plain user message before it
    # first answered (a workflow agent gets the relayed user request first,
    # then its own task).
    def brief(path)
      texts = []
      File.foreach(path) do |line|
        entry = JSON.parse(line) rescue next
        break if entry["type"] == "assistant"
        next unless entry["type"] == "user"

        content = entry.dig("message", "content")
        text = content.is_a?(String) ? content : Array(content).filter_map { |b| b["text"] if b.is_a?(Hash) && b["type"] == "text" }.join("\n")
        texts << text unless text.strip.empty?
      end
      texts.last.to_s.sub(HARNESS_PREAMBLE, "")
    end

    def first_timestamp(path)
      File.foreach(path) do |line|
        stamp = (JSON.parse(line)["timestamp"] rescue nil)
        return Time.iso8601(stamp) if stamp
      end
      nil
    rescue ArgumentError
      nil
    end

    # What the agent said and called, newest last; tool outputs left out.
    def recent_activity(path)
      tail_entries(path).select { |e| e["type"] == "assistant" }.flat_map do |entry|
        Array(entry.dig("message", "content")).filter_map do |block|
          next unless block.is_a?(Hash)

          case block["type"]
          when "text" then "said: #{clip(block["text"], ACTIVITY_CHARS)}" unless block["text"].to_s.strip.empty?
          when "tool_use" then "#{block["name"]}: #{clip(input_summary(block["input"]), ACTIVITY_CHARS)}"
          end
        end
      end.last(ACTIVITIES)
    end

    def input_summary(input)
      return input.to_s unless input.is_a?(Hash)

      key = INPUT_KEYS.find { |k| input[k].is_a?(String) && !input[k].strip.empty? }
      key ? input[key] : JSON.generate(input)
    end

    def tail_entries(path)
      size = File.size(path)
      data = File.open(path, "rb") do |f|
        f.seek([size - TAIL_BYTES, 0].max)
        f.read
      end
      lines = data.force_encoding("UTF-8").scrub.split("\n")
      lines.shift if size > TAIL_BYTES # a cut-off first line
      lines.filter_map { |line| JSON.parse(line) rescue nil }
    end

    def tool_uses(entry)
      return [] unless entry

      Array(entry.dig("message", "content")).select { |b| b.is_a?(Hash) && b["type"] == "tool_use" }
    end

    def read_json(path)
      File.exist?(path) ? JSON.parse(File.read(path)) : nil
    rescue JSON::ParserError
      nil
    end

    def clip(text, max)
      text = text.to_s.gsub(/\s+/, " ").strip
      text.size > max ? "#{text[0, max]}…" : text
    end

    # The structured answer, or nil when it can't be read as one — the page
    # then shows the model's text as it came.
    def parse(out)
      list = JSON.parse(out).dig("structured_output", "agents")
      list.is_a?(Array) && list.all?(Hash) ? list : nil
    rescue JSON::ParserError, NoMethodError, TypeError
      nil
    end

    def answer_text(out)
      parsed = JSON.parse(out)
      parsed.is_a?(Hash) && parsed["result"].is_a?(String) && !parsed["result"].strip.empty? ? parsed["result"].strip : out.to_s.strip
    rescue JSON::ParserError
      out.to_s.strip
    end

    # One line per active agent, in our order; an agent the model skipped
    # still shows, and one it invented doesn't.
    def lines(agents, estimates)
      by_label = estimates.to_h { |e| [e["label"].to_s, e] }
      agents.map do |agent|
        estimate = by_label[agent.label] || {}
        percent = estimate["percent"]
        { "task" => agent.task, "run" => agent.run_id, "agent" => agent.key,
          "percent" => percent.is_a?(Numeric) ? percent.clamp(0, 100).round : nil,
          "doing" => estimate["doing"].to_s.strip.empty? ? "no estimate" : estimate["doing"].to_s.strip }
      end
    end

    def headless_claude(prompt, stdin)
      Open3.capture3(
        { "QM_SKIP" => "1" },
        "claude", "-p", prompt, "--model", "haiku",
        "--tools", "", "--strict-mcp-config", "--no-session-persistence",
        "--output-format", "json", "--json-schema", JSON.generate(ANSWER_SCHEMA),
        stdin_data: stdin
      )
    end
  end
end
