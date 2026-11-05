# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/distill_test.rb`).
require_relative "test_helper"

class SessionTurnsTest < Minitest::Test
  include QmTestHelpers

  def write_transcript(session_id, entries)
    dir = File.join(Quartermaster::TRANSCRIPTS_DIR, "proj")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{session_id}.jsonl")
    File.write(path, entries.map { |e| JSON.generate(e) }.join("\n"))
    path
  end

  def test_turns_pair_each_prompt_with_its_tool_activity_and_reply
    path = write_transcript("sess-t", [
      { "type" => "ai-title", "aiTitle" => "Fix the widget" },
      { "type" => "user", "timestamp" => "2026-08-10T09:00:00Z", "gitBranch" => "main",
        "message" => { "content" => "Fix the widget" } },
      { "type" => "assistant", "message" => { "model" => "claude-fable-5", "content" => [
        { "type" => "tool_use", "name" => "Edit", "input" => { "file_path" => "/a/b/widget.rb" } },
        { "type" => "tool_use", "name" => "Edit", "input" => { "file_path" => "/a/b/widget.rb" } },
        { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "ruby test" } },
        { "type" => "text", "text" => "Fixed it." }
      ] } },
      { "type" => "user", "toolUseResult" => { "ok" => true },
        "message" => { "content" => [{ "type" => "tool_result" }] } },
      { "type" => "user", "isMeta" => true, "message" => { "content" => "meta noise" } },
      { "type" => "user", "message" => { "content" => "<system-reminder>injected</system-reminder>" } },
      { "type" => "user", "isSidechain" => true, "message" => { "content" => "subagent prompt" } },
      { "type" => "user", "timestamp" => "2026-08-10T09:05:00Z", "message" => { "content" => "Now ship it" } }
    ])

    parsed = Quartermaster.session_turns(path)

    assert_equal "Fix the widget", parsed["title"]
    assert_equal "main", parsed["branch"]
    assert_equal "claude-fable-5", parsed["model"]
    assert_equal ["Fix the widget", "Now ship it"], parsed["turns"].map { |t| t["prompt"] }
    turn = parsed["turns"].first
    assert_equal [{ "name" => "Edit", "count" => 2 }, { "name" => "Bash", "count" => 1 }], turn["tools"]
    assert_equal ["widget.rb"], turn["files"]
    assert_equal "Fixed it.", turn["reply"]
    assert_nil parsed["turns"].last["reply"]
  end

  def test_long_prompts_and_replies_are_clipped_before_crossing_the_wire
    path = write_transcript("sess-long", [
      { "type" => "user", "message" => { "content" => "p" * 2_000 } },
      { "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "r" * 2_000 }] } }
    ])

    turn = Quartermaster.session_turns(path)["turns"].first

    assert_operator turn["prompt"].length, :<=, Quartermaster::TURN_PROMPT_CHARS + 1
    assert turn["prompt"].end_with?("…")
    assert_operator turn["reply"].length, :<=, Quartermaster::TURN_REPLY_CHARS + 1
  end

  def test_missing_transcript_yields_nil
    assert_nil Quartermaster.session_turns("/nowhere/gone.jsonl")
    assert_nil Quartermaster.session_turns(nil)
  end
end

class DistillTest < Minitest::Test
  include QmTestHelpers

  # A window-controlled Attention so the tests don't depend on the real
  # ~/.claude/settings.json cleanupPeriodDays.
  def attention
    Quartermaster::Attention.new(
      retention_days: 30,
      pr_status: Quartermaster::PrStatus.new(fetcher: ->(_item, _branch) { nil }),
      project_map: Quartermaster::ProjectMap.new(roots: {})
    )
  end

  def capture_session(session_id, age_days:, ended_at: Time.now)
    transcript = File.join(Quartermaster::ROOT, "transcript-#{session_id}.jsonl")
    Quartermaster.ensure_setup
    File.write(transcript, "transcript body")
    mtime = Time.now - (age_days * 86_400)
    File.utime(mtime, mtime, transcript)
    log = Quartermaster::SessionLog.new
    log.append("event" => "start", "session_id" => session_id, "cwd" => "/",
               "transcript_path" => transcript, "ts" => (ended_at - 60).iso8601)
    log.append("event" => "end", "session_id" => session_id, "ts" => ended_at.iso8601)
  end

  def target_ids(item, **kw)
    Quartermaster.distill_targets(item, Quartermaster::SessionLog.new, attention: attention, **kw).map(&:id)
  end

  def test_bare_distill_targets_every_expiring_unsnapshotted_session
    capture_session("sess-old", age_days: 26)
    capture_session("sess-mid", age_days: 25)
    capture_session("sess-new", age_days: 1)
    item = Quartermaster::WorkItem.create("Multi", project: "No project", session_id: "sess-old")
    item.attach_session("sess-mid")
    item.attach_session("sess-new")

    assert_equal %w[sess-mid sess-old], target_ids(item).sort
  end

  def test_bare_distill_skips_expiring_sessions_already_snapshotted_or_acked
    capture_session("sess-a", age_days: 25)
    capture_session("sess-b", age_days: 25)
    capture_session("sess-c", age_days: 25)
    item = Quartermaster::WorkItem.create("Multi", project: "No project", session_id: "sess-a")
    item.attach_session("sess-b")
    item.attach_session("sess-c")
    item.add_snapshot("sess-a", "already kept")
    item.ack_degrade("sess-b")

    assert_equal %w[sess-c], target_ids(Quartermaster::WorkItem.find("multi"))
  end

  def test_bare_distill_falls_back_to_the_latest_resumable_session_when_nothing_expires
    capture_session("sess-early", age_days: 1, ended_at: Time.now - 3_600)
    capture_session("sess-late", age_days: 1, ended_at: Time.now)
    item = Quartermaster::WorkItem.create("Fresh", project: "No project", session_id: "sess-early")
    item.attach_session("sess-late")

    assert_equal %w[sess-late], target_ids(item)
  end

  def test_fallback_onto_a_snapshotted_session_needs_force
    capture_session("sess-1", age_days: 1)
    item = Quartermaster::WorkItem.create("Fresh", project: "No project", session_id: "sess-1")
    item.add_snapshot("sess-1", "already distilled")

    assert_raises(Quartermaster::AlreadyDistilledError) { target_ids(item) }
    assert_equal %w[sess-1], target_ids(item, force: true)
  end

  def test_explicit_session_onto_a_snapshot_needs_force
    capture_session("sess-1", age_days: 1)
    item = Quartermaster::WorkItem.create("Fresh", project: "No project", session_id: "sess-1")
    item.add_snapshot("sess-1", "already distilled")

    assert_raises(Quartermaster::AlreadyDistilledError) { target_ids(item, session_id: "sess-1") }
    assert_equal %w[sess-1], target_ids(item, session_id: "sess-1", force: true)
  end

  def test_explicit_session_must_belong_to_the_item_and_be_resumable
    capture_session("sess-elsewhere", age_days: 1)
    item = Quartermaster::WorkItem.create("Fresh", project: "No project")

    assert_raises(ArgumentError) { target_ids(item, session_id: "sess-elsewhere") }
  end

  def test_add_snapshot_replaces_an_existing_snapshot_for_the_same_session
    item = Quartermaster::WorkItem.create("Snapped", project: "No project")
    item.add_snapshot("sess-1", "first take")
    Quartermaster::WorkItem.find("snapped").add_snapshot("sess-2", "other session")
    Quartermaster::WorkItem.find("snapped").add_snapshot("sess-1", "second take")

    snaps = Quartermaster::WorkItem.find("snapped").snapshots
    assert_equal 2, snaps.size
    assert_equal ["second take"], snaps.select { |s| s["session"] == "sess-1" }.map { |s| s["text"] }
    assert_equal ["other session"], snaps.select { |s| s["session"] == "sess-2" }.map { |s| s["text"] }
  end

  def test_snapshot_for_ignores_session_mentions_outside_the_snapshots_section
    item = Quartermaster::WorkItem.create("Chatty", project: "No project")
    item.add_note("flaky run traced to session sess-9, see transcript")

    refute Quartermaster::WorkItem.find("chatty").snapshot_for?("sess-9")
  end

  FakeStatus = Struct.new(:ok) do
    def success? = ok
  end

  def gui
    Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
  end

  def ok_host
    { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  end

  def state_of(server)
    JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])
  end

  # Polls like the page does and returns the first state with no running
  # distill — the one carrying the finished job, which a state build hands
  # out only once.
  def wait_until_settled(server)
    Timeout.timeout(5) do
      loop do
        state = state_of(server)
        return state if state["distilling"].empty?

        sleep 0.01
      end
    end
  end

  # Replaces the headless-claude seam: handler gets each call's stdin bytes
  # and returns [stdout, stderr, status].
  def with_fake_claude(handler)
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) { |*, stdin_data: nil, **| handler.call(stdin_data) }
    yield
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  def big_transcript_item(bytes: 500_000)
    capture_session("sess-big", age_days: 1)
    File.write(File.join(Quartermaster::ROOT, "transcript-sess-big.jsonl"), "x" * bytes)
    Quartermaster::WorkItem.create("Big", project: "No project", session_id: "sess-big")
  end

  def test_distill_shrinks_the_tail_when_the_prompt_is_too_long
    big_transcript_item
    sizes = []
    handler = lambda do |stdin|
      sizes << stdin.bytesize
      next ["Prompt is too long · reduce context", "", FakeStatus.new(false)] if stdin.bytesize > 150_000

      ["the distilled snapshot", "", FakeStatus.new(true)]
    end

    results = with_fake_claude(handler) { Quartermaster.distill("big") }

    assert_equal sizes, sizes.sort.reverse
    assert_operator sizes.size, :>, 1
    assert_equal "the distilled snapshot", results.first[:snapshot]
    assert Quartermaster::WorkItem.find("big").snapshot_for?("sess-big")
  end

  def test_distill_gives_up_at_the_tail_floor_and_reports_claudes_stdout
    big_transcript_item
    handler = ->(_stdin) { ["Prompt is too long · reduce context", "", FakeStatus.new(false)] }

    error = assert_raises(ArgumentError) { with_fake_claude(handler) { Quartermaster.distill("big") } }
    assert_match(/Prompt is too long/, error.message)

    # A failure that isn't over-limit surfaces immediately, stdout included
    # (claude -p reports some errors there with an empty stderr).
    handler = ->(_stdin) { ["Some API error", "", FakeStatus.new(false)] }
    error = assert_raises(ArgumentError) { with_fake_claude(handler) { Quartermaster.distill("big", force: true) } }
    assert_match(/claude -p failed: Some API error/, error.message)
  end

  # Regression: the GUI ran distill inside the action mutex, so every action
  # after a click (a state change, a note) queued behind minutes of claude -p
  # and the page looked hung. Now the action answers at once, the state
  # reports the slug as distilling while claude runs, and the outcome is
  # handed to the page exactly once when it lands.
  def test_gui_distill_runs_in_the_background_and_reports_through_state
    big_transcript_item(bytes: 100)
    server = gui
    release = Queue.new
    handler = ->(_stdin) { release.pop; ["the distilled snapshot", "", FakeStatus.new(true)] }

    with_fake_claude(handler) do
      _s, _c, out = server.respond("POST", "/api/action", ok_host, JSON.generate("cmd" => "distill", "slug" => "big"))
      result = JSON.parse(out)
      assert result["ok"]
      assert result["background"]
      assert_equal 1, result["sessions"]

      state = state_of(server)
      assert_equal ["big"], state["distilling"]
      assert_empty state["distilled"]

      # Other actions are not queued behind the running distill.
      _s, _c, out = server.respond("POST", "/api/action", ok_host,
                                   JSON.generate("cmd" => "state", "slug" => "big", "args" => { "state" => "fridge" }))
      assert JSON.parse(out)["ok"]

      _s, _c, out = server.respond("POST", "/api/action", ok_host, JSON.generate("cmd" => "distill", "slug" => "big"))
      assert_includes JSON.parse(out)["error"], "already being distilled"

      release << :go
      settled = wait_until_settled(server)
      assert_equal [{ "ok" => true, "sessions" => 1, "slug" => "big" }], settled["distilled"]
    end

    assert_empty state_of(server)["distilled"]
    assert Quartermaster::WorkItem.find("big").snapshot_for?("sess-big")
  end

  def test_gui_distill_failures_reach_the_page_as_a_finished_job
    big_transcript_item(bytes: 100)
    server = gui
    handler = ->(_stdin) { ["Some API error", "", FakeStatus.new(false)] }

    finished = with_fake_claude(handler) do
      server.respond("POST", "/api/action", ok_host, JSON.generate("cmd" => "distill", "slug" => "big"))
      wait_until_settled(server)["distilled"]
    end

    assert_equal 1, finished.size
    refute finished.first["ok"]
    assert_match(/claude -p failed: Some API error/, finished.first["error"])
  end

  def test_gui_distill_guards_answer_before_anything_runs_in_the_background
    big_transcript_item(bytes: 100)
    Quartermaster::WorkItem.find("big").add_snapshot("sess-big", "already distilled")
    server = gui

    _s, _c, out = server.respond("POST", "/api/action", ok_host, JSON.generate("cmd" => "distill", "slug" => "big"))
    result = JSON.parse(out)
    assert result["needs_confirmation"]
    assert_empty state_of(server)["distilling"]
  end
end

class AskSearchTest < Minitest::Test
  include QmTestHelpers

  FakeStatus = Struct.new(:ok) do
    def success? = ok
  end

  def answer(*hits)
    JSON.generate("type" => "result", "structured_output" => { "hits" => hits })
  end

  # Replaces the headless-claude seam: handler gets [argv, stdin] and returns
  # [stdout, stderr, status].
  def with_fake_claude(handler)
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) { |*argv, stdin_data: nil, **| handler.call(argv, stdin_data) }
    yield
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  def test_index_carries_each_items_fields_with_the_newest_notes_first_within_budget
    item = Quartermaster::WorkItem.create("Resume after adoption", project: "No project", description: "why resume broke")
    item.add_note("the oldest note")
    30.times { |n| item.add_note("filler #{n} #{"x" * 280}") }
    item.add_note("the newest note")

    index = Quartermaster::AskSearch.new.index
    assert_includes index, "## resume-after-adoption"
    assert_includes index, "title: Resume after adoption"
    assert_includes index, "description: why resume broke"
    assert_includes index, "the newest note"
    refute_includes index, "the oldest note"
    assert_operator index.size, :<, Quartermaster::AskSearch::NOTES_CHARS + 500
  end

  def test_ask_returns_ranked_hits_for_real_items_only
    Quartermaster::WorkItem.create("Alpha", project: "No project")
    Quartermaster::WorkItem.create("Beta", project: "No project")
    argv_seen = nil
    handler = lambda do |argv, _stdin|
      argv_seen = argv
      [answer({ "slug" => "beta", "why" => "b" }, { "slug" => "ghost", "why" => "invented" },
              { "slug" => "alpha", "why" => "a" }, { "slug" => "beta", "why" => "dupe" }), "", FakeStatus.new(true)]
    end

    hits = with_fake_claude(handler) { Quartermaster::AskSearch.new.call("which one?") }

    assert_equal [{ "slug" => "beta", "why" => "b" }, { "slug" => "alpha", "why" => "a" }], hits
    assert_includes argv_seen.join(" "), "Query: which one?"
    assert_includes argv_seen, "--json-schema"
  end

  def test_ask_surfaces_claude_failures_and_empty_queries
    Quartermaster::WorkItem.create("Alpha", project: "No project")
    assert_raises(ArgumentError) { Quartermaster::AskSearch.new.call("  ") }

    error = with_fake_claude(->(*) { ["Some API error", "", FakeStatus.new(false)] }) do
      assert_raises(ArgumentError) { Quartermaster::AskSearch.new.call("anything") }
    end
    assert_match(/claude -p failed: Some API error/, error.message)
  end

  def test_gui_ask_endpoint_answers_without_the_action_mutex
    Quartermaster::WorkItem.create("Alpha", project: "No project")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
    host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
    handler = ->(*) { [answer({ "slug" => "alpha", "why" => "it is alpha" }), "", FakeStatus.new(true)] }

    out = with_fake_claude(handler) do
      server.instance_variable_get(:@mutex).synchronize do
        Timeout.timeout(2) { server.respond("POST", "/api/ask", host, JSON.generate("query" => "the first one"))[2] }
      end
    end
    assert_equal({ "ok" => true, "hits" => [{ "slug" => "alpha", "why" => "it is alpha" }] }, JSON.parse(out))

    _s, _c, out = server.respond("POST", "/api/ask", host, JSON.generate("query" => ""))
    assert_equal({ "ok" => false, "error" => "query is empty" }, JSON.parse(out))
  end
end
