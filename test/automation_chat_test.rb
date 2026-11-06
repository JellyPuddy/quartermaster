# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/automation_chat_test.rb`).
require_relative "test_helper"

# `qm automation new` / `edit`: the automation's item and local files, and its
# chat started with the brief qm writes (docs/areas/automations.md).
class AutomationChatTest < Minitest::Test
  include QmTestHelpers

  HOUSE_RULES = File.read(File.expand_path("../docs/automations-house-rules.md", __dir__))

  def host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def store = Quartermaster::AutomationStore.new
  def dir = Quartermaster::AUTOMATIONS_DIR

  def new_automation
    item = Quartermaster::AutomationChat.create("Shipped digest", project: "MyApp", description: "DM me what shipped.")
    item.add_note("posts to the DM channel only", kind: "decision")
    Quartermaster::WorkItem.find(item.slug)
  end

  def test_create_makes_an_in_progress_automation_item_and_empty_local_files
    item = Quartermaster::AutomationChat.create("Shipped digest", project: "MyApp")

    found = Quartermaster::WorkItem.find("shipped-digest")
    assert_equal item.slug, found.slug
    assert_equal ["automation", "cloud", nil, "in_progress", "MyApp"],
                 [found.kind, found.runner, found.routine, found.state, found.project]
    assert_equal "", File.read(File.join(dir, "shipped-digest.prompt.md"))
    assert_equal({ "v" => 1, "runner" => "cloud", "name" => "Shipped digest", "enabled" => true },
                 YAML.safe_load(File.read(File.join(dir, "shipped-digest.yml"))))
  end

  def test_create_with_runner_local_makes_a_disabled_local_automation
    Quartermaster::AutomationChat.create("Shipped digest", project: "MyApp", runner: "local")

    found = Quartermaster::WorkItem.find("shipped-digest")
    assert_equal %w[automation local in_progress], [found.kind, found.runner, found.state]
    assert_equal({ "v" => 1, "runner" => "local", "name" => "Shipped digest", "enabled" => false },
                 YAML.safe_load(File.read(File.join(dir, "shipped-digest.yml"))))
  end

  def test_create_refuses_an_unknown_runner
    error = assert_raises(ArgumentError) { Quartermaster::AutomationChat.create("Shipped digest", project: "MyApp", runner: "moon") }
    assert_equal "runner is cloud or local, got moon", error.message
    assert_raises(ArgumentError) { Quartermaster::WorkItem.find("shipped-digest") }
  end

  # The local snapshot, hand-written: local cron, the dry-run loop, no push
  # or RemoteTrigger, house rules verbatim.
  def test_local_brief_snapshot
    item = Quartermaster::AutomationChat.create("Shipped digest", project: "MyApp", description: "Draft what shipped.", runner: "local")
    expected = <<~BRIEF
      You are working on the qm automation "Shipped digest" (work item shipped-digest, project MyApp): a local automation, a Claude Code run that qm starts on this machine on a schedule. It runs unattended, with the user's own permissions. It was created disabled: its cron and guard don't run until it is enabled with `qm automation resume shipped-digest`.

      ## Its files

      - Prompt: #{dir}/shipped-digest.prompt.md (the run's prompt, nothing else; each guard item is appended to it as a final `## Item` section)
      - Settings: #{dir}/shipped-digest.yml (name, cron in Europe/Amsterdam local time, enabled, when (the guard command), flow, cwd, model, allowed_tools, permission_mode, timeout_minutes, notify; keep `v:` and any key you don't know)

      ## The loop

      1. Edit the two files.
      2. `qm automation tick --dry-run shipped-digest` runs the guard and prints the items a run would be queued for; it writes nothing.
      3. `qm automation run shipped-digest` queues a run now; a tick starts it.
      4. Read the run: `qm automation runs shipped-digest` lists its runs with their session ids; `qm show-session SESSION_ID` shows one, and its transcript is `~/.claude/projects/*/SESSION_ID.jsonl`.
      5. Refine and repeat.

      Nothing to push: qm reads the two files on every tick.
      Record each decision as a note on the item: `qm note shipped-digest --kind decision "..."`.

      ## House rules

      #{HOUSE_RULES.strip}

      ## Description

      Draft what shipped.

      ## Notes

      _none yet_
    BRIEF

    assert_equal expected, Quartermaster::AutomationChat.brief(item)
    refute_match(/RemoteTrigger|qm automation push/, Quartermaster::AutomationChat.brief(item))
  end

  def test_qm_automation_new_with_runner_local_creates_a_local_automation
    with_no_gui do
      out, = capture_io { Quartermaster::CLI.new(runner: FakeRunner.new).run(["automation", "new", "Shipped digest", "--project", "MyApp", "--runner", "local"]) }

      assert_equal "local", Quartermaster::WorkItem.find("shipped-digest").runner
      assert_equal false, store.read("shipped-digest").record["enabled"]
      assert_includes out, "shipped-digest: created (MyApp, runs locally)"
    end
  end

  def test_create_refuses_a_slug_whose_files_already_exist
    store.write("shipped-digest", { "name" => "Old" }, "keep me")

    error = assert_raises(ArgumentError) { Quartermaster::AutomationChat.create("Shipped digest", project: "MyApp") }
    assert_match(/already/, error.message)
    assert_raises(ArgumentError) { Quartermaster::WorkItem.find("shipped-digest") }
    assert_equal "keep me", store.read("shipped-digest").prompt
  end

  # The snapshot, hand-written: house rules verbatim, both absolute paths, the
  # loop, the push-only rule and decisions as notes.
  def test_brief_snapshot
    item = new_automation
    stamp = item.notes.first.stamp
    expected = <<~BRIEF
      You are working on the qm automation "Shipped digest" (work item shipped-digest, project MyApp): a claude.ai cloud routine that qm manages. It has no routine yet: the first push creates it.

      ## Its files

      - Prompt: #{dir}/shipped-digest.prompt.md (the routine's prompt, nothing else)
      - Settings: #{dir}/shipped-digest.yml (name, cron in UTC, model, sources, connectors, allowed_tools, environment_id, enabled; keep `v:` and any key you don't know)

      ## The loop

      1. Edit the two files.
      2. `qm automation push shipped-digest` sends them to the routine (the first push creates it).
      3. `qm automation run shipped-digest` runs it now.
      4. Read the run: its claude.ai link (`qm automation show shipped-digest`) or RemoteTrigger get_run_log.
      5. Refine and repeat.

      Never call RemoteTrigger create or update yourself: push is the only way a change reaches the routine.
      Record each decision as a note on the item: `qm note shipped-digest --kind decision "..."`.

      ## House rules

      #{HOUSE_RULES.strip}

      ## Description

      DM me what shipped.

      ## Notes

      - #{stamp} [decision]: posts to the DM channel only
    BRIEF

    assert_equal expected, Quartermaster::AutomationChat.brief(item)
  end

  def test_brief_names_the_routine_once_there_is_one
    item = new_automation
    item.front["routine"] = "trig_01JJ"
    item.save

    brief = Quartermaster::AutomationChat.brief(Quartermaster::WorkItem.find(item.slug))
    assert_includes brief, "Its routine is trig_01JJ (https://claude.ai/code/routines/trig_01JJ)."
    refute_includes brief, "no routine yet"
  end

  def test_brief_of_an_item_without_a_description_says_so_instead_of_the_placeholder
    item = Quartermaster::AutomationChat.create("Shipped digest", project: "MyApp")

    brief = Quartermaster::AutomationChat.brief(item)
    assert_includes brief, "## Description\n\n_none yet_\n"
    refute_includes brief, "_TODO_"
  end

  def test_open_starts_the_items_chat_with_the_brief_as_claudes_argument
    item = new_automation
    tmux = FakeTmux.new

    reply = Quartermaster::AutomationChat.new(tmux: tmux).open(item.slug)

    assert_equal({ "ok" => true, "mode" => "start" }, reply)
    assert_equal [{ name: item.slug, cwd: Dir.home, argv: ["claude", Quartermaster::AutomationChat.brief(item)],
                    env: { "QM_ITEM" => item.slug } }], tmux.opened
  end

  def test_open_on_a_live_chat_types_nothing_and_hands_back_the_brief
    item = new_automation
    tmux = FakeTmux.new([item.slug])

    reply = Quartermaster::AutomationChat.new(tmux: tmux).open(item.slug)

    assert_equal({ "ok" => true, "attached" => true, "brief" => Quartermaster::AutomationChat.brief(item) }, reply)
    assert_empty tmux.opened
    assert_empty tmux.typed
  end

  def test_open_resumes_an_earlier_chat_with_the_brief
    item = new_automation
    launcher = Object.new
    launcher.define_singleton_method(:chat_plan) do |_item, fresh:, prompt:|
      raise "a resume, not a fresh chat" if fresh

      { mode: :resume, cwd: "/w", argv: ["claude", "--resume", "s-1"], env: {}, prompt: prompt }
    end
    item.attach_session("s-1")
    tmux = FakeTmux.new

    reply = Quartermaster::AutomationChat.new(tmux: tmux, launcher: launcher).open(item.slug)

    assert_equal "resume", reply["mode"]
    assert_equal ["claude", "--resume", "s-1", Quartermaster::AutomationChat.brief(Quartermaster::WorkItem.find(item.slug))],
                 tmux.opened.first[:argv]
  end

  def test_open_refuses_an_item_that_is_not_an_automation
    Quartermaster::WorkItem.create("Plain work", project: "MyApp")

    assert_raises(ArgumentError) { Quartermaster::AutomationChat.new(tmux: FakeTmux.new).open("plain-work") }
  end

  def test_the_gui_action_opens_the_chat_and_a_local_process_may_post_it
    item = new_automation
    tmux = FakeTmux.new
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

    status, _type, body = gui.respond("POST", "/api/action", { "host" => "127.0.0.1:4567" },
                                      JSON.generate("cmd" => "automation-chat", "slug" => item.slug))

    assert_equal "200 OK", status
    assert_equal({ "ok" => true, "mode" => "start" }, JSON.parse(body))
    assert_equal item.slug, tmux.opened.first[:name]
  end

  def test_qm_automation_new_without_a_gui_creates_the_item_and_prints_how_to_start_the_chat
    with_no_gui do
      out, = capture_io { Quartermaster::CLI.new(runner: FakeRunner.new).run(["automation", "new", "Shipped digest", "--project", "MyApp"]) }

      item = Quartermaster::WorkItem.find("shipped-digest")
      assert item.automation?
      assert store.exists?("shipped-digest")
      assert_includes out, "shipped-digest: created"
      assert_includes out, "QM_ITEM=shipped-digest claude #{Shellwords.escape(Quartermaster::AutomationChat.brief(item))}"
    end
  end

  def test_qm_automation_new_with_a_gui_opens_the_chat_there_and_brings_it_up
    runner = FakeRunner.new
    with_gui_replying("ok" => true, "mode" => "start") do |posted|
      out, = capture_io { Quartermaster::CLI.new(runner: runner).run(["automation", "new", "Shipped digest", "--project", "MyApp"]) }

      assert_equal [["automation-chat", "shipped-digest"]], posted
      assert_includes out, "shipped-digest: its chat started in the qm gui"
      assert(runner.argvs.any? { |argv| argv.first == "osascript" }, "ChatOpener brings the GUI tab to the chat")
    end
  end

  def test_qm_automation_edit_on_a_live_chat_prints_the_brief
    new_automation
    with_gui_replying("ok" => true, "attached" => true, "brief" => "THE BRIEF") do
      out, = capture_io { Quartermaster::CLI.new(runner: FakeRunner.new).run(%w[automation edit shipped-digest]) }

      assert_includes out, "already running"
      assert_includes out, "THE BRIEF"
    end
  end

  def test_qm_automation_edit_refuses_a_plain_item
    Quartermaster::WorkItem.create("Plain work", project: "MyApp")

    _out, err = capture_io do
      assert_raises(SystemExit) { Quartermaster::CLI.new(runner: FakeRunner.new).run(%w[automation edit plain-work]) }
    end
    assert_match(/not an automation/, err)
  end

  private

  # Swaps the CLI's POST to the running GUI; yields the [cmd, slug] pairs posted.
  def with_gui_replying(reply)
    posted = []
    Quartermaster::CLI.define_method(:gui_action) do |_name, cmd, slug: nil, args: {}, optional: false|
      posted << [cmd, slug]
      reply
    end
    yield posted
  ensure
    Quartermaster::CLI.remove_method(:gui_action)
  end

  def with_no_gui(&block) = with_gui_replying(nil) { block.call }
end
