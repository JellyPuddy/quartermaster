# frozen_string_literal: true

module Quartermaster
  # The benchmark modal's payload, folded read-only from the run folders
  # under BenchmarkRun::DIR: each run's meta.json (the pipeline's record of what
  # it ran and where it is), events.jsonl (the bench script's progress
  # events, the benchmark skill's "Progress events"), agent.jsonl (the
  # planning agent's stream, for the activity line) and verdict.md. Unknown
  # fields and event kinds are ignored, and a line that doesn't parse (a
  # write still in flight) is skipped.
  #
  # A run whose state isn't final but that isn't live by BenchmarkRun.live?
  # reads as failed, "pipeline died".
  class BenchmarkReport
    RUN_ID = /\A\d{8}_\d{6}(?:_\d+)?\z/
    AGENT_TAIL_BYTES = 64 * 1024

    # head_of: the branch's current head, nil when unknown; resolve: the
    # sha a ref names in a repo root, nil when none; alive: whether pid is
    # the pipeline of that run id. All read-only; tests pass stubs.
    def initialize(runner: CommandRunner.new, tmux: Tmux.new, head_of: nil, resolve: nil, alive: nil, now: -> { Time.now })
      @head_of = head_of || lambda do |item, branch|
        BranchDiff.new(tmux: tmux, runner: runner).tip(item, branch: branch)["head"]
      rescue StandardError
        nil
      end
      @resolve = resolve || ->(root, ref) { Quartermaster.git(root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}") }
      @alive = alive || BenchmarkRun.method(:alive?)
      @now = now
    end

    # The run files the modal's Logs section may show, in its order.
    LOGS = %w[bench.log pipeline.log bench.out run.json bench.rb].freeze
    LOG_TAIL_BYTES = 64 * 1024

    # GET /api/benchmark/<slug>?branch=B[&run=ID],
    # GET /api/benchmark-plan/<run-id>/<file> and
    # GET /api/benchmark-log/<run-id>/<name>, as the GUI router's
    # [status, content type, body].
    def self.respond(route, query, runner:, tmux:)
      if (rest = route[%r{\A/api/benchmark-plan/(.*)}m, 1])
        return text_response(rest) { |id, file| plan_file(id, file) }
      end
      if (rest = route[%r{\A/api/benchmark-log/(.*)}m, 1])
        return text_response(rest) { |id, name| log_file(id, name) }
      end

      params = URI.decode_www_form(query.to_s).to_h
      item = WorkItem.find(URI.decode_www_form_component(route.delete_prefix("/api/benchmark/")))
      json({ "ok" => true }.merge(new(runner: runner, tmux: tmux).call(item, branch: params["branch"], run: params["run"])))
    rescue StandardError => e
      Quartermaster.log_error("gui-benchmark", e) unless e.is_a?(ArgumentError)
      json("ok" => false, "error" => e.message)
    end

    def self.text_response(rest)
      id, file = rest.split("/", 2).map { |part| URI.decode_www_form_component(part.to_s) }
      ["200 OK", "text/plain; charset=utf-8", yield(id, file)]
    rescue StandardError => e
      Quartermaster.log_error("gui-benchmark-file", e) unless e.is_a?(ArgumentError)
      ["404 Not Found", "text/plain; charset=utf-8", e.message]
    end

    def self.json(object) = ["200 OK", "application/json; charset=utf-8", JSON.generate(object)]

    # A saved EXPLAIN plan: a plain file name inside that run's plans/.
    def self.plan_file(id, file)
      plans = File.join(run_dir(id), "plans")
      name = file.to_s
      raise ArgumentError, "bad plan file name" if name.empty? || name.include?("/") || %w[. ..].include?(name)

      path = File.join(plans, name)
      raise ArgumentError, "no plan #{name} in run #{id}" unless File.file?(path)
      raise ArgumentError, "bad plan file name" unless File.realpath(path).start_with?("#{File.realpath(plans)}/")

      File.read(path)
    end

    # The last 64 KB of one of LOGS in an existing run folder, as text.
    def self.log_file(id, name)
      raise ArgumentError, "no log #{name.inspect}" unless LOGS.include?(name)

      path = File.join(run_dir(id), name)
      raise ArgumentError, "no #{name} in run #{id}" unless File.file?(path)

      File.open(path) do |f|
        f.seek([f.size - LOG_TAIL_BYTES, 0].max)
        f.read.scrub
      end
    end

    def self.run_dir(id)
      raise ArgumentError, "bad benchmark run id #{id.inspect}" unless id.to_s.match?(RUN_ID)

      File.join(BenchmarkRun::DIR, id)
    end

    # { enabled, branch, busy, runs, run }: the runs of item's branch,
    # newest first, and the asked run (or the newest) in full.
    def call(item, branch: nil, run: nil)
      branch = branch.to_s.empty? ? nil : branch
      metas = all_metas
      mine = metas.select { |meta| meta["slug"] == item.slug && meta["branch"] == branch }
                  .sort_by { |meta| [meta["startedAt"].to_s, meta["id"]] }.reverse
      chosen = run.to_s.empty? ? mine.first : find(metas, run)
      { "enabled" => BenchmarkRun.enabled?(item), "branch" => branch, "busy" => busy(metas),
        "runs" => mine.map { |meta| meta.slice("id", "startedAt", "state", "request", "rerunOf") },
        "run" => chosen && full(item, chosen) }
    end

    # The live run, machine-wide, or nil.
    def busy(metas = all_metas)
      live = metas.find { |meta| !BenchmarkRun::FINAL.include?(meta["state"]) }
      live&.slice("id", "slug", "branch", "state")
    end

    private

    def find(metas, id)
      self.class.run_dir(id)
      metas.find { |meta| meta["id"] == id } || raise(ArgumentError, "no benchmark run #{id}")
    end

    def all_metas
      Dir[File.join(BenchmarkRun::DIR, "*", "meta.json")].sort.filter_map { |path| read_meta(File.basename(File.dirname(path)), path) }
    end

    def read_meta(id, path)
      return nil unless id.match?(RUN_ID)

      meta = JSON.parse(File.read(path))
      return nil unless meta.is_a?(Hash)

      meta = meta.merge("id" => id, "request" => meta["request"].to_s)
      return meta if BenchmarkRun::FINAL.include?(meta["state"]) || BenchmarkRun.live?(meta, now: @now.call, &@alive)

      meta.merge("state" => "failed", "error" => "pipeline died")
    rescue StandardError
      nil
    end

    def full(item, meta)
      dir = File.join(BenchmarkRun::DIR, meta["id"])
      events = read_events(File.join(dir, "events.jsonl"))
      current = meta["head"] && @head_of.call(item, meta["branch"])
      meta.slice("id", "slug", "branch", "request", "model", "startedAt", "finishedAt", "state", "error", "warning",
                 "head", "rerunOf")
          .merge("durationS" => duration(meta), "activity" => (activity(dir) if meta["state"] == "planning"),
                 "currentHead" => current, "moved" => !current.nil? && current != meta["head"],
                 "stages" => stages(meta), "subjects" => subjects(events), "rows" => rows(events),
                 "verdict" => verdict(dir), "canRerun" => can_rerun?(meta, dir),
                 "logs" => LOGS.select { |name| File.file?(File.join(dir, name)) })
    end

    def read_events(path)
      return [] unless File.file?(path)

      File.foreach(path).filter_map do |line|
        event = JSON.parse(line)
        event if event.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end

    def stages(meta)
      Array(meta["stages"]).select { |stage| stage.is_a?(Hash) }.map { |stage| stage.slice("name", "ref", "sha") }
    end

    def subjects(events)
      events.select { |e| e["t"] == "subject" }.each_with_object({}) { |e, by| by[e["subject"]] = e["about"] }
            .map { |subject, about| { "subject" => subject, "about" => about } }
    end

    # One row per planned subject × case (the last plan event's), then any
    # measured one the plan didn't name; cells keyed by stage name.
    def rows(events)
      plan = events.reverse.find { |e| e["t"] == "plan" }
      rows = {}
      Array(plan && plan["cases"]).each do |c|
        next unless c.is_a?(Hash)

        rows[[c["subject"], c["case"]]] = { "subject" => c["subject"], "case" => c["case"], "why" => c["why"], "cells" => {} }
      end
      events.each do |e|
        key = [e["subject"], e["case"]]
        case e["t"]
        when "case"
          row = rows[key] ||= { "subject" => e["subject"], "case" => e["case"], "why" => nil, "cells" => {} }
          row["cells"][e["stage"]] = e.slice("ms", "timeout", "queries", "plan").merge("ids" => nil, "vs" => nil)
        when "ids"
          cell = rows.dig(key, "cells", e["stage"])
          cell&.merge!(e.slice("ids", "vs"))
        end
      end
      rows.values
    end

    def duration(meta)
      return nil if BenchmarkRun::FINAL.include?(meta["state"]) && !meta["finishedAt"]

      started = Time.iso8601(meta["startedAt"].to_s)
      finished = meta["finishedAt"] ? Time.iso8601(meta["finishedAt"]) : @now.call
      (finished - started).round
    rescue ArgumentError
      nil
    end

    # The agent's latest tool call as one line, read from the stream's tail.
    def activity(dir)
      path = File.join(dir, "agent.jsonl")
      return nil unless File.file?(path)

      size = File.size(path)
      tail = File.open(path) do |f|
        f.seek([size - AGENT_TAIL_BYTES, 0].max)
        f.read.scrub
      end
      tail.split("\n").reverse_each do |line|
        call = tool_use(line)
        return TranscriptHistory.tool_line(call) if call
      end
      nil
    end

    def tool_use(line)
      entry = JSON.parse(line)
      return nil unless entry.is_a?(Hash) && entry["type"] == "assistant"

      Array(entry.dig("message", "content")).reverse.find { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
    rescue JSON::ParserError
      nil
    end

    def verdict(dir)
      path = File.join(dir, "verdict.md")
      text = File.file?(path) ? File.read(path).strip : ""
      text.empty? ? nil : text
    end

    # Re-running needs the script and its run.json, a final run, and every
    # stage ref still naming the sha it was measured at.
    def can_rerun?(meta, dir)
      return false unless BenchmarkRun::FINAL.include?(meta["state"])
      return false unless %w[bench.rb run.json].all? { |file| File.file?(File.join(dir, file)) }

      stages = stages(meta)
      !stages.empty? && stages.all? { |stage| stage["ref"] && stage["sha"] && @resolve.call(meta["root"], stage["ref"]) == stage["sha"] }
    end
  end
end
