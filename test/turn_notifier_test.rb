# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/turn_notifier_test.rb`).
require_relative "test_helper"

class TurnNotifierTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def setup
    super
    Quartermaster::BackgroundJobs.reset!
    @now = Time.now
    @runner = FakeRunner.new
    @notifier = Quartermaster::TurnNotifier.new(runner: @runner, clock: -> { @now }, terminal_notifier: nil)
    @notifier.check # takes stock of an empty log
  end

  def osascripts = @runner.argvs.select { |argv| argv.first == "osascript" }

  def the_osascript
    assert_equal 1, osascripts.size
    osascripts.first
  end

  def test_the_first_check_only_takes_stock
    log_events("s-old", [60, "UserPromptSubmit"], [5, "PermissionRequest", "Bash"])
    fresh = Quartermaster::TurnNotifier.new(runner: @runner, terminal_notifier: nil)

    assert_empty fresh.check
    assert_empty osascripts
  end

  def test_a_blocked_chat_always_notifies_with_sound_naming_the_item
    live_item("Fix the login", "s-block")
    log_events("s-block", [3, "UserPromptSubmit"], [1, "PermissionRequest", "Bash"])

    raised = @notifier.check
    assert_equal [["fix-the-login", "blocked", "Fix the login", "Needs you: Bash"]],
                 raised.map { |n| n.values_at("slug", "kind", "title", "body") }
    argv = the_osascript
    assert_equal ["Fix the login", "Needs you: Bash"], argv.last(2), "text goes in as argv"
    assert_match(/sound name "Glass"/, argv.join(" "))
    assert_empty @notifier.check, "nothing changed since"
    assert_equal 1, osascripts.size
  end

  def test_a_turn_ending_notifies_only_after_thirty_seconds
    live_item("Short", "s-short")
    live_item("Long", "s-long")
    log_events("s-short", [12, "UserPromptSubmit"], [2, "Stop"])
    log_events("s-long", [50, "UserPromptSubmit"], [2, "Stop"])

    raised = @notifier.check
    assert_equal [["long", "your_turn", "Your turn — after 0m 48s"]], raised.map { |n| n.values_at("slug", "kind", "body") }
    refute_match(/sound/, the_osascript.join(" "), "a finished turn is silent")
  end

  def test_working_and_a_resolved_block_never_notify
    live_item("Busy", "s-busy")
    log_events("s-busy", [40, "UserPromptSubmit"], [30, "PostToolUse", "Read"])
    assert_empty @notifier.check

    log_events("s-busy", [20, "PermissionRequest", "Bash"], [10, "PostToolUse", "Bash"])
    assert_empty @notifier.check, "the block resolved before the check saw it"
  end

  def test_a_snoozed_turn_never_notifies
    item = live_item("Snoozed", "s-snooze")
    log_events("s-snooze", [60, "UserPromptSubmit"], [5, "Stop"])
    item.snooze_turn(@now)

    assert_empty @notifier.check
    assert_empty osascripts
  end

  def test_a_turn_that_handed_off_to_background_work_is_waiting_not_news
    path = write_transcript("s-bg", [user_text(90, "sweep it"), *shell_launched(80, "b1", "Dry-run the sweep"), assistant(70)])
    live_item("Sweeping", "s-bg", transcript: path)
    log_events("s-bg", [90, "UserPromptSubmit"], [80, "PostToolUse", "Bash"], [70, "Stop"])

    assert_empty @notifier.check
  end

  def test_an_aside_never_notifies
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "s-aside", "cwd" => "/",
                                         "pid" => Process.pid, "aside" => "some-item", "ts" => @now.iso8601)
    log_events("s-aside", [5, "PermissionRequest", "Bash"])

    assert_empty @notifier.check
  end

  def test_an_unlinked_session_counts_too
    path = write_transcript("s-loose", [user_text(60, "why is the build red")])
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "s-loose", "cwd" => "/",
                                         "transcript_path" => path, "pid" => Process.pid, "ts" => @now.iso8601)
    log_events("s-loose", [2, "PermissionRequest", "Bash"])

    assert_equal [[nil, "why is the build red"]], @notifier.check.map { |n| n.values_at("slug", "title") }
    assert_nil @notifier.recent.last["loose"], "no loose chat to open"
  end

  def loose_session(id)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "s-#{id}", "cwd" => "/",
                                         "pid" => Process.pid, "loose" => id, "ts" => @now.iso8601)
    log_events("s-#{id}", [2, "PermissionRequest", "Bash"])
  end

  def test_a_loose_chat_carries_its_tmux_name
    loose_session("ab12cd34")

    assert_equal [[nil, "loose--ab12cd34"]], @notifier.check.map { |n| n.values_at("slug", "loose") }
  end

  def test_a_page_focused_on_that_very_loose_chat_shows_nothing
    @notifier.page_seen(focused: true, chat: "loose--ab12cd34")
    loose_session("ab12cd34")

    assert_equal [false], @notifier.check.map { |n| n["page"] }
    assert_empty osascripts
  end

  def test_terminal_notifier_click_opens_a_loose_chat
    notifier = Quartermaster::TurnNotifier.new(runner: @runner, clock: -> { @now }, terminal_notifier: "/opt/tn")
    notifier.check
    loose_session("ab12cd34")
    notifier.check

    argv = @runner.argvs.last
    assert_equal "-execute", argv[-2]
    assert_equal [RbConfig.ruby, Quartermaster::EXECUTABLE, "open-chat", "loose--ab12cd34"], Shellwords.split(argv.last)
  end

  def test_a_visible_page_takes_over_from_macos
    live_item("Seen", "s-seen")
    @notifier.page_seen(focused: true, chat: "other-item")
    log_events("s-seen", [1, "PermissionRequest", "Bash"])

    assert_equal [true], @notifier.check.map { |n| n["page"] }
    assert_empty osascripts, "the page shows it"
    assert_equal 1, @notifier.recent.last["id"]
    assert_equal 1, @notifier.seq
  end

  def test_a_page_focused_on_that_very_chat_shows_nothing
    live_item("Watched", "s-watch")
    @notifier.page_seen(focused: true, chat: "watched")
    log_events("s-watch", [1, "PermissionRequest", "Bash"])

    assert_equal [false], @notifier.check.map { |n| n["page"] }
    assert_empty osascripts
  end

  def test_a_tab_just_hidden_hands_notifications_back_to_macos
    live_item("Hidden", "s-hidden")
    @notifier.page_seen(focused: false, chat: nil)
    @notifier.page_hidden
    log_events("s-hidden", [1, "PermissionRequest", "Bash"])

    assert_equal [false], @notifier.check.map { |n| n["page"] }
    assert_equal 1, osascripts.size
  end

  def test_a_pulse_older_than_three_seconds_means_macos_again
    live_item("Away", "s-away")
    @notifier.page_seen(focused: true, chat: "away")
    @now += 4
    log_events("s-away", [1, "PermissionRequest", "Bash"])

    assert_equal [false], @notifier.check.map { |n| n["page"] }
    assert_equal 1, osascripts.size
  end

  def test_terminal_notifier_when_present_whose_click_opens_the_chat
    notifier = Quartermaster::TurnNotifier.new(runner: @runner, clock: -> { @now }, terminal_notifier: "/opt/tn")
    notifier.check
    live_item("Fix the login", "s-tn")
    log_events("s-tn", [3, "UserPromptSubmit"], [1, "PermissionRequest", "Bash"])
    notifier.check

    assert_empty osascripts
    argv = @runner.argvs.last
    assert_equal ["/opt/tn", "-title", "Fix the login", "-message", "Needs you: Bash", "-group", "qm-fix-the-login",
                  "-sound", "Glass", "-execute"], argv[0..-2]
    assert_equal [RbConfig.ruby, Quartermaster::EXECUTABLE, "open-chat", "fix-the-login"], Shellwords.split(argv.last),
                 "this very ruby: the click's PATH has no asdf shims"
  end

  def test_terminal_notifier_for_a_finished_turn_or_an_unlinked_chat
    notifier = Quartermaster::TurnNotifier.new(runner: @runner, clock: -> { @now }, terminal_notifier: "/opt/tn")
    notifier.check
    live_item("Long", "s-long")
    log_events("s-long", [50, "UserPromptSubmit"], [2, "Stop"])
    log_events("s-loose", [2, "PermissionRequest", "Bash"])
    notifier.check

    long, loose = @runner.argvs.partition { |argv| argv.include?("qm-long") }.map(&:first)
    refute_includes long, "-sound", "a finished turn is silent"
    assert_includes long, "-execute"
    refute_includes loose, "-execute", "no item, no chat to open"
    assert_includes loose, "qm-s-loose"
  end
end

class ChatOpenerTest < Minitest::Test
  include QmTestHelpers

  def test_an_open_arc_tab_takes_the_chat
    runner = FakeRunner.new(["osascript"] => ["found\n", "", true])
    assert_equal :arc, Quartermaster::ChatOpener.new(runner: runner, port: 4567).open("fix-login")

    argv = runner.argvs.first
    assert_equal ["osascript", "-e", Quartermaster::ChatOpener::ARC_SCRIPT], argv.first(3)
    assert_equal ["http://127.0.0.1:4567/#chat=fix-login", "http://127.0.0.1:4567/", "http://localhost:4567/"],
                 argv.drop(3), "URLs go in as argv, never spliced into the script"
    assert_equal 1, runner.argvs.size, "nothing opened besides"
  end

  def test_no_arc_tab_or_a_failing_script_opens_the_url
    [["none\n", "", true], ["", "Arc got an error", false]].each do |answer|
      runner = FakeRunner.new(["osascript"] => answer)
      assert_equal :browser, Quartermaster::ChatOpener.new(runner: runner, port: 4567).open("fix-login")
      assert_equal ["open", "http://127.0.0.1:4567/#chat=fix-login"], runner.argvs.last
    end
  end

  def test_qm_open_chat_runs_it
    runner = FakeRunner.new(["osascript"] => ["found\n", "", true])
    Quartermaster::CLI.new(runner: runner).run(["open-chat", "fix-login"])

    assert_includes runner.argvs.first, "http://127.0.0.1:#{Quartermaster::Gui.port}/#chat=fix-login"
  end

  def test_the_page_opens_a_chat_named_by_the_hash
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner), { "host" => "127.0.0.1:4567" })

    assert_includes page, 'addEventListener("hashchange", openChatFromHash)'
    assert_includes page, "history.replaceState"
    assert_includes page, "else if (lc) openLooseChat(lc);", "a loose chat's name opens it too"
  end
end

class TurnNotifierGuiTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  HEADERS = { "host" => "127.0.0.1:4567" }.freeze

  # Whichever channel this machine has.
  def macos?(argv) = argv.first == "osascript" || argv.first.end_with?("terminal-notifier")

  def test_the_pulse_reports_a_visible_page_and_only_a_visible_one
    runner = quiet_runner
    gui = Quartermaster::Gui.new(port: 4567, runner: runner)
    gui.notifier.check
    live_item("Pulse", "s-pulse")

    gui.respond("GET", "/api/pulse?visible=1&focused=0&chat=pulse", HEADERS, "")
    gui.respond("GET", "/api/pulse?visible=0&focused=1&chat=pulse", HEADERS, "")
    log_events("s-pulse", [1, "PermissionRequest", "Bash"])
    gui.notifier.check
    assert_equal 1, runner.argvs.count { |argv| macos?(argv) }, "a hidden tab shows nothing"

    reply = JSON.parse(gui.respond("GET", "/api/pulse?visible=1&focused=0&chat=pulse", HEADERS, "")[2])
    assert reply["events"].end_with?(":1"), "the notification moves the page's pulse"
    log_events("s-pulse", [1, "PostToolUse", "Bash"], [0, "PermissionRequest", "Edit"])
    gui.notifier.check
    assert_equal 1, runner.argvs.count { |argv| macos?(argv) }, "the visible page shows it"

    state = JSON.parse(gui.respond("GET", "/api/state", HEADERS, "")[2])
    assert_equal [false, true], state["notifications"].map { |n| n["page"] }
    attention = JSON.parse(gui.respond("GET", "/api/attention", HEADERS, "")[2])
    assert_equal [%w[pulse blocked]], attention["attention"].map { |a| a.values_at("slug", "state") }
    assert_equal 2, attention["notifications"].size
  end

  def test_the_page_loads_the_notification_script
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner), HEADERS)

    assert_includes page, "function noticeTurns"
    assert_includes page, "/api/pulse?"
    assert_includes page, "Notification.requestPermission"
  end
end
