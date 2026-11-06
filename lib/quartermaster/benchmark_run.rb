# frozen_string_literal: true

module Quartermaster
  # One benchmark run of a branch against its project's benchmark database
  # (docs/areas/benchmarks.md): its folder under benchmarks/<run id>, its
  # meta.json, and starting, cancelling and re-running it. The steps
  # themselves run in a detached pipeline process (BenchmarkPipeline, `qm
  # bench-run <run dir>`) that outlives the GUI; this class only spawns it.
  #
  # One run at a time, machine-wide: a run is live while its meta.json says a
  # non-final state and its pid is a process whose command line names the
  # run's folder (or, pid not written yet, for STARTING_GRACE seconds after it
  # started). A non-final run that isn't live reads as failed.
  class BenchmarkRun
    DIR = File.join(ROOT, "benchmarks")
    VERSION = 1
    FINAL = %w[done failed cancelled].freeze
    STARTING_GRACE = 30
    MODELS = %w[opus sonnet].freeze
    START_LOCK = Mutex.new

    PROMPT = <<~PROMPT
      You plan and write a benchmark for the branch `%<branch>s`; qm
      measures it after you stop. Read the benchmark skill
      (%<skill>s/SKILL.md) and follow its Protocol, Guard and
      "Progress events" sections.

      Stages, compared in this order (name: ref @ sha); every event names a
      stage by exactly this name:
      %<stages>s

      What to benchmark: %<request>s

      The run folder is %<dir>s (also $QM_BENCH_DIR; the run id is
      $QM_BENCH_RUN = %<id>s). Write there:
      1. bench.rb: a copy of %<skill>s/bin/example_bench.rb with STAGES,
         cases and subject picks swapped for this branch. It appends the
         subject, stage, case, ids and done events to $QM_BENCH_DIR/events.jsonl
         as the example does, and leaves PLAN_DIR unset (plans go to
         $QM_BENCH_DIR/plans/). Keep the example's dry mode (BENCH_DRY=1:
         resolve the subjects, load every stage and build every case, then
         exit without measuring or emitting) and time with its realtime_ms.%<notes>s
      2. One `plan` event line appended to $QM_BENCH_DIR/events.jsonl: the
         stages and every case with its subject and why.
      3. run.json: {"cwd": "%<checkout>s", "clone": false}.
         cwd is this branch's checkout, so it holds the branch's version of
         every staged file: never rely on the checkout for main's code.
         bench.rb loads main like a stage (Protocol step 2): keep the
         example's MAIN stage, which evals origin/main's version of every
         file any stage changes before measuring main.
         Never check out a branch or create a worktree.
         "clone" is true only when a case writes (a job, a listener, a service
         that saves); qm then runs the script on a clone named exactly
         %<database>s_%<id>s and drops it afterwards. Otherwise qm runs it
         read-only with DATABASE_URL='%<read_only>s'.

      Before you stop, load-check bench.rb: in run.json's cwd run
      `BENCH_DRY=1 DATABASE_URL='%<read_only>s' bin/rails runner $QM_BENCH_DIR/bench.rb`
      and fix bench.rb until it exits 0. Keep the example's dry mode in
      bench.rb, since qm's measuring run is the same script without it.

      Do not measure: beyond that dry run, write bench.rb, the plan event and
      run.json, then stop.
    PROMPT
    DEFAULT_REQUEST = "work out what this branch's changes make slower or faster from its diff against main"

    # spawner: (run dir) → pid of the detached pipeline. process_line: pid →
    # its command line, or nil when no such process. killer: (signal, -pgid).
    # Tests stub all three and the runner, so nothing real starts or dies.
    def initialize(runner: CommandRunner.new, tmux: Tmux.new, branch_diff: nil, spawner: self.class.method(:spawn_pipeline),
                   process_line: self.class.method(:command_line), killer: Process.method(:kill), now: -> { Time.now })
      @runner = runner
      @branch_diff = branch_diff || BranchDiff.new(tmux: tmux, runner: runner)
      @spawner = spawner
      @process_line = process_line
      @killer = killer
      @now = now
    end

    # A project's benchmark settings (ProjectSettings::Benchmark), nil when
    # its config.yml entry has no `benchmark:`.
    def self.settings(project) = ProjectConfig.current.settings(project.to_s).benchmark

    def self.enabled?(item) = !settings(item.project).nil?

    def self.settings!(project)
      settings(project) || raise(ArgumentError, "#{project} has no benchmarks: run " \
                                                "`qm config set projects.#{project}.benchmark.database <database>` and " \
                                                "`qm config set projects.#{project}.benchmark.skill <skill folder>`")
    end

    # The template database a run measures on: the one it started with,
    # else (a run from before meta recorded it) its project's.
    def self.database(meta) = meta["database"] || settings!(meta["project"]).database

    def self.read_only_url(meta) = ProjectSettings::Benchmark.new(database: database(meta)).read_only_url

    def self.dir_for(id)
      raise ArgumentError, "not a benchmark run id: #{id}" unless id.to_s.match?(/\A\d{8}_\d{6}(_\d+)?\z/)

      File.join(DIR, id)
    end

    def self.read(id)
      JSON.parse(File.read(File.join(dir_for(id), "meta.json")))
    rescue Errno::ENOENT, JSON::ParserError
      raise ArgumentError, "no benchmark run #{id}"
    end

    # Every run's meta, newest first; an unreadable one is skipped.
    def self.all
      Dir[File.join(DIR, "*", "meta.json")].sort.reverse.filter_map do |path|
        JSON.parse(File.read(path))
      rescue JSON::ParserError, SystemCallError
        nil
      end
    end

    # meta.json written whole: a temp file renamed over it, under the run's
    # lock, so the pipeline and the GUI never interleave. The block gets the
    # current meta and returns the new one.
    def self.update(id)
      dir = dir_for(id)
      File.open(File.join(dir, ".lock"), File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        meta = yield(JSON.parse(File.read(File.join(dir, "meta.json"))))
        write_meta(dir, meta)
        meta
      end
    end

    def self.write_meta(dir, meta)
      temp = File.join(dir, "meta.json.#{Process.pid}.#{Thread.current.object_id}.tmp")
      File.write(temp, JSON.pretty_generate(meta))
      File.rename(temp, File.join(dir, "meta.json"))
    end

    # The state a reader shows: a non-final run whose pipeline is gone has failed.
    def effective(meta)
      return meta if FINAL.include?(meta["state"]) || live?(meta)

      meta.merge("state" => "failed", "error" => meta["error"] || "pipeline died")
    end

    def live?(meta) = self.class.live?(meta, now: @now.call) { |pid, id| self.class.pipeline?(@process_line.call(pid), id) }

    # The one liveness rule, shared with BenchmarkReport: a non-final run
    # whose pid passes alive (pid, id), or, with no pid yet, one that started
    # less than STARTING_GRACE seconds before now.
    def self.live?(meta, now:, &alive)
      return false if FINAL.include?(meta["state"])
      return now - Time.iso8601(meta["startedAt"].to_s) < STARTING_GRACE if meta["pid"].nil?

      meta["pid"].is_a?(Integer) && alive.call(meta["pid"], meta["id"].to_s)
    rescue ArgumentError
      false
    end

    # Whether a process's command line is run id's pipeline: a word naming
    # exactly that run's folder, so <id>_2's pipeline is not <id>'s.
    def self.pipeline?(command_line, id) = command_line.to_s.split.any? { |word| File.basename(word) == id.to_s }

    def self.alive?(pid, id) = pipeline?(command_line(pid), id)

    # The one live run among metas (default: every run), as {id, slug,
    # branch, state}, or nil.
    def busy(metas = self.class.all)
      meta = metas.find { |m| live?(m) }
      meta && meta.slice("id", "slug", "branch", "state")
    end

    # Per branch of slug, its newest run that finished done, as {id,
    # finishedAt}; metas newest first, as all reads them.
    def self.finished_by_branch(metas, slug)
      metas.each_with_object({}) do |meta, done|
        next unless meta["slug"] == slug && meta["state"] == "done"

        done[meta["branch"].to_s] ||= { "id" => meta["id"], "finishedAt" => meta["finishedAt"] }
      end
    end

    # Starts a run of item's branch: folder, meta.json, the detached
    # pipeline. Refused while another run is live.
    def start(item, branch:, request: "", model: "opus")
      raise ArgumentError, "model must be one of: #{MODELS.join(", ")}" unless MODELS.include?(model)

      settings = self.class.settings!(item.project)
      tip = @branch_diff.tip(item, branch: branch.to_s.empty? ? nil : branch)
      stages = stages_for(tip)
      launch(nil) do |id|
        { "slug" => item.slug, "project" => item.project, "database" => settings.database, "root" => tip["root"],
          "checkout" => tip["path"], "branch" => tip["branch"], "request" => request.to_s.strip, "model" => model,
          "stages" => stages, "head" => tip["head"] }.tap { |meta| meta["prompt"] = prompt(meta, id, settings) }
      end
    end

    # A new run of an earlier run's script (no agent): its bench.rb,
    # run.json and plan event, measured afresh. Refused once any stage ref
    # resolves to another sha than the original run recorded.
    def rerun(id)
      original = self.class.read(id)
      source = self.class.dir_for(id)
      %w[bench.rb run.json].each do |file|
        raise ArgumentError, "run #{id} has no #{file} to re-run" unless File.exist?(File.join(source, file))
      end
      moved = original["stages"].reject { |s| stage_sha(original["root"], s["ref"]) == s["sha"] }
      unless moved.empty?
        raise ArgumentError, "can't re-run #{id}: #{moved.map { |s| s["ref"] }.join(", ")} moved since it ran — start a new benchmark"
      end

      database = self.class.database(original)
      launch(source) do
        original.slice("slug", "project", "root", "checkout", "branch", "request", "model", "stages", "head")
                .merge("database" => database, "rerunOf" => id)
      end
    end

    # Stops a run: state cancelled first (so the dying pipeline writes no
    # other), then its process group killed, then its clone dropped by
    # exactly its own name (none when no database is known for it).
    # Measured cases stay.
    def cancel(id)
      before = nil
      meta = self.class.update(id) do |current|
        before = current
        raise ArgumentError, "run #{id} already #{current["state"]}" if FINAL.include?(current["state"])

        current.merge("state" => "cancelled", "finishedAt" => @now.call.utc.iso8601)
      end
      begin
        @killer.call("TERM", -before["pid"]) if before["pid"] && live?(before)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      clone = begin
        self.class.clone_name(before)
      rescue ArgumentError
        return meta
      end
      dropped = @runner.call(["dropdb", "--if-exists", "--force", clone])
      return meta if dropped.success? || before["state"] != "measuring"

      File.write(File.join(self.class.dir_for(id), "pipeline.log"),
                 "#{@now.call.utc.iso8601} cancel: dropdb failed\n#{dropped.err.to_s.strip}\n", mode: "a")
      self.class.clone_left(id, dropped.err)
    end

    def self.clone_name(meta) = "#{database(meta)}_#{meta["id"]}"

    # Records on meta.json's warning (appended to any earlier one unless it
    # already says the same, never touching error) that the run's clone
    # survived a failed dropdb; → meta.
    def self.clone_left(id, stderr)
      name = clone_name(read(id))
      cause = Quartermaster.clip(BenchmarkPipeline.cause_line(stderr) || "it printed nothing", 200)
      text = "dropdb failed: #{cause} — clone #{name} is still on disk; drop it with: dropdb #{name} — see pipeline.log"
      update(id) do |meta|
        next meta if meta["warning"].to_s.include?(text)

        meta.merge("warning" => [meta["warning"], text].compact.reject(&:empty?).join(" "))
      end
    end

    # main, then one stage per gh-stack layer from the bottom up to and
    # including the branch, else the branch alone; each {name, ref, sha}.
    def stages_for(tip)
      root = tip["root"]
      trunk = GitRepo.new(root).trunk_refs.first
      raise ArgumentError, "no main to compare against: none of #{GitRepo::TRUNK_REFS.join(", ")} exists" unless trunk

      stack = GhStack.for_root(root).stacks_for([tip["branch"]]).first
      entries = stack ? stack.to_a : [GhStack::Entry.new(branch: tip["branch"])]
      upto = entries.index { |e| e.branch == tip["branch"] }
      layers = entries.first(upto + 1).map do |entry|
        ref = [entry.branch, "origin/#{entry.branch}"].find { |r| stage_sha(root, r) }
        raise ArgumentError, "stack layer #{entry.branch} has no ref" unless ref

        { "name" => entry.pr_number ? "##{entry.pr_number}" : entry.branch, "ref" => ref, "sha" => stage_sha(root, ref) }
      end
      [{ "name" => "main", "ref" => trunk, "sha" => stage_sha(root, trunk) }] + layers
    end

    def prompt(meta, id, settings)
      stages = meta["stages"].map { |s| "- #{s["name"]}: #{s["ref"]} @ #{s["sha"]}" }.join("\n")
      request = meta["request"].to_s.empty? ? DEFAULT_REQUEST : meta["request"]
      format(PROMPT, branch: meta["branch"], stages: stages, request: request, dir: self.class.dir_for(id), id: id,
                     checkout: meta["checkout"], skill: settings.skill, database: settings.database,
                     read_only: settings.read_only_url, notes: settings.notes ? "\n#{settings.notes.gsub(/^/, "   ")}" : "")
    end

    # The detached pipeline: its own process group (a cancel kills it with
    # everything it started), stdio to pipeline.log, so it outlives the GUI.
    def self.spawn_pipeline(dir)
      log = File.join(dir, "pipeline.log")
      pid = Process.spawn(RbConfig.ruby, EXECUTABLE, "bench-run", dir, pgroup: true, chdir: dir,
                                                                       in: File::NULL, out: [log, "a"], err: [log, "a"])
      Process.detach(pid)
      pid
    end

    def self.command_line(pid)
      out, _err, status = Open3.capture3("ps", "-o", "command=", "-p", pid.to_s)
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    private

    def stage_sha(root, ref) = Quartermaster.git(root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")

    # The folder and meta.json of a new run, then its pipeline. copy_from:
    # the run whose script a re-run measures again.
    def launch(copy_from)
      START_LOCK.synchronize do
        if (other = busy)
          raise ArgumentError, "a benchmark is already running: #{other["branch"]} (#{other["slug"]}, run #{other["id"]})"
        end

        id, dir = claim_dir
        meta = { "v" => VERSION, "id" => id }.merge(yield(id))
                                             .merge("startedAt" => @now.call.utc.iso8601, "finishedAt" => nil,
                                                    "state" => copy_from ? "measuring" : "planning", "error" => nil, "pid" => nil)
        meta["rerunOf"] ||= nil
        copy_script(copy_from, dir) if copy_from
        self.class.write_meta(dir, meta)
        begin
          pid = @spawner.call(dir)
        rescue StandardError => e
          self.class.update(id) { |current| current.merge("state" => "failed", "error" => "could not start: #{e.message}") }
          raise ArgumentError, "the benchmark pipeline did not start: #{e.message}"
        end
        self.class.update(id) { |current| current.merge("pid" => pid) }
      end
    end

    # run id: the UTC second, _2, _3… on a clash; DB-name safe.
    def claim_dir
      FileUtils.mkdir_p(DIR)
      stamp = @now.call.utc.strftime("%Y%m%d_%H%M%S")
      (1..).each do |n|
        id = n == 1 ? stamp : "#{stamp}_#{n}"
        dir = File.join(DIR, id)
        begin
          Dir.mkdir(dir)
        rescue Errno::EEXIST
          next
        end
        FileUtils.mkdir_p(File.join(dir, "plans"))
        return [id, dir]
      end
    end

    def copy_script(source, dir)
      %w[bench.rb run.json].each { |file| FileUtils.cp(File.join(source, file), File.join(dir, file)) }
      plan = BenchmarkPipeline.events(source).find { |event| event["t"] == "plan" }
      File.write(File.join(dir, "events.jsonl"), "#{JSON.generate(plan)}\n") if plan
    end
  end
end
