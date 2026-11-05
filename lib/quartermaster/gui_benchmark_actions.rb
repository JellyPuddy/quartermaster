# frozen_string_literal: true

module Quartermaster
  # The benchmark modal's actions (BenchmarkRun, docs/areas/benchmarks.md):
  # start, cancel and re-run. GuiActions hands every benchmark-* command here,
  # and Gui runs them off the action mutex: BenchmarkRun keeps its own start
  # lock and meta.json flock, and a cancel's dropdb runs on a job.
  class GuiBenchmarkActions
    COMMANDS = %w[benchmark-start benchmark-cancel benchmark-rerun].freeze

    def initialize(benchmarks:, jobs:)
      @benchmarks = benchmarks
      @jobs = jobs
    end

    def dispatch(cmd, slug, args)
      case cmd
      when "benchmark-start" then start(WorkItem.find(slug), args)
      when "benchmark-cancel" then cancel(args["run"].to_s)
      when "benchmark-rerun" then busy_reply || launched(@benchmarks.rerun(args["run"].to_s))
      end
    end

    private

    def start(item, args)
      BenchmarkRun.settings!(item.project)

      model = args["model"].to_s.empty? ? "opus" : args["model"]
      busy_reply || launched(@benchmarks.start(item, branch: args["branch"].to_s, request: args["request"].to_s, model: model))
    end

    # Refused before the pipeline is touched; the job then kills the group
    # and drops the clone, which can take a while on a big database.
    def cancel(id)
      state = BenchmarkRun.read(id)["state"]
      raise ArgumentError, "run #{id} already #{state}" if BenchmarkRun::FINAL.include?(state)

      @jobs.background("benchmark-#{id}", "cancelling the benchmark…") do
        @benchmarks.cancel(id)
        { "ok" => true, "message" => "benchmark #{id} cancelled" }
      end
    end

    # The modal links to the busy run; BenchmarkRun's own refusal still
    # guards the race between this check and the launch.
    def busy_reply
      busy = @benchmarks.busy or return

      { "ok" => false, "busy" => busy,
        "error" => "a benchmark is already running: #{busy["branch"]} (#{busy["slug"]}, run #{busy["id"]})" }
    end

    def launched(meta) = { "ok" => true, "run" => meta["id"] }
  end
end
