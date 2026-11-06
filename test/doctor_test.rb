# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/doctor_test.rb`).
# `qm doctor`; the error count it shares with the badge is tested in error_log_test.rb.
require_relative "test_helper"

class DoctorTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    @dir = Dir.mktmpdir("qm-doctor")
    @settings = File.join(@dir, "settings.json")
    @asdf = File.join(@dir, "asdf")
    FileUtils.mkdir_p(File.join(@asdf, "installs", "ruby", "3.4.7"))
    @launcher = File.join(@dir, "bin", "quartermaster")
    @record = File.join(@dir, "hooks", "record-event.sh")
    [@launcher, @record].each do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#!/bin/sh\n")
    end
    Quartermaster.ensure_setup
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def command(cmd) = [{ "hooks" => [{ "type" => "command", "command" => cmd }] }]

  def write_settings(**overrides)
    hooks = {
      "SessionStart" => command("#{@launcher} hook-session-start"),
      "SessionEnd" => command("#{@launcher} hook-session-end")
    }
    %w[UserPromptSubmit PermissionRequest Stop StopFailure PostToolUseFailure PostToolUse].each do |event|
      hooks[event] = command(@record)
    end
    File.write(@settings, JSON.generate("hooks" => hooks.merge(overrides.transform_keys(&:to_s)).compact))
  end

  def pin(version)
    File.write(File.join(Quartermaster::ROOT, "ruby-version"), "#{version}\n")
  end

  def captured(ago: 60)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "s1", "ts" => (Time.now - ago).iso8601)
  end

  def doctor(**options)
    Quartermaster::Doctor.new(settings_path: @settings, pin: Quartermaster::RubyPin.new(asdf_dir: @asdf), **options)
  end

  def marks = doctor.checks.to_h { |check| [check.name, check.mark] }
  def check(name) = doctor.checks.find { |c| c.name == name }

  def test_a_healthy_setup_passes_every_check
    write_settings
    pin("3.4.7")
    captured

    assert_equal({ "SessionStart hook" => "✓", "SessionEnd hook" => "✓", "record-event.sh hook" => "✓",
                   "Ruby pin" => "✓", "Ruby floor" => "✓", "Data root" => "✓", "qm.log errors" => "✓",
                   "Capture" => "✓" }, marks)
    refute doctor.failed?
  end

  def test_the_snippet_qm_install_hooks_prints_passes_every_hook_check
    out, _err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT }, RbConfig.ruby, QM_BIN, "install-hooks")
    assert status.success?
    File.write(@settings, out.lines.reject { |line| line.start_with?("#") }.join)

    assert_equal %w[✓ ✓ ✓], ["SessionStart hook", "SessionEnd hook", "record-event.sh hook"].map { |n| check(n).mark }
  end

  def test_a_missing_session_start_hook_fails_with_the_install_hint
    write_settings(SessionStart: nil)

    assert_equal "✗", check("SessionStart hook").mark
    assert_match(/qm install-hooks/, check("SessionStart hook").line)
    assert doctor.failed?
  end

  def test_a_hook_pointing_at_a_missing_file_fails
    write_settings(SessionEnd: command("/nowhere/quartermaster hook-session-end"))

    assert_equal "✗", check("SessionEnd hook").mark
    assert_match(%r{/nowhere/quartermaster}, check("SessionEnd hook").line)
  end

  def test_record_event_missing_from_one_event_fails_naming_it
    write_settings(Stop: nil)

    assert_equal "✗", check("record-event.sh hook").mark
    assert_match(/Stop/, check("record-event.sh hook").line)
  end

  def test_unreadable_settings_fail_every_hook_check
    File.write(@settings, "{ not json")

    assert_equal %w[✗ ✗ ✗], ["SessionStart hook", "SessionEnd hook", "record-event.sh hook"].map { |n| check(n).mark }
  end

  def test_no_pin_is_a_warning
    assert_equal "!", check("Ruby pin").mark
    assert_match(/qm pin-ruby/, check("Ruby pin").line)
  end

  def test_a_pin_asdf_lacks_fails
    pin("3.4.1")

    assert_equal "✗", check("Ruby pin").mark
    assert_match(/asdf install ruby 3\.4\.1/, check("Ruby pin").line)
  end

  def test_a_ruby_below_the_floor_fails
    assert_equal "✗", doctor(ruby_version: "3.0.1").checks.find { |c| c.name == "Ruby floor" }.mark
  end

  def test_an_unwritable_root_fails
    File.chmod(0o500, Quartermaster::ROOT)

    assert_equal "✗", check("Data root").mark
  ensure
    File.chmod(0o700, Quartermaster::ROOT)
  end

  def test_errors_since_the_marker_warn_with_the_last_one
    File.write(Quartermaster::LOG_FILE, "#{(Time.now - 60).iso8601} [gui] RuntimeError: boom\n")

    assert_equal "!", check("qm.log errors").mark
    assert_match(/1 error.*RuntimeError: boom/, check("qm.log errors").line)
  end

  def test_nothing_captured_in_a_day_warns
    captured(ago: 2 * 24 * 3600)

    assert_equal "!", check("Capture").mark
    assert_match(/tool-versions/, check("Capture").line)
  end

  def test_a_recent_tool_call_event_counts_as_capture
    captured(ago: 2 * 24 * 3600)
    File.write(File.join(Quartermaster::ROOT, "events.jsonl"),
               "#{JSON.generate("v" => 1, "ts" => Time.now.utc.iso8601, "session_id" => "s1", "event" => "Stop")}\n")

    assert_equal "✓", check("Capture").mark
  end

  def test_doctor_writes_nothing
    write_settings
    File.write(File.join(Quartermaster::ROOT, "events.jsonl"),
               "#{JSON.generate("v" => 1, "ts" => Time.now.utc.iso8601, "session_id" => "s1", "event" => "Stop")}\n")
    before = Dir.children(Quartermaster::ROOT).sort
    doctor.checks

    assert_equal before, Dir.children(Quartermaster::ROOT).sort
  end

  def test_qm_doctor_prints_a_line_per_check_and_exits_one_on_a_failure
    out, _err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_CLAUDE_SETTINGS" => @settings,
                                         "ASDF_DATA_DIR" => @asdf }, RbConfig.ruby, QM_BIN, "doctor")

    assert_equal 1, status.exitstatus
    assert_equal 8, out.lines.size
    assert(out.lines.all? { |line| line.start_with?("✓ ", "✗ ", "! ") })
    assert_match(/✗ SessionStart hook: .*#{Regexp.escape(@settings)}/, out)
  end
end
