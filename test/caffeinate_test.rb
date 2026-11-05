# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/caffeinate_test.rb`).
require_relative "test_helper"

# A Caffeinate whose process seams record calls instead of starting a real
# caffeinate. `die(pid)` simulates the child exiting on its own.
module CaffeinateHelpers
  class FakeProcesses
    attr_reader :spawned, :killed

    def initialize
      @spawned = []
      @killed = []
      @live = []
      @next_pid = 4100
    end

    def caffeinate(owner_pid: 777)
      Quartermaster::Caffeinate.new(
        owner_pid: owner_pid,
        spawn: lambda { |argv|
          @spawned << argv
          (@next_pid += 1).tap { |pid| @live << pid }
        },
        alive: ->(pid) { @live.include?(pid) },
        kill: lambda { |pid|
          @killed << pid
          @live.delete(pid)
        }
      )
    end

    def die(pid) = @live.delete(pid)
  end
end

class CaffeinateTest < Minitest::Test
  include CaffeinateHelpers

  def test_on_spawns_one_display_assertion_tied_to_the_owner_and_off_kills_it
    procs = FakeProcesses.new
    caf = procs.caffeinate(owner_pid: 777)

    assert_equal({ "on" => false, "pid" => nil, "mode" => "off" }, caf.status)
    assert_equal({ "on" => true, "pid" => 4101, "mode" => "on" }, caf.on)
    assert_equal [["/usr/bin/caffeinate", "-i", "-w", "777"]], procs.spawned
    caf.on
    assert_equal 1, procs.spawned.size, "a second on keeps the running child"

    assert_equal({ "on" => false, "pid" => nil, "mode" => "off" }, caf.off)
    assert_equal [4101], procs.killed
    caf.off
    assert_equal [4101], procs.killed, "off with nothing running kills nothing"
  end

  def test_a_child_that_died_on_its_own_reads_as_off_and_on_starts_a_new_one
    procs = FakeProcesses.new
    caf = procs.caffeinate
    caf.on
    procs.die(4101)

    assert_equal false, caf.status["on"]
    caf.off
    assert_empty procs.killed, "never signals a pid that is no longer ours"
    assert_equal 4102, caf.on["pid"]
  end

  def test_auto_holds_the_child_only_while_busy_and_manual_modes_ignore_the_verdict
    procs = FakeProcesses.new
    caf = procs.caffeinate

    assert_equal({ "on" => false, "pid" => nil, "mode" => "auto" }, caf.auto(false))
    assert_empty procs.spawned
    assert_equal({ "on" => true, "pid" => 4101, "mode" => "auto" }, caf.sync(true))
    caf.sync(true)
    assert_equal 1, procs.spawned.size, "still busy keeps the running child"
    assert_equal({ "on" => false, "pid" => nil, "mode" => "auto" }, caf.sync(false))
    assert_equal [4101], procs.killed

    caf.on
    caf.sync(false)
    assert_equal true, caf.status["on"], "a manual on outlasts an idle verdict"
    caf.off
    caf.sync(true)
    assert_equal false, caf.status["on"], "a manual off outlasts a busy verdict"
    assert_equal true, caf.auto(true)["on"], "switching to auto applies the verdict at once"
  end

  def test_the_real_seams_report_a_finished_child_as_dead
    caf = Quartermaster::Caffeinate.new
    pid = Process.spawn("true")
    Timeout.timeout(5) { sleep 0.05 while caf.send(:process_alive?, pid) }
    assert_equal false, caf.send(:process_alive?, pid), "reaped, so asking again is still false"
  end
end

class GuiCaffeinateTest < Minitest::Test
  include QmTestHelpers
  include CaffeinateHelpers
  include ChatAttentionHelpers

  def host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def post(server, payload, headers = host) = server.respond("POST", "/api/action", headers, JSON.generate(payload))
  def state_of(server) = JSON.parse(server.respond("GET", "/api/state", host, "")[2])

  def gui(procs) = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new, caffeinate: procs.caffeinate)

  def test_the_toggle_action_drives_the_child_and_the_state_reports_it
    procs = FakeProcesses.new
    server = gui(procs)
    assert_equal({ "on" => false, "pid" => nil, "mode" => "off" }, state_of(server)["caffeinate"])

    on = JSON.parse(post(server, "cmd" => "caffeinate", "args" => { "mode" => "on" })[2])
    assert_equal({ "ok" => true, "caffeinate" => { "on" => true, "pid" => 4101, "mode" => "on" } }, on)
    assert_equal({ "on" => true, "pid" => 4101, "mode" => "on" }, state_of(server)["caffeinate"])
    assert_equal true, JSON.parse(post(server, "cmd" => "caffeinate", "args" => { "mode" => "status" })[2])["caffeinate"]["on"]

    off = JSON.parse(post(server, "cmd" => "caffeinate", "args" => { "mode" => "off" })[2])
    assert_equal({ "on" => false, "pid" => nil, "mode" => "off" }, off["caffeinate"])
    assert_equal [4101], procs.killed

    bad = JSON.parse(post(server, "cmd" => "caffeinate", "args" => { "mode" => "sometimes" })[2])
    assert_equal false, bad["ok"]
  end

  def live_session(session_id)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => "/",
                                         "pid" => Process.pid, "ts" => Time.now.iso8601)
  end

  def test_auto_holds_while_any_live_session_works_and_lets_go_when_all_are_done
    procs = FakeProcesses.new
    server = gui(procs)
    live_session("s-unlinked")
    live_item("Chat", "s-item")
    log_events("s-unlinked", [30, "UserPromptSubmit"])
    log_events("s-item", [20, "UserPromptSubmit"], [10, "PermissionRequest", "Bash"])

    auto = JSON.parse(post(server, "cmd" => "caffeinate", "args" => { "mode" => "auto" })[2])["caffeinate"]
    assert_equal({ "on" => true, "pid" => 4101, "mode" => "auto" }, auto, "an unlinked session counts too")

    log_events("s-unlinked", [5, "Stop"])
    refute server.actions.sessions_busy?, "a chat blocked on a permission is not busy"
    assert_equal false, server.instance_variable_get(:@caffeinate).sync(server.actions.sessions_busy?)["on"]
    assert_equal [4101], procs.killed
  end

  def test_a_background_shell_keeps_a_finished_turn_busy_but_a_watch_does_not
    Quartermaster::BackgroundJobs.reset!
    server = gui(FakeProcesses.new)
    path = write_transcript("s-shell", [user_text(90, "sweep"), *shell_launched(80, "b1", "Dry-run the sweep"),
                                        *shell_launched(80, "b2", "Watch CI on #123"), assistant(70)])
    live_item("Sweep", "s-shell", transcript: path)
    log_events("s-shell", [90, "UserPromptSubmit"], [80, "PostToolUse", "Bash"], [70, "Stop"])

    assert server.actions.sessions_busy?, "a Stop with a background shell out is waiting, and keeps the Mac awake"
    File.write(path, "#{JSON.generate(notified(30, "b1"))}\n", mode: "a")
    refute server.actions.sessions_busy?, "only the CI watcher is left: your turn, free to sleep"
  end

  def test_a_foreign_page_cannot_switch_it
    procs = FakeProcesses.new
    status, = post(gui(procs), { "cmd" => "caffeinate", "args" => { "mode" => "on" } },
                   host.merge("origin" => "https://evil.example"))
    assert_equal "403 Forbidden", status
    assert_empty procs.spawned
  end

  def test_the_page_has_the_header_toggle
    page = served_page(gui(FakeProcesses.new), host)
    ['id="caffeinate"', 'act("caffeinate"', "renderCaffeinate()", "st.caffeinate"].each { |seam| assert_includes page, seam }
  end
end

class CliCaffeinateTest < Minitest::Test
  include QmTestHelpers
  include CaffeinateHelpers

  # A real GUI (stubbed spawns) served over a real socket on a free port, so
  # the CLI's HTTP round-trip — no Origin, our Host — is what's tested.
  def with_gui(procs)
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.addr[1]
    server = Quartermaster::Gui.new(port: port, runner: quiet_runner, tmux: FakeTmux.new, caffeinate: procs.caffeinate)
    acceptor = Thread.new do
      loop { server.send(:handle_client, listener.accept) }
    rescue IOError, SystemCallError
      nil
    end
    with_port(port) { yield }
  ensure
    listener&.close
    acceptor&.join(1)
  end

  def with_port(port)
    previous = ENV["QM_GUI_PORT"]
    ENV["QM_GUI_PORT"] = port.to_s
    yield
  ensure
    ENV["QM_GUI_PORT"] = previous
  end

  def qm(*argv)
    exited = nil
    out, err = capture_io do
      Quartermaster::CLI.new.run(argv)
    rescue SystemExit => e
      exited = e.status
    end
    [out, err, exited]
  end

  def test_on_status_off_act_on_the_running_gui
    procs = FakeProcesses.new
    with_gui(procs) do
      assert_equal ["caffeinate on (pid 4101, until the GUI exits)\n", "", nil], qm("caffeinate", "on")
      assert_equal "caffeinate on (pid 4101, until the GUI exits)\n", qm("caffeinate", "status")[0]
      assert_equal ["caffeinate off\n", "", nil], qm("caffeinate", "off")
      assert_equal "caffeinate off\n", qm("caffeinate")[0], "status is the default"
      assert_match(/\Acaffeinate auto \(not held — held while any session is working/, qm("caffeinate", "auto")[0])
    end
    assert_equal 1, procs.spawned.size
    assert_equal [4101], procs.killed
  end

  def test_without_a_running_gui_it_says_so_and_does_nothing
    free = TCPServer.new("127.0.0.1", 0)
    port = free.addr[1]
    free.close
    with_port(port) do
      _out, err, exited = qm("caffeinate", "on")
      assert_equal 1, exited
      assert_match(/no qm gui running on 127.0.0.1:#{port} — nothing done/, err)
    end
  end

  def test_a_bad_mode_prints_usage
    _out, err, exited = qm("caffeinate", "forever")
    assert_equal 1, exited
    assert_match(/usage: qm caffeinate on\|off\|auto\|status/, err)
  end
end
