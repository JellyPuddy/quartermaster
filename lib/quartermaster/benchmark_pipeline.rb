# frozen_string_literal: true

module Quartermaster
  # The steps of one benchmark run, run by the detached `qm bench-run <run
  # dir>` process BenchmarkRun spawns (docs/areas/benchmarks.md):
  #   1. plan & write — `claude -p` in the branch's checkout writes bench.rb,
  #      the plan event and run.json (skipped by a re-run, which copied them);
  #   2. measure — `bin/rails runner bench.rb` in run.json's cwd, read-only,
  #      or on a clone named exactly <database>_<run id> that is dropped
  #      afterwards, also on failure;
  #   3. verdict — a sonnet call over the table, saved as verdict.md.
  # Each state lands in meta.json before its step starts; a final state
  # (a cancel's) is never overwritten, and stops the pipeline at its next
  # step. On done or failed: a macOS notification whose click opens the
  # GUI's benchmark modal, and a history note on the item.
  class BenchmarkPipeline
    AGENT_TOOLS = "Read,Grep,Glob,Write,Edit,Bash"
    MIN_FREE_BYTES = 20 * 1024**3

    VERDICT_PROMPT = <<~PROMPT
      Below is a benchmark of a branch against main on the project's benchmark
      database: why each case was picked, then the measured table (milliseconds
      per stage; "timeout" means more than 60 s; "same ids" checks a list case
      returns what the earlier stage returned). Write two or three plain
      sentences: what got faster or slower, by roughly how much, and whether
      any case returns different ids. Timings move 20-40% between runs, even
      main against main, so call a difference under about 40% noise rather
      than a change. Answer with the sentences only.
    PROMPT

    # Stops the pipeline: its run reached a final state elsewhere (a cancel).
    class Stopped < StandardError; end

    # A step that failed: its message is meta.json's error, stderr the tail
    # pipeline.log keeps when no log of the step's own holds it.
    class StepFailed < StandardError
      attr_reader :stderr

      def initialize(message, stderr = nil)
        super(message)
        @stderr = stderr
      end
    end

    ERROR_MAX = 300
    STDERR_TAIL = 4000
    EXCEPTION_LINE = /\b\w*(Error|Exception)\b|:in '.*': /
    WARNING_LINE = /\bwarning:/i

    # The line of a failed command's stderr that names its cause: the first
    # exception-looking line that is no warning, else the last non-empty one.
    def self.cause_line(stderr)
      lines = stderr.to_s.lines.map(&:strip).reject(&:empty?)
      lines.find { |line| line.match?(EXCEPTION_LINE) && !line.match?(WARNING_LINE) } || lines.last
    end

    def self.events(dir)
      File.readlines(File.join(dir, "events.jsonl")).filter_map { |line| Quartermaster.json_object(line) }
    rescue SystemCallError
      []
    end

    # free_bytes: → bytes free where a clone would land; notifier: what
    # #announce raises the finished run's notification on.
    def initialize(dir, runner: CommandRunner.new, notifier: nil, free_bytes: self.class.method(:free_bytes),
                   now: -> { Time.now })
      @id = File.basename(File.expand_path(dir))
      @dir = BenchmarkRun.dir_for(@id)
      @runner = runner
      @notifier = notifier || TurnNotifier.new(runner: runner)
      @free_bytes = free_bytes
      @now = now
    end

    def call
      meta = BenchmarkRun.update(@id) { |current| current.merge("pid" => Process.pid) }
      plan(meta) unless meta["rerunOf"]
      measure(meta)
      verdict
      finish("done")
    rescue Stopped
      nil
    rescue StandardError, SignalException => e
      log("#{e.class}: #{e.message}")
      log("stderr:\n#{e.stderr[-STDERR_TAIL..] || e.stderr}") if e.is_a?(StepFailed) && e.stderr
      finish("failed", e.message)
    end

    private

    def path(file) = File.join(@dir, file)

    def plan(meta)
      transition("planning")
      argv = ["env", "QM_SKIP=1", "QM_BENCH_DIR=#{@dir}", "QM_BENCH_RUN=#{@id}", "claude", "-p", meta["prompt"],
              "--model", meta["model"], "--allowedTools", AGENT_TOOLS, "--add-dir", @dir,
              "--output-format", "stream-json", "--verbose", "--strict-mcp-config"]
      result, stderr = streamed(argv, meta["checkout"], "agent.jsonl", "pipeline.log")
      raise failure("the planning agent failed", stderr, "pipeline.log", silent: "agent.jsonl") unless result.success?

      run_spec
    end

    # run.json as the agent wrote it, checked: {cwd, clone}.
    def run_spec
      raise ArgumentError, "the planning agent wrote no bench.rb" unless File.exist?(path("bench.rb"))

      spec = JSON.parse(File.read(path("run.json")))
      raise ArgumentError, "run.json's cwd #{spec["cwd"].inspect} is no directory" unless spec["cwd"].is_a?(String) && File.directory?(spec["cwd"])

      spec
    rescue Errno::ENOENT
      raise ArgumentError, "the planning agent wrote no run.json"
    rescue JSON::ParserError => e
      raise ArgumentError, "run.json does not parse: #{e.message[0, 200]}"
    end

    def measure(meta)
      spec = run_spec
      transition("measuring")
      url = spec["clone"] ? clone(meta) : BenchmarkRun.read_only_url(meta)
      argv = ["env", "QM_SKIP=1", "QM_BENCH_DIR=#{@dir}", "QM_BENCH_RUN=#{@id}", "DATABASE_URL=#{url}",
              "bin/rails", "runner", path("bench.rb")]
      result, stderr = streamed(argv, spec["cwd"], "bench.out", "bench.log")
      raise failure("bin/rails runner failed", stderr, "bench.log", silent: "bench.out", keep: true) unless result.success?
    ensure
      drop_clone if @cloned
    end

    # The clone's URL, after checking there is room for it.
    def clone(meta)
      free = @free_bytes.call
      if free < MIN_FREE_BYTES
        raise ArgumentError, "only #{free / 1024**3} GB free; a clone of the benchmark database needs #{MIN_FREE_BYTES / 1024**3} GB"
      end

      name = BenchmarkRun.clone_name(meta)
      result = @runner.call(["createdb", "-T", BenchmarkRun.database(meta), name])
      raise failure("createdb #{name} failed", result.err, "pipeline.log", keep: true) unless result.success?

      @cloned = name
      "postgres:///#{name}"
    end

    # A failed drop is logged and lands on meta.json's warning, never
    # raised: it must not mask the step's own error.
    def drop_clone
      result = @runner.call(["dropdb", "--if-exists", "--force", @cloned])
      return if result.success?

      log("#{failure("dropdb failed", result.err, "pipeline.log").message}\n#{result.err.to_s.strip}")
      BenchmarkRun.clone_left(@id, result.err)
    rescue StandardError => e
      log("dropdb warning: #{e.message}")
    end

    def verdict
      table = File.exist?(path("bench.out")) ? File.read(path("bench.out")).strip : ""
      raise ArgumentError, "bench.rb printed no table" if table.empty?

      transition("verdict")
      result = @runner.call(["env", "QM_SKIP=1", "claude", "-p", "#{VERDICT_PROMPT}\n#{whys}\n\n#{table}\n",
                             "--model", "sonnet", "--tools", "", "--strict-mcp-config", "--no-session-persistence"])
      text = result.out.to_s.strip
      unless result.success? && !text.empty?
        raise failure("the verdict call failed", result.err.to_s.strip.empty? ? text : result.err, "pipeline.log", keep: true)
      end

      File.write(path("verdict.md"), "#{text}\n")
    end

    def whys
      plan = self.class.events(@dir).find { |event| event["t"] == "plan" }
      cases = plan ? Array(plan["cases"]) : []
      lines = cases.map { |c| "- #{c["subject"]} / #{c["case"]}: #{c["why"]}" }
      "Why each case:\n#{lines.empty? ? "(no plan event)" : lines.join("\n")}"
    end

    # Moves the run to state unless it is already final; Stopped when it is.
    def transition(state, extra = {})
      moved = false
      BenchmarkRun.update(@id) do |meta|
        next meta if BenchmarkRun::FINAL.include?(meta["state"])

        moved = true
        meta.merge("state" => state).merge(extra)
      end
      raise Stopped unless moved
    end

    def finish(state, error = nil)
      transition(state, "finishedAt" => @now.call.utc.iso8601, "error" => error)
      meta = BenchmarkRun.read(@id)
      summary = state == "done" ? one_line(File.read(path("verdict.md"))) : "failed: #{one_line(error.to_s)}"
      announce(meta, state, summary)
      record(meta, summary)
    rescue Stopped
      nil
    end

    def announce(meta, state, summary)
      @notifier.announce(title: "Benchmark #{state} · #{meta["branch"]}", body: summary, group: "qm-bench-#{@id}",
                         click: ["open-chat", meta["slug"], "--benchmark", meta["branch"]])
    rescue StandardError => e
      log("notification: #{e.message}")
    end

    def record(meta, summary)
      WorkItem.find(meta["slug"]).add_note("Benchmark #{meta["branch"]}: #{summary} (run #{@id})", kind: "history")
    rescue StandardError => e
      log("history note: #{e.message}")
    end

    def one_line(text) = Quartermaster.clip(text.gsub(/\s+/, " ").strip, 240)

    # Runs argv streaming to the run folder's out and err files; → [result,
    # the stderr this call appended].
    def streamed(argv, chdir, out, err)
      from = File.size?(path(err)).to_i
      result = @runner.call(argv, chdir: chdir, out: path(out), err: path(err))
      stderr = File.exist?(path(err)) ? File.open(path(err), "rb") { |f| f.seek(from) && f.read } : ""
      [result, stderr.to_s.force_encoding(Encoding::UTF_8).scrub]
    end

    # "<step>: <cause line> — see <log>" in at most ERROR_MAX chars, the
    # cause losing its front at a path or word boundary. silent: the file to
    # point at when stderr was empty; keep: pipeline.log keeps the stderr tail.
    def failure(step, stderr, log, silent: log, keep: false)
      cause = self.class.cause_line(stderr)
      return StepFailed.new("#{step}: it printed nothing — see #{silent}") unless cause

      suffix = " — see #{log}"
      StepFailed.new("#{step}: #{front_clipped(cause, ERROR_MAX - step.length - 2 - suffix.length)}#{suffix}",
                     keep ? stderr.to_s.strip : nil)
    end

    def front_clipped(text, room)
      return text if text.length <= room

      tail = text[-(room - 1)..]
      cut = tail.index(%r{[\s/]})
      "…#{cut ? tail[(cut + 1)..] : tail}"
    end

    def log(message)
      File.write(path("pipeline.log"), "#{@now.call.utc.iso8601} #{message}\n", mode: "a")
    rescue SystemCallError
      nil
    end

    # Bytes free in the home volume, where Postgres.app keeps its data.
    def self.free_bytes
      out, _err, status = Open3.capture3("df", "-Pk", Dir.home)
      status.success? ? out.lines.last.split[3].to_i * 1024 : 0
    end
  end
end
