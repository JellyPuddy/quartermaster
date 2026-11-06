# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/loose_chat_test.rb`).
require_relative "test_helper"
require "socket"

module LooseChatHelpers
  # top: further config.yml keys (loose_starters:).
  def with_project(name = "Widget", **top)
    Dir.mktmpdir do |dir|
      root = File.realpath(dir)
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { name => root } }.merge(top.transform_keys(&:to_s)).to_yaml)
      yield root
    end
  end

  def log_loose_start(session_id, id, transcript: nil, pid: Process.pid, project: "Widget", ts: Time.now)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => Dir.home,
                                         "transcript_path" => transcript, "branch" => "main", "project" => project,
                                         "loose" => id, "pid" => pid, "ts" => ts.iso8601)
  end

  def start_input(id, cwd: "/") = JSON.generate("session_id" => id, "cwd" => cwd, "source" => "startup")
end

# 10a: the launch plan, the tmux session and the CLI.
class LooseChatStartTest < Minitest::Test
  include QmTestHelpers
  include LooseChatHelpers

  def test_the_plan_runs_in_the_projects_main_checkout_marked_loose_with_model_and_prompt
    with_project do |root|
      plan = Quartermaster::Launcher.new.loose_plan("ab12cd34", project: "Widget", model: "opus", prompt: "Why is CI red?")

      assert_equal({ cwd: root, argv: ["claude", "--model", "opus", "Why is CI red?"],
                     env: { "QM_LOOSE" => "ab12cd34", "QM_ITEM" => "" } }, plan)
    end
  end

  def test_without_a_project_root_model_or_prompt_it_is_a_bare_claude_at_home
    plan = Quartermaster::Launcher.new.loose_plan("ab12cd34", project: "No project", prompt: "  ")

    assert_equal({ cwd: Dir.home, argv: ["claude"], env: { "QM_LOOSE" => "ab12cd34", "QM_ITEM" => "" } }, plan)
  end

  def test_start_opens_a_loose_tmux_session_that_no_slug_can_name
    with_project do |root|
      tmux = FakeTmux.new
      name = Quartermaster::LooseChat.new(tmux: tmux).start(project: "Widget", model: "haiku", prompt: "hi")

      id = name.delete_prefix("loose--")
      assert_match(/\Aloose--[0-9a-f]{8}\z/, name)
      assert_equal [{ name: name, cwd: root, argv: %w[claude --model haiku hi], env: { "QM_LOOSE" => id, "QM_ITEM" => "" } }],
                   tmux.opened
      refute_equal name, Quartermaster::WorkItem.slugify("Loose #{id}"), "a double dash never comes out of slugify"
    end
  end

  def test_an_unknown_model_is_refused
    error = assert_raises(ArgumentError) { Quartermaster::LooseChat.new(tmux: FakeTmux.new).start(project: "x", model: "gpt") }
    assert_match(/unknown model/, error.message)
  end
end

class CliLooseTest < Minitest::Test
  include QmTestHelpers
  include LooseChatHelpers

  def setup
    super
    @port = ENV["QM_GUI_PORT"]
  end

  def teardown
    @port ? ENV["QM_GUI_PORT"] = @port : ENV.delete("QM_GUI_PORT")
  end

  def qm(*argv)
    exited = nil
    out, err = capture_io do
      Quartermaster::CLI.new(runner: quiet_runner, cwd: Dir.home).run(argv)
    rescue SystemExit => e
      exited = e.status
    end
    [out, err, exited]
  end

  def test_without_a_gui_it_prints_how_to_start_the_loose_chat
    with_project do |root|
      free = TCPServer.new("127.0.0.1", 0)
      ENV["QM_GUI_PORT"] = free.addr[1].to_s
      free.close

      out, err, exited = qm("loose", "--project", "Widget", "--model", "sonnet", "What does X do?")

      assert_nil exited, err
      assert_match(/cd #{Regexp.escape(root)} && QM_LOOSE=[0-9a-f]{8} QM_ITEM= claude --model sonnet What\\ does\\ X\\ do\\\?/, out)
    end
  end

  def test_with_a_gui_the_gui_opens_it_from_an_origin_less_post
    with_project do
      tmux = FakeTmux.new
      listener = TCPServer.new("127.0.0.1", 0)
      ENV["QM_GUI_PORT"] = listener.addr[1].to_s
      server = Quartermaster::Gui.new(port: listener.addr[1], runner: quiet_runner, tmux: tmux)
      acceptor = Thread.new do
        loop { server.send(:handle_client, listener.accept) }
      rescue IOError, SystemCallError
        nil
      end

      out, err, exited = qm("loose", "--project", "Widget", "look around")

      assert_nil exited, err
      assert_match(/loose chat [0-9a-f]{8} started in the qm gui \(Widget\)/, out)
      assert_equal %w[claude look\ around], tmux.opened.first[:argv]
    ensure
      listener&.close
      acceptor&.join(1)
    end
  end

  def test_a_bad_model_aborts_before_anything_runs
    _out, err, exited = qm("loose", "--model", "gpt")

    assert_equal 1, exited
    assert_match(/unknown model/, err)
  end
end

# 10b: the SessionStart hook.
class LooseChatHookTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include LooseChatHelpers

  def test_a_loose_chat_gets_the_loose_injection_and_is_never_linked
    Quartermaster::WorkItem.create("Elsewhere", project: "No project")

    stdout, _stderr, status = run_hook("hook-session-start", start_input("sess-loose"),
                                       { "QM_LOOSE" => "ab12cd34", "QM_ITEM" => "elsewhere" })

    assert_equal 0, status.exitstatus
    assert_includes stdout, "is a loose chat, by intent"
    assert_includes stdout, "ask the user to promote this chat"
    refute_includes stdout, "Linking protocol", "the unlinked injection would ask it to link itself"
    assert_empty Quartermaster::WorkItem.find("elsewhere").sessions
    event = logged_events.fetch(0)
    assert_equal "ab12cd34", event["loose"]
    assert_nil event["work_item"]
  end

  def test_the_loose_marker_wins_over_a_branch_match
    with_project("Repo") do |dir|
      system("git", "init", "-q", "-b", "issue/9-x", dir)
      system("git", "-C", dir, *StackRepoHelpers::GIT_ID, "commit", "-q", "--allow-empty", "-m", "init")
      Quartermaster::WorkItem.create("Branchy", project: "Repo", branch: "issue/9-x")

      run_hook("hook-session-start", start_input("sess-b", cwd: dir), { "QM_LOOSE" => "ab12cd34" })

      assert_empty Quartermaster::WorkItem.find("branchy").sessions
    end
  end

  # Unlike an aside: it stays in the inbox, its turns are recorded (attention,
  # notifications), and no item holds it, so nothing ever distills it.
  def test_a_loose_chat_counts_for_attention_and_stays_in_the_inbox_undistilled
    run_hook("hook-session-start", start_input("sess-att"), { "QM_LOOSE" => "ab12cd34" })
    _out, _err, status = run_sh("record-event.sh", '{"session_id":"sess-att","hook_event_name":"Stop"}', "QM_LOOSE" => "ab12cd34")

    assert status.success?
    assert_equal "your_turn", turn("sess-att")["state"]
    assert_equal ["sess-att"], Quartermaster::SessionLog.new.inbox.map(&:id)
    assert(Quartermaster::WorkItem.all.none? { |i| i.sessions.any? }, "no item, so no distill target")
    stdout, = run_hook("sessions", "")
    assert_match(/sess-att.*loose:ab12cd34/, stdout)
  end

  # A promoted chat keeps QM_LOOSE in its process: a /clear restart (new
  # session id) follows the item it became instead of going loose again.
  def test_a_restart_after_promotion_links_to_the_promoted_item
    log_loose_start("sess-first", "ab12cd34")
    Quartermaster::WorkItem.from_session("sess-first", title: "Promoted")

    stdout, = run_hook("hook-session-start", start_input("sess-cleared"), { "QM_LOOSE" => "ab12cd34" })

    assert_includes stdout, "linked to work item 'promoted'"
    assert_equal %w[sess-first sess-cleared], Quartermaster::WorkItem.find("promoted").sessions.map { |s| s["id"] }
  end
end

# 10c + 10d: the GUI's Loose group, ✕ and → Work item.
class LooseChatGuiTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include LooseChatHelpers

  def host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def post(server, payload) = JSON.parse(server.respond("POST", "/api/action", host, JSON.generate(payload))[2])
  def state_of(server) = JSON.parse(server.respond("GET", "/api/state", host, "")[2])

  def test_live_loose_tmux_sessions_are_the_loose_group_titled_by_their_first_prompt
    tmux = FakeTmux.new(%w[some-item loose--aa11 loose--bb22])
    transcript = write_transcript("sess-a", [user_text(60, "Why does the export drop rows?")])
    log_loose_start("sess-a", "aa11", transcript: transcript)
    log_events("sess-a", [30, "UserPromptSubmit"], [5, "Stop"])
    log_loose_start("sess-dead", "cc33", pid: nil)
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

    state = state_of(server)

    assert_equal [%w[loose--aa11 aa11 sess-a your_turn], ["loose--bb22", "bb22", nil, "none"]],
                 state["loose"].map { |l| l.values_at("name", "id", "session", "state") }
    assert_equal ["Why does the export drop rows?", "New loose chat"], state["loose"].map { |l| l["title"] }
    assert_equal ["sess-dead"], state["inbox"].map { |s| s["id"] }, "an open loose chat is under Loose, a dead one in the inbox"
    assert_equal ["loose--aa11"], JSON.parse(server.respond("GET", "/api/attention", host, "")[2])["loose"]
      .select { |l| l["state"] == "your_turn" }.map { |l| l["name"] }
  end

  def test_the_gui_starts_a_loose_chat
    with_project do |root|
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      reply = post(server, "cmd" => "loose-start", "args" => { "project" => "Widget", "model" => "", "prompt" => "hello" })

      assert_equal true, reply["ok"]
      assert_equal "loose--#{reply["id"]}", reply["name"]
      assert_equal [root, %w[claude hello]], tmux.opened.first.values_at(:cwd, :argv)
    end
  end

  def test_close_types_exit_kills_the_session_and_dismisses_it_from_the_inbox
    tmux = FakeTmux.new(%w[loose--aa11])
    log_loose_start("sess-a", "aa11")
    slept = []
    loose = Quartermaster::LooseChat.new(tmux: tmux, sleeper: ->(s) { slept << s })

    assert loose.close("aa11")

    assert_equal [["loose--aa11", "/exit"], ["loose--aa11", :enter]], tmux.typed
    assert_empty tmux.sessions
    assert_empty Quartermaster::SessionLog.new.inbox
    assert_equal Quartermaster::Rotation::TYPE_SETTLE, slept.first
  end

  # claude ends its tmux session itself once /exit is submitted.
  class ExitingTmux < FakeTmux
    def send_enter(name) = super && (typed.last(2) != [[name, "/exit"], [name, :enter]] || kill(name))
  end

  def test_close_from_the_gui_runs_on_a_job
    tmux = ExitingTmux.new(%w[loose--aa11])
    log_loose_start("sess-a", "aa11")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

    reply = post(server, "cmd" => "loose-close", "args" => { "id" => "aa11" })

    assert_equal [true, true], reply.values_at("ok", "background")
    Timeout.timeout(15) { sleep 0.05 until server.jobs.running.empty? }
    assert_equal "loose chat closed", server.jobs.take_finished.last["message"]
    assert_empty tmux.sessions
  end

  def test_promote_makes_an_item_with_the_session_and_renames_the_chat_to_its_slug
    tmux = FakeTmux.new(%w[loose--aa11])
    log_loose_start("sess-old", "aa11", ts: Time.now - 60, pid: nil)
    log_loose_start("sess-a", "aa11")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

    reply = post(server, "cmd" => "loose-promote", "args" => { "id" => "aa11", "title" => "Export drops rows" })

    assert_equal({ "ok" => true, "slug" => "export-drops-rows" }, reply)
    item = Quartermaster::WorkItem.find("export-drops-rows")
    assert_equal ["sess-a"], item.sessions.map { |s| s["id"] }
    assert_equal "Widget", item.project
    assert_empty item.branches, "the main checkout's branch is no item's"
    assert_equal ["export-drops-rows"], tmux.sessions
    assert_empty state_of(server)["loose"]
  end

  def test_promote_needs_a_title_and_a_captured_session
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new(%w[loose--aa11]))

    assert_match(/title is required/, post(server, "cmd" => "loose-promote", "args" => { "id" => "aa11" })["error"])
    assert_match(/no captured session/, post(server, "cmd" => "loose-promote", "args" => { "id" => "aa11", "title" => "T" })["error"])
  end

  def test_the_page_loads_loose_js_after_the_chat_scripts_and_before_events
    html = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
    order = %w[chat.js chat-main.js loose.js events.js].map { |f| html.index(%(<script src="/assets/js/#{f}">)) }

    assert_equal order.sort, order
    ['id="loose-new"', "renderLooseGroup(list);", "if (lc) { renderLooseMain(lc, headSlot, wrap);",
     'act("loose-close", { args: { id: lc.id } })', "args: { id: lc.id, title, tell: tellBox.checked }",
     'localStorage.setItem("qm-loose-model", model)',
     "[...attention, ...looseChats.filter(lc => !(lc.run && lc.run.quiet))].filter"].each { |seam| assert_includes html, seam }
  end

  def test_promote_onto_a_slug_whose_chat_runs_warns_and_keeps_the_loose_pane
    tmux = FakeTmux.new(%w[loose--aa11 taken])
    log_loose_start("sess-a", "aa11")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

    reply = post(server, "cmd" => "loose-promote", "args" => { "id" => "aa11", "title" => "Taken" })

    assert_equal "taken", reply["slug"]
    assert_match(/stays under loose--aa11/, reply["warning"])
  end

  TOLD = "This chat is now work item export-drops-rows; run qm show export-drops-rows " \
         "and follow its work item protocol from here."

  def promoting(tmux)
    slept = []
    log_loose_start("sess-a", "aa11")
    [Quartermaster::LooseChat.new(tmux: tmux, sleeper: ->(s) { slept << s }), slept]
  end

  def test_promote_with_tell_types_the_new_item_into_the_renamed_chat_after_the_settle
    tmux = FakeTmux.new(%w[loose--aa11])
    loose, slept = promoting(tmux)

    item, renamed, told = loose.promote("aa11", title: "Export drops rows", tell: true)

    assert_equal ["export-drops-rows", true, true], [item.slug, renamed, told]
    assert_equal [["export-drops-rows", TOLD], ["export-drops-rows", :enter]], tmux.typed
    assert_equal [Quartermaster::Rotation::TYPE_SETTLE], slept
  end

  def test_promote_without_tell_types_nothing
    tmux = FakeTmux.new(%w[loose--aa11])
    loose, = promoting(tmux)

    _, renamed, told = loose.promote("aa11", title: "Export drops rows")

    assert_equal [true, false], [renamed, told]
    assert_empty tmux.typed
  end

  def test_a_failed_promote_tells_nothing
    tmux = FakeTmux.new(%w[loose--aa11])
    loose = Quartermaster::LooseChat.new(tmux: tmux, sleeper: ->(_) {})

    assert_raises(ArgumentError) { loose.promote("aa11", title: "T", tell: true) }
    assert_raises(ArgumentError) { loose.promote("aa11", title: " ", tell: true) }
    assert_empty tmux.typed
  end

  class DeadPaneTmux < FakeTmux
    def pane_dead?(_name) = true
  end

  def test_a_dead_pane_is_not_told
    tmux = DeadPaneTmux.new(%w[loose--aa11])
    loose, = promoting(tmux)

    _, renamed, told = loose.promote("aa11", title: "Export drops rows", tell: true)

    assert_equal [true, false], [renamed, told]
    assert_empty tmux.typed
  end

  def test_a_chat_that_kept_its_loose_name_is_not_told
    tmux = FakeTmux.new(%w[loose--aa11 export-drops-rows])
    loose, = promoting(tmux)

    _, renamed, told = loose.promote("aa11", title: "Export drops rows", tell: true)

    assert_equal [false, false], [renamed, told]
    assert_empty tmux.typed
  end

  def test_promote_from_the_gui_tells_the_chat_only_when_asked
    tmux = FakeTmux.new(%w[loose--aa11 loose--bb22])
    log_loose_start("sess-a", "aa11")
    log_loose_start("sess-b", "bb22")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

    told = post(server, "cmd" => "loose-promote", "args" => { "id" => "aa11", "title" => "Export drops rows", "tell" => true })
    quiet = post(server, "cmd" => "loose-promote", "args" => { "id" => "bb22", "title" => "Other" })

    assert_equal({ "ok" => true, "slug" => "export-drops-rows", "told" => true }, told)
    assert_equal({ "ok" => true, "slug" => "other" }, quiet)
    assert_equal [["export-drops-rows", TOLD], ["export-drops-rows", :enter]], tmux.typed
  end
end

# A config.yml loose starter: a kickoff as claude's argument that has the chat
# load something through its own tools before the first question.
class LooseChatStarterTest < Minitest::Test
  include QmTestHelpers
  include LooseChatHelpers

  BACKLOG_KICKOFF = "Load the issues of the current sprint with your issue-tracker tools. Don't change code. " \
                    "Then give a one-line count of them and"
  STARTERS = { "backlog" => { "label" => "Sprint backlog", "prompt" => BACKLOG_KICKOFF } }.freeze

  def host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def post(server, payload) = JSON.parse(server.respond("POST", "/api/action", host, JSON.generate(payload))[2])

  def started_argv(args)
    with_project(loose_starters: STARTERS) do
      tmux = FakeTmux.new
      reply = post(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux), "cmd" => "loose-start", "args" => args)
      assert_equal true, reply["ok"], reply["error"]
      return tmux.opened.first[:argv]
    end
  end

  def test_without_a_starter_there_is_no_kickoff
    assert_equal %w[claude], started_argv("project" => "Widget", "starter" => "")
    assert_equal ["claude", "Why?"], started_argv("project" => "Widget", "prompt" => "Why?")
  end

  def test_the_backlog_starter_loads_the_sprint_backlog_and_asks
    assert_equal ["claude", "--model", "opus", "#{BACKLOG_KICKOFF} ask me what I want to know about them."],
                 started_argv("project" => "Widget", "model" => "opus", "starter" => "backlog")
  end

  def test_a_typed_question_ends_the_backlog_kickoff_instead_of_asking
    assert_equal ["claude", "#{BACKLOG_KICKOFF} answer my question about them:\n\nWhich are blocked?"],
                 started_argv("project" => "Widget", "starter" => "backlog", "prompt" => " Which are blocked? ")
  end

  def test_the_state_lists_the_configured_starters_and_none_by_default
    with_project(loose_starters: STARTERS) do
      state = JSON.parse(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new).respond("GET", "/api/state", host, "")[2])
      assert_equal [{ "key" => "backlog", "label" => "Sprint backlog" }], state["looseStarters"]
    end
    with_project do
      state = JSON.parse(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new).respond("GET", "/api/state", host, "")[2])
      assert_equal [], state["looseStarters"]
    end
  end

  def test_an_unknown_starter_is_refused
    error = assert_raises(ArgumentError) { Quartermaster::LooseChat.new(tmux: FakeTmux.new).start(project: "x", starter: "jira") }
    assert_match(/unknown starter "jira"/, error.message)
  end

  def test_qm_loose_starter_without_a_gui_prints_the_kickoff_as_claudes_argument
    with_project(loose_starters: STARTERS) do
      free = TCPServer.new("127.0.0.1", 0)
      port = ENV["QM_GUI_PORT"]
      ENV["QM_GUI_PORT"] = free.addr[1].to_s
      free.close
      out, = capture_io { Quartermaster::CLI.new(runner: quiet_runner, cwd: Dir.home).run(%w[loose --project Widget --starter backlog]) }

      argv = Shellwords.split(out.lines.last.split(" && ").last).drop(2)
      assert_equal ["claude", "#{BACKLOG_KICKOFF} ask me what I want to know about them."], argv
    ensure
      port ? ENV["QM_GUI_PORT"] = port : ENV.delete("QM_GUI_PORT")
    end
  end
end
