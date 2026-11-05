# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/chat_attention_test.rb`).
require_relative "test_helper"

class EventHookScriptTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def test_record_event_appends_a_slim_line_from_the_top_level_keys
    payload = JSON.generate("session_id" => "sess-1", "transcript_path" => "/t.jsonl", "cwd" => "/",
                            "hook_event_name" => "PostToolUse", "tool_name" => "Bash",
                            "tool_input" => { "command" => 'echo "session_id":"decoy"', "tool_name" => "Decoy" },
                            "tool_response" => { "stdout" => "x" })
    out, err, status = run_sh("record-event.sh", payload)

    assert status.success?
    assert_empty out
    assert_empty err
    line = JSON.parse(File.read(events_path))
    assert_equal({ "v" => 1, "session_id" => "sess-1", "event" => "PostToolUse", "tool" => "Bash", "agent" => "" },
                 line.except("ts"))
    assert_in_delta Time.now.to_f, Time.parse(line["ts"]).to_f, 5
  end

  def test_record_event_ignores_keys_nested_in_tool_objects
    payload = JSON.generate("session_id" => "sess-1", "hook_event_name" => "PostToolUse", "tool_name" => "mcp__x",
                            "tool_input" => { "agent_id" => "decoy" },
                            "tool_response" => { "agent_id" => "decoy" })
    run_sh("record-event.sh", payload)

    assert_equal "", JSON.parse(File.read(events_path))["agent"], "a main-thread call must not read as a sub-agent's"
  end

  def test_record_event_marks_sub_agent_calls_and_tolerates_pretty_json
    payload = JSON.pretty_generate("session_id" => "sess-1", "hook_event_name" => "PostToolUse",
                                   "tool_name" => "Read", "agent_id" => "agent-7")
    run_sh("record-event.sh", payload)

    assert_equal "agent-7", JSON.parse(File.read(events_path))["agent"]
  end

  def test_record_event_never_fails_or_prints
    [["", {}], ["not json at all", {}], ['{"hook_event_name":"Stop"}', {}]].each do |stdin, env|
      out, err, status = run_sh("record-event.sh", stdin, env)
      assert status.success?
      assert_empty out + err
    end
    refute File.exist?(events_path), "a payload without session_id writes nothing"

    out, err, status = run_sh("record-event.sh", '{"session_id":"s","hook_event_name":"Stop"}',
                              "QM_ROOT" => "/dev/null/unwritable")
    assert status.success?
    assert_empty out + err
  end

  def test_record_event_honors_qm_skip
    _out, _err, status = run_sh("record-event.sh", '{"session_id":"s","hook_event_name":"Stop"}', "QM_SKIP" => "1")

    assert status.success?
    refute File.exist?(events_path)
  end

  def test_record_board_write_keeps_the_full_payload_on_one_line
    payload = JSON.pretty_generate(
      "session_id" => "sess-1", "hook_event_name" => "PostToolUse", "tool_name" => "ArtifactData",
      "agent_id" => "agent-1",
      "tool_input" => { "action" => "update", "url" => "https://claude.ai/artifact/X", "collection" => "tasks",
                        "doc_id" => "attention", "data" => { "status" => "running", "note" => "line1\nline2" } }
    )
    out, err, status = run_sh("record-board-write.sh", payload)

    assert status.success?
    assert_empty out + err
    lines = File.readlines(File.join(Quartermaster::ROOT, "board-writes.jsonl"))
    assert_equal 1, lines.size
    record = JSON.parse(lines.first)
    assert_equal 1, record["v"]
    assert_equal "line1\nline2", record.dig("payload", "tool_input", "data", "note")
    assert_equal "agent-1", record.dig("payload", "agent_id")
  end

  def test_record_board_write_never_fails_and_honors_qm_skip
    path = File.join(Quartermaster::ROOT, "board-writes.jsonl")
    ["", "garbage"].each do |stdin|
      out, err, status = run_sh("record-board-write.sh", stdin)
      assert status.success?
      assert_empty out + err
    end
    run_sh("record-board-write.sh", '{"session_id":"s"}', "QM_SKIP" => "1")
    refute File.exist?(path)

    out, err, status = run_sh("record-board-write.sh", '{"session_id":"s"}', "QM_ROOT" => "/dev/null/unwritable")
    assert status.success?
    assert_empty out + err
  end
end

class EventLogTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  # Spike order (2026-10-21): permission prompt → PermissionRequest right
  # after PreToolUse; approving runs the tool (PostToolUse); Stop ends the turn.
  def test_permission_round_trip_follows_the_spike_event_order
    log_events("s", [60, "UserPromptSubmit"], [50, "PostToolUse", "Read"], [40, "PermissionRequest", "Bash"])
    blocked = turn("s")
    assert_equal "blocked", blocked["state"]
    assert_equal "Bash", blocked["tool"]
    assert_equal stamp(fixed_now - 40), blocked["since"]

    log_events("s", [30, "PostToolUse", "Bash"], [20, "PostToolUse", "Edit"])
    working = turn("s")
    assert_equal "working", working["state"]
    assert_equal stamp(fixed_now - 30), working["since"], "since marks entering the state, not the latest event"

    log_events("s", [10, "Stop"])
    done = turn("s")
    assert_equal "your_turn", done["state"]
    assert_equal stamp(fixed_now - 10), done["since"]
    assert_equal stamp(fixed_now - 10), done["stop_ts"]
  end

  def test_ask_user_question_blocks_until_answered
    log_events("s", [30, "UserPromptSubmit"], [20, "PermissionRequest", "AskUserQuestion"])
    assert_equal "blocked", turn("s")["state"]

    log_events("s", [10, "PostToolUse", "AskUserQuestion"])
    assert_equal "working", turn("s")["state"]
  end

  def test_failure_variants_resolve_a_block_and_end_a_turn
    log_events("s", [40, "UserPromptSubmit"], [30, "PermissionRequest", "Bash"], [20, "PostToolUseFailure", "Bash"])
    assert_equal "working", turn("s")["state"], "an approved tool that fails still resolves the block"

    log_events("s", [10, "StopFailure"])
    assert_equal ["your_turn", stamp(fixed_now - 10)], turn("s").values_at("state", "stop_ts")
  end

  def test_sessions_quiet_for_a_month_drop_out_of_the_fold
    month = Quartermaster::EventLog::FORGET_AFTER
    log_events("old", [month + 60, "Stop"])
    log_events("new", [10, "Stop"])

    assert_equal ["new"], Quartermaster::EventLog.new.turns.keys
    assert_nil turn("old"), "nor does a fresh reader of the persisted fold bring it back"
  end

  def test_a_new_prompt_restarts_working_since
    log_events("s", [60, "UserPromptSubmit"], [50, "Stop"], [5, "UserPromptSubmit"])

    assert_equal stamp(fixed_now - 5), turn("s")["since"]
    assert_equal stamp(fixed_now - 5), turn("s")["prompt_ts"]
  end

  def test_background_sub_agents_do_not_end_your_turn_but_their_permissions_block
    log_events("s", [60, "UserPromptSubmit"], [50, "Stop"], [40, "PostToolUse", "Bash", "agent-1"])
    assert_equal "your_turn", turn("s")["state"]
    assert_equal stamp(fixed_now - 50), turn("s")["since"]

    log_events("s", [30, "PermissionRequest", "Bash", "agent-1"])
    assert_equal "blocked", turn("s")["state"]

    log_events("s", [20, "PostToolUse", "Bash", "agent-1"])
    assert_equal "your_turn", turn("s")["state"]
  end

  def test_sessions_fold_independently_and_unknown_events_are_ignored
    log_events("a", [30, "UserPromptSubmit"])
    log_events("b", [20, "Stop"], [10, "SomethingNew"])

    assert_equal "working", turn("a")["state"]
    assert_equal "your_turn", turn("b")["state"]
    assert_nil turn("c")
  end

  def test_reads_only_appended_bytes_and_leaves_a_partial_line_for_later
    log = Quartermaster::EventLog.new
    log_events("s", [30, "UserPromptSubmit"])
    assert_equal "working", log.turn_for("s")["state"]

    line = JSON.generate("v" => 1, "ts" => stamp(fixed_now), "session_id" => "s", "event" => "Stop")
    File.open(events_path, "a") { |f| f.write(line[0, 20]) }
    assert_equal "working", log.turn_for("s")["state"]

    File.open(events_path, "a") { |f| f.write("#{line[20..]}\n") }
    assert_equal "your_turn", log.turn_for("s")["state"]

    fold = JSON.parse(File.read(File.join(Quartermaster::ROOT, "events-fold.json")))
    assert_equal File.size(events_path), fold["offset"]
  end

  def test_a_fresh_reader_resumes_from_the_persisted_fold
    log_events("s", [30, "UserPromptSubmit"])
    Quartermaster::EventLog.new.turns
    fold_path = File.join(Quartermaster::ROOT, "events-fold.json")
    fold = JSON.parse(File.read(fold_path))
    fold["sessions"]["s"]["state"] = "marker-from-fold"
    File.write(fold_path, JSON.generate(fold))

    assert_equal "marker-from-fold", turn("s")["state"], "already-folded bytes are not re-read"
  end

  def test_a_replaced_or_truncated_log_is_refolded_from_scratch
    log_events("s", [30, "UserPromptSubmit"], [20, "Stop"])
    Quartermaster::EventLog.new.turns
    File.write(events_path, "")
    log_events("t", [10, "UserPromptSubmit"])

    assert_nil turn("s")
    assert_equal "working", turn("t")["state"]
  end

  def test_no_log_means_no_turns
    assert_empty Quartermaster::EventLog.new.turns
  end
end

class TranscriptVitalsTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def test_context_size_is_the_last_assistant_messages_input_plus_cache
    path = write_transcript("s", [assistant(120, input: 5, read: 1000, created: 200),
                                  user_text(60, "next"),
                                  assistant(30, input: 7, read: 40_000, created: 3_000),
                                  assistant(10, input: 0, model: "<synthetic>")])
    vitals = Quartermaster::TranscriptVitals.read(path)

    assert_equal 43_007, vitals.context_tokens
    assert_equal Time.parse(stamp(fixed_now - 30)), vitals.last_assistant_at
  end

  def test_cache_warmth_follows_the_tier_the_cache_was_written_at
    one_hour = Quartermaster::TranscriptVitals.read(
      write_transcript("a", [assistant(600, created: 500, tier: "1h"), assistant(30, read: 900)])
    )
    assert_equal Time.parse(stamp(fixed_now - 30)) + 3600, one_hour.cache_warm_until
    assert one_hour.cache_warm?

    five_min = Quartermaster::TranscriptVitals.read(write_transcript("b", [assistant(600, created: 500, tier: "5m")]))
    assert_equal Time.parse(stamp(fixed_now - 600)) + 300, five_min.cache_warm_until
    refute five_min.cache_warm?
  end

  def test_finds_the_last_interrupt
    path = write_transcript("s", [user_text(90, "[Request interrupted by user]"), assistant(60),
                                  user_text(30, "[Request interrupted by user for tool use]")])

    assert_equal Time.parse(stamp(fixed_now - 30)), Quartermaster::TranscriptVitals.read(path).interrupted_at
  end

  def test_grows_the_tail_past_huge_tool_output
    padding = { "type" => "user", "timestamp" => stamp(fixed_now - 20),
                "message" => { "content" => [{ "type" => "tool_result", "content" => "x" * 400_000 }] } }
    path = write_transcript("s", [assistant(60, input: 1234), padding])

    assert_equal 1234, Quartermaster::TranscriptVitals.read(path).context_tokens
  end

  def test_missing_or_empty_transcripts_degrade
    assert_nil Quartermaster::TranscriptVitals.read(nil)
    assert_nil Quartermaster::TranscriptVitals.read("/no/such.jsonl")
    assert_nil Quartermaster::TranscriptVitals.read(write_transcript("e", [])).context_tokens
  end
end

class ChatAttentionTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def entries = Quartermaster::ChatAttention.new.entries

  def test_orders_blocked_then_your_turn_then_working_then_no_chat_longest_waiting_first
    live_item("Working", "s-work")
    log_events("s-work", [100, "UserPromptSubmit"])
    live_item("Your turn new", "s-turn-new")
    log_events("s-turn-new", [200, "UserPromptSubmit"], [10, "Stop"])
    live_item("Your turn old", "s-turn-old")
    log_events("s-turn-old", [200, "UserPromptSubmit"], [50, "Stop"])
    live_item("Blocked", "s-block")
    log_events("s-block", [20, "UserPromptSubmit"], [5, "PermissionRequest", "Bash"])
    Quartermaster::WorkItem.create("Idle", project: "No project")

    assert_equal %w[blocked your-turn-old your-turn-new working idle], entries.map(&:slug)
    assert_equal %w[blocked your_turn your_turn working none], entries.map(&:state)
    assert_equal "Bash", entries.first.tool
  end

  def test_ended_sessions_have_no_chat_and_only_live_or_in_progress_items_are_listed
    item = live_item("Ended", "s-ended", pid: 999_999_999)
    log_events("s-ended", [30, "UserPromptSubmit"])
    live_item("Fridge but live", "s-fridge", state: "fridge")
    log_events("s-fridge", [30, "Stop"])
    Quartermaster::WorkItem.create("Fridge idle", project: "No project").update_state("fridge")

    by_slug = entries.to_h { |e| [e.slug, e] }
    assert_equal %w[ended fridge-but-live], by_slug.keys.sort
    assert_equal "none", by_slug["ended"].state
    assert_equal item.slug, by_slug["ended"].slug
    assert_equal "your_turn", by_slug["fridge-but-live"].state
  end

  def test_the_most_urgent_live_session_speaks_for_the_item
    item = live_item("Two chats", "s-1")
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "s-2", "cwd" => "/",
                                         "pid" => Process.pid, "ts" => Time.now.iso8601)
    item.attach_session("s-2")
    log_events("s-1", [30, "UserPromptSubmit"])
    log_events("s-2", [30, "UserPromptSubmit"], [10, "PermissionRequest", "AskUserQuestion"])

    entry = entries.first
    assert_equal ["blocked", "s-2"], [entry.state, entry.session_id]
  end

  def test_live_session_without_events_has_no_turn
    live_item("Just opened", "s-new")

    assert_equal "none", entries.first.state
  end

  def test_esc_interrupt_after_the_last_prompt_is_your_turn
    path = write_transcript("s-esc", [user_text(60, "do it"), assistant(50),
                                      user_text(20, "[Request interrupted by user]")])
    live_item("Escaped", "s-esc", transcript: path)
    log_events("s-esc", [120, "Stop"], [60, "UserPromptSubmit"], [50, "PostToolUse", "Bash"])

    entry = entries.first
    assert_equal "your_turn", entry.state
    assert_equal Time.parse(stamp(fixed_now - 20)), entry.since
  end

  def test_expected_times_hold_when_the_clock_crosses_a_second
    with_ticking_clock do
      test_esc_interrupt_after_the_last_prompt_is_your_turn
      setup
      test_entries_carry_context_size_from_the_chosen_session
    end
  end

  def launched(ago, id, description, workflow: false)
    result = workflow ? { "status" => "async_launched", "taskId" => id, "taskType" => "local_workflow", "workflowName" => description }
                      : { "isAsync" => true, "status" => "async_launched", "agentId" => id, "description" => description }
    { "type" => "user", "timestamp" => stamp(fixed_now - ago), "toolUseResult" => result,
      "message" => { "role" => "user", "content" => [{ "type" => "tool_result", "content" => "launched" }] } }
  end

  def test_a_stop_with_a_sub_agent_still_building_is_waiting_not_your_turn
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-deleg", [user_text(90, "build it"), launched(80, "a1", "Fold fixes and restack stack"),
                                        launched(80, "a2", "Watch PRs 20406 and 20407"), assistant(70)])
    live_item("Delegated", "s-deleg", transcript: path)
    log_events("s-deleg", [90, "UserPromptSubmit"], [80, "PostToolUse", "Agent"], [70, "Stop"])

    entry = entries.first
    assert_equal ["waiting", ["Fold fixes and restack stack"]], [entry.state, entry.waiting_on], "the watcher doesn't count"
    assert_equal Time.parse(stamp(fixed_now - 70)), entry.since

    File.write(path, "#{JSON.generate(notified(30, "a1"))}\n", mode: "a")
    assert_equal "your_turn", entries.first.state, "only the watcher is left"
  end

  def test_background_jobs_fold_launches_against_notifications_incrementally
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-jobs", [launched(300, "a1", "Swap LMS id columns"), launched(200, "wf1", "delegate-build", workflow: true),
                                       launched(100, "a2", "Monitor CI on #123"), notified(50, "a1"),
                                       launched(13 * 3600, "a-old", "Lost to a restart")])
    jobs = Quartermaster::BackgroundJobs.pending(path)

    assert_equal %w[wf1 a2], jobs.map(&:id), "oldest first; notified and over-age launches dropped"
    assert_equal [false, true], jobs.map(&:watcher?), "a workflow is never a watcher"
    File.write(path, "#{JSON.generate(notified(10, "wf1"))}\n", mode: "a")
    assert_equal %w[a2], Quartermaster::BackgroundJobs.pending(path).map(&:id)
    assert_empty Quartermaster::BackgroundJobs.pending(nil)
  end

  def test_watchers_are_recognised_by_name
    watcher = ->(name) { Quartermaster::BackgroundJobs::Job.new(description: name).watcher? }

    ["Watch PRs 20406 and 20407", "Watch download_state stack PRs", "Monitor CI", "babysit the stack"].each { |n| assert watcher.(n), n }
    ["Fix CI failure", "Poll text and show loading files", "Diagnose external portal e2e failures", "Rebuild throwaway test branch"].each { |n| refute watcher.(n), n }
  end

  def test_background_shells_are_jobs_until_their_notification
    Quartermaster::BackgroundJobs.reset!
    hook = { "type" => "attachment", "attachment" => { "type" => "hook_success", "hookName" => "PreToolUse:Bash", "toolUseID" => "toolu_t1" } }
    path = write_transcript("s-sh", [*shell_launched(300, "b1", "Dry-run the sweep"),
                                     bash_call(200, "toolu_fg", "ls"), bash_result(200, "toolu_fg"),
                                     bash_call(150, "toolu_t1", "bin/rspec\nexit"), hook,
                                     bash_result(100, "toolu_t1", background: "b2", timed_out: true),
                                     *shell_launched(13 * 3600, "b-old", "Forgotten dev server")])
    jobs = Quartermaster::BackgroundJobs.pending(path)

    assert_equal %w[b1 b2], jobs.map(&:id), "a foreground command isn't a job; over-age shells drop out"
    assert_equal ["Dry-run the sweep", "bin/rspec"], jobs.map(&:description), "no description: the command's first line"
    assert_equal Time.parse(stamp(fixed_now - 100)), jobs.last.launched_at
    assert_empty Quartermaster::BackgroundJobs.instance_variable_get(:@cache)[path][2], "answered Bash calls are forgotten"

    File.write(path, "#{JSON.generate(notified(10, "b1"))}\n", mode: "a")
    assert_equal %w[b2], Quartermaster::BackgroundJobs.pending(path).map(&:id)
  end

  def test_a_quoted_task_id_is_not_a_notification
    Quartermaster::BackgroundJobs.reset!
    quoted = "Its end is a `<task-notification>` with `<task-id>b1</task-id>`"
    brief = { "type" => "assistant", "timestamp" => stamp(fixed_now - 50),
              "message" => { "role" => "assistant", "content" => [{ "type" => "tool_use", "id" => "toolu_ag", "name" => "Agent",
                                                                    "input" => { "prompt" => quoted } }] } }
    grep = { "type" => "user", "timestamp" => stamp(fixed_now - 40),
             "message" => { "role" => "user", "content" => [{ "tool_use_id" => "toolu_g", "type" => "tool_result", "content" => quoted }] } }
    path = write_transcript("s-q", [*shell_launched(300, "b1", "Dry-run the sweep"), brief, grep])
    assert_equal %w[b1], Quartermaster::BackgroundJobs.pending(path).map(&:id)

    queued = { "type" => "queue-operation", "operation" => "enqueue", "content" => "<task-notification>\n<task-id>b1</task-id>\n</task-notification>" }
    File.write(path, "#{JSON.generate(queued)}\n", mode: "a")
    assert_empty Quartermaster::BackgroundJobs.pending(path)
  end

  def test_a_watching_gh_command_is_a_watcher_whatever_its_name
    watcher = ->(command) { Quartermaster::BackgroundJobs::Job.new(description: "Wait for the re-run", command: command).watcher? }

    ["gh pr checks 123 --watch --interval 30", "gh run watch 456 --exit-status > /dev/null; gh run view 456",
     "cd x && gh pr checks --watch"].each { |c| assert watcher.(c), c }
    ["gh pr checks 123", "gh run view 456 --json status", "gh pr checks 1; npm test --watch",
     "bin/webpack --watch", "gh run rerun 456 --failed"].each { |c| refute watcher.(c), c }
  end

  def test_a_stop_with_a_background_shell_running_is_waiting
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-bgsh", [user_text(90, "sweep it"), *shell_launched(80, "b1", "Dry-run the sweep"),
                                       *shell_launched(80, "b2", "Wait for CI", command: "gh pr checks 1 --watch"), assistant(70)])
    live_item("Sweeping", "s-bgsh", transcript: path)
    log_events("s-bgsh", [90, "UserPromptSubmit"], [80, "PostToolUse", "Bash"], [70, "Stop"])

    assert_equal ["waiting", ["Dry-run the sweep"]], [entries.first.state, entries.first.waiting_on], "the CI watch doesn't count"

    File.write(path, "#{JSON.generate(notified(30, "b1"))}\n", mode: "a")
    assert_equal "your_turn", entries.first.state, "only the watcher is left"
  end

  # TaskStop's result as Claude Code writes it: no <task-notification> follows.
  def task_stopped(ago, id, task_type: "local_bash", failed: false, sidechain: false)
    use_id = "toolu_stop_#{id}"
    result = failed ? "Error: No task found with ID: #{id}"
                    : { "message" => "Successfully stopped task: #{id} (pnpm dev)", "task_id" => id,
                        "task_type" => task_type, "command" => "pnpm dev" }
    block = { "tool_use_id" => use_id, "type" => "tool_result",
              "content" => failed ? "<tool_use_error>No task found with ID: #{id}</tool_use_error>" : JSON.generate(result) }
    block["is_error"] = true if failed
    [{ "type" => "assistant", "timestamp" => stamp(fixed_now - ago), "isSidechain" => sidechain,
       "message" => { "role" => "assistant", "content" => [{ "type" => "tool_use", "id" => use_id, "name" => "TaskStop",
                                                              "input" => { "task_id" => id } }] } },
     { "type" => "user", "timestamp" => stamp(fixed_now - ago), "isSidechain" => sidechain, "toolUseResult" => result,
       "message" => { "role" => "user", "content" => [block] } }]
  end

  def test_a_stop_after_task_stop_ended_the_background_shell_is_your_turn
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-killed", [user_text(90, "run the dev server"), *shell_launched(80, "b1", "Run the dev server"),
                                         *task_stopped(75, "b1"), assistant(70)])
    live_item("Dev server", "s-killed", transcript: path)
    log_events("s-killed", [90, "UserPromptSubmit"], [75, "PostToolUse", "TaskStop"], [70, "Stop"])

    assert_equal "your_turn", entries.first.state
  end

  def test_only_a_successful_task_stop_in_the_main_chain_ends_a_job
    Quartermaster::BackgroundJobs.reset!
    grep = bash_result(40, "toolu_g").tap { |e| e["toolUseResult"]["stdout"] = "Successfully stopped task: a1 (x)" }
    path = write_transcript("s-stops", [*shell_launched(300, "b1", "Dry-run the sweep"), launched(300, "a1", "Swap LMS id columns"),
                                        launched(300, "wf1", "delegate-build", workflow: true),
                                        *task_stopped(60, "b1", failed: true), *task_stopped(50, "a1", sidechain: true),
                                        bash_call(40, "toolu_g", "grep stopped"), grep])
    assert_equal %w[b1 a1 wf1], Quartermaster::BackgroundJobs.pending(path).map(&:id),
                 "a failed stop, a sub-agent's stop and a grep quoting a stop end nothing"

    File.write(path, [*task_stopped(30, "b1"), *task_stopped(20, "a1", task_type: "local_agent"),
                      *task_stopped(10, "wf1", task_type: "local_workflow")].map { |e| "#{JSON.generate(e)}\n" }.join, mode: "a")
    assert_empty Quartermaster::BackgroundJobs.pending(path)
  end

  # SendMessage reviving a finished sub-agent, trimmed from a real transcript
  # line: no async_launched status, no backgroundTaskId.
  def resumed(ago, id)
    { "type" => "user", "isSidechain" => false, "timestamp" => stamp(fixed_now - ago),
      "message" => { "role" => "user", "content" => [{ "tool_use_id" => "toolu_019ngAd5Sc3tX3necjZ2822P", "type" => "tool_result",
                                                       "content" => [{ "type" => "text", "text" => "{\"success\":true,\"message\":\"Resuming agent #{id[0, 7]}\",\"resumedAgentId\":\"#{id}\"}" }] }] },
      "toolUseResult" => { "success" => true, "message" => "Resuming agent #{id[0, 7]}", "resumedAgentId" => id, "revivedAgentId" => id,
                           "pin" => { "id" => id, "name" => id, "ref" => "62c231" } } }
  end

  def test_a_stop_after_resuming_a_sub_agent_is_waiting_until_it_notifies_again
    Quartermaster::BackgroundJobs.reset!
    queued = resumed(60, "a7606ba48663da5fc").tap do |e|
      message = "Message queued for delivery to a7606ba48663da5fc at its next tool round."
      e["message"]["content"][0]["content"] = [{ "type" => "text", "text" => JSON.generate("success" => true, "message" => message) }]
      e["toolUseResult"] = { "success" => true, "message" => message, "pin" => e["toolUseResult"]["pin"] }
    end
    path = write_transcript("s-resume", [user_text(300, "build it"), launched(290, "a7606ba48663da5fc", "Benchmark generator"),
                                         notified(200, "a7606ba48663da5fc"), user_text(100, "send it the fix"),
                                         resumed(80, "a7606ba48663da5fc"), queued, assistant(70)])
    live_item("Resumed", "s-resume", transcript: path)
    log_events("s-resume", [100, "UserPromptSubmit"], [80, "PostToolUse", "SendMessage"], [70, "Stop"])

    entry = entries.first
    assert_equal ["waiting", ["Benchmark generator"]], [entry.state, entry.waiting_on], "named as it was launched"
    assert_equal Time.parse(stamp(fixed_now - 80)), Quartermaster::BackgroundJobs.pending(path).first.launched_at

    File.write(path, "#{JSON.generate(notified(30, "a7606ba48663da5fc"))}\n", mode: "a")
    assert_equal "your_turn", entries.first.state
  end

  def test_a_resumed_watcher_still_does_not_hold_the_turn_and_an_unknown_agent_gets_the_resume_message
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-resume2", [launched(290, "a2", "Watch PRs 20406"), notified(200, "a2"),
                                          resumed(80, "a2"), resumed(70, "a9e3f0c1d2b4a5968")])
    jobs = Quartermaster::BackgroundJobs.pending(path)

    assert_equal [["a2", true], ["a9e3f0c1d2b4a5968", false]], jobs.map { |j| [j.id, j.watcher?] }
    assert_equal "Resuming agent a9e3f0c", jobs.last.description
  end

  # The user resuming a sub-agent from its transcript view, as the real queue
  # line records it: a notification with no <status> that starts the agent.
  def resumed_by_user(ago, id, name)
    { "type" => "queue-operation", "operation" => "enqueue", "timestamp" => stamp(fixed_now - ago),
      "content" => "<task-notification>\n<task-id>#{id}</task-id>\n<summary>Agent \"#{name}\" was resumed by the user</summary>\n" \
                   "<note>The user resumed this agent from its transcript view; it is running again. Do not treat its work as " \
                   "cancelled or relaunch it; its result arrives in a later task-notification for this task-id.</note>\n" \
                   "</task-notification>" }
  end

  def test_a_sub_agent_resumed_by_the_user_is_waited_on_until_it_notifies_again
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-userresume", [user_text(300, "build it"), launched(290, "a7606ba48663da5fc", "Benchmark generator"),
                                             notified(200, "a7606ba48663da5fc"), assistant(190),
                                             resumed_by_user(80, "a7606ba48663da5fc", "Benchmark generator: goal feedback + viewers")])
    live_item("Resumed by the user", "s-userresume", transcript: path)
    log_events("s-userresume", [300, "UserPromptSubmit"], [190, "Stop"])

    entry = entries.first
    assert_equal ["waiting", ["Benchmark generator"]], [entry.state, entry.waiting_on], "named as it was launched"
    assert_equal Time.parse(stamp(fixed_now - 80)), Quartermaster::BackgroundJobs.pending(path).first.launched_at

    File.write(path, "#{JSON.generate(notified(30, "a7606ba48663da5fc"))}\n", mode: "a")
    assert_equal "your_turn", entries.first.state
  end

  def test_a_user_resume_of_an_unknown_agent_is_named_from_its_summary_and_task_stop_ends_it
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-userresume2", [resumed_by_user(80, "a9e3f0c1d2b4a5968", "Watch PRs 20406"),
                                              resumed_by_user(70, "a5", "Swap LMS id columns")])
    jobs = Quartermaster::BackgroundJobs.pending(path)

    assert_equal [["a9e3f0c1d2b4a5968", "Watch PRs 20406", true], ["a5", "Swap LMS id columns", false]],
                 jobs.map { |j| [j.id, j.description, j.watcher?] }
    File.write(path, task_stopped(20, "a5", task_type: "local_agent").map { |e| "#{JSON.generate(e)}\n" }.join, mode: "a")
    assert_equal %w[a9e3f0c1d2b4a5968], Quartermaster::BackgroundJobs.pending(path).map(&:id)
  end

  # A sub-agent that stopped with its own background work still running, as
  # the real notification reads (also queued as a queue-operation).
  def interim(ago, id)
    user_text(ago, "<task-notification>\n<task-id>#{id}</task-id>\n<tool-use-id>toolu_01JsUZbHQt761BA7WRPZzGLJ</tool-use-id>\n" \
                   "<output-file>/private/tmp/tasks/#{id}.output</output-file>\n<status>completed</status>\n" \
                   "<summary>Agent \"Reshape benchmark DB generator\" is waiting on its own background work</summary>\n" \
                   "<note>This agent stopped with background work of its own still running. It may resume on its own when " \
                   "that work completes or reports, and the same task-id notifies again if it does; the result below may be " \
                   "interim.</note>\n<result>This agent has not reported yet: it is waiting on its own background work and " \
                   "will deliver its report through SubagentHandback when that finishes.\n</result>\n" \
                   "<usage><subagent_tokens>223843</subagent_tokens><tool_uses>42</tool_uses><duration_ms>998501</duration_ms></usage>\n" \
                   "</task-notification>")
  end

  def test_an_interim_notification_keeps_the_sub_agent_waited_on_until_its_final_one
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-interim", [user_text(300, "build it"), launched(290, "a1630fcd7ffad17d6", "Reshape benchmark DB generator"),
                                          interim(200, "a1630fcd7ffad17d6"), interim(150, "a1630fcd7ffad17d6"), assistant(140)])
    live_item("Interim", "s-interim", transcript: path)
    log_events("s-interim", [300, "UserPromptSubmit"], [140, "Stop"])

    assert_equal ["waiting", ["Reshape benchmark DB generator"]], [entries.first.state, entries.first.waiting_on]
    job = Quartermaster::BackgroundJobs.pending(path).first
    assert_equal [Time.parse(stamp(fixed_now - 290)), Time.parse(stamp(fixed_now - 150))], [job.launched_at, job.seen_at]

    File.write(path, "#{JSON.generate(notified(30, "a1630fcd7ffad17d6"))}\n", mode: "a")
    assert_empty Quartermaster::BackgroundJobs.pending(path)
    assert_equal "your_turn", entries.first.state
  end

  def test_task_stop_ends_a_sub_agent_after_an_interim_notification
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-interim-stop", [launched(290, "a1", "Reshape benchmark DB generator"), interim(200, "a1")])
    assert_equal %w[a1], Quartermaster::BackgroundJobs.pending(path).map(&:id)

    File.write(path, task_stopped(20, "a1", task_type: "local_agent").map { |e| "#{JSON.generate(e)}\n" }.join, mode: "a")
    assert_empty Quartermaster::BackgroundJobs.pending(path)
  end

  def test_an_interim_notification_restarts_the_age_limit
    Quartermaster::BackgroundJobs.reset!
    max_age = Quartermaster::BackgroundJobs::MAX_AGE
    path = write_transcript("s-interim-age", [launched(max_age + 600, "a1", "Reshape benchmark DB generator"), interim(1200, "a1")])

    assert_equal %w[a1], Quartermaster::BackgroundJobs.pending(path, now: fixed_now).map(&:id), "alive as of the interim"
    assert_empty Quartermaster::BackgroundJobs.pending(path, now: fixed_now + max_age), "MAX_AGE past the interim"
  end

  def test_an_interim_notification_for_an_unknown_id_starts_nothing
    Quartermaster::BackgroundJobs.reset!
    queued = { "type" => "queue-operation", "operation" => "enqueue", "timestamp" => stamp(fixed_now - 50),
               "content" => interim(50, "a-unknown").dig("message", "content") }
    path = write_transcript("s-interim-unknown", [interim(60, "a-unknown"), queued])
    assert_empty Quartermaster::BackgroundJobs.pending(path)
  end

  def test_launches_quoting_a_stop_or_a_notification_still_count
    Quartermaster::BackgroundJobs.reset!
    quote = "Successfully stopped task: x1 writes no <task-notification>"
    agent = launched(300, "a1", "Review the fix").tap { |e| e["toolUseResult"]["prompt"] = quote }
    path = write_transcript("s-quotes", [agent, *shell_launched(200, "b1", "Grep stops", command: "grep '#{quote}' x")])
    assert_equal %w[a1 b1], Quartermaster::BackgroundJobs.pending(path).map(&:id)
  end

  def test_an_interrupt_before_the_latest_prompt_or_stop_is_history
    path = write_transcript("s-old", [user_text(90, "[Request interrupted by user]"), assistant(50)])
    live_item("Old interrupt", "s-old", transcript: path)
    log_events("s-old", [60, "UserPromptSubmit"], [40, "PermissionRequest", "Bash"])

    assert_equal "blocked", entries.first.state
  end

  def test_snoozed_your_turn_sinks_below_working_until_the_next_turn_ends
    snoozed = live_item("Snoozed", "s-snooze")
    log_events("s-snooze", [300, "UserPromptSubmit"], [200, "Stop"])
    live_item("Working", "s-work")
    log_events("s-work", [10, "UserPromptSubmit"])
    snoozed.snooze("turn")

    assert_equal [%w[working working false], %w[snoozed your_turn true]],
                 entries.map { |e| [e.slug, e.state, e.snoozed.to_s] }

    log_events("s-snooze", [5, "UserPromptSubmit"])
    File.write(events_path, File.read(events_path) +
      "#{JSON.generate("v" => 1, "ts" => stamp(fixed_now + 5), "session_id" => "s-snooze", "event" => "Stop")}\n")
    assert_equal [%w[snoozed your_turn false], %w[working working false]],
                 entries.map { |e| [e.slug, e.state, e.snoozed.to_s] }
  end

  def test_clear_lifts_a_turn_snooze
    item = live_item("Snoozed", "s-snooze")
    log_events("s-snooze", [200, "Stop"])
    item.snooze("turn")
    Quartermaster::WorkItem.find("snoozed").snooze("clear")

    refute entries.first.snoozed
  end

  def test_entries_carry_context_size_from_the_chosen_session
    path = write_transcript("s-ctx", [assistant(30, input: 2, read: 150_000, created: 8_000)])
    live_item("Big context", "s-ctx", transcript: path)

    entry = entries.first
    assert_equal 158_002, entry.context_tokens
    assert_equal Time.parse(stamp(fixed_now - 30)) + 3600, entry.cache_warm_until
  end

  def test_items_without_a_live_chat_report_their_newest_sessions_context
    path = write_transcript("s-done", [assistant(30, input: 12_000)])
    live_item("Done chat", "s-done", transcript: path, pid: 999_999_999)

    entry = entries.first
    assert_equal ["none", 12_000], [entry.state, entry.context_tokens]
  end

  def test_a_chat_wrapped_up_and_closed_reports_no_context
    path = write_transcript("s-closed", [assistant(7200, input: 160_000)])
    item = live_item("Closed chat", "s-closed", transcript: path, pid: 999_999_999)
    item.record_rotation(from_session: "s-closed", via: "wrap-up")

    entry = entries.first
    assert_nil entry.context_tokens
    assert_nil Quartermaster::ContextMeter.rotate_offer(entry.context_tokens, entry.last_assistant_at)
  end
end

class ChatAttentionCliTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def qm(*args)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                   RbConfig.ruby, QM_BIN, *args)
  end

  def test_attention_lists_chats_by_attention_with_context_size
    path = write_transcript("s-block", [assistant(30, input: 1, read: 181_499, created: 500)])
    live_item("Blocked", "s-block", transcript: path)
    log_events("s-block", [60, "UserPromptSubmit"], [5, "PermissionRequest", "Bash"])
    live_item("Working", "s-work")
    log_events("s-work", [10, "UserPromptSubmit"])

    out, _err, status = qm("attention")

    assert status.success?
    lines = out.lines.map { |l| l.gsub(/\e\[\d+m/, "") }
    assert_match(/🔴 blocked\s+blocked\s+[56]s · Bash\s+ctx 182k · cache warm 59m/, lines[0])
    assert_match(/🔵 working\s+working\s+1[01]s/, lines[1])
  end

  def test_attention_says_so_when_nothing_needs_it
    out, _err, status = qm("attention")

    assert status.success?
    assert_equal "Nothing needs attention.\n", out
  end

  def test_snooze_turn_from_the_cli
    live_item("Snoozed", "s-snooze")
    out, _err, status = qm("snooze", "snoozed", "turn")

    assert status.success?
    assert_match(/your-turn snoozed/, out)
    assert Quartermaster::WorkItem.find("snoozed").front["turn_snoozed_at"]
  end

  def test_install_hooks_prints_a_snippet_with_absolute_paths_and_writes_nothing
    Dir.mktmpdir do |home|
      out, _err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "HOME" => home },
                                         RbConfig.ruby, QM_BIN, "install-hooks")

      assert status.success?
      assert_empty Dir.children(home), "install-hooks must not write settings.json"
      hooks = JSON.parse(out.lines.reject { |l| l.start_with?("#") }.join)["hooks"]
      launcher = File.realpath(QM_BIN)
      events = File.join(File.dirname(launcher), "hooks", "record-event.sh")
      assert_equal "#{launcher} hook-session-start", hooks.dig("SessionStart", 0, "hooks", 0, "command")
      assert_equal "#{launcher} hook-session-end", hooks.dig("SessionEnd", 0, "hooks", 0, "command")
      %w[UserPromptSubmit PermissionRequest Stop StopFailure PostToolUse PostToolUseFailure].each do |event|
        assert_equal events, hooks.dig(event, 0, "hooks", 0, "command")
      end
      board = hooks["PostToolUse"].find { |h| h["matcher"] == "ArtifactData" }
      assert_equal File.join(File.dirname(launcher), "hooks", "record-board-write.sh"), board.dig("hooks", 0, "command")
      snapshot = hooks.dig("UserPromptSubmit", 0, "hooks", 1, "command")
      assert_equal File.join(File.dirname(launcher), "hooks", "snapshot-worktree.sh"), snapshot
      [events, board.dig("hooks", 0, "command"), snapshot].each { |script| assert File.executable?(script), script }
    end
  end
end

class GuiChatViewTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
  def get(path) = JSON.parse(gui.respond("GET", path, { "host" => "127.0.0.1:4567" }, "")[2])

  def test_state_carries_the_attention_list_in_order_with_context_size
    path = write_transcript("s-turn", [assistant(30, input: 5, read: 160_000, created: 2_000)])
    live_item("Your turn", "s-turn", transcript: path)
    log_events("s-turn", [100, "UserPromptSubmit"], [40, "Stop"])
    live_item("Blocked", "s-block")
    log_events("s-block", [20, "UserPromptSubmit"], [5, "PermissionRequest", "Bash"])
    Quartermaster::WorkItem.create("Idle", project: "No project")
    Quartermaster::WorkItem.create("Fridged", project: "No project").update_state("fridge")

    attention = get("/api/state")["attention"]

    assert_equal %w[blocked your-turn idle], attention.map { |a| a["slug"] }
    assert_equal %w[blocked your_turn none], attention.map { |a| a["state"] }
    blocked, turn, idle = attention
    assert_equal ["Bash", "s-block"], [blocked["tool"], blocked["session"]]
    assert_equal 162_005, turn["contextTokens"]
    assert Time.parse(turn["cacheWarmUntil"]) > Time.now
    assert_equal false, turn["snoozed"]
    assert_nil idle["since"]
  end

  def test_snoozing_a_turn_through_the_action_endpoint_marks_the_entry
    live_item("Your turn", "s-turn")
    log_events("s-turn", [40, "Stop"])

    result = gui.actions.dispatch("cmd" => "snooze", "slug" => "your-turn", "args" => { "duration" => "turn" })

    assert result["ok"]
    assert_equal true, get("/api/state")["attention"].first["snoozed"]
  end

  def test_pulse_moves_when_a_hook_appends_an_event_or_a_session_starts
    live_item("Chat", "s-1")
    before = get("/api/pulse")["pulse"]
    assert_equal before, get("/api/state")["pulse"]

    log_events("s-1", [1, "UserPromptSubmit"])
    after_event = get("/api/pulse")["pulse"]
    refute_equal before, after_event

    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "s-2", "cwd" => "/",
                                         "pid" => Process.pid, "ts" => Time.now.iso8601)
    refute_equal after_event, get("/api/pulse")["pulse"]
  end

  def test_pulse_moves_when_a_working_chat_is_interrupted_with_esc
    path = write_transcript("s-work", [user_text(60, "do it"), assistant(50)])
    live_item("Working", "s-work", transcript: path)
    log_events("s-work", [60, "UserPromptSubmit"], [50, "PostToolUse", "Bash"])
    server = gui
    get_from = ->(route) { JSON.parse(server.respond("GET", route, { "host" => "127.0.0.1:4567" }, "")[2]) }
    assert_equal "working", get_from.("/api/state")["attention"].first["state"]
    before = get_from.("/api/pulse")["pulse"]

    File.write(path, "#{JSON.generate(user_text(0, "[Request interrupted by user]"))}\n", mode: "a")

    refute_equal before, get_from.("/api/pulse")["pulse"]
    assert_equal "your_turn", get_from.("/api/state")["attention"].first["state"]
  end

  def test_pulse_without_any_log_yet_is_still_an_answer
    assert_equal "0:0:0:0:0:0", get("/api/pulse")["pulse"]
  end

  def test_items_say_which_notes_a_new_session_is_told_about
    item = Quartermaster::WorkItem.create("Digest", project: "No project")
    item.add_note("mechanics", kind: "history")
    item.add_note("chose X")
    item.add_note("waiting on review", kind: "open")

    payload = get("/api/state")["items"].find { |i| i["slug"] == "digest" }

    assert_equal [2, 3], payload["injected"].sort
  end
end
