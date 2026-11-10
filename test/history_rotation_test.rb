# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/history_rotation_test.rb`).
require_relative "rotation_helpers"

class TranscriptHistoryTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include HistoryHelpers

  def test_renders_prompts_and_replies_in_full_and_each_tool_call_on_one_line
    long_reply = "First paragraph.\n\n#{"word " * 400}".strip
    path = write_transcript("s-hist", [
      { "type" => "summary", "summary" => "ignored" },
      said(600, "Fix the flaky spec\nin spec/models"),
      { "type" => "user", "isMeta" => true, "timestamp" => at(599), "message" => { "content" => "<hook output>" } },
      replied(590, "m1", { "type" => "thinking", "thinking" => "hmm" }),
      replied(590, "m1", text_block("Looking at it.")),
      replied(589, "m1", text_block("Second block of the same message.")),
      replied(588, "m1", tool_block("Bash", "command" => "bin/rspec   spec/models/user_spec.rb\n--seed 1", "description" => "run")),
      tool_result(587),
      replied(586, "m2", tool_block("Read", "file_path" => File.join(Dir.home, "code/app/user.rb"))),
      replied(585, "m2", tool_block("TodoWrite", "todos" => [])),
      { "type" => "assistant", "isSidechain" => true, "timestamp" => at(584),
        "message" => { "id" => "side", "content" => [text_block("sub-agent chatter")] } },
      replied(580, "m3", text_block(long_reply)),
      said(500, "[Request interrupted by user]"),
      { "type" => "user", "isCompactSummary" => true, "timestamp" => at(400),
        "message" => { "content" => "This session is being continued…" } },
      "not an entry"
    ])

    entries = Quartermaster::TranscriptHistory.entries(path)

    assert_equal %w[user assistant tool tool tool assistant event], entries.map { |e| e["kind"] }
    assert_equal "Fix the flaky spec\nin spec/models", entries[0]["text"]
    assert_equal "Looking at it.\n\nSecond block of the same message.", entries[1]["text"]
    assert_equal "Bash  bin/rspec spec/models/user_spec.rb --seed 1", entries[2]["text"]
    assert_equal "Read  ~/code/app/user.rb", entries[3]["text"]
    assert_equal "TodoWrite", entries[4]["text"]
    assert_equal long_reply, entries[5]["text"], "replies are never clipped"
    assert_equal at(600), entries[0]["ts"]
  end

  def test_a_tool_line_is_clipped_and_prefers_the_identifying_input
    line = Quartermaster::TranscriptHistory.tool_line("name" => "Grep", "input" => { "glob" => "*.rb", "pattern" => "x" * 300 })
    assert line.start_with?("Grep  xxx")
    assert_operator line.length, :<=, Quartermaster::TranscriptHistory::TOOL_LINE_CHARS + 1
    assert line.end_with?("…")
  end

  def test_a_missing_transcript_has_no_entries
    assert_nil Quartermaster::TranscriptHistory.entries(File.join(Quartermaster::ROOT, "gone.jsonl"))
    assert_nil Quartermaster::TranscriptHistory.entries(nil)
  end
end

class ChatHistoryTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include HistoryHelpers

  def history = Quartermaster::ChatHistory.new

  # Three earlier sessions (one pruned, one distilled-then-pruned) and the live one.
  def setup_item
    first = write_transcript("s-first", [said(9000, "start the work"), replied(8990, "a", text_block("on it"))])
    log_session("s-first", ago: 9000, transcript: first)
    log_session("s-pruned", ago: 7000)
    log_session("s-distilled", ago: 5000)
    log_session("s-live", ago: 100, ended: false, pid: Process.pid)
    item = item_with_sessions("Long haul", "s-first", "s-pruned", "s-distilled", "s-live")
    item.add_snapshot("s-distilled", "What happened, distilled.")
    item.add_note("chose the queue", kind: "decision")
    item.add_note("mechanics", kind: "history")
    item.add_note("does staging need it?", kind: "open")
    Quartermaster::WorkItem.find(item.slug)
  end

  def test_the_timeline_runs_oldest_first_without_the_live_chat_and_places_rotation_dividers
    item = setup_item
    item.record_rotation(from_session: "s-pruned", via: "wrap-up", at: Time.now - 6000)

    timeline = history.timeline(Quartermaster::WorkItem.find(item.slug))

    assert_equal [%w[session s-first], %w[session s-pruned], %w[divider s-pruned], %w[session s-distilled]],
                 timeline.map { |s| [s["type"], s["id"] || s["from"]] }
    assert_equal %w[transcript none snapshot], timeline.select { |s| s["type"] == "session" }.map { |s| s["source"] }
    divider = timeline[2]
    assert_equal [1, 1, "wrap-up"], [divider["decisions"], divider["open"], divider["via"]]
    assert_equal ["chose the queue", "does staging need it?"], divider["notes"].map { |n| n["text"] }.sort
    assert_equal [1, 3], divider["notes"].map { |n| n["position"] }.sort
  end

  def test_pages_run_from_the_newest_end_with_a_cursor_to_the_older_ones
    entries = (1..7).map { |i| said(1000 - i, "prompt #{i}") }
    path = write_transcript("s-paged", entries)
    log_session("s-paged", ago: 1000, transcript: path)
    item = item_with_sessions("Paged", "s-paged")

    newest = history.page(item, "s-paged", limit: 3)
    assert_equal ["prompt 5", "prompt 6", "prompt 7"], newest["entries"].map { |e| e["text"] }
    assert_equal [4, 7], [newest["before"], newest["total"]]

    middle = history.page(item, "s-paged", before: newest["before"], limit: 3)
    assert_equal ["prompt 2", "prompt 3", "prompt 4"], middle["entries"].map { |e| e["text"] }
    oldest = history.page(item, "s-paged", before: middle["before"], limit: 3)
    assert_equal ["prompt 1"], oldest["entries"].map { |e| e["text"] }
    assert_nil oldest["before"]
  end

  def test_an_expired_transcript_falls_back_to_its_snapshot_or_says_nothing_survived
    item = setup_item

    snapshot = history.page(item, "s-distilled")["entries"]
    assert_equal [%w[snapshot What\ happened,\ distilled.]], snapshot.map { |e| [e["kind"], e["text"]] }
    gone = history.page(item, "s-pruned")["entries"]
    assert_equal ["event"], gone.map { |e| e["kind"] }
    assert_match(/never distilled/, gone.first["text"])
  end

  def test_the_live_chat_and_strangers_are_not_pages_of_the_history
    item = setup_item
    assert_raises(ArgumentError) { history.page(item, "s-live") }
    assert_raises(ArgumentError) { history.page(item, "s-other") }
  end

  def test_a_grown_transcript_is_parsed_again
    path = write_transcript("s-grow", [said(100, "one")])
    log_session("s-grow", ago: 100, transcript: path)
    item = item_with_sessions("Grows", "s-grow")
    cache = {}
    shared = Quartermaster::ChatHistory.new(cache: cache)
    assert_equal 1, shared.page(item, "s-grow")["total"]

    File.open(path, "a") { |f| f.puts JSON.generate(said(50, "two")) }

    assert_equal 2, shared.page(item, "s-grow")["total"]
    assert_equal 1, cache.size, "the stale parse is dropped"
  end
end

class RotationRecordTest < Minitest::Test
  include QmTestHelpers

  def test_records_the_injected_note_positions_and_counts_at_rotation_time
    item = Quartermaster::WorkItem.create("Rotating", project: "No project")
    item.add_note("old decision")
    item.add_note("mechanics", kind: "history")
    item.add_note("blocker", kind: "open")
    stale = Quartermaster::WorkItem.find(item.slug)
    item.add_note("written by the wrap-up")

    rotation = stale.record_rotation(from_session: "s-old", via: "wrap-up", at: Time.utc(2026, 10, 21, 14, 2))

    assert_equal({ "at" => "2026-10-21T14:02:00Z", "from" => "s-old", "via" => "wrap-up", "carried" => [1, 3, 4],
                   "decisions" => 2, "open" => 1 }, rotation)
    assert_equal [rotation], Quartermaster::WorkItem.find(item.slug).rotations
    assert_equal stale.injectable_notes.map(&:position), rotation["carried"]
  end
end

class ContextMeterTest < Minitest::Test
  M = Quartermaster::ContextMeter

  def test_levels
    assert_nil M.level(nil)
    assert_nil M.level(149_999)
    assert_equal "amber", M.level(150_000)
    assert_equal "amber", M.level(249_999)
    assert_equal "red", M.level(250_000)
  end

  def test_rotation_is_offered_at_the_threshold_or_on_a_cold_cache_over_50k
    now = Time.now
    assert_equal "threshold", M.rotate_offer(150_000, now, now)
    assert_equal "threshold", M.rotate_offer(300_000, now - 7200, now)
    assert_equal "cold", M.rotate_offer(50_001, now - 3601, now)
    assert_nil M.rotate_offer(50_000, now - 7200, now), "only above 50k"
    assert_nil M.rotate_offer(120_000, now - 3500, now), "warm within the hour"
    assert_nil M.rotate_offer(120_000, nil, now)
    assert_nil M.rotate_offer(nil, now - 7200, now)
  end
end

class RotationTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include HistoryHelpers

  def setup
    super
    @now = fixed_now
    @slept = 0
  end

  def live_chat(turn: [[60, "UserPromptSubmit"], [30, "Stop"]], transcript: nil)
    log_session("s-chat", ago: 600, ended: false, pid: Process.pid, transcript: transcript)
    log_events("s-chat", *turn)
    item = item_with_sessions("Big context", "s-chat")
    item.add_note("carried decision")
    item
  end

  def rotation(tmux, clock: -> { @now + @slept }, distiller: ->(*) { flunk "a live chat is never distilled" })
    Quartermaster::Rotation.new(tmux: tmux, distiller: distiller, sleeper: ->(s) { @slept += s }, clock: clock)
  end

  # The fake chat's side of the hand-off.
  def play_chat(tmux, item)
    tmux.on_submit = lambda do |text|
      case text
      when Quartermaster::Rotation::WRAP_UP_PROMPT
        log_events("s-chat", [0, "UserPromptSubmit"])
        item.add_note("recorded during the wrap-up", kind: "open")
        log_events("s-chat", [0, "Stop"])
      when "/exit"
        Quartermaster::SessionLog.new.append("event" => "end", "session_id" => "s-chat", "ts" => Time.now.iso8601)
        tmux.die(item.slug)
      end
    end
  end

  def test_a_live_chat_wraps_up_exits_and_restarts_fresh_in_the_same_window
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    play_chat(tmux, item)
    r = rotation(tmux)

    plan = r.plan(item)
    assert_equal :wrap_up, plan.mode
    result = r.run(item, plan)

    slug = item.slug
    assert_equal [[:send_text, slug, Quartermaster::Rotation::WRAP_UP_PROMPT], [:send_enter, slug],
                  [:keep_on_exit, slug, true], [:send_text, slug, "/exit"], [:send_enter, slug],
                  [:respawn, slug, { "QM_ITEM" => slug }], [:keep_on_exit, slug, false]], tmux.calls
    rotation = Quartermaster::WorkItem.find(slug).rotations.last
    assert_equal ["s-chat", "wrap-up", 1, 1], rotation.values_at("from", "via", "decisions", "open")
    assert_equal [1, 2], rotation["carried"], "the note the wrap-up wrote is carried"
    assert result["ok"]
    assert_match(/carried 1 decisions, 1 open/, result["message"])
  end

  def test_wrap_up_and_close_records_the_rotation_and_closes_the_window_without_a_fresh_start
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    play_chat(tmux, item)
    r = rotation(tmux)

    result = r.run(item, r.plan(item, close: true))

    slug = item.slug
    assert_equal [[:send_text, slug, Quartermaster::Rotation::WRAP_UP_PROMPT], [:send_enter, slug],
                  [:keep_on_exit, slug, true], [:send_text, slug, "/exit"], [:send_enter, slug]], tmux.calls
    refute tmux.live?(slug), "the dead window is gone, so Start works later"
    assert_equal [1, 2], Quartermaster::WorkItem.find(slug).rotations.last["carried"]
    assert_match(/wrapped up and closed — carried 1 decisions, 1 open/, result["message"])
  end

  def test_wrap_up_and_close_needs_a_chat_open_in_the_gui
    path = write_transcript("s-dead", [said(900, "hello")])
    log_session("s-dead", ago: 900, transcript: path)
    item = item_with_sessions("Closed already", "s-dead")

    error = assert_raises(ArgumentError) { rotation(RotationTmux.new).plan(item, close: true) }
    assert_match(/no chat open to wrap up/, error.message)
  end

  def test_a_stop_from_before_the_wrap_up_does_not_end_the_wait
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    clock = -> { @now + @slept }
    r = rotation(tmux, clock: clock)

    error = assert_raises(ArgumentError) { r.run(item, r.plan(item)) }

    assert_match(/no Stop/, error.message)
    assert_operator @slept, :>=, Quartermaster::Rotation::STOP_TIMEOUT
    refute(tmux.calls.any? { |c| c[0] == :send_text && c[2] == "/exit" }, "the chat is left running")
    assert_empty Quartermaster::WorkItem.find(item.slug).rotations
  end

  def test_a_chat_that_will_not_exit_gets_its_window_back_to_normal
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    play_chat(tmux, item)
    tmux.on_submit = ->(text) { log_events("s-chat", [0, "UserPromptSubmit"], [0, "Stop"]) if text != "/exit" }
    clock = -> { @now + @slept }
    r = rotation(tmux, clock: clock)

    assert_raises(ArgumentError) { r.run(item, r.plan(item)) }

    assert_equal [:keep_on_exit, item.slug, false], tmux.calls.last
    assert_empty Quartermaster::WorkItem.find(item.slug).rotations
  end

  def test_a_failed_restart_closes_the_kept_window_so_start_works_again
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    play_chat(tmux, item)
    def tmux.respawn(*, **) = raise(ArgumentError, "tmux could not restart")

    assert_raises(ArgumentError) { rotation(tmux).run(item, rotation(tmux).plan(item)) }

    refute tmux.live?(item.slug), "no dead window is left to block Start"
  end

  def test_refuses_mid_turn_outside_the_gui_and_before_a_session_is_captured
    item = live_chat(turn: [[5, "UserPromptSubmit"]])
    error = assert_raises(ArgumentError) { rotation(RotationTmux.new([item.slug])).plan(item) }
    assert_match(/mid-turn \(working\)/, error.message)

    error = assert_raises(ArgumentError) { rotation(RotationTmux.new).plan(item) }
    assert_match(/outside the GUI/, error.message)

    fresh = Quartermaster::WorkItem.create("Fresh pane", project: "No project")
    error = assert_raises(ArgumentError) { rotation(RotationTmux.new([fresh.slug])).plan(fresh) }
    assert_match(/no captured session/, error.message)
  end

  def test_a_dead_chat_is_distilled_then_restarted_fresh
    path = write_transcript("s-dead", [said(900, "hello"), replied(890, "m", text_block("hi"))])
    log_session("s-dead", ago: 900, transcript: path)
    item = item_with_sessions("Crashed", "s-dead")
    distilled = []
    tmux = RotationTmux.new
    r = rotation(tmux, distiller: ->(it, session) { distilled << session.id; it.add_snapshot(session.id, "snap") })

    plan = r.plan(item)
    assert_equal [:distill, "s-dead"], [plan.mode, plan.session.id]
    r.run(item, plan)

    assert_equal ["s-dead"], distilled
    assert_equal [[:open, item.slug, { "QM_ITEM" => item.slug }]], tmux.calls
    assert_equal "distill", Quartermaster::WorkItem.find(item.slug).rotations.last["via"]
  end

  def test_an_already_distilled_or_pruned_dead_chat_is_not_distilled_again
    log_session("s-pruned", ago: 900)
    item = item_with_sessions("Pruned", "s-pruned")
    r = rotation(RotationTmux.new, distiller: ->(*) { flunk "nothing left to distill" })

    r.run(item, r.plan(item))

    assert_equal 1, Quartermaster::WorkItem.find(item.slug).rotations.size
  end

  # qm rotate --self: the chat asks mid-turn, then ends that turn itself.
  def self_rotation(tmux, item, stop_after_request: true)
    play_chat(tmux, item)
    ended = false
    sleeper = lambda do |s|
      @slept += s
      next if ended || !stop_after_request

      ended = true
      log_events("s-chat", [0, "Stop"])
    end
    Quartermaster::Rotation.new(tmux: tmux, distiller: ->(*) { flunk "a live chat is never distilled" },
                                sleeper: sleeper, clock: -> { @now + @slept })
  end

  def test_a_self_rotation_types_nothing_waits_for_its_own_turn_to_end_then_hands_over
    item = live_chat(turn: [[60, "UserPromptSubmit"], [30, "Stop"], [5, "UserPromptSubmit"], [1, "PostToolUse", "Bash"]])
    tmux = RotationTmux.new([item.slug])
    @now = Time.now
    r = self_rotation(tmux, item)

    plan = r.plan(item, by_chat: true, session_id: "s-chat")
    assert_equal [:self, "s-chat"], [plan.mode, plan.session.id], "mid-turn is fine when the chat asks itself"
    result = r.run(item, plan)

    slug = item.slug
    assert_equal [[:keep_on_exit, slug, true], [:send_text, slug, "/exit"], [:send_enter, slug],
                  [:respawn, slug, { "QM_ITEM" => slug }], [:keep_on_exit, slug, false]], tmux.calls
    rotation = Quartermaster::WorkItem.find(slug).rotations.last
    assert_equal ["s-chat", "self", [1]], rotation.values_at("from", "via", "carried")
    assert_match(/rotated — carried 1 decisions/, result["message"])
  end

  def test_a_self_rotation_with_close_closes_the_window_after_the_turn
    item = live_chat(turn: [[5, "UserPromptSubmit"]])
    tmux = RotationTmux.new([item.slug])
    r = self_rotation(tmux, item)

    result = r.run(item, r.plan(item, close: true, by_chat: true))

    refute tmux.live?(item.slug)
    refute(tmux.calls.any? { |c| c[0] == :respawn })
    assert_match(/wrapped up and closed/, result["message"])
  end

  def test_a_stop_from_before_the_self_request_does_not_end_the_wait
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    @now = Time.now + 5
    r = self_rotation(tmux, item, stop_after_request: false)

    error = assert_raises(ArgumentError) { r.run(item, r.plan(item, by_chat: true, session_id: "s-chat")) }

    assert_match(/no Stop from #{item.slug}'s chat within 20 min of its rotate request/, error.message)
    assert_empty tmux.calls, "nothing typed, the chat is left running"
    assert_empty Quartermaster::WorkItem.find(item.slug).rotations
  end

  # A chat whose transcript has a background shell still running.
  def chat_with_pending_job(turn)
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-chat", [user_text(60, "build it"), *shell_launched(50, "b1", "Run the full suite")])
    [live_chat(turn: turn, transcript: path), path]
  end

  def append_entries(path, *entries) = File.write(path, entries.map { |e| "#{JSON.generate(e)}\n" }.join, mode: "a")

  def test_a_self_rotation_with_background_work_out_waits_for_it_to_report_and_its_turn_to_end
    item, path = chat_with_pending_job([[5, "UserPromptSubmit"]])
    tmux = RotationTmux.new([item.slug])
    polls = 0
    exited_at = nil
    sleeper = lambda do |s|
      @slept += s
      polls += 1 unless s == Quartermaster::Rotation::TYPE_SETTLE
      case polls
      when 1 then log_events("s-chat", [0, "Stop"]) # the requesting turn ends, the shell still runs
      when 4 then append_entries(path, notified(0, "b1"))
      when 7 then log_events("s-chat", [-2, "Stop"]) # the turn that took the notification up
      end
    end
    tmux.on_submit = lambda do |text|
      next unless text == "/exit"

      exited_at = polls
      tmux.die(item.slug)
    end
    labels = []
    r = Quartermaster::Rotation.new(tmux: tmux, sleeper: sleeper, clock: -> { @now + @slept })

    r.run(item, r.plan(item, by_chat: true, session_id: "s-chat"), relabel: ->(l) { labels << l })

    assert_equal 7, exited_at, "no /exit while the shell runs, nor before the turn its notification woke ends"
    assert_equal [Quartermaster::Rotation::WAITING_LABEL], labels
    assert_equal "self", Quartermaster::WorkItem.find(item.slug).rotations.last["via"]
  end

  def test_a_self_rotation_whose_background_work_never_reports_gives_up_without_exiting
    item, = chat_with_pending_job([[5, "UserPromptSubmit"]])
    tmux = RotationTmux.new([item.slug])
    r = self_rotation(tmux, item)

    error = assert_raises(ArgumentError) { r.run(item, r.plan(item, by_chat: true, session_id: "s-chat")) }

    assert_match(/background work did not finish within 60 min/, error.message)
    assert_operator @slept, :>=, Quartermaster::Rotation::BACKGROUND_TIMEOUT
    assert_empty tmux.calls, "nothing typed, the chat is left running"
    assert_empty Quartermaster::WorkItem.find(item.slug).rotations
  end

  def test_a_click_rotation_refuses_while_the_chat_waits_on_background_work
    item, = chat_with_pending_job([[60, "UserPromptSubmit"], [30, "Stop"]])

    error = assert_raises(ArgumentError) { rotation(RotationTmux.new([item.slug])).plan(item) }

    assert_match(/waiting on background work \(Run the full suite\)/, error.message)
  end

  def test_a_wrap_up_that_leaves_background_work_out_waits_before_exiting
    Quartermaster::BackgroundJobs.reset!
    path = write_transcript("s-chat", [user_text(60, "build it")])
    item = live_chat(transcript: path)
    tmux = RotationTmux.new([item.slug])
    polls = 0
    exited_at = nil
    tmux.on_submit = lambda do |text|
      if text == "/exit"
        exited_at = polls
        tmux.die(item.slug)
      else # the wrap-up starts a shell in the background and ends its turn
        append_entries(path, *shell_launched(0, "b2", "Push the branch"))
        log_events("s-chat", [0, "UserPromptSubmit"], [0, "Stop"])
      end
    end
    sleeper = lambda do |s|
      @slept += s
      polls += 1 unless s == Quartermaster::Rotation::TYPE_SETTLE
      next unless polls == 3

      append_entries(path, notified(0, "b2"))
      log_events("s-chat", [-2, "PostToolUse", "Bash"], [-2, "Stop"])
    end
    r = Quartermaster::Rotation.new(tmux: tmux, sleeper: sleeper, clock: -> { @now + @slept })

    r.run(item, r.plan(item))

    assert_equal 3, exited_at, "the /exit waits for the shell's notification and the turn it woke"
  end

  def test_a_self_rotation_needs_the_items_live_gui_chat
    item = live_chat(turn: [[5, "UserPromptSubmit"]])

    error = assert_raises(ArgumentError) { rotation(RotationTmux.new).plan(item, by_chat: true, session_id: "s-chat") }
    assert_match(/isn't open in the qm gui/, error.message)

    error = assert_raises(ArgumentError) { rotation(RotationTmux.new([item.slug])).plan(item, by_chat: true, session_id: "s-other") }
    assert_match(/s-other is not #{item.slug}'s live chat/, error.message)
  end

  # A second live chat of the item (a Warp tab) must not get the pane's /exit.
  def test_a_self_rotation_only_rotates_the_chat_its_pane_runs
    log_session("s-warp", ago: 300, ended: false, pid: Process.ppid)
    log_session("s-pane", ago: 600, ended: false, pid: Process.pid)
    item = item_with_sessions("Two chats", "s-warp", "s-pane")
    tmux = RotationTmux.new([item.slug])
    tmux.pane_pids[item.slug] = 4242
    lineage = ->(pid) { pid == Process.pid ? [pid, 4242] : [pid, 1] }
    r = Quartermaster::Rotation.new(tmux: tmux, lineage: lineage)

    assert_equal "s-pane", r.plan(item, by_chat: true).session.id, "QM_ITEM fallback: the pane's own chat"
    error = assert_raises(ArgumentError) { r.plan(item, by_chat: true, session_id: "s-warp") }
    assert_match(/s-warp runs outside two-chats's qm gui pane/, error.message)
  end
end

class GuiHistoryRotationTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include HistoryHelpers

  def gui(tmux = FakeTmux.new) = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
  def get(server, path) = JSON.parse(server.respond("GET", path, { "host" => "127.0.0.1:4567" }, "")[2])

  def test_history_endpoints_serve_the_timeline_and_pages
    path = write_transcript("s-one", [said(900, "hello"), replied(890, "m", text_block("hi there"))])
    log_session("s-one", ago: 900, transcript: path)
    item_with_sessions("Has history", "s-one")
    server = gui

    timeline = get(server, "/api/history/has-history")["timeline"]
    assert_equal [%w[session s-one transcript]], timeline.map { |s| s.values_at("type", "id", "source") }
    page = get(server, "/api/history/has-history/s-one?before=2")
    assert_equal ["hello", "hi there"], page["entries"].map { |e| e["text"] }
    assert_equal false, get(server, "/api/history/no-such-item")["ok"]
  end

  def test_attention_rows_carry_the_meter_level_and_the_rotation_offer
    hot = write_transcript("s-hot", [assistant(30, read: 160_000)])
    live_item("Hot", "s-hot", transcript: hot)
    cold = write_transcript("s-cold", [assistant(7200, read: 60_000)])
    live_item("Cold", "s-cold", transcript: cold)

    rows = get(gui, "/api/state")["attention"].to_h { |a| [a["slug"], a] }

    assert_equal %w[amber threshold], rows["hot"].values_at("ctxLevel", "rotate")
    assert_equal [nil, "cold"], rows["cold"].values_at("ctxLevel", "rotate")
    assert rows["cold"]["lastAssistantAt"]
  end

  def test_the_rotate_action_refuses_at_once_and_otherwise_runs_as_the_items_job
    live_item("Busy", "s-busy")
    log_events("s-busy", [5, "UserPromptSubmit"])
    server = gui(FakeTmux.new(["busy"]))

    refused = server.actions.dispatch("cmd" => "rotate", "slug" => "busy")
    assert_equal false, refused["ok"]
    assert_match(/mid-turn/, refused["error"])
    assert_empty server.state.build["jobs"]
  end
end

class TmuxRespawnTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    skip "tmux not installed" unless system("command -v tmux >/dev/null")
    @tmux = Quartermaster::Tmux.new(socket: "qm-test-respawn-#{Process.pid}")
  end

  def teardown
    @tmux&.kill_server
  end

  def screen(name) = Open3.capture2("tmux", "-L", @tmux.socket, "capture-pane", "-p", "-t", "=#{name}:")[0]
  def wait_for(timeout = 5) = Timeout.timeout(timeout) { sleep 0.05 until yield }

  def test_typed_text_reaches_the_program_and_a_kept_window_takes_a_fresh_one
    @tmux.open("rot", cwd: Dir.home, argv: ["sh", "-c", 'read line; echo "got:$line"; exit 0'])
    assert @tmux.keep_on_exit("rot", true)
    assert @tmux.send_text("rot", "Enter is a word here")
    assert @tmux.send_enter("rot")

    wait_for { @tmux.pane_dead?("rot") }
    assert_includes screen("rot"), "got:Enter is a word here"
    assert @tmux.live?("rot"), "the window outlives its program"
    assert_kind_of Integer, @tmux.pane_pid("rot")
    assert_nil @tmux.pane_pid("gone")

    @tmux.respawn("rot", cwd: Dir.home, argv: ["sh", "-c", 'echo "fresh:$QM_ITEM:$$"; sleep 30'], env: { "QM_ITEM" => "rot" })
    assert @tmux.keep_on_exit("rot", false)
    wait_for { screen("rot").include?("fresh:rot") }
    refute @tmux.pane_dead?("rot")
    assert_includes screen("rot"), "fresh:rot:#{@tmux.pane_pid("rot")}", "the pane runs the chat itself, exec'd"
    refute @tmux.send_text("a:b", "x"), "odd names are refused"
  end
end

# qm pane-start / pane-resume / rotate drive the running GUI over a real
# loopback socket, no Origin — like qm caffeinate.
class CliPaneRotateTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include HistoryHelpers

  def setup
    super
    @env = ENV.to_h.slice("QM_GUI_PORT", "QM_ITEM", "QM_ASIDE")
    ENV.delete("QM_ITEM")
    ENV.delete("QM_ASIDE")
  end

  def teardown
    %w[QM_GUI_PORT QM_ITEM QM_ASIDE].each { |k| @env.key?(k) ? ENV[k] = @env[k] : ENV.delete(k) }
  end

  def with_gui(tmux)
    listener = TCPServer.new("127.0.0.1", 0)
    ENV["QM_GUI_PORT"] = listener.addr[1].to_s
    @server = Quartermaster::Gui.new(port: listener.addr[1], runner: quiet_runner, tmux: tmux)
    acceptor = Thread.new do
      loop { @server.send(:handle_client, listener.accept) }
    rescue IOError, SystemCallError
      nil
    end
    yield
  ensure
    listener&.close
    acceptor&.join(1)
  end

  def qm(*argv, caller_pids: [Process.pid])
    exited = nil
    out, err = capture_io do
      Quartermaster::CLI.new(caller_pids: -> { caller_pids }).run(argv)
    rescue SystemExit => e
      exited = e.status
    end
    [out, err, exited]
  end

  # The GUI's background job, run to its end so it can't leak into a later test.
  def finished_job
    Timeout.timeout(10) { sleep 0.05 until @server.jobs.running.empty? }
    @server.jobs.take_finished.last
  end

  def test_pane_start_opens_the_items_chat_in_the_gui_and_says_when_it_already_runs
    item = Quartermaster::WorkItem.create("Phone start", project: "No project")
    tmux = FakeTmux.new
    with_gui(tmux) do
      assert_equal ["phone-start: fresh chat started in its qm gui pane\n", "", nil], qm("pane-start", item.slug)
      assert_equal "phone-start: its chat is already running in the qm gui\n", qm("pane-resume", item.slug)[0]
    end
    assert_equal [{ "QM_ITEM" => "phone-start" }], tmux.opened.map { |o| o[:env] }
  end

  def test_without_a_running_gui_nothing_happens
    free = TCPServer.new("127.0.0.1", 0)
    ENV["QM_GUI_PORT"] = free.addr[1].to_s
    free.close
    _out, err, exited = qm("pane-start", "anything")
    assert_equal 1, exited
    assert_match(/qm pane-start: no qm gui running/, err)
    assert_match(/usage: qm rotate SLUG/, qm("rotate")[1])
  end

  def test_rotate_keeps_its_refusals
    live_item("Busy", "s-busy")
    log_events("s-busy", [5, "UserPromptSubmit"])
    with_gui(FakeTmux.new(["busy"])) do
      _out, err, exited = qm("rotate", "busy")
      assert_equal 1, exited
      assert_match(/qm rotate: busy's chat is mid-turn \(working\)/, err)
    end
  end

  def test_rotate_self_finds_the_calling_chat_and_hands_over_after_its_turn
    log_session("s-chat", ago: 600, ended: false, pid: Process.pid)
    log_events("s-chat", [5, "UserPromptSubmit"], [1, "PostToolUse", "Bash"])
    item = item_with_sessions("Self rotate", "s-chat")
    tmux = RotationTmux.new([item.slug])
    tmux.on_submit = ->(text) { tmux.die(item.slug) if text == "/exit" }
    with_gui(tmux) do
      out, _err, exited = qm("rotate", "--self")
      assert_nil exited
      assert_equal "self-rotate: rotating after this turn ends — end the turn now\n", out
      log_events("s-chat", [-1, "Stop"])
      job = finished_job
      assert job["ok"], job["error"]
    end
    assert_includes tmux.calls, [:respawn, item.slug, { "QM_ITEM" => item.slug }]
    assert_equal "self", Quartermaster::WorkItem.find(item.slug).rotations.last["via"]
  end

  def test_rotate_self_refuses_an_aside_and_a_process_that_is_no_items_chat
    ENV["QM_ASIDE"] = "some-item"
    assert_match(/an aside can't rotate/, qm("rotate", "--self")[1])
    ENV.delete("QM_ASIDE")

    _out, err, exited = qm("rotate", "--self", caller_pids: [1])
    assert_equal 1, exited
    assert_match(/belongs to no item's chat/, err)

    ENV["QM_ITEM"] = "launched"
    Quartermaster::WorkItem.create("Launched", project: "No project")
    with_gui(RotationTmux.new) do
      assert_match(/qm rotate: launched's chat isn't open in the qm gui/, qm("rotate", "--self", caller_pids: [1])[1])
    end
  end
end
