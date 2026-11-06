# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/non_object_lines_test.rb`).
require_relative "test_helper"

# martijnpieters/quartermaster#5: a JSONL line that parses but is not an
# object (a hand edit, a stray write) is skipped like a garbled one, by every
# reader that parses per line, and never takes the reader down.
class NonObjectLinesTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  NON_OBJECTS = "5\n[]\n\"x\"\nnull\n"

  def append_raw(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "a") { |f| f.write(text) }
  end

  def test_the_event_fold_skips_them_and_moves_its_offset_past
    log_events("s", [30, "UserPromptSubmit"])
    append_raw(events_path, NON_OBJECTS)
    log_events("s", [10, "Stop"])

    assert_equal "your_turn", turn("s")["state"]
    fold = JSON.parse(File.read(File.join(Quartermaster::ROOT, "events-fold.json")))
    assert_equal File.size(events_path), fold["offset"]
  end

  def test_the_session_log_skips_them
    log = Quartermaster::SessionLog.new
    log.append("event" => "start", "session_id" => "s1", "cwd" => "/", "ts" => "2026-01-01T00:00:00Z")
    append_raw(log.path, NON_OBJECTS)
    log.append("event" => "end", "session_id" => "s1", "ts" => "2026-01-01T01:00:00Z")

    assert_equal %w[start end], Quartermaster::SessionLog.new.events.map { |e| e["event"] }
    assert_equal ["s1"], Quartermaster::SessionLog.new.sessions.map(&:id)
  end

  def test_the_feature_use_report_skips_them
    path = File.join(Quartermaster::ROOT, "feature-use.jsonl")
    use = Quartermaster::FeatureUse.new(path: path)
    use.record("cli", "list")
    append_raw(path, NON_OBJECTS)
    use.record("cli", "list")

    assert_match(/^\s+2  list /, use.report)
  end

  def test_a_benchmark_runs_event_log_skips_them
    dir = File.join(Quartermaster::ROOT, "run")
    append_raw(File.join(dir, "events.jsonl"), "#{NON_OBJECTS}{\"t\":\"plan\"}\n")

    assert_equal [{ "t" => "plan" }], Quartermaster::BenchmarkPipeline.events(dir)
  end

  def test_background_jobs_skip_them_even_when_they_carry_a_marker
    Quartermaster::BackgroundJobs.reset!
    launch = ->(ago, id) do
      { "type" => "user", "timestamp" => stamp(fixed_now - ago),
        "toolUseResult" => { "isAsync" => true, "status" => "async_launched", "agentId" => id, "description" => id },
        "message" => { "role" => "user", "content" => [{ "type" => "tool_result", "content" => "launched" }] } }
    end
    path = write_transcript("s-jobs", [launch.call(100, "a1")])
    append_raw(path, "[\"async_launched\"]\n\"<task-notification>\"\n")
    File.open(path, "a") { |f| f.puts JSON.generate(launch.call(50, "a2")) }

    assert_equal %w[a1 a2], Quartermaster::BackgroundJobs.pending(path).map(&:id)
  end

  def test_transcript_readers_skip_them
    path = write_transcript("s", [user_text(60, "first ask")])
    append_raw(path, NON_OBJECTS)
    File.open(path, "a") { |f| f.puts JSON.generate(assistant(30, input: 1234)) }

    assert_equal "first ask", Quartermaster.first_prompt(path)
    assert_equal ["first ask"], Quartermaster.session_turns(path)["turns"].map { |t| t["prompt"] }
    assert_equal 1234, Quartermaster::TranscriptVitals.read(path).context_tokens
  end
end
