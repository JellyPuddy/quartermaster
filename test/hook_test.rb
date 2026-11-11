# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/hook_test.rb`).
require_relative "test_helper"

# Every way a session can be claimed for an item must leave it on exactly that
# item — the fzf inbox paths once shipped without the detach half, so each new
# claiming entry point earns a row here rather than its own hand-rolled test.
class ClaimParityTest < Minitest::Test
  include QmTestHelpers

  SESSION = "sess-parity"

  def gui_post(cmd, args, slug: nil)
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
    body = JSON.generate({ "cmd" => cmd, "slug" => slug, "args" => args })
    _s, _c, out = gui.respond("POST", "/api/action", { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }, body)
    res = JSON.parse(out)
    raise res["error"] unless res["ok"]
  end

  # Each entry point claims SESSION (already attached to alpha) and returns
  # the slug it should now exclusively live on.
  ENTRY_POINTS = {
    "cmd_attach" => lambda {
      Quartermaster::WorkItem.create("Beta", project: "MyApp")
      capture_io { Quartermaster::CLI.new.run(["attach", "beta", "--session", SESSION]) }
      "beta"
    },
    "cmd_new" => lambda {
      capture_io { Quartermaster::CLI.new.run(["new", "Beta item", "--project", "MyApp", "--session", SESSION]) }
      "beta-item"
    },
    "cmd_attach_session" => lambda {
      Quartermaster::WorkItem.create("Beta", project: "MyApp")
      capture_io { with_picked("beta\tBeta") { Quartermaster::CLI.new.run(["attach-session", SESSION]) } }
      "beta"
    },
    "cmd_item_from_session" => lambda {
      capture_io { with_stdin("Beta item\n") { Quartermaster::CLI.new.run(["item-from-session", SESSION]) } }
      "beta-item"
    },
    "gui_attach" => lambda {
      Quartermaster::WorkItem.create("Beta", project: "MyApp")
      gui_post("attach", { "session" => SESSION }, slug: "beta")
      "beta"
    },
    "gui_item_from_session" => lambda {
      gui_post("item-from-session", { "session" => SESSION, "title" => "Beta item" })
      "beta-item"
    }
  }.freeze

  ENTRY_POINTS.each do |name, claim|
    define_method("test_#{name}_leaves_the_session_on_exactly_one_item") do
      Quartermaster::WorkItem.create("Alpha", project: "MyApp", session_id: SESSION)
      Quartermaster::SessionLog.new.append(
        "event" => "start", "session_id" => SESSION, "ts" => Time.now.utc.iso8601,
        "project" => "MyApp", "branch" => "main"
      )

      home = instance_exec(&claim)

      holders = Quartermaster::WorkItem.all.select { |i| i.sessions.any? { |s| s["id"] == SESSION } }
      assert_equal [home], holders.map(&:slug)
    end

    # On the suite's QM_TMUX_SOCKET server, which CLI and GUI both default to.
    define_method("test_#{name}_takes_the_chat_pane_along") do
      skip "tmux not installed" unless system("command -v tmux >/dev/null")
      tmux = Quartermaster::Tmux.new
      tmux.open("alpha", cwd: Dir.home, argv: %w[sleep 300])
      Quartermaster::WorkItem.create("Alpha", project: "MyApp", session_id: SESSION)
      Quartermaster::SessionLog.new.append(
        "event" => "start", "session_id" => SESSION, "ts" => Time.now.utc.iso8601,
        "project" => "MyApp", "branch" => "main", "pid" => tmux.pane_pid("alpha")
      )

      home = instance_exec(&claim)

      assert tmux.live?(home), "the pane is named after the item its session moved to"
      refute tmux.live?("alpha")
    ensure
      tmux&.sessions&.each { |s| tmux.kill(s) }
    end
  end
end

class HookTest < Minitest::Test
  include QmTestHelpers

  START_INPUT = {
    "session_id" => "sess-hook-1", "cwd" => "/", "transcript_path" => "/tmp/t.jsonl",
    "hook_event_name" => "SessionStart", "source" => "startup"
  }.freeze

  def test_session_start_records_a_versioned_event
    stdout, stderr, status = run_hook("hook-session-start", JSON.generate(START_INPUT))

    assert_equal 0, status.exitstatus
    assert_empty stderr

    event = logged_events.fetch(0)
    assert_equal Quartermaster::EVENT_VERSION, event["v"]
    assert_equal "start", event["event"]
    assert_equal "sess-hook-1", event["session_id"]
    assert_equal "startup", event["source"]
    assert_equal "/tmp/t.jsonl", event["transcript_path"]
    assert_equal "No project", event["project"]
    assert_nil event["work_item"]
    refute_nil event["ts"]

    assert_includes stdout, "not linked to a work item"
    assert_includes stdout, "(none yet)"
  end

  def test_session_end_pairs_with_its_start_to_derive_duration
    run_hook("hook-session-start", JSON.generate(START_INPUT))
    _stdout, _stderr, status = run_hook(
      "hook-session-end",
      JSON.generate(START_INPUT.merge("hook_event_name" => "SessionEnd", "reason" => "other"))
    )

    assert_equal 0, status.exitstatus
    event = logged_events.fetch(1)
    assert_equal "end", event["event"]
    assert_equal "other", event["reason"]
    assert_operator event["duration_s"], :>=, 0
  end

  def test_hooks_swallow_malformed_input_instead_of_blocking_the_session
    stdout, stderr, status = run_hook("hook-session-start", "not json at all")

    assert_equal 0, status.exitstatus
    assert_empty stdout
    assert_empty stderr
    refute_path_exists File.join(Quartermaster::ROOT, "sessions.jsonl")
    assert_match(/hook-session-start.*JSON::ParserError/, File.read(File.join(Quartermaster::ROOT, "qm.log")))
  end

  def test_wi_skip_disables_capture
    _stdout, _stderr, status = run_hook("hook-session-start", JSON.generate(START_INPUT), { "QM_SKIP" => "1" })

    assert_equal 0, status.exitstatus
    refute_path_exists File.join(Quartermaster::ROOT, "sessions.jsonl")
  end
end

class HookLinkingTest < Minitest::Test
  include QmTestHelpers

  def test_wi_item_env_var_links_and_injects_the_work_item
    Quartermaster::WorkItem.create("Launched item", project: "No project", description: "Launched from viewer")

    stdout, _stderr, status = run_hook(
      "hook-session-start",
      JSON.generate("session_id" => "sess-l1", "cwd" => "/", "source" => "startup"),
      { "QM_ITEM" => "launched-item" }
    )

    assert_equal 0, status.exitstatus
    assert_includes stdout, "linked to work item 'launched-item'"
    assert_includes stdout, "Launched from viewer"
    assert_equal "launched-item", logged_events.fetch(0)["work_item"]
    assert_equal [{ "id" => "sess-l1" }], Quartermaster::WorkItem.find("launched-item").sessions
  end

  def test_matching_branch_and_project_links_automatically
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "issue/42-fix-thing", dir)
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Repo" => dir } }.to_yaml)
      Quartermaster::WorkItem.create("Fix thing", project: "Repo", branch: "issue/42-fix-thing")
      Quartermaster::WorkItem.create("Unrelated", project: "Repo", branch: "issue/7-other")

      stdout, _stderr, _status = run_hook(
        "hook-session-start",
        JSON.generate("session_id" => "sess-b1", "cwd" => dir, "source" => "startup")
      )

      assert_includes stdout, "linked to work item 'fix-thing'"
      assert_equal "fix-thing", logged_events.fetch(0)["work_item"]
      assert_equal [{ "id" => "sess-b1" }], Quartermaster::WorkItem.find("fix-thing").sessions
      assert_empty Quartermaster::WorkItem.find("unrelated").sessions
    end
  end

  def test_any_branch_of_a_stack_matches
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "issue/42-part-2", dir)
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Repo" => dir } }.to_yaml)
      Quartermaster::WorkItem.create("Stacked", project: "Repo", branch: "issue/42-part-1").link_branch("issue/42-part-2")

      stdout, _stderr, _status = run_hook(
        "hook-session-start",
        JSON.generate("session_id" => "sess-s2", "cwd" => dir, "source" => "startup")
      )

      assert_includes stdout, "linked to work item 'stacked'"
    end
  end

  # Epics (docs/areas/linking.md): never guessed, only attached on purpose.
  def epic_repo(branch)
    dir = Dir.mktmpdir
    system("git", "init", "-q", "-b", branch, dir)
    system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
           "commit", "-q", "--allow-empty", "-m", "init")
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Repo" => dir } }.to_yaml)
    dir
  end

  def create_epic(title = "Epic Alpha", **opts)
    Quartermaster::WorkItem.create(title, project: "Repo", front: { "kind" => "epic" }, **opts)
  end

  def test_a_branch_match_never_links_a_session_to_an_epic
    dir = epic_repo("issue/9-planning")
    create_epic(branch: "issue/9-planning")

    stdout, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-e1", "cwd" => dir, "source" => "startup"))

    assert_includes stdout, "not linked to a work item"
    assert_empty Quartermaster::WorkItem.find("epic-alpha").sessions
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def test_a_branch_shared_by_an_epic_and_its_child_links_the_child
    dir = epic_repo("issue/9-part")
    create_epic(branch: "issue/9-part")
    Quartermaster::WorkItem.create("Child one", project: "Repo", branch: "issue/9-part", front: { "epic" => "epic-alpha" })

    stdout, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-e2", "cwd" => dir, "source" => "startup"))

    assert_includes stdout, "linked to work item 'child-one'"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def test_the_unlinked_shortlist_leaves_epics_out
    create_epic
    Quartermaster::WorkItem.create("Open thing", project: "Repo")

    stdout, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-e3", "cwd" => "/", "source" => "startup"))

    assert_includes stdout, "open-thing"
    refute_includes stdout, "epic-alpha"
  end

  def test_a_child_session_is_told_its_epic_in_one_line
    create_epic(description: "Ship the new grading flow.\nSecond line stays out.")
    Quartermaster::WorkItem.create("Child one", project: "Repo", session_id: "sess-e4", front: { "epic" => "epic-alpha" })

    stdout, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-e4", "cwd" => "/", "source" => "resume"))

    assert_includes stdout, "Epic: Epic Alpha (epic-alpha) — Ship the new grading flow.\n"
    refute_includes stdout, "Second line stays out"
  end

  def test_an_epic_without_a_description_is_named_without_the_placeholder
    create_epic
    Quartermaster::WorkItem.create("Child one", project: "Repo", session_id: "sess-e8", front: { "epic" => "epic-alpha" })

    stdout, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-e8", "cwd" => "/", "source" => "resume"))

    assert_includes stdout, "Epic: Epic Alpha (epic-alpha)\n"
  end

  def test_a_child_of_a_dangling_epic_gets_no_epic_line
    Quartermaster::WorkItem.create("Plain", project: "Repo", session_id: "sess-e5")
    path = Quartermaster::WorkItem.path_for("plain")
    File.write(path, File.read(path).sub("project: Repo", "project: Repo\nepic: gone"))

    stdout, _stderr, status = run_hook("hook-session-start", JSON.generate("session_id" => "sess-e5", "cwd" => "/", "source" => "resume"))

    assert_equal 0, status.exitstatus
    assert_includes stdout, "linked to work item 'plain'"
    refute_includes stdout, "Epic:"
  end

  def test_a_chat_started_from_an_epic_links_and_lists_its_children
    create_epic
    Quartermaster::WorkItem.create("Child one", project: "Repo", front: { "epic" => "epic-alpha" })
    Quartermaster::WorkItem.create("Child two", project: "Repo", front: { "epic" => "epic-alpha" }).update_state("fridge")
    Quartermaster::WorkItem.create("Elsewhere", project: "Repo")

    stdout, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-e6", "cwd" => "/", "source" => "startup"),
                       { "QM_ITEM" => "epic-alpha" })

    assert_includes stdout, "linked to work item 'epic-alpha'"
    assert_includes stdout, "Children of this epic:\n- child-one [in_progress] Child one\n- child-two [fridge] Child two\n"
    refute_includes stdout, "elsewhere"
    assert_equal [{ "id" => "sess-e6" }], Quartermaster::WorkItem.find("epic-alpha").sessions
  end

  def test_an_aside_on_a_child_gets_no_epic_line
    create_epic
    Quartermaster::WorkItem.create("Child one", project: "Repo", front: { "epic" => "epic-alpha" })

    stdout, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-e7", "cwd" => "/", "source" => "startup"),
                       { "QM_ASIDE" => "child-one" })

    assert_includes stdout, "is an aside"
    refute_includes stdout, "Epic:"
  end

  def test_resumed_sessions_recognize_the_item_they_are_already_attached_to
    Quartermaster::WorkItem.create("Ongoing", project: "No project", session_id: "sess-r1")

    stdout, _stderr, _status = run_hook(
      "hook-session-start",
      JSON.generate("session_id" => "sess-r1", "cwd" => "/", "source" => "resume")
    )

    assert_includes stdout, "linked to work item 'ongoing'"
    assert_equal "ongoing", logged_events.fetch(0)["work_item"]
  end

  def test_the_linked_protocol_offers_an_exit_for_misattributed_sessions
    Quartermaster::WorkItem.create("Ongoing", project: "No project", session_id: "sess-r2")

    stdout, _stderr, _status = run_hook(
      "hook-session-start",
      JSON.generate("session_id" => "sess-r2", "cwd" => "/", "source" => "resume")
    )

    assert_includes stdout, "qm attach <other-slug> --session sess-r2"
    assert_includes stdout, "qm detach ongoing --session sess-r2"
    assert_includes stdout, "don't mention tracking again"
    assert_includes stdout, "re-link it then and there"
  end

  def test_only_a_linked_session_is_told_about_qm_todo
    Quartermaster::WorkItem.create("Ongoing", project: "No project", session_id: "sess-t1")
    input = ->(id) { JSON.generate("session_id" => id, "cwd" => "/", "source" => "startup") }

    linked, = run_hook("hook-session-start", input.call("sess-t1"))
    aside, = run_hook("hook-session-start", input.call("sess-t2"), { "QM_ASIDE" => "ongoing" })
    loose, = run_hook("hook-session-start", input.call("sess-t3"), { "QM_LOOSE" => "ab12cd34" })

    assert_includes linked, "something needs their own hands outside this session: qm todo add \"…\" [--item ongoing]"
    assert_includes aside, "work item 'ongoing'"
    refute_includes aside, "qm todo"
    assert_includes loose, "loose chat"
    refute_includes loose, "qm todo"
  end

  def test_a_session_moved_off_its_launch_item_stays_moved_on_compact
    Quartermaster::WorkItem.create("Launched", project: "No project")
    input = { "session_id" => "sess-mv", "cwd" => "/", "source" => "startup" }
    run_hook("hook-session-start", JSON.generate(input), { "QM_ITEM" => "launched" })
    Quartermaster::WorkItem.create("Next issue", project: "No project").claim_session("sess-mv")

    stdout, _stderr, _status = run_hook("hook-session-start", JSON.generate(input.merge("source" => "compact")),
                                        { "QM_ITEM" => "launched" })

    assert_includes stdout, "linked to work item 'next-issue'"
    assert_empty Quartermaster::WorkItem.find("launched").sessions
    assert_equal [{ "id" => "sess-mv" }], Quartermaster::WorkItem.find("next-issue").sessions
  end

  def test_the_injected_digest_trims_old_notes_and_omits_session_ids
    item = Quartermaster::WorkItem.create("Long runner", project: "No project", session_id: "sess-d1")
    item.describe("The durable shape of the work.")
    8.times { |i| item = Quartermaster::WorkItem.find("long-runner").tap { |w| w.add_note("note number #{i}") } }

    stdout, _stderr, _status = run_hook(
      "hook-session-start",
      JSON.generate("session_id" => "sess-d1", "cwd" => "/", "source" => "resume")
    )

    assert_includes stdout, "The durable shape of the work."
    assert_includes stdout, "note number 7"
    assert_includes stdout, "note number 3"
    refute_includes stdout, "note number 2"
    assert_includes stdout, "5 of 8"
    assert_includes stdout, "qm show long-runner"
    refute_includes stdout, "sess-d1\n"
    assert_includes stdout, "sessions: 1 (ids in the file)"
  end

  def test_the_digest_carries_a_status_board_only_when_the_item_has_one
    Quartermaster::WorkItem.create("Boarded", project: "No project", session_id: "sess-sb1")
      .link_board("https://claude.ai/code/artifact/9999")
    Quartermaster::WorkItem.create("Boardless", project: "No project", session_id: "sess-sb2")

    with_board, = run_hook("hook-session-start",
                           JSON.generate("session_id" => "sess-sb1", "cwd" => "/", "source" => "resume"))
    without_board, = run_hook("hook-session-start",
                              JSON.generate("session_id" => "sess-sb2", "cwd" => "/", "source" => "resume"))

    assert_includes with_board, "status board: https://claude.ai/code/artifact/9999"
    refute_includes without_board, "status board:"
  end

  def test_a_short_item_is_injected_whole_without_a_truncation_notice
    item = Quartermaster::WorkItem.create("Brief", project: "No project", session_id: "sess-d2")
    item.add_note("the only note")

    stdout, _stderr, _status = run_hook(
      "hook-session-start",
      JSON.generate("session_id" => "sess-d2", "cwd" => "/", "source" => "resume")
    )

    assert_includes stdout, "the only note"
    refute_includes stdout, "newest of"
    refute_includes stdout, "qm show brief"
  end

  def test_history_notes_are_never_injected_and_open_notes_always_are
    item = Quartermaster::WorkItem.create("Tagged", project: "No project", session_id: "sess-k1")
    item.add_note("the blocker: nothing writes role:coach yet", kind: "open")
    6.times { |i| item.add_note("rebased and folded #{i}", kind: "history") }
    3.times { |i| item.add_note("chose approach #{i}") }

    stdout, _stderr, _status = run_hook(
      "hook-session-start",
      JSON.generate("session_id" => "sess-k1", "cwd" => "/", "source" => "resume")
    )

    assert_includes stdout, "the blocker: nothing writes role:coach yet"
    assert_includes stdout, "chose approach 0"
    refute_includes stdout, "rebased and folded"
    assert_includes stdout, "- #1 #{Date.today} [open]:"
  end

  def test_an_open_note_survives_far_past_the_recency_window
    item = Quartermaster::WorkItem.create("Blocked", project: "No project", session_id: "sess-k2")
    item.add_note("awaiting the user's call on the group label", kind: "open")
    20.times { |i| item.add_note("decision #{i}") }

    stdout, _stderr, _status = run_hook(
      "hook-session-start",
      JSON.generate("session_id" => "sess-k2", "cwd" => "/", "source" => "resume")
    )

    assert_includes stdout, "awaiting the user's call on the group label"
    refute_includes stdout, "decision 0"
  end

  def test_retagging_a_handled_open_note_drops_it_out_of_the_injection
    item = Quartermaster::WorkItem.create("Retagged", project: "No project", session_id: "sess-k3")
    item.add_note("blocked on the SCIM path", kind: "open")
    6.times { |i| item.add_note("decision #{i}") }

    assert_equal "history", item.update_note_kind(1, "history").kind

    stdout, _stderr, _status = run_hook(
      "hook-session-start",
      JSON.generate("session_id" => "sess-k3", "cwd" => "/", "source" => "resume")
    )

    refute_includes stdout, "blocked on the SCIM path"
    assert_equal "history", Quartermaster::WorkItem.find("retagged").notes.last.kind
  end

  def test_retagging_rejects_unknown_kinds_and_positions_without_touching_the_file
    item = Quartermaster::WorkItem.create("Guarded", project: "No project")
    item.add_note("only note")
    before = File.read(Quartermaster::WorkItem.path_for("guarded"))

    assert_raises(ArgumentError) { item.update_note_kind(1, "urgent") }
    assert_raises(ArgumentError) { item.update_note_kind(9, "history") }
    assert_raises(ArgumentError) { item.update_note_kind(0, "history") }
    assert_equal before, File.read(Quartermaster::WorkItem.path_for("guarded"))
  end

  def test_a_default_note_stays_unmarked_on_disk_and_legacy_notes_read_as_decisions
    item = Quartermaster::WorkItem.create("Plain", project: "No project")
    item.add_note("a choice")
    item.add_note("mechanics", kind: "history")
    stored = File.read(Quartermaster::WorkItem.path_for("plain"))

    assert_includes stored, "- #{Date.today}: a choice"
    assert_includes stored, "- #{Date.today} [history]: mechanics"
    assert_equal %w[decision history], Quartermaster::WorkItem.find("plain").notes.reverse.map(&:kind)
  end

  def test_an_unrecognised_kind_marker_degrades_to_the_default_instead_of_dropping_the_note
    item = Quartermaster::WorkItem.create("Weird", project: "No project")
    path = Quartermaster::WorkItem.path_for("weird")
    File.write(path, File.read(path).sub("## Notes\n", "## Notes\n- 2026-01-01 [bogus]: still readable\n"))

    note = Quartermaster::WorkItem.find("weird").notes.first

    assert_equal "still readable", note.text
    assert_equal "decision", note.kind
  end

  def test_retagging_only_rewrites_the_targeted_note
    item = Quartermaster::WorkItem.create("Precise", project: "No project")
    3.times { |i| item.add_note("note #{i}") }
    item.update_note_kind(2, "history")

    notes = Quartermaster::WorkItem.find("precise").notes.reverse

    assert_equal %w[decision history decision], notes.map(&:kind)
    assert_equal ["note 0", "note 1", "note 2"], notes.map(&:text)
  end

  def test_notes_drop_a_date_prefix_the_caller_already_wrote
    item = Quartermaster::WorkItem.create("Stamped", project: "No project")
    item.add_note("#{Date.today}: did the thing")

    assert_equal "did the thing", Quartermaster::WorkItem.find("stamped").notes.first.text
    stored = File.read(Quartermaster::WorkItem.path_for("stamped"))[/^- .*did the thing$/]
    assert_equal "- #{Date.today}: did the thing", stored
  end

  def test_unlinked_sessions_get_the_shortlist_without_resolved_items
    Quartermaster::WorkItem.create("Open thing", project: "No project")
    Quartermaster::WorkItem.create("Done thing", project: "No project").update_state("resolved")

    stdout, _stderr, _status = run_hook(
      "hook-session-start",
      JSON.generate("session_id" => "sess-u1", "cwd" => "/", "source" => "startup")
    )

    assert_includes stdout, "not linked to a work item"
    assert_includes stdout, "open-thing"
    refute_includes stdout, "done-thing"
  end

  def test_aborted_sessions_detach_from_their_work_item_and_skip_the_inbox
    Quartermaster::WorkItem.create("Launched", project: "No project")
    input = { "session_id" => "sess-aborted", "cwd" => "/", "source" => "startup",
              "transcript_path" => File.join(Quartermaster::ROOT, "never-written.jsonl") }
    run_hook("hook-session-start", JSON.generate(input), { "QM_ITEM" => "launched" })
    assert_equal [{ "id" => "sess-aborted" }], Quartermaster::WorkItem.find("launched").sessions

    run_hook("hook-session-end", JSON.generate(input.merge("reason" => "other")))

    assert_empty Quartermaster::WorkItem.find("launched").sessions
    assert Quartermaster::SessionLog.new.events.find { |e| e["event"] == "end" }["empty"]
    assert_empty Quartermaster::SessionLog.new.inbox
  end

  def test_misrecorded_transcript_paths_resolve_by_session_id
    real_home = File.join(Quartermaster::TRANSCRIPTS_DIR, "-Users-x-repo")
    FileUtils.mkdir_p(real_home)
    File.write(File.join(real_home, "sess-wt.jsonl"), "")

    assert_equal File.join(real_home, "sess-wt.jsonl"),
                 Quartermaster.locate_transcript("sess-wt", "/wrong/worktree-slug/sess-wt.jsonl")

    misrecorded = Quartermaster::Session.new(
      id: "sess-wt", live: false, last_event: nil,
      start_event: { "transcript_path" => "/wrong/worktree-slug/sess-wt.jsonl" }
    )
    assert_equal "resumable", misrecorded.tier

    Quartermaster::WorkItem.create("Worktree item", project: "No project")
    input = { "session_id" => "sess-wt", "cwd" => "/", "source" => "resume",
              "transcript_path" => "/wrong/worktree-slug/sess-wt.jsonl" }
    run_hook("hook-session-start", JSON.generate(input), { "QM_ITEM" => "worktree-item" })
    run_hook("hook-session-end", JSON.generate(input.merge("reason" => "other")))

    assert_equal [{ "id" => "sess-wt" }], Quartermaster::WorkItem.find("worktree-item").sessions
    assert_nil Quartermaster::SessionLog.new.events.find { |e| e["event"] == "end" }["empty"]
  end

  def ended_session(id, live: false) = Quartermaster::Session.new(id: id, live: live, last_event: nil, start_event: {})

  # An expired transcript is the one that keeps globbing every project dir,
  # so its miss is remembered: a file appearing later under that id goes unseen.
  def test_an_ended_sessions_missing_transcript_is_not_searched_for_again
    assert_nil ended_session("sess-gone").transcript

    path = write_transcript("sess-gone", [])
    assert_nil ended_session("sess-gone").transcript
    assert_equal path, ended_session("sess-gone", live: true).transcript
  end

  def test_a_live_sessions_missing_transcript_is_found_once_it_appears
    assert_nil ended_session("sess-new", live: true).transcript

    path = write_transcript("sess-new", [])
    assert_equal path, ended_session("sess-new", live: true).transcript
    assert_equal "resumable", ended_session("sess-new").tier
  end

  def test_a_remembered_transcript_that_was_pruned_reads_as_gone
    path = write_transcript("sess-pruned", [])
    assert_equal path, ended_session("sess-pruned").transcript

    File.delete(path)
    assert_equal "expired", ended_session("sess-pruned").tier
  end

  def test_used_sessions_stay_attached_after_ending
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      File.write(transcript, "")
      Quartermaster::WorkItem.create("Launched", project: "No project")
      input = { "session_id" => "sess-used", "cwd" => "/", "source" => "startup",
                "transcript_path" => transcript }
      run_hook("hook-session-start", JSON.generate(input), { "QM_ITEM" => "launched" })
      run_hook("hook-session-end", JSON.generate(input.merge("reason" => "other")))

      assert_equal [{ "id" => "sess-used" }], Quartermaster::WorkItem.find("launched").sessions
      assert_nil Quartermaster::SessionLog.new.events.find { |e| e["event"] == "end" }["empty"]
    end
  end

  def test_inbox_lists_only_sessions_linked_to_no_work_item
    Quartermaster::WorkItem.create("Claimed", project: "No project")
    run_hook("hook-session-start",
             JSON.generate("session_id" => "sess-claimed", "cwd" => "/", "source" => "startup"),
             { "QM_ITEM" => "claimed" })
    run_hook("hook-session-start",
             JSON.generate("session_id" => "sess-loose", "cwd" => "/", "source" => "startup"))

    stdout, _stderr, status = Open3.capture3(
      { "QM_ROOT" => Quartermaster::ROOT }, RbConfig.ruby, QM_BIN, "inbox"
    )

    assert_equal 0, status.exitstatus
    assert_includes stdout, "sess-loo"
    refute_includes stdout, "sess-cla"
  end
end
