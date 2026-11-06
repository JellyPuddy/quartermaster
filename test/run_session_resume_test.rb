# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/run_session_resume_test.rb`).
require_relative "test_helper"

# A local automation's runs attach to its item through QM_ITEM, but are never
# its chat: every resume path (qm resume and the viewer, the GUI's pane, the
# edit chat) skips them (docs/areas/linking.md).
class RunSessionResumeTest < Minitest::Test
  include QmTestHelpers

  def test_resume_plan_skips_a_live_run_and_resumes_the_authoring_session
    with_automation do |item, cwd, transcript|
      log_session("s-author", cwd: cwd, transcript: transcript, ended: true)
      item.attach_session("s-author")
      start_run(item, "s-run", cwd: cwd, transcript: transcript)

      plan = Quartermaster::Launcher.new.resume_plan(Quartermaster::WorkItem.find(item.slug))

      assert_equal({ mode: :resume, session_id: "s-author", cwd: cwd }, plan)
    end
  end

  def test_resume_plan_never_resumes_an_ended_run
    with_automation do |item, cwd, transcript|
      start_run(item, "s-run", cwd: cwd, transcript: transcript, ended: true)

      plan = Quartermaster::Launcher.new.resume_plan(Quartermaster::WorkItem.find(item.slug))

      assert_equal :rehydrate, plan[:mode]
    end
  end

  def test_resume_plan_is_not_refused_by_a_live_run
    with_automation do |item, cwd, transcript|
      start_run(item, "s-run", cwd: cwd, transcript: transcript)

      plan = Quartermaster::Launcher.new.resume_plan(Quartermaster::WorkItem.find(item.slug))

      assert_equal :rehydrate, plan[:mode]
    end
  end

  # A session picked by id (the ^X view, a session row) is the user's own
  # choice, a run's included.
  def test_resume_plan_still_resumes_a_run_picked_by_id
    with_automation do |item, cwd, transcript|
      start_run(item, "s-run", cwd: cwd, transcript: transcript, ended: true)

      plan = Quartermaster::Launcher.new.resume_plan(Quartermaster::WorkItem.find(item.slug), session_id: "s-run")

      assert_equal({ mode: :resume, session_id: "s-run", cwd: cwd }, plan)
    end
  end

  def test_the_gui_pane_starts_beside_a_live_run_instead_of_refusing
    with_automation do |item, cwd, transcript|
      start_run(item, "s-run", cwd: cwd, transcript: transcript)
      tmux = FakeTmux.new
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      _status, _type, body = gui.respond("POST", "/api/action", { "host" => "127.0.0.1:4567" },
                                         JSON.generate("cmd" => "pane-resume", "slug" => item.slug))

      assert_equal({ "ok" => true, "mode" => "start" }, JSON.parse(body))
      assert_equal [item.slug], tmux.opened.map { |o| o[:name] }
    end
  end

  def test_the_gui_pane_resumes_the_authoring_session_past_a_live_run
    with_automation do |item, cwd, transcript|
      log_session("s-author", cwd: cwd, transcript: transcript, ended: true)
      item.attach_session("s-author")
      start_run(item, "s-run", cwd: cwd, transcript: transcript)
      tmux = FakeTmux.new
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      _status, _type, body = gui.respond("POST", "/api/action", { "host" => "127.0.0.1:4567" },
                                         JSON.generate("cmd" => "pane-resume", "slug" => item.slug))

      assert_equal({ "ok" => true, "mode" => "resume" }, JSON.parse(body))
      assert_equal ["claude", "--resume", "s-author"], tmux.opened.first[:argv]
    end
  end

  # Only a local automation's runs are skipped: a plain item's live session
  # still refuses.
  def test_a_plain_items_live_session_still_refuses
    Dir.mktmpdir do |cwd|
      transcript = File.join(cwd, "t.jsonl")
      File.write(transcript, "")
      item = Quartermaster::WorkItem.create("Plain work", project: "MyApp")
      log_session("s-live", cwd: cwd, transcript: transcript, pid: Process.pid)
      item.attach_session("s-live")

      plan = Quartermaster::Launcher.new.chat_plan(Quartermaster::WorkItem.find(item.slug))

      assert_equal({ mode: :live, session_id: "s-live" }, plan)
    end
  end

  def test_run_session_ids_names_only_a_local_automations_runs
    with_automation do |item, cwd, transcript|
      start_run(item, "s-run", cwd: cwd, transcript: transcript)
      plain = Quartermaster::WorkItem.create("Plain work", project: "MyApp")

      assert_equal ["s-run"], Quartermaster::RunLog.session_ids_for(Quartermaster::WorkItem.find(item.slug))
      assert_empty Quartermaster::RunLog.session_ids_for(plain)
    end
  end

  private

  def with_automation
    Dir.mktmpdir do |cwd|
      transcript = File.join(cwd, "t.jsonl")
      File.write(transcript, "")
      item = Quartermaster::AutomationChat.create("Shipped digest", project: "MyApp", runner: "local")
      yield item, cwd, transcript
    end
  end

  def log_session(id, cwd:, transcript:, ended: false, pid: 999_999_999)
    log = Quartermaster::SessionLog.new
    log.append("event" => "start", "session_id" => id, "cwd" => cwd, "transcript_path" => transcript, "pid" => pid, "ts" => Time.now.iso8601)
    log.append("event" => "end", "session_id" => id, "ts" => Time.now.iso8601) if ended
  end

  # A run of the automation, started and attached to its item as QM_ITEM does;
  # live (this process's pid) unless ended.
  def start_run(item, session_id, cwd:, transcript:, ended: false)
    log_session(session_id, cwd: cwd, transcript: transcript, ended: ended, pid: Process.pid)
    Quartermaster::WorkItem.find(item.slug).attach_session(session_id)
    runs = Quartermaster::RunLog.new(item.slug)
    run_id = runs.enqueue(key: "cron:#{session_id}", item: nil, flow: "chat", trigger: "manual")
    runs.started(run_id, session_id: session_id, tmux: "#{item.slug}--run-#{run_id}", item_slug: item.slug)
  end
end
