# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/pf_test.rb`).
require_relative "test_helper"

class PfTest < Minitest::Test
  include QmTestHelpers

  def server(**overrides)
    Quartermaster::ProjectSettings.new("WebApp", featured_project("/repo", dev_server: featured_project("/repo")["dev_server"].merge(overrides.transform_keys(&:to_s)))).dev_server
  end

  def test_status_prefers_the_running_servers_endpoint
    runner = FakeRunner.new(["curl"] => [JSON.generate("mode" => "ngrok", "root" => "/wt/a", "switching" => false), "", true])

    status = Quartermaster::Pf.new(runner: runner, server: server).status

    assert_equal({ "mode" => "ngrok", "root" => "/wt/a", "running" => true, "switching" => false }, status.to_h)
    assert_equal [["curl", "-s", "--max-time", "0.5", "http://localhost:3000/status"]], runner.argvs
  end

  def test_status_falls_back_to_the_state_file_and_the_status_command
    Dir.mktmpdir do |dir|
      current = File.join(dir, "current")
      File.write(current, "tunnel /wt/b\n")
      stopped = FakeRunner.new(["curl"] => ["", "", false], %w[pf status] => ["", "nothing is running", false])
      running = FakeRunner.new(["curl"] => ["", "", false])
      on_file = server(state_file: current)

      assert_equal({ "mode" => "tunnel", "root" => "/wt/b", "running" => false, "switching" => false },
                   Quartermaster::Pf.new(runner: stopped, server: on_file).status.to_h)
      assert Quartermaster::Pf.new(runner: running, server: on_file).status.running
      assert Quartermaster::Pf.new(runner: running, server: on_file).serves?("/wt/b")
      refute Quartermaster::Pf.new(runner: stopped, server: on_file).serves?("/wt/b")
      refute Quartermaster::Pf.new(runner: running, server: on_file).serves?("/wt/c")
    end
  end

  def test_without_a_status_url_or_state_file_only_the_status_command_runs
    runner = FakeRunner.new(%w[devserver status] => ["", "", true])

    status = Quartermaster::Pf.new(runner: runner, server: server(command: "devserver", status_url: nil, state_file: nil)).status

    assert_equal({ "mode" => nil, "root" => nil, "running" => true, "switching" => false }, status.to_h)
    assert_equal [%w[devserver status]], runner.argvs
  end

  def test_without_a_configured_dev_server_nothing_runs
    runner = FakeRunner.new

    assert_nil Quartermaster::Pf.new(runner: runner).status
    refute Quartermaster::Pf.new(runner: runner).serves?("/wt")
    error = assert_raises(ArgumentError) { Quartermaster::Pf.new(runner: runner).stop }
    assert_includes error.message, "no dev server configured"
    assert_empty runner.calls
  end

  def test_switch_failures_surface_the_commands_stderr
    runner = FakeRunner.new(%w[devserver switch] => ["", "devserver: no such worktree", false])

    error = assert_raises(ArgumentError) { Quartermaster::Pf.new(runner: runner, server: server(command: "devserver")).switch("/wt", "dev") }
    assert_includes error.message, "devserver switch failed: devserver: no such worktree"
  end

  def test_the_fence_refuses_the_configured_commands_changes_and_passes_status
    configure_projects({ "WebApp" => featured_project("/repo", dev_server: "devserver") })
    runner = FakeRunner.new
    fence = Quartermaster::PfFence.new(runner)

    refute fence.call(%w[devserver switch /wt dev]).success?
    refute fence.call(%w[/usr/local/bin/devserver stop]).success?
    assert fence.call(%w[devserver status]).success?
    assert fence.call(%w[pf stop]).success?
    assert_equal [%w[devserver status], %w[pf stop]], runner.argvs
  end
end

class PfModeTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    configure_projects({ "WebApp" => featured_project("/repo"), "Docs" => "/docs" })
  end

  def run_qm(*argv)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                   RbConfig.ruby, QM_BIN, *argv)
  end

  def test_pf_mode_defaults_to_the_projects_default_mode_and_round_trips_through_the_file
    item = Quartermaster::WorkItem.create("Pf item", project: "WebApp")
    assert_equal "dev", item.pf_mode
    refute item.front.key?("pf_mode")

    item.update_pf_mode("tunnel")

    assert_equal "tunnel", Quartermaster::WorkItem.find("pf-item").pf_mode
    assert_equal "tunnel", Quartermaster::WorkItem.find("pf-item").to_h["pf_mode"]
  end

  def test_pf_mode_needs_a_dev_server_and_one_of_its_modes
    other = Quartermaster::WorkItem.create("Elsewhere", project: "Docs")
    assert_nil other.pf_mode
    error = assert_raises(ArgumentError) { other.update_pf_mode("dev") }
    assert_includes error.message, "`qm config set projects.Docs.dev_server.command <command>`"

    item = Quartermaster::WorkItem.create("Pf item", project: "WebApp")
    assert_raises(ArgumentError) { item.update_pf_mode("production") }
    assert_raises(ArgumentError) { Quartermaster::WorkItem.create("Bad", project: "WebApp", pf_mode: "nope") }
  end

  def test_the_cli_sets_and_prints_pf_mode_including_on_new
    _out, _err, status = run_qm("new", "Tunnelled", "--project", "WebApp", "--pf-mode", "ngrok")
    assert status.success?
    assert_equal "ngrok", Quartermaster::WorkItem.find("tunnelled").pf_mode

    stdout, _err, status = run_qm("pf-mode", "tunnelled", "tunnel")
    assert status.success?
    assert_equal "tunnelled → pf tunnel\n", stdout
    stdout, _err, = run_qm("pf-mode", "tunnelled")
    assert_equal "tunnel\n", stdout

    _out, stderr, status = run_qm("pf-mode", "tunnelled", "bogus")
    refute status.success?
    assert_includes stderr, "pf mode must be one of: dev, ngrok, tunnel"
  end

  def test_only_configured_projects_get_the_dev_server_and_pr_requires_lines
    Quartermaster::WorkItem.create("Pf item", project: "WebApp", session_id: "sess-pf1").update_pf_mode("ngrok")
    Quartermaster::WorkItem.create("Other item", project: "Docs", session_id: "sess-pf2")

    featured, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-pf1", "cwd" => "/", "source" => "resume"))
    other, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-pf2", "cwd" => "/", "source" => "resume"))

    line = featured.lines.find { |l| l.include?("qm work-on") }
    assert_equal "- Dev server: qm work-on pf-item (pf ngrok); mode: qm pf-mode pf-item MODE\n", line
    refute_includes other, "work-on"
    refute_includes other, "pf-mode"

    pr_line = featured.lines.find { |l| l.include?("qm pr-requires") }
    assert_equal "- PR may merge only after an earlier PR/commit is deployed: qm pr-requires <pr-or-sha> [--note TEXT]\n", pr_line
    refute_includes other, "pr-requires"
  end

  def test_the_dev_server_line_names_the_configured_ide
    configure_projects({ "WebApp" => featured_project("/repo") }, ide_command: ["myide", "PATH"], ide_label: "MyIDE")
    Quartermaster::WorkItem.create("Pf item", project: "WebApp", session_id: "sess-pf1")

    stdout, = run_hook("hook-session-start", JSON.generate("session_id" => "sess-pf1", "cwd" => "/", "source" => "resume"))

    assert_includes stdout, "- Dev server: qm work-on pf-item (pf dev + MyIDE); mode: qm pf-mode pf-item MODE\n"
  end

  def test_a_broken_config_turns_the_lines_off_without_breaking_the_hook
    Quartermaster::WorkItem.create("Pf item", project: "WebApp", session_id: "sess-pf1")
    File.write(Quartermaster::CONFIG_FILE, "projects: [::")

    stdout, _err, status = run_hook("hook-session-start", JSON.generate("session_id" => "sess-pf1", "cwd" => "/", "source" => "resume"))

    assert status.success?
    assert_includes stdout, "linked to work item 'pf-item'"
    refute_includes stdout, "work-on"
  end
end

class WorkspaceTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  def test_work_on_switches_the_dev_server_in_the_items_mode_and_opens_the_ide_on_the_same_worktree
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      wt = add_worktree(repo, "b1", "wt-b1")
      configure_projects({ "WebApp" => featured_project(repo) }, ide_command: ["zsh", "-ic", "myide PATH"], ide_label: "MyIDE")
      map = Quartermaster::ProjectMap.new
      item = Quartermaster::WorkItem.create("Work", project: "WebApp", branch: "b1", pf_mode: "tunnel")
      runner = FakeRunner.new

      report = Quartermaster::Workspace.new(project_map: map, runner: runner).work_on(item)

      path = report.target.path
      assert_equal wt, File.realpath(path)
      assert_equal [["pf", "switch", path, "tunnel"], ["zsh", "-ic", "myide #{Shellwords.escape(path)}"]], runner.argvs
      assert_equal "tunnel", report.mode
      assert_equal "MyIDE opened #{Quartermaster.shorten_home(path)}", report.steps.last

      runner.calls.clear
      Quartermaster::Workspace.new(project_map: map, runner: runner).switch_pf(item, mode: "dev")
      assert_equal [["pf", "switch", path, "dev"]], runner.argvs
    end
  end

  def test_work_on_without_a_dev_server_only_opens_the_ide_and_pf_switch_refuses
    Dir.mktmpdir do |dir|
      repo = make_repo(dir)
      map = Quartermaster::ProjectMap.new(roots: { "Docs" => { "root" => repo, "ide_command" => ["open", "-a", "My IDE", "PATH"] } })
      item = Quartermaster::WorkItem.create("Docs", project: "Docs")
      runner = FakeRunner.new
      workspace = Quartermaster::Workspace.new(project_map: map, runner: runner)

      report = workspace.work_on(item)

      assert_equal [["open", "-a", "My IDE", repo]], runner.argvs, "a bare PATH element is the path, unescaped"
      assert_equal "IDE opened #{Quartermaster.shorten_home(repo)}", report.steps.last, "the label defaults to IDE"
      assert_equal "dev server skipped: Docs has none (qm config set projects.Docs.dev_server.command <command>)", report.steps.first
      error = assert_raises(ArgumentError) { workspace.switch_pf(item) }
      assert_includes error.message, "Docs has no dev server: run `qm config set projects.Docs.dev_server.command <command>`"
    end
  end

  def test_without_an_ide_command_open_ide_refuses_naming_the_setting_and_work_on_only_switches
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      system("git", "-C", repo, "branch", "fresh")
      configure_projects({ "WebApp" => featured_project(repo, test_db: nil), "Docs" => repo })
      map = Quartermaster::ProjectMap.new
      item = Quartermaster::WorkItem.create("Fresh", project: "WebApp", branch: "fresh")
      docs = Quartermaster::WorkItem.create("Docs", project: "Docs")
      runner = FakeRunner.new
      workspace = Quartermaster::Workspace.new(project_map: map, runner: runner)

      error = assert_raises(ArgumentError) { workspace.open_ide(item) }
      assert_includes error.message, "set ide_command"
      assert_empty runner.calls, "a refused IDE creates no worktree"
      error = assert_raises(ArgumentError) { workspace.work_on(docs) }
      assert_includes error.message, "set ide_command"

      report = workspace.work_on(item)

      assert_equal [["pf", "switch", report.target.path, "dev"]], runner.argvs.reject { |argv| argv.first == "git" }
      assert_equal "IDE skipped: none configured (qm config set ide_command '[open, -a, <IDE>, PATH]')", report.steps.last
    end
  end

  def test_an_ide_command_without_a_path_placeholder_leaves_the_ide_off
    assert_nil Quartermaster::ProjectConfig.new("ide_command" => ["myide"]).ide
    assert_nil Quartermaster::ProjectConfig.new("ide_command" => "myide PATH").ide
    config = Quartermaster::ProjectConfig.new("ide_command" => ["myide", "PATH"], "ide_label" => "Global",
                                              "projects" => { "A" => { "root" => "/a", "ide_command" => ["other", "PATH"], "ide_label" => "Own" },
                                                              "B" => "/b" })
    assert_equal "Own", config.ide("A").label
    assert_equal "Global", config.ide("B").label
    assert_equal "Global", config.ide.label
  end

  def test_terminal_opens_a_warp_tab_in_the_items_worktree_without_a_command
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      wt = add_worktree(repo, "b1", "wt-b1")
      map = Quartermaster::ProjectMap.new(roots: { "WebApp" => repo })
      item = Quartermaster::WorkItem.create("Shell", project: "WebApp", branch: "b1")
      runner = FakeRunner.new

      report = Quartermaster::Workspace.new(project_map: map, runner: runner).open_terminal(item)

      assert_equal [%w[open warp://tab_config/qm-launch]], runner.argvs
      config = File.read(File.join(ENV["QM_WARP_TAB_CONFIGS"], "qm-launch.toml"))
      assert_includes config, %(directory = "#{report.target.path}")
      assert_includes config, %(name = "shell · b1")
      refute_includes config, "commands"
      assert_equal wt, File.realpath(report.target.path)
    end
  end

  def test_a_failure_after_earlier_steps_still_reports_what_already_ran
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      system("git", "-C", repo, "branch", "fresh")
      configure_projects({ "WebApp" => featured_project(repo, test_db: nil) }, ide_command: ["myide", "PATH"], ide_label: "MyIDE")
      map = Quartermaster::ProjectMap.new
      item = Quartermaster::WorkItem.create("Fresh", project: "WebApp", branch: "fresh")
      runner = FakeRunner.new(["myide"] => ["", "myide: not found", false])

      error = assert_raises(ArgumentError) do
        Quartermaster::Workspace.new(project_map: map, runner: runner).work_on(item)
      end

      assert_match(/created worktree .*fresh; pf dev @ .*; then opening MyIDE failed: myide: not found/, error.message)
    end
  end
end
