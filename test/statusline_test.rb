# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/statusline_test.rb`).
# The status line runs under /usr/bin/ruby
# (system Ruby 2.6), so these tests run it there, as a subprocess, with a
# HOME of their own: its ~/bin/qm is a stub printing a fixed item title.
require_relative "test_helper"
class StatuslineTest < Minitest::Test
  include QmTestHelpers

  STATUSLINE = File.expand_path("../statusline/statusline.rb", __dir__)
  SYSTEM_RUBY = "/usr/bin/ruby"
  def setup
    super
    skip "no #{SYSTEM_RUBY}" unless File.executable?(SYSTEM_RUBY)
    @now = Time.now.to_i
    @home = Dir.mktmpdir("qm-test-statusline-home")
    FileUtils.mkdir_p(File.join(@home, "bin"))
    qm = File.join(@home, "bin", "qm")
    File.write(qm, "#!/bin/sh\necho 'Stub item title'\n")
    File.chmod(0o755, qm)
    @cwd = Dir.mktmpdir("qm-test-statusline-cwd")
    FileUtils.mkdir_p(Quartermaster::ROOT)
  end

  def teardown
    FileUtils.rm_rf(@home) if @home
    FileUtils.rm_rf(@cwd) if @cwd
  end

  def input(rate_limits: default_limits)
    data = {
      "session_id" => "s-1",
      "workspace" => { "current_dir" => @cwd },
      "model" => { "display_name" => "Opus" },
      "context_window" => { "used_percentage" => 31.4 }
    }
    data["rate_limits"] = rate_limits if rate_limits
    JSON.generate(data)
  end

  def default_limits
    { "five_hour" => { "used_percentage" => 42.2, "resets_at" => @now + 8100 },
      "seven_day" => { "used_percentage" => 61.0, "resets_at" => @now + 273_600 } }
  end

  def statusline(stdin = input, ruby: SYSTEM_RUBY, **env)
    out, err, status = Open3.capture3(
      { "HOME" => @home, "QM_ROOT" => Quartermaster::ROOT, "COLUMNS" => "160", "TMUX" => nil,
        "QM_TMUX_SOCKET" => nil, "TERM" => "dumb" }.merge(env.transform_keys(&:to_s)),
      ruby, STATUSLINE, stdin_data: stdin
    )
    assert status.success?, "status line failed: #{err}"
    out.gsub(/\e\[[0-9;]*m/, "")
  end

  def snapshot_path
    File.join(Quartermaster::ROOT, "rate-limits.json")
  end

  def test_parses_under_system_ruby_without_warnings
    _, err, status = Open3.capture3(SYSTEM_RUBY, "-wc", STATUSLINE)
    assert status.success?, err
    assert_empty err
  end

  def test_outside_qm_shows_limits_and_the_item_line
    out = statusline

    assert_match(/ctx \[.*\] 31%/, out)
    assert_match(/5h \[.*\] 42% \(2h1[45]m\)/, out)
    assert_match(/wk \[.*\] 61% \(3d[34]h\)/, out)
    assert_match(/\n◆ Stub item title\z/, out)
  end

  def test_a_qm_chat_drops_the_limits_and_the_item_line_but_keeps_context
    out = statusline(TMUX: "/private/tmp/tmux-501/qm,4242,3")

    assert_match(/ctx \[.*\] 31%/, out)
    refute_match(/\b(5h|wk) \[/, out)
    refute_includes out, "◆"
    refute_includes out, "\n"
  end

  def test_a_test_gui_socket_counts_as_qm
    out = statusline(TMUX: "/private/tmp/tmux-501/qm-test-7,1,0", QM_TMUX_SOCKET: "qm-test-7")

    refute_match(/\b5h \[/, out)
    refute_includes out, "◆"
  end

  def test_another_tmux_server_is_not_qm
    out = statusline(TMUX: "/private/tmp/tmux-501/default,99,0")

    assert_match(/\b5h \[/, out)
    assert_includes out, "◆ Stub item title"
  end

  def test_writes_the_snapshot_atomically_into_the_qm_root
    statusline(TMUX: "/private/tmp/tmux-501/qm,4242,3")

    doc = JSON.parse(File.read(snapshot_path))
    assert_equal 1, doc["v"]
    assert_equal({ "used_percentage" => 42.2, "resets_at" => @now + 8100 }, doc["five_hour"])
    assert_equal({ "used_percentage" => 61.0, "resets_at" => @now + 273_600 }, doc["seven_day"])
    assert_in_delta Time.now.to_i, Time.parse(doc["captured_at"]).to_i, 30
    assert_equal ["rate-limits.json"], Dir.children(Quartermaster::ROOT)
  end

  def test_no_rate_limits_leaves_the_last_snapshot_alone
    File.write(snapshot_path, "previous")

    out = statusline(input(rate_limits: nil))

    assert_equal "previous", File.read(snapshot_path)
    refute_match(/\b5h \[/, out)
  end

  def test_never_creates_the_qm_root
    FileUtils.rm_rf(Quartermaster::ROOT)

    statusline

    refute File.exist?(Quartermaster::ROOT)
  end

  def test_an_unwritable_snapshot_never_breaks_the_status_line
    FileUtils.mkdir_p(snapshot_path) # a directory where the file goes: rename fails

    out = statusline

    assert_match(/5h \[.*\] 42%/, out)
    assert_equal [".", "..", "rate-limits.json"].sort, Dir.entries(Quartermaster::ROOT).sort
  end

  def test_also_runs_on_the_suite_ruby
    out = statusline(ruby: RbConfig.ruby)

    assert_match(/5h \[.*\] 42%/, out)
    assert File.exist?(snapshot_path)
  end
end
