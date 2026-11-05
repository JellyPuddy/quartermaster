# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/viewer_test.rb`).
require_relative "test_helper"

class ViewerDataTest < Minitest::Test
  include QmTestHelpers

  def run_wi(*argv)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                   RbConfig.ruby, QM_BIN, *argv)
  end

  def test_session_item_prints_the_linked_title_and_stays_silent_when_unlinked
    Quartermaster::WorkItem.create("Status line work", project: "MyApp", session_id: "sess-x")

    linked, = run_wi("session-item", "sess-x")
    assert_equal "Status line work", linked.strip

    unlinked, = run_wi("session-item", "sess-none")
    assert_empty unlinked.strip
  end

  def test_viewer_rows_hide_resolved_by_default_and_filter_by_state
    Quartermaster::WorkItem.create("Active", project: "MyApp")
    Quartermaster::WorkItem.create("Frozen", project: "MyApp").update_state("fridge")
    Quartermaster::WorkItem.create("Done", project: "MyApp").update_state("resolved")

    default_rows, = run_wi("viewer-rows")
    assert_includes default_rows, "active"
    assert_includes default_rows, "frozen"
    refute_includes default_rows, "done"

    all_rows, = run_wi("viewer-rows", "--state", "all")
    assert_includes all_rows, "done"

    fridge_rows, = run_wi("viewer-rows", "--state", "fridge")
    assert_includes fridge_rows, "frozen"
    refute_includes fridge_rows, "active"
  end

  def test_viewer_rows_order_attention_first_then_most_recent_activity
    %w[Oldest Newest Stale].each { |t| Quartermaster::WorkItem.create(t, project: "Nowhere") }
    age = lambda do |slug, seconds|
      t = Time.now - seconds
      File.utime(t, t, Quartermaster::WorkItem.path_for(slug))
    end
    age.call("oldest", 2 * 3600)
    age.call("newest", 60)
    age.call("stale", 12 * 86_400)

    rows, = run_wi("viewer-rows")

    assert_equal %w[stale newest oldest], rows.lines.map { |l| l.split("\t").first }
  end

  def test_cycling_the_viewer_filter_advances_and_persists
    Quartermaster::WorkItem.create("Active", project: "MyApp")
    Quartermaster::WorkItem.create("Done", project: "MyApp").update_state("resolved")

    run_wi("cycle-filter")
    assert_equal "in_progress", File.read(Quartermaster::Viewer::FILTER_FILE).strip
    rows, = run_wi("viewer-rows")
    assert_includes rows, "active"
    refute_includes rows, "done"

    3.times { run_wi("cycle-filter") }
    assert_equal "all", File.read(Quartermaster::Viewer::FILTER_FILE).strip
    all_rows, = run_wi("viewer-rows")
    assert_includes all_rows, "done"

    run_wi("cycle-filter")
    assert_equal "open", File.read(Quartermaster::Viewer::FILTER_FILE).strip
  end

  def test_item_session_rows_sort_newest_first_with_uncaptured_last
    log = Quartermaster::SessionLog.new
    item = Quartermaster::WorkItem.create("My item", project: "Nowhere", session_id: "sess-uncaptured")
    item.attach_session("sess-old")
    item.attach_session("sess-new")
    log.append("event" => "start", "session_id" => "sess-old", "cwd" => "/", "ts" => (Time.now - 3600).iso8601)
    log.append("event" => "start", "session_id" => "sess-new", "cwd" => "/", "ts" => Time.now.iso8601)

    rows, = run_wi("session-rows", "my-item")

    assert_equal %w[sess-new sess-old sess-uncaptured],
                 rows.lines.map { |l| l.split("\t").first }
  end

  def test_show_renders_meta_derived_issue_sessions_and_body
    # Unconfigured project: PR lookups resolve no repo root, so no gh calls.
    Quartermaster::WorkItem.create("My thing", project: "Nowhere", branch: "issue/123-my-thing",
                        session_id: "sess-x", description: "The description")

    stdout, _stderr, status = run_wi("show", "my-thing")

    assert_equal 0, status.exitstatus
    assert_includes stdout, "My thing"
    assert_includes stdout, "issue #123"
    assert_includes stdout, "uncaptured"
    assert_includes stdout, "The description"
  end

  def test_session_tier_distinguishes_live_resumable_and_expired
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      File.write(transcript, "")

      build = lambda { |live:, transcript_path: nil|
        Quartermaster::Session.new(id: "sess-t", live: live, last_event: nil,
                                   start_event: { "transcript_path" => transcript_path })
      }

      assert_equal "live", build.call(live: true).tier
      assert_equal "resumable", build.call(live: false, transcript_path: transcript).tier
      assert_equal "expired", build.call(live: false, transcript_path: "/gone.jsonl").tier
      assert_equal "uncaptured", Quartermaster::Session.uncaptured("sess-t").tier
    end
  end

  # 'when' on every session list means last activity — the fzf rows used to
  # show the start time while the GUI showed last activity for the same row.
  def test_session_rows_show_last_activity_not_start
    log = Quartermaster::SessionLog.new
    log.append("event" => "start", "session_id" => "sess-when", "cwd" => "/",
               "ts" => "2026-08-01T09:00:00+02:00")
    log.append("event" => "end", "session_id" => "sess-when", "reason" => "other",
               "ts" => "2026-08-05T17:30:00+02:00")
    Quartermaster::WorkItem.create("Timed", project: "No project", session_id: "sess-when")

    stdout, = capture_io { Quartermaster::CLI.new.run(["session-rows", "timed"]) }

    assert_includes stdout, "2026-08-05T17:30"
    refute_includes stdout, "2026-08-01T09:00"
  end

  def test_dismissed_sessions_leave_the_inbox
    log = Quartermaster::SessionLog.new
    log.append("event" => "start", "session_id" => "sess-noise", "cwd" => "/", "ts" => Time.now.iso8601)

    assert_equal ["sess-noise"], log.inbox.map(&:id)

    log.dismiss("sess-noise")
    assert_empty log.inbox
  end

  def test_first_prompt_reads_string_and_block_content_and_skips_wrappers
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      File.write(transcript, [
        JSON.generate("type" => "meta"),
        JSON.generate("type" => "user", "message" => { "content" => "<system-reminder>noise</system-reminder>" }),
        JSON.generate("type" => "user", "message" => { "content" => [{ "type" => "text", "text" => "Fix the login bug" }] })
      ].join("\n"))

      assert_equal "Fix the login bug", Quartermaster.first_prompt(transcript)
      assert_nil Quartermaster.first_prompt("/nonexistent")
    end
  end
end

class CliLinkingTest < Minitest::Test
  include QmTestHelpers

  def run_wi(*argv)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                   RbConfig.ruby, QM_BIN, *argv)
  end

  def test_detach_unlinks_a_session_from_a_work_item
    Quartermaster::WorkItem.create("Alpha", project: "MyApp", session_id: "sess-d")

    _stdout, _stderr, status = run_wi("detach", "alpha", "--session", "sess-d")

    assert status.success?
    assert_empty Quartermaster::WorkItem.find("alpha").sessions
  end

  def test_attach_moves_a_session_off_its_previous_item
    Quartermaster::WorkItem.create("Alpha", project: "MyApp", session_id: "sess-mv")
    Quartermaster::WorkItem.create("Beta", project: "MyApp")

    stdout, _stderr, status = run_wi("attach", "beta", "--session", "sess-mv")

    assert status.success?
    assert_includes stdout, "detached from 'alpha'"
    assert_empty Quartermaster::WorkItem.find("alpha").sessions
    assert_equal [{ "id" => "sess-mv" }], Quartermaster::WorkItem.find("beta").sessions
  end

  def test_attach_session_moves_a_session_off_its_previous_item
    Quartermaster::WorkItem.create("Alpha", project: "MyApp", session_id: "sess-as")
    Quartermaster::WorkItem.create("Beta", project: "MyApp")

    stdout, = capture_io do
      with_picked("beta\tBeta") { Quartermaster::CLI.new.run(["attach-session", "sess-as"]) }
    end

    assert_includes stdout, "detached from 'alpha'"
    assert_empty Quartermaster::WorkItem.find("alpha").sessions
    assert_equal [{ "id" => "sess-as" }], Quartermaster::WorkItem.find("beta").sessions
  end

  def test_item_from_session_moves_the_session_off_its_previous_item
    Quartermaster::WorkItem.create("Alpha", project: "MyApp", session_id: "sess-ifs")
    Quartermaster::SessionLog.new.append(
      "event" => "start", "session_id" => "sess-ifs", "ts" => Time.now.utc.iso8601,
      "project" => "MyApp", "branch" => "main"
    )

    stdout, = capture_io do
      with_stdin("Fresh from session\n") { Quartermaster::CLI.new.run(["item-from-session", "sess-ifs"]) }
    end

    assert_includes stdout, "detached from 'alpha'"
    assert_empty Quartermaster::WorkItem.find("alpha").sessions
    assert_equal [{ "id" => "sess-ifs" }], Quartermaster::WorkItem.find("fresh-from-session").sessions
  end

  def test_new_with_a_session_moves_it_off_its_previous_item
    Quartermaster::WorkItem.create("Alpha", project: "MyApp", session_id: "sess-nw")

    stdout, _stderr, status = run_wi("new", "Fresh work", "--project", "MyApp", "--session", "sess-nw")

    assert status.success?
    assert_includes stdout, "detached from 'alpha'"
    assert_equal "fresh-work", stdout.lines.last.strip
    assert_empty Quartermaster::WorkItem.find("alpha").sessions
    assert_equal [{ "id" => "sess-nw" }], Quartermaster::WorkItem.find("fresh-work").sessions
  end
end

class CliBoardTest < Minitest::Test
  include QmTestHelpers

  BOARD = "https://claude.ai/code/artifact/1234"

  def run_wi(*argv)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                   RbConfig.ruby, QM_BIN, *argv)
  end

  def test_setting_a_board_stores_it_and_echoes_it
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")

    stdout, _stderr, status = run_wi("board", "alpha", BOARD)

    assert status.success?
    assert_includes stdout, BOARD
    assert_equal BOARD, Quartermaster::WorkItem.find("alpha").board
  end

  # A caller tests cheaply with `url=$(qm board alpha) || publish a new one`.
  def test_reading_prints_only_the_url_and_fails_when_there_is_none
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")

    stdout, _stderr, status = run_wi("board", "alpha")
    refute status.success?
    assert_empty stdout

    run_wi("board", "alpha", BOARD)
    stdout, _stderr, status = run_wi("board", "alpha")
    assert status.success?
    assert_equal BOARD, stdout.strip
  end

  def test_clear_removes_the_board
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")
    run_wi("board", "alpha", BOARD)

    _stdout, _stderr, status = run_wi("board", "alpha", "clear")

    assert status.success?
    assert_nil Quartermaster::WorkItem.find("alpha").board
  end
end

# The fzf surfaces shell back into qm: every command a bind, reload, rows or
# preview names must exist in CLI#run's dispatch, or that key dies silently at
# runtime. Source-level on purpose — the binds are built inside methods whose
# last act is exec'ing fzf, so there is nothing to call without a terminal.
class ViewerBindContractTest < Minitest::Test
  LIB = File.expand_path("../lib/quartermaster", __dir__)

  def test_every_viewer_bind_names_a_real_cli_command
    cli_commands = File.read(File.join(LIB, "cli.rb")).scan(/when "([a-z][a-z-]*)"/).flatten + Quartermaster::CLI.commands.keys
    bound = File.read(File.join(LIB, "viewer.rb")).scan(/#\{bin\} ([a-z][a-z-]*)/).flatten.uniq

    assert_empty(bound - cli_commands, "viewer binds reference unknown qm commands")
    refute_empty bound, "the bind scan found nothing — did the viewer's command syntax change?"
  end
end

class CliBoardRowsTest < Minitest::Test
  include QmTestHelpers

  BOARD = "https://claude.ai/artifact/ExampleBoard123"

  def run_qm(*argv, stdin: "")
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                   RbConfig.ruby, QM_BIN, *argv, stdin_data: stdin)
  end

  def append_row(doc_id, data)
    FileUtils.mkdir_p(Quartermaster::ROOT)
    line = { "tool_name" => "ArtifactData", "tool_response" => "Database set committed",
             "tool_input" => { "action" => "set", "url" => BOARD, "collection" => "tasks", "doc_id" => doc_id, "data" => data } }
    File.open(File.join(Quartermaster::ROOT, "board-writes.jsonl"), "a") { |f| f.puts(JSON.generate(line)) }
  end

  def test_board_with_answers_dir_records_both
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")
    dir = Dir.mktmpdir("qm-answers")

    stdout, _stderr, status = run_qm("board", "alpha", BOARD, "--answers-dir", dir)

    assert status.success?
    assert_includes stdout, dir
    assert_equal dir, Quartermaster::WorkItem.find("alpha").board_answers_dir
  end

  def test_answers_dir_without_a_url_is_refused
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")

    _stdout, _stderr, status = run_qm("board", "alpha", "--answers-dir", "/tmp/x")

    refute status.success?
  end

  def test_board_rows_prints_the_mirrored_rows
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")
    run_qm("board", "alpha", BOARD)
    append_row("board-mirror", { "status" => "running", "title" => "Board mirror", "note" => "specs green", "order" => 1 })

    stdout, _stderr, status = run_qm("board-rows", "alpha")
    assert status.success?
    assert_match(/board-mirror\s+running\s+Board mirror — specs green/, stdout)

    stdout, _stderr, _status = run_qm("board-rows", "alpha", "--json")
    assert_equal "running", JSON.parse(stdout).first["status"]
  end

  def test_board_rows_without_a_board_fails
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")

    _stdout, stderr, status = run_qm("board-rows", "alpha")

    refute status.success?
    assert_includes stderr, "no status board"
  end

  def test_board_answer_writes_from_stdin
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")
    dir = Dir.mktmpdir("qm-answers")
    run_qm("board", "alpha", BOARD, "--answers-dir", dir)
    append_row("t1", { "status" => "blocked" })

    _stdout, _stderr, status = run_qm("board-answer", "alpha", "t1", stdin: "STOP\n")

    assert status.success?
    assert_equal "STOP\n", File.read(File.join(dir, "t1.md"))
  end
end
