# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/run_attention_test.rb`).
require_relative "test_helper"

# A local automation's chat-flow run (its own `<slug>--run-<id>` tmux) has no
# item row in attention (its item is the automation), so it gets a row of its
# own in the Runs group, and a turn notification for it opens its tmux.
class RunAttentionTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def setup
    super
    Quartermaster::BackgroundJobs.reset!
  end

  def automation(slug, notify: "attention", flow: "chat")
    Quartermaster::WorkItem.create(slug.capitalize, project: "No project", slug: slug,
                                                    front: { "kind" => "automation", "runner" => "local" })
    Quartermaster::AutomationStore.new.write(slug, { "runner" => "local", "name" => slug.capitalize, "notify" => notify,
                                                     "flow" => flow, "cwd" => Dir.home }, "Do it.\n")
  end

  # A started run whose session is live (this process's pid) unless told otherwise.
  def run_of(slug, session_id, tmux: nil, item: { "key" => "a", "title" => "Thing A" }, pid: Process.pid)
    log = Quartermaster::RunLog.new(slug)
    id = log.enqueue(key: item["key"], item: item, flow: "chat", trigger: "guard")
    log.started(id, session_id: session_id, tmux: tmux || Quartermaster::ChatFlow.tmux_name(slug, id), item_slug: slug)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => "/", "pid" => pid,
                                         "ts" => Time.now.iso8601)
    Quartermaster::WorkItem.find(slug).attach_session(session_id)
    id
  end

  def test_a_live_runs_turn_is_a_row_in_the_runs_group
    automation("nightly")
    id = run_of("nightly", "s-run")
    log_events("s-run", [120, "UserPromptSubmit"], [60, "Stop"])

    attention = Quartermaster::ChatAttention.new
    runs = attention.runs

    assert_equal [["nightly--run-#{id}", "s-run", "your_turn", "nightly", "Nightly · Thing A"]],
                 runs.map { |e| [e.slug, e.session_id, e.state, e.run.slug, e.run.title] }
    assert_empty attention.entries, "the automation item itself still has no row"
  end

  def test_quiet_ended_and_pr_review_runs_have_no_row
    automation("hush", notify: "quiet")
    run_of("hush", "s-quiet")
    automation("nightly")
    run_of("nightly", "s-gone", pid: 999_999_999)
    automation("reviews", flow: "pr-review")
    run_of("reviews", "s-review", tmux: "review-acme-1")

    assert_empty Quartermaster::ChatAttention.new.runs
  end

  def test_a_run_without_an_item_title_is_titled_by_its_key
    automation("nightly")
    id = run_of("nightly", "s-run", item: { "key" => "cron:x" })

    assert_equal ["Nightly · cron:x"], Quartermaster::ChatAttention.new.runs.map { |e| e.run.title }
    assert_equal "nightly--run-#{id}", Quartermaster::RunChats.by_session["s-run"].tmux
  end

  def test_a_blocked_run_notifies_naming_and_opening_its_tmux
    automation("nightly")
    id = run_of("nightly", "s-run")
    runner = FakeRunner.new
    notifier = Quartermaster::TurnNotifier.new(runner: runner, terminal_notifier: "/opt/homebrew/bin/terminal-notifier")
    log_events("s-run", [30, "UserPromptSubmit"])
    notifier.check

    log_events("s-run", [1, "PermissionRequest", "Bash"])
    raised = notifier.check

    tmux = "nightly--run-#{id}"
    assert_equal [[nil, tmux, "Nightly · Thing A"]], raised.map { |n| n.values_at("slug", "run", "title") }
    assert_equal tmux, Quartermaster::TurnNotifier.chat_of(raised.first)
    argv = runner.argvs.last
    assert_equal "qm-#{tmux}", argv[argv.index("-group") + 1]
    assert_match(/open-chat #{tmux}\z/, argv[argv.index("-execute") + 1])
  end

  def test_the_gui_serves_a_live_run_chat_with_its_state_and_opens_a_run_notification_in_it
    automation("nightly")
    id = run_of("nightly", "s-run")
    log_events("s-run", [5, "UserPromptSubmit"], [1, "PermissionRequest", "Bash"])
    tmux = "nightly--run-#{id}"
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new([tmux, "nightly"]))

    status, _type, body = gui.respond("GET", "/api/attention", { "host" => "127.0.0.1:4567" }, "")

    assert_equal "200 OK", status
    payload = JSON.parse(body)
    assert_equal [["nightly", nil, "none", "Nightly"], [tmux, "s-run", "blocked", "Nightly · Thing A"]],
                 payload["loose"].map { |c| c.values_at("name", "session", "state", "title") },
                 "its own tmux is its edit chat, whose turn its run's session never is"
    assert_empty payload["attention"], "the automation item has no row of its own"
    assert_includes File.read(File.expand_path("../lib/quartermaster/gui/js/notify.js", __dir__)),
                    "looseOf(n.run || n.loose)"
  end

  def test_qm_attention_lists_a_runs_row
    automation("nightly")
    id = run_of("nightly", "s-run")
    log_events("s-run", [5, "UserPromptSubmit"], [1, "PermissionRequest", "Bash"])

    out, _err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                                       RbConfig.ruby, QM_BIN, "attention")

    assert status.success?
    assert_match(/🔴 blocked\s+nightly--run-#{id}\s+\d+s · Bash\s+Nightly · Thing A/, out.gsub(/\e\[\d+m/, ""))
  end
end
