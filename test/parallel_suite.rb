# frozen_string_literal: true

# Runs test files as fresh `ruby` processes, at most `jobs` at once, biggest file
# first, and prints one summed result. Loads nothing of qm itself: every child
# loads test_helper on its own, so each gets its own tmpdirs and tmux socket.
require "etc"
require "open3"
require "rbconfig"
require "shellwords"

class ParallelSuite
  SUMMARY = /(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/
  FileResult = Struct.new(:file, :output, :status, :counts) do
    def passed? = status.success? && !counts.nil? && counts[2].zero? && counts[3].zero?
  end

  def self.jobs(env = ENV)
    jobs = Integer(env.fetch("QM_TEST_JOBS", Etc.nprocessors))
    raise ArgumentError, "QM_TEST_JOBS must be at least 1, got #{jobs}" if jobs < 1

    jobs
  end

  # [seed, the other arguments]: one seed for every file, so each replays alone.
  def self.split_seed(args)
    rest = args.dup
    if (i = rest.index("--seed"))
      seed = rest.delete_at(i + 1)
      rest.delete_at(i)
    elsif (flag = rest.find { |a| a.start_with?("--seed=") })
      seed = rest.delete(flag).delete_prefix("--seed=")
    end
    [seed ? Integer(seed) : Random.new_seed % 0xFFFF, rest]
  end

  def initialize(files, jobs:, seed:, args: [], out: $stdout)
    @files = files.map { |f| f.delete_prefix("#{Dir.pwd}/") }
    @jobs = jobs
    @seed = seed
    @args = args
    @out = out
  end

  def queue_order = @files.sort_by { |f| -File.size(f) }

  # true when every file ran and passed.
  def run
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    queue = Queue.new
    queue_order.each { |f| queue << f }
    queue.close
    results = Queue.new
    Array.new([@jobs, @files.size].min) do
      Thread.new { while (file = queue.pop) do results << run_file(file) end }
    end.each(&:join)
    report(Array.new(results.size) { results.pop }, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
  end

  private

  def command(file) = [RbConfig.ruby, file, "--seed", @seed.to_s, *@args]

  def run_file(file)
    output, status = Open3.capture2e(*command(file))
    FileResult.new(file, output, status, output.scan(SUMMARY).last&.map(&:to_i))
  end

  def report(results, seconds)
    failed = results.reject(&:passed?).sort_by { |r| @files.index(r.file) }
    failed.each do |r|
      why = r.counts ? "" : " (no minitest summary, exit #{r.status.exitstatus.inspect})"
      @out.puts "== #{r.file}#{why}", r.output, "Replay: #{Shellwords.join(['ruby', *command(r.file).drop(1)])}", ""
    end
    totals = results.filter_map(&:counts).transpose.map(&:sum)
    totals = [0] * 5 if totals.empty?
    @out.puts format("%d runs, %d assertions, %d failures, %d errors, %d skips in %.1fs " \
                     "(%d files, %d workers, seed %d)", *totals, seconds, @files.size, @jobs, @seed)
    @out.puts "#{failed.size} of #{@files.size} files failed" unless failed.empty?
    failed.empty?
  end
end
