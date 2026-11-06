# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/ruby_pin_test.rb`).
# The launcher's sh half (the Ruby pin), `qm pin-ruby`, and the Ruby floor guard.
require_relative "test_helper"

class RubyPinTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    @dir = Dir.mktmpdir("qm-pin")
    @asdf = File.join(@dir, "asdf")
    FileUtils.mkdir_p(File.join(@asdf, "installs", "ruby", "3.4.7"))
    @bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(@bin)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # A `ruby` first on PATH that reports what the launcher handed it.
  def stub_ruby_reporting
    write_ruby_stub(<<~SH)
      #!/bin/sh
      echo "asdf=${ASDF_RUBY_VERSION-unset} mise=${MISE_RUBY_VERSION-unset}"
      echo "argv=$*"
    SH
  end

  def stub_ruby_passing_through
    write_ruby_stub("#!/bin/sh\nexec #{Shellwords.escape(RbConfig.ruby)} \"$@\"\n")
  end

  def write_ruby_stub(body)
    path = File.join(@bin, "ruby")
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def launch(*argv, via: QM_BIN, env: {})
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "ASDF_DATA_DIR" => @asdf,
                     "PATH" => "#{@bin}:/usr/bin:/bin", "ASDF_RUBY_VERSION" => nil,
                     "MISE_RUBY_VERSION" => nil }.merge(env), via, *argv)
  end

  def pin_file
    File.join(Quartermaster::ROOT, "ruby-version")
  end

  def write_pin(content)
    FileUtils.mkdir_p(Quartermaster::ROOT)
    File.write(pin_file, content)
  end

  def test_without_a_pin_file_ruby_runs_as_the_environment_resolves_it
    stub_ruby_reporting
    out, _err, status = launch("hook-session-start", env: { "ASDF_RUBY_VERSION" => "9.9.9" })

    assert status.success?
    assert_equal ["asdf=9.9.9 mise=unset", "argv=#{QM_BIN} hook-session-start"], out.lines.map(&:chomp)
  end

  def test_a_pinned_version_overrides_the_environment
    stub_ruby_reporting
    write_pin("3.4.7\n")
    out, = launch("list", "--all", env: { "ASDF_RUBY_VERSION" => "9.9.9" })

    assert_equal ["asdf=3.4.7 mise=3.4.7", "argv=#{QM_BIN} list --all"], out.lines.map(&:chomp)
  end

  def test_a_pinned_launch_remembers_the_versions_it_overrode
    write_ruby_stub(<<~SH)
      #!/bin/sh
      echo "outer_asdf=${QM_OUTER_ASDF_RUBY_VERSION-unset} outer_mise=${QM_OUTER_MISE_RUBY_VERSION-unset}"
    SH
    write_pin("3.4.7\n")
    out, = launch("list", env: { "ASDF_RUBY_VERSION" => "9.9.9" })

    assert_equal "outer_asdf=9.9.9 outer_mise=", out.chomp
  end

  # Chats, dev servers and IDEs qm starts must run on their project's Ruby,
  # not on the one qm pinned for itself.
  def test_qm_hands_its_children_the_ruby_versions_it_overrode
    env = { "ASDF_RUBY_VERSION" => "3.4.7", "MISE_RUBY_VERSION" => "3.4.7",
            "QM_OUTER_ASDF_RUBY_VERSION" => "9.9.9", "QM_OUTER_MISE_RUBY_VERSION" => "" }
    Quartermaster::RubyPin.hand_back_outer_env(env)

    assert_equal({ "ASDF_RUBY_VERSION" => "9.9.9" }, env)
  end

  def test_an_unpinned_launch_leaves_the_ruby_versions_alone
    env = { "ASDF_RUBY_VERSION" => "9.9.9" }
    Quartermaster::RubyPin.hand_back_outer_env(env)

    assert_equal({ "ASDF_RUBY_VERSION" => "9.9.9" }, env)
  end

  def test_an_empty_pin_file_pins_nothing
    stub_ruby_reporting
    write_pin("  \n")
    out, = launch("list")

    assert_equal "asdf=unset mise=unset", out.lines.first.chomp
  end

  # An uninstalled pin would make the asdf shim fail every hook; running
  # unpinned instead leaves the floor guard to report a too-old Ruby.
  def test_a_pin_asdf_has_not_installed_is_skipped
    stub_ruby_reporting
    write_pin("3.1.0")
    out, = launch("list")

    assert_equal "asdf=unset mise=unset", out.lines.first.chomp
  end

  def test_the_launcher_resolves_its_lib_through_a_symlink
    stub_ruby_passing_through
    link = File.join(@bin, "qm")
    File.symlink(QM_BIN, link)
    out, err, status = launch("pin-ruby", "3.4.7", via: link)

    assert status.success?, err
    assert_match(/3\.4\.7/, out)
    assert_equal "3.4.7\n", File.read(pin_file)
  end

  def test_pin_ruby_defaults_to_the_running_ruby
    FileUtils.mkdir_p(File.join(@asdf, "installs", "ruby", RUBY_VERSION))
    _out, err, status = run_qm("pin-ruby")

    assert status.success?, err
    assert_equal "#{RUBY_VERSION}\n", File.read(pin_file)
  end

  def test_pin_ruby_refuses_a_version_asdf_has_not_installed
    _out, err, status = run_qm("pin-ruby", "3.4.1")

    refute status.success?
    assert_match(/3\.4\.1 is not installed/, err)
    refute File.exist?(pin_file)
  end

  def test_pin_ruby_refuses_a_version_below_the_floor
    FileUtils.mkdir_p(File.join(@asdf, "installs", "ruby", "3.0.1"))
    _out, err, status = run_qm("pin-ruby", "3.0.1")

    refute status.success?
    assert_match(/needs Ruby >= 3\.3/, err)
    refute File.exist?(pin_file)
  end

  def test_pin_ruby_accepts_any_version_without_asdf
    FileUtils.rm_rf(File.join(@asdf, "installs"))
    _out, err, status = run_qm("pin-ruby", "3.4.1")

    assert status.success?, err
    assert_equal "3.4.1\n", File.read(pin_file)
  end

  def test_pin_ruby_clear_removes_the_pin
    write_pin("3.4.7\n")
    out, _err, status = run_qm("pin-ruby", "--clear")

    assert status.success?
    assert_match(/unpinned/i, out)
    refute File.exist?(pin_file)
  end

  def run_qm(*argv)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "ASDF_DATA_DIR" => @asdf }, RbConfig.ruby, QM_BIN, *argv)
  end
end

class RubyFloorTest < Minitest::Test
  include QmTestHelpers

  def enforce(command, version)
    Quartermaster::RubyFloor.enforce(command, version: version, ruby: "/opt/old/bin/ruby")
  end

  def log_lines
    File.readlines(File.join(Quartermaster::ROOT, "qm.log"), chomp: true)
  end

  def test_a_ruby_at_or_above_the_floor_passes_silently
    out, err = capture_io do
      enforce("list", "3.3.0")
      enforce("hook-session-start", "4.0.6")
    end

    assert_equal ["", ""], [out, err]
    refute File.exist?(File.join(Quartermaster::ROOT, "qm.log"))
  end

  def test_a_hook_below_the_floor_logs_once_stays_silent_and_exits_zero
    error = nil
    out, err = capture_io { error = assert_raises(SystemExit) { enforce("hook-session-start", "3.0.1") } }

    assert_equal 0, error.status
    assert_equal ["", ""], [out, err]
    assert_equal 1, log_lines.size
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d \[ruby-floor\] qm needs Ruby >= 3\.3, got 3\.0\.1 \(\/opt\/old\/bin\/ruby\); pin one with qm pin-ruby\z/,
                 log_lines.first)
  end

  def test_a_command_below_the_floor_logs_warns_on_stderr_and_exits_one
    error = nil
    out, err = capture_io { error = assert_raises(SystemExit) { enforce("list", "2.6.10") } }

    assert_equal 1, error.status
    assert_equal "", out
    assert_equal "#{log_lines.first.split(" ", 2).last}\n", err
    assert_match(/got 2\.6\.10/, log_lines.first)
  end

  # The guard has to run on the old Ruby it reports, so it may use no 3.x syntax.
  def test_the_launcher_guard_runs_on_a_pre_floor_system_ruby
    system_ruby = "/usr/bin/ruby"
    version = File.executable?(system_ruby) && `#{system_ruby} -e 'print RUBY_VERSION'`
    skip "no pre-3.3 system Ruby here" unless version && (version.split(".").map(&:to_i) <=> [3, 3]).negative?

    out, err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT }, system_ruby, QM_BIN, "hook-session-start",
                                      stdin_data: "{}")
    assert_equal [0, "", ""], [status.exitstatus, out, err]
    assert_match(/\[ruby-floor\] qm needs Ruby >= 3\.3, got #{Regexp.escape(version)} \(\/\S+ruby\)/, log_lines.last)
  end
end
