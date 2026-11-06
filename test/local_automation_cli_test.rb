# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/local_automation_cli_test.rb`).
require_relative "test_helper"

# `qm automation …` for `runner: local` automations: rows and runs from the
# run log with no network, manual runs, pause/resume, retry, delete, the
# tick and its LaunchAgent. Routines come from a stub client, chats open in
# a FakeTmux, guards and launchctl answer from a FakeRunner, and the
# LaunchAgents directory is a temp dir.
class LocalAutomationCliTest < Minitest::Test
  include QmTestHelpers

  GUARD = "list-things"

  # A routines client that must never be asked for anything.
  class NoNetwork
    attr_reader :calls

    def initialize(answer = []) = (@answer = answer) && (@calls = [])

    def list
      @calls << :list
      raise @answer if @answer.is_a?(Exception)

      @answer
    end

    def method_missing(name, *) = (@calls << name) && raise("no #{name} call expected")

    def respond_to_missing?(*) = true
  end

  def setup
    super
    Quartermaster.ensure_setup
    @client = NoNetwork.new
    @tmux = FakeTmux.new
    @runner = FakeRunner.new
    @agents = Dir.mktmpdir("qm-agents")
  end

  def teardown
    FileUtils.rm_rf(@agents)
    super
  end

  def local_automation(slug = "nightly", **record)
    Quartermaster::WorkItem.create(slug.capitalize, project: "MyApp", slug: slug,
                                                    front: { "kind" => "automation", "runner" => "local" })
    base = { "runner" => "local", "name" => slug.capitalize, "cron" => "0 8 * * *", "enabled" => true, "cwd" => Dir.home }
    store.write(slug, base.merge(record), "Do the thing.\n")
  end

  # Runs `qm automation ARGV` with the stubs in place of RoutinesClient,
  # Tmux and the real LaunchAgents directory.
  def invoke(*argv, stdin: "")
    stubs = { Quartermaster::RoutinesClient => ->(_new, *, **) { @client },
              Quartermaster::Tmux => ->(_new, *, **) { @tmux },
              Quartermaster::TickInstaller => ->(new, *, **kw) { new.call(**kw, agents_dir: @agents) } }
    originals = stubs.keys.to_h { |klass| [klass, klass.method(:new)] }
    stubs.each { |klass, factory| klass.define_singleton_method(:new) { |*a, **kw| factory.call(originals[klass], *a, **kw) } }
    with_stdin(stdin) { Quartermaster::CLI.new(runner: @runner).run(["automation", *argv]) }
  ensure
    originals&.each { |klass, original| klass.define_singleton_method(:new, original) }
  end

  def qm(*argv, stdin: "") = capture_io { invoke(*argv, stdin: stdin) }

  def qm_fails(*argv, stdin: "")
    capture_io do
      error = assert_raises(SystemExit) { invoke(*argv, stdin: stdin) }
      refute error.success?
    end
  end

  def store = Quartermaster::AutomationStore.new

  def log(slug = "nightly") = Quartermaster::RunLog.new(slug)

  def item(slug = "nightly") = Quartermaster::WorkItem.find(slug)

  def history(slug = "nightly") = item(slug).notes.select { |n| n.kind == "history" }.map(&:text)

  def guard_says(out, success: true)
    @runner = FakeRunner.new(["sh", "-c", GUARD] => [out, "", success])
  end

  def ended_run(slug = "nightly", status: "failed")
    id = log(slug).enqueue(key: "k1", item: { "key" => "k1" }, flow: "chat", trigger: "guard")
    log(slug).started(id, session_id: "s-1", tmux: "#{slug}--run-#{id}", item_slug: slug)
    status == "failed" ? log(slug).failed(id, error: "boom") : log(slug).public_send(status, id)
    id
  end

  def test_list_prints_local_rows_without_a_routines_call_when_automations_are_off
    local_automation
    @client = NoNetwork.new(Quartermaster::RoutinesClient::NotEnabled.new)
    ended_run(status: "finished")

    out, = qm("list")

    assert_includes out, "nightly  MyApp  in_progress  every day 08:00  enabled  local"
    assert_includes out, "nightly: on this machine, 0 queued, 0 live, last run finished"
  end

  def test_list_keeps_local_rows_out_of_the_claude_ai_overview
    local_automation
    @client = NoNetwork.new([])

    out, = qm("list")

    refute_includes out, "not pushed yet"
    assert_equal [:list], @client.calls
  end

  def test_show_reads_schedule_guard_queue_and_runs_from_the_run_log
    local_automation("when" => GUARD, "notify" => "quiet")
    failed = ended_run
    queued = log.enqueue(key: "k2", item: { "key" => "k2" }, flow: "chat", trigger: "guard")
    log.waiting(queued, reason: "Review chat for a#1 is open")
    log.guard_error(error: "guard failed: nope")

    out, = qm("show", "nightly")

    assert_includes out, "schedule: every day 08:00  (0 8 * * * Amsterdam time)"
    assert_includes out, "guard: #{GUARD}"
    assert_includes out, "flow: chat  notify: quiet  timeout: 30 min"
    assert_includes out, "last guard error: guard failed: nope"
    assert_includes out, "  #{queued}  guard  k2  waiting: Review chat for a#1 is open"
    assert_match(/  #{failed}  failed  .*  k1  boom/, out)
    assert_empty @client.calls
  end

  def test_push_pull_and_adopt_refuse_a_local_automation
    local_automation

    %w[push pull].each do |verb|
      _, err = qm_fails(verb, "nightly")
      assert_includes err, "nightly runs locally — nothing on claude.ai"
    end
    _, err = qm_fails("adopt", "trig_1", "--project", "MyApp", "--slug", "nightly")
    assert_includes err, "nightly runs locally — nothing on claude.ai"
    assert_empty @client.calls
  end

  def test_run_without_a_guard_queues_a_manual_run_and_ticks_it_into_its_own_chat
    local_automation

    out, = qm("run", "nightly")

    queued = log.runs.first
    assert_equal ["manual", nil, "live"], [queued.trigger, queued.item, queued.status]
    assert_equal "nightly--run-#{queued.id}", @tmux.opened.first[:name]
    assert_includes out, "nightly: started run #{queued.id}"
  end

  def test_run_of_a_disabled_automation_starts_and_a_held_one_names_the_global_pause
    local_automation("enabled" => false)

    out, = qm("run", "nightly")
    assert_includes out, "nightly: started run #{log.runs.first.id}"

    Quartermaster::ConfigFile.load.set("automations.local_paused", true).write!
    out, = qm("run", "nightly")
    assert_includes out, "nightly: queued run #{log.queue.first.id} — local automations are paused"
  end

  def test_run_with_a_guard_queues_its_new_items_and_says_when_there_are_none
    local_automation("when" => GUARD)
    guard_says("a\nb\n")
    Quartermaster::ConfigFile.load.set("automations.local_paused", true).write!

    out, = qm("run", "nightly")

    assert_equal [%w[a manual], %w[b manual]], log.queue.map { [_1.key, _1.trigger] }
    assert_includes out, "nightly: queued 2 runs (#{log.queue.map(&:id).join(", ")}) — local automations are paused"
    out, = qm("run", "nightly")
    assert_includes out, "nightly: the guard found nothing new"
  end

  def test_pause_and_resume_move_the_item_with_a_history_note_and_never_push
    local_automation

    qm("pause", "nightly")
    assert_equal [false, "fridge"], [store.read("nightly").record["enabled"], item.state]
    qm("resume", "nightly")

    assert_equal [true, "active"], [store.read("nightly").record["enabled"], item.state]
    assert_equal %w[paused resumed], history.sort
    assert_empty @client.calls
  end

  def test_resume_skip_existing_marks_the_guards_current_items_seen
    local_automation("when" => GUARD, "enabled" => false)
    guard_says("a\nb\n")

    out, = qm("resume", "nightly", "--skip-existing")

    assert_equal Set["a", "b"], log.seen_keys
    assert_empty log.queue
    assert_includes out, "nightly: resumed, 2 existing items marked seen"
    assert_equal ["resumed; 2 existing guard items marked seen"], history
  end

  def test_retry_queues_an_ended_runs_item_again
    local_automation
    Quartermaster::ConfigFile.load.set("automations.local_paused", true).write!
    failed = ended_run

    out, = qm("retry", "nightly", failed)

    again = log.queue.first
    assert_equal ["retry", { "key" => "k1" }], [again.trigger, again.item]
    assert_includes out, "nightly: queued run #{again.id} (retry of #{failed})"
    _, err = qm_fails("retry", "nightly", again.id)
    assert_includes err, "run #{again.id} is still queued"
  end

  def test_delete_is_refused_while_a_run_is_live_and_then_removes_files_and_runs
    local_automation
    id = log.enqueue(key: "k", item: nil, flow: "chat", trigger: "manual")
    log.started(id, session_id: "s", tmux: "nightly--run-#{id}", item_slug: "nightly")

    _, err = qm_fails("delete", "nightly", "--yes")
    assert_includes err, "nightly has a live run — stop or finish its runs first"
    log.finished(id)

    out, = qm("delete", "nightly", stdin: "y\n")

    assert_includes out, "nightly: deleted"
    refute store.exists?("nightly")
    refute File.exist?(log.path)
    assert_equal "resolved", item.state
    assert_equal ["deleted"], history
  end

  def test_runs_lists_queued_and_recent_runs
    local_automation
    failed = ended_run
    queued = log.enqueue(key: "k2", item: nil, flow: "chat", trigger: "manual")

    out, = qm("runs", "nightly")

    assert_match(/queued.*#{queued}  manual  k2/m, out)
    assert_match(/#{failed}  failed .* k1  boom/, out)
  end

  def test_tick_runs_one_tick_and_dry_run_writes_nothing
    local_automation("when" => GUARD)
    guard_says("a\n")

    out, = qm("tick", "--dry-run", "nightly")
    assert_includes out, "nightly: would queue a"
    refute File.exist?(log.path)

    log.enqueue(key: "m", item: nil, flow: "chat", trigger: "manual")
    out, = qm("tick")
    assert_includes out, "started nightly/#{log.runs.first.id}"
    assert_equal 1, @tmux.opened.size
    assert Quartermaster::AutomationTick.state["last_tick_at"]
  end

  def test_install_tick_prints_or_installs_the_launch_agent_and_uninstall_removes_it
    plist = File.join(@agents, "#{Quartermaster::TickInstaller::LABEL}.plist")

    out, = qm("install-tick", "--print")
    assert_includes out, "<string>tick</string>"
    refute File.exist?(plist)

    @runner = FakeRunner.new(["launchctl"] => ["", "", true])
    out, = qm("install-tick")
    assert File.exist?(plist)
    assert_includes @runner.argvs, ["launchctl", "bootstrap", "gui/#{Process.uid}", plist]
    assert_includes out, "installed"

    out, = qm("uninstall-tick")
    refute File.exist?(plist)
    assert_includes out, "uninstalled"
  end
end
