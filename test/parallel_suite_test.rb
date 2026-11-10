# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/parallel_suite_test.rb`).
# The parallel runner against tiny fixture test files, never the real suite.
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "parallel_suite"

class ParallelSuiteTest < Minitest::Test
  PASSING = <<~RUBY
    require "minitest/autorun"
    class PassingFixture < Minitest::Test
      def test_passes = assert(true)
    end
  RUBY
  FAILING = <<~RUBY
    require "minitest/autorun"
    class FailingFixture < Minitest::Test
      def test_fails = assert_equal("expected", "actual")
      def test_skips = skip
    end
  RUBY

  def with_fixtures(files)
    Dir.mktmpdir do |dir|
      paths = files.map do |name, source|
        File.join(dir, name).tap { |path| File.write(path, source) }
      end
      yield(*paths)
    end
  end

  def run_suite(files, jobs: 2, args: [])
    out = StringIO.new
    ok = ParallelSuite.new(files, jobs: jobs, seed: 42, args: args, out: out).run
    [ok, out.string]
  end

  def test_all_passing_files_report_their_summed_counts_and_succeed
    with_fixtures("a_test.rb" => PASSING, "b_test.rb" => PASSING) do |a, b|
      ok, out = run_suite([a, b])
      assert ok
      assert_match(/^2 runs, 2 assertions, 0 failures, 0 errors, 0 skips in [\d.]+s/, out)
      refute_match(/Replay/, out)
      refute_match(/PassingFixture/, out)
    end
  end

  def test_a_failing_file_shows_its_output_and_a_replay_command_and_fails_the_run
    with_fixtures("pass_test.rb" => PASSING, "fail_test.rb" => FAILING) do |pass, fail|
      ok, out = run_suite([pass, fail])
      refute ok
      assert_match(/^3 runs, 2 assertions, 1 failures, 0 errors, 1 skips/, out)
      assert_match(/FailingFixture#test_fails/, out)
      assert_match(/Expected: "expected"/, out)
      assert_includes out, "Replay: ruby #{fail} --seed 42"
      refute_includes out, "Replay: ruby #{pass}"
    end
  end

  def test_a_file_that_crashes_or_prints_no_summary_fails_the_run
    with_fixtures("pass_test.rb" => PASSING, "crash_test.rb" => "raise 'boom at load'\n",
                  "silent_test.rb" => "puts 'no tests here'\n") do |pass, crash, silent|
      ok, out = run_suite([pass, crash, silent], jobs: 3)
      refute ok
      assert_match(/^1 runs, 1 assertions, 0 failures, 0 errors, 0 skips/, out)
      assert_match(/boom at load/, out)
      assert_includes out, "Replay: ruby #{crash} --seed 42"
      assert_includes out, "Replay: ruby #{silent} --seed 42"
      assert_match(/2 of 3 files failed/, out)
    end
  end

  def test_extra_arguments_reach_every_file_and_its_replay_command
    with_fixtures("fail_test.rb" => FAILING) do |fail|
      ok, out = run_suite([fail], args: ["-n", "test_skips"])
      assert ok
      assert_match(/^1 runs, 0 assertions, 0 failures, 0 errors, 1 skips/, out)
    end
  end

  def test_the_queue_starts_with_the_biggest_file
    with_fixtures("small_test.rb" => "#", "big_test.rb" => "#" * 100, "mid_test.rb" => "#" * 10) do |small, big, mid|
      assert_equal [big, mid, small], ParallelSuite.new([small, big, mid], jobs: 2, seed: 1).queue_order
    end
  end

  def test_jobs_default_to_the_cpu_count_and_follow_qm_test_jobs
    assert_equal Etc.nprocessors, ParallelSuite.jobs({})
    assert_equal 3, ParallelSuite.jobs("QM_TEST_JOBS" => "3")
    assert_raises(ArgumentError) { ParallelSuite.jobs("QM_TEST_JOBS" => "0") }
  end

  def test_a_seed_in_the_arguments_is_taken_out_and_used
    assert_equal [7, ["-n", "x"]], ParallelSuite.split_seed(["--seed", "7", "-n", "x"])
    assert_equal [8, []], ParallelSuite.split_seed(["--seed=8"])
    seed, rest = ParallelSuite.split_seed(["-v"])
    assert_kind_of Integer, seed
    assert_equal ["-v"], rest
  end
end
