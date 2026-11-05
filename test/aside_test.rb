# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/aside_test.rb`).
require_relative "test_helper"

module AsideHelpers
  def write_transcript(entries)
    path = File.join(Quartermaster::TRANSCRIPTS_DIR, "aside-#{rand(1_000_000)}.jsonl")
    File.write(path, entries.map { |e| JSON.generate(e) }.join("\n") + "\n")
    path
  end

  def assistant(id, *blocks) = { "type" => "assistant", "message" => { "id" => id, "role" => "assistant", "content" => blocks } }
  def text(t) = { "type" => "text", "text" => t }
  def model_says(model) = assistant("m-#{rand(1_000_000)}", text("hi")).tap { |e| e["message"]["model"] = model }
  def user(t) = { "type" => "user", "message" => { "role" => "user", "content" => t } }

  def log_aside_start(session_id, slug, transcript, pid: Process.pid)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => Dir.home,
                                         "transcript_path" => transcript, "aside" => slug, "pid" => pid, "ts" => Time.now.iso8601)
  end
end

class AsideHookTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def start_input(id, cwd: "/") = JSON.generate("session_id" => id, "cwd" => cwd, "source" => "startup")

  def test_an_aside_gets_the_digest_but_is_never_linked
    Quartermaster::WorkItem.create("Asked about", project: "No project", description: "The item's truth")

    stdout, _stderr, status = run_hook("hook-session-start", start_input("sess-aside"), { "QM_ASIDE" => "asked-about" })

    assert_equal 0, status.exitstatus
    assert_includes stdout, "aside about work item 'asked-about'"
    assert_includes stdout, "The item's truth"
    refute_includes stdout, "linked to work item", "the aside must not be told it is the item's chat"
    assert_empty Quartermaster::WorkItem.find("asked-about").sessions
    event = logged_events.fetch(0)
    assert_equal "asked-about", event["aside"]
    assert_nil event["work_item"]
  end

  # QM_ITEM may leak into the aside's environment (a GUI started from a
  # qm-launched session); the aside marker must win.
  def test_the_aside_marker_wins_over_qm_item
    Quartermaster::WorkItem.create("Mine", project: "No project")

    run_hook("hook-session-start", start_input("sess-both"), { "QM_ASIDE" => "mine", "QM_ITEM" => "mine" })

    assert_empty Quartermaster::WorkItem.find("mine").sessions
  end

  def test_the_aside_marker_wins_over_a_branch_match
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "issue/9-asked", dir)
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Repo" => dir } }.to_yaml)
      Quartermaster::WorkItem.create("Asked", project: "Repo", branch: "issue/9-asked")

      run_hook("hook-session-start", start_input("sess-branch", cwd: dir), { "QM_ASIDE" => "asked" })

      assert_empty Quartermaster::WorkItem.find("asked").sessions
    end
  end

  def test_an_unknown_aside_slug_is_silent_and_still_unlinked
    stdout, _stderr, status = run_hook("hook-session-start", start_input("sess-ghost"), { "QM_ASIDE" => "no-such-item" })

    assert_equal 0, status.exitstatus
    assert_empty stdout
    assert_equal "no-such-item", logged_events.fetch(0)["aside"]
  end

  def test_asides_stay_out_of_the_inbox_and_the_items_sessions
    Quartermaster::WorkItem.create("Quiet", project: "No project")
    run_hook("hook-session-start", start_input("sess-quiet"), { "QM_ASIDE" => "quiet" })
    run_hook("hook-session-start", start_input("sess-plain"))

    assert_equal ["sess-plain"], Quartermaster::SessionLog.new.inbox.map(&:id)
    assert_empty Quartermaster.item_sessions(Quartermaster::WorkItem.find("quiet"))
    stdout, = run_hook("sessions", "")
    assert_match(/sess-qui.*aside:quiet/, stdout, "listings mark an aside rather than showing it unowned")
  end

  def test_record_event_logs_nothing_for_an_aside
    _out, _err, status = run_sh("record-event.sh", '{"session_id":"s","hook_event_name":"Stop"}', "QM_ASIDE" => "x")

    assert status.success?
    refute File.exist?(events_path), "an aside never asks for attention"
  end
end

class AsideTest < Minitest::Test
  include QmTestHelpers
  include AsideHelpers

  def test_last_answer_joins_the_final_messages_blocks_and_skips_tool_only_entries
    transcript = write_transcript([
                                    user("question"),
                                    assistant("m1", text("first thought")),
                                    assistant("m2", text("Final answer,"), { "type" => "tool_use", "name" => "Bash" }),
                                    assistant("m2", text("part two.")),
                                    assistant("m3", { "type" => "tool_use", "name" => "Read" }),
                                    { "type" => "user", "message" => { "content" => [{ "type" => "tool_result" }] } }
                                  ])

    assert_equal "Final answer,\n\npart two.", Quartermaster::Aside.last_answer_in(transcript)
  end

  def test_last_answer_is_nil_without_a_transcript_or_an_answer
    assert_nil Quartermaster::Aside.last_answer_in(nil)
    assert_nil Quartermaster::Aside.last_answer_in(write_transcript([user("only a question")]))
  end

  def test_promote_notes_the_running_asides_last_answer_on_one_line
    item = Quartermaster::WorkItem.create("Promoted", project: "No project")
    log_aside_start("old", "promoted", write_transcript([assistant("a", text("stale"))]), pid: nil)
    log_aside_start("new", "promoted", write_transcript([assistant("b", text("Use the\n\nsecond   way."))]))
    log_aside_start("other", "someone-else", write_transcript([assistant("c", text("not ours"))]))

    note = Quartermaster::Aside.new(tmux: FakeTmux.new).promote(item)

    assert_equal "aside: Use the second way.", note
    stored = Quartermaster::WorkItem.find("promoted").notes.first
    assert_equal "aside: Use the second way.", stored.text
    assert_equal Quartermaster::DEFAULT_NOTE_KIND, stored.kind
  end

  def test_promote_refuses_when_there_is_no_answer
    item = Quartermaster::WorkItem.create("Empty", project: "No project")
    # A closed aside's answer, while the fresh one's start is not logged yet.
    log_aside_start("closed", "empty", write_transcript([assistant("a", text("an earlier aside's"))]), pid: nil)

    assert_raises(ArgumentError) { Quartermaster::Aside.new(tmux: FakeTmux.new).promote(item) }
    assert_empty Quartermaster::WorkItem.find("empty").notes
  end

  def test_open_runs_the_chosen_model_marked_as_an_aside
    item = Quartermaster::WorkItem.create("Side", project: "No project")
    tmux = FakeTmux.new
    aside = Quartermaster::Aside.new(tmux: tmux)

    assert aside.open(item)
    assert_equal({ name: "side--aside", cwd: Dir.home, argv: %w[claude --model sonnet],
                   env: { "QM_ASIDE" => "side", "QM_ITEM" => "" } }, tmux.opened.first)
    refute aside.open(item, model: "opus"), "one aside per item"
    assert_raises(ArgumentError) { Quartermaster::Aside.new(tmux: FakeTmux.new).open(item, model: "gpt") }

    assert aside.close(item)
    refute aside.live?(item)
  end

  def test_history_lists_the_items_asides_newest_first_with_their_answers
    item = Quartermaster::WorkItem.create("Asked", project: "No project")
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "older", "cwd" => Dir.home, "aside" => "asked",
                                         "transcript_path" => write_transcript([user("why?"), assistant("a", text("Because\n\nso."))]),
                                         "ts" => "2026-10-01T10:00:00+02:00")
    log_aside_start("newer", "asked", write_transcript([user("how?")]))
    log_aside_start("theirs", "someone-else", write_transcript([assistant("c", text("not ours"))]))
    item.add_note("aside: Because so.")

    rows = Quartermaster::Aside.new(tmux: FakeTmux.new).history(item)

    assert_equal %w[newer older], rows.map { |r| r["id"] }
    assert_equal ["how?", nil, false], rows[0].values_at("prompt", "answer", "promoted")
    assert_nil rows[1]["model"], "a transcript without one names no model"
    assert_equal ["why?", "Because\n\nso.", true], rows[1].values_at("prompt", "answer", "promoted")
  end

  def test_promote_takes_an_earlier_asides_answer_by_session
    item = Quartermaster::WorkItem.create("Later", project: "No project")
    log_aside_start("closed", "later", write_transcript([assistant("a", text("from before"))]), pid: nil)

    assert_equal "aside: from before", Quartermaster::Aside.new(tmux: FakeTmux.new).promote(item, session_id: "closed")
    assert_raises(ArgumentError) { Quartermaster::Aside.new(tmux: FakeTmux.new).promote(item, session_id: "nope") }
  end

  def test_the_model_is_the_last_real_assistant_messages
    transcript = write_transcript([model_says("claude-sonnet-5-5"), user("/model opus"), model_says("claude-opus-5-5"), model_says("<synthetic>")])
    assert_equal "claude-opus-5-5", Quartermaster::Aside.model_in(transcript)
    assert_nil Quartermaster::Aside.model_in(write_transcript([user("only a question")]))
  end

  def test_reopen_resumes_an_earlier_aside_under_its_marker_one_at_a_time
    item = Quartermaster::WorkItem.create("Again", project: "No project")
    log_aside_start("before", "again", write_transcript([model_says("claude-haiku-5-5"), model_says("<synthetic>")]), pid: nil)
    log_aside_start("theirs", "someone-else", write_transcript([assistant("b", text("hi"))]), pid: nil)
    tmux = FakeTmux.new
    aside = Quartermaster::Aside.new(tmux: tmux)

    assert_raises(ArgumentError) { aside.reopen(item, "theirs") }
    assert aside.reopen(item, "before")
    assert_equal({ name: "again--aside", cwd: Dir.home, argv: %w[claude --model claude-haiku-5-5 --resume before],
                   env: { "QM_ASIDE" => "again", "QM_ITEM" => "" } }, tmux.opened.first)
    assert_raises(ArgumentError) { aside.reopen(item, "before") }
  end
end

class GuiAsideTest < Minitest::Test
  include QmTestHelpers
  include AsideHelpers

  def host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def post(server, payload) = JSON.parse(server.respond("POST", "/api/action", host, JSON.generate(payload))[2])
  def state_of(server) = JSON.parse(server.respond("GET", "/api/state", host, "")[2])

  def test_the_drawer_opens_promotes_and_closes_an_aside_beside_the_chat
    tmux = FakeTmux.new(["drawer"])
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    Quartermaster::WorkItem.create("Drawer", project: "No project")

    reply = post(server, "cmd" => "aside-open", "slug" => "drawer", "args" => { "model" => "haiku" })
    assert_equal({ "ok" => true, "session" => "drawer--aside", "attached" => false }, reply)
    assert_equal %w[claude --model haiku], tmux.opened.first[:argv]

    state = state_of(server)
    item = state["items"].find { |i| i["slug"] == "drawer" }
    assert_equal true, item["aside"]
    assert_equal true, item["pane"], "the item's own chat is untouched"
    assert_equal %w[sonnet opus haiku], state["asideModels"]

    log_aside_start("sess-d", "drawer", write_transcript([assistant("x", text("42"))]))
    assert_equal "aside: 42", post(server, "cmd" => "aside-promote", "slug" => "drawer")["note"]

    assert_equal true, post(server, "cmd" => "aside-close", "slug" => "drawer")["ok"]
    assert_equal ["drawer"], tmux.sessions
    assert_equal true, post(server, "cmd" => "aside-close", "slug" => "drawer")["ok"], "closing twice is fine"
  end

  def test_a_bad_model_or_an_empty_aside_is_a_json_error
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    Quartermaster::WorkItem.create("Errs", project: "No project")

    assert_match(/unknown model/, post(server, "cmd" => "aside-open", "slug" => "errs", "args" => { "model" => "gpt" })["error"])
    assert_match(/no answer/, post(server, "cmd" => "aside-promote", "slug" => "errs")["error"])
    assert_match(/not an aside/, post(server, "cmd" => "aside-reopen", "slug" => "errs", "args" => { "session" => "x" })["error"])
  end

  def test_earlier_asides_load_on_demand_and_only_their_count_is_in_the_state
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    Quartermaster::WorkItem.create("Counted", project: "No project")
    log_aside_start("one", "counted", write_transcript([user("q"), assistant("a", text("answer"))]), pid: nil)

    item = state_of(server)["items"].find { |i| i["slug"] == "counted" }
    assert_equal 1, item["asideCount"]
    refute item.key?("asides"), "transcripts are read on demand, not every poll"
    assert_empty item["sessionList"]

    rows = JSON.parse(server.respond("GET", "/api/asides/counted", host, "")[2])["asides"]
    assert_equal [%w[one q answer]], rows.map { |r| r.values_at("id", "prompt", "answer") }
    assert_equal "aside: answer", post(server, "cmd" => "aside-promote", "slug" => "counted", "args" => { "session" => "one" })["note"]
  end
end
