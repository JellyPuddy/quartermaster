# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/tick_installer_test.rb`).
require_relative "test_helper"

class TickInstallerTest < Minitest::Test
  include QmTestHelpers

  LABEL = "com.quartermaster.automation-tick"

  def setup
    super
    @agents = Dir.mktmpdir("qm-test-agents")
    @runner = FakeRunner.new
  end

  def teardown
    FileUtils.rm_rf(@agents)
    super
  end

  def installer(env: { "PATH" => "/opt/homebrew/bin:/usr/bin", "QM_ROOT" => "/tmp/qm root" }, root: "/tmp/qm root")
    Quartermaster::TickInstaller.new(runner: @runner, agents_dir: @agents, env: env, root: root, uid: 501,
                                     program: "/opt/qm/quartermaster")
  end

  def plist_file = File.join(@agents, "#{LABEL}.plist")

  EXPECTED = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>com.quartermaster.automation-tick</string>
      <key>ProgramArguments</key>
      <array>
        <string>/opt/qm/quartermaster</string>
        <string>automation</string>
        <string>tick</string>
      </array>
      <key>StartInterval</key>
      <integer>300</integer>
      <key>RunAtLoad</key>
      <false/>
      <key>StandardOutPath</key>
      <string>/tmp/qm root/automations/tick.log</string>
      <key>StandardErrorPath</key>
      <string>/tmp/qm root/automations/tick.log</string>
      <key>EnvironmentVariables</key>
      <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/bin</string>
        <key>QM_ROOT</key>
        <string>/tmp/qm root</string>
      </dict>
    </dict>
    </plist>
  XML

  def test_the_plist_runs_the_launcher_every_five_minutes_with_the_installing_path_and_root
    assert_equal EXPECTED, installer.plist
  end

  def test_without_qm_root_set_the_plist_carries_only_path
    plist = installer(env: { "PATH" => "/usr/bin" }).plist

    refute_includes plist, "QM_ROOT"
    assert_includes plist, "<key>PATH</key>\n    <string>/usr/bin</string>\n  </dict>"
  end

  def test_values_are_xml_escaped
    plist = installer(env: { "PATH" => "/a&b:<c>" }, root: "/r&d").plist

    assert_includes plist, "<string>/a&amp;b:&lt;c&gt;</string>"
    assert_includes plist, "<string>/r&amp;d/automations/tick.log</string>"
  end

  def test_the_program_defaults_to_the_launchers_realpath
    plist = Quartermaster::TickInstaller.new(runner: @runner, agents_dir: @agents).plist

    assert_includes plist, "<string>#{File.realpath(QM_BIN)}</string>\n    <string>automation</string>"
  end

  def test_install_writes_the_plist_and_bootstraps_it_in_the_users_gui_domain
    root = File.join(Quartermaster::ROOT, "elsewhere")
    tick = installer(root: root)
    refute tick.installed?

    tick.install

    assert_equal tick.plist, File.read(plist_file)
    assert tick.installed?
    assert File.directory?(File.join(root, "automations")), "launchd needs the log's directory"
    assert_equal [%w[launchctl bootout gui/501/com.quartermaster.automation-tick],
                  ["launchctl", "bootstrap", "gui/501", plist_file]], @runner.argvs
  end

  def test_a_failed_bootstrap_leaves_no_plist_and_says_why
    @runner = FakeRunner.new(%w[launchctl bootstrap] => ["", "Bootstrap failed: 5: Input/output error", false])
    tick = installer(root: Quartermaster::ROOT)

    error = assert_raises(ArgumentError) { tick.install }

    assert_includes error.message, "Bootstrap failed: 5"
    refute tick.installed?
  end

  def test_uninstall_boots_out_and_removes_the_plist
    tick = installer(root: Quartermaster::ROOT)
    tick.install
    @runner.calls.clear

    tick.uninstall

    refute tick.installed?
    assert_equal [%w[launchctl bootout gui/501/com.quartermaster.automation-tick]], @runner.argvs
  end

  def test_uninstall_removes_the_plist_even_when_launchd_no_longer_has_it
    @runner = FakeRunner.new(%w[launchctl bootout] => ["", "Boot-out failed: 3: No such process", false])
    tick = installer(root: Quartermaster::ROOT)
    File.write(plist_file, "stale")

    tick.uninstall

    refute tick.installed?
  end
end
