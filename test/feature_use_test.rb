# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/feature_use_test.rb`).
require_relative "test_helper"

# The feature-use log: which GUI actions, GUI reads and CLI commands get used.
class FeatureUseTest < Minitest::Test
  include QmTestHelpers

  def gui
    @gui ||= Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
  end

  def ok_host
    { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  end

  def uses
    return [] unless File.exist?(Quartermaster::FeatureUse::FILE)

    File.readlines(Quartermaster::FeatureUse::FILE).map { |line| JSON.parse(line) }
  end

  def used = uses.map { |use| use.values_at("kind", "name") }

  def test_a_gui_action_is_logged_by_its_cmd_even_an_unknown_one
    gui.respond("POST", "/api/action", ok_host, JSON.generate("cmd" => "no-such-cmd", "args" => { "slug" => "x" }))
    gui.respond("POST", "/api/ask", ok_host, JSON.generate("query" => ""))

    assert_equal [%w[action no-such-cmd], %w[action /api/ask]], used
    use = uses.first
    assert_equal %w[at kind name v], use.keys.sort, "nothing but the kind and name"
    assert_equal 1, use["v"]
    assert_equal use["at"], Time.iso8601(use["at"]).utc.iso8601
  end

  def test_a_get_is_logged_by_its_route_without_the_id_and_polls_are_not
    gui.respond("GET", "/api/session/sess-ghost", ok_host, "")
    gui.respond("GET", "/api/issues?x=1", ok_host, "")
    gui.respond("GET", "/api/state", ok_host, "")
    gui.respond("GET", "/api/pulse?page=1", ok_host, "")
    gui.respond("GET", "/", ok_host, "")
    gui.respond("GET", "/assets/js/core.js", ok_host, "")

    assert_equal [%w[get /api/session], %w[get /api/issues]], used
  end

  def test_a_refused_request_is_not_a_use
    gui.respond("GET", "/api/session/s", { "host" => "evil.example.com" }, "")
    gui.respond("POST", "/api/action", { "host" => "127.0.0.1:4567" }, JSON.generate("cmd" => "resume"))

    assert_empty used
  end

  def test_a_failing_write_never_fails_the_request
    FileUtils.mkdir_p(Quartermaster::FeatureUse::FILE) # a directory where the log should be

    status, = gui.respond("GET", "/api/session/sess-ghost", ok_host, "")

    assert_equal "200 OK", status
    assert_match(/\[feature-use\] Errno::EISDIR/, File.read(Quartermaster::LOG_FILE))
  end

  def test_a_cli_command_is_logged_by_its_word
    capture_io { Quartermaster::CLI.new.run(["list"]) }

    assert_equal [%w[cli list]], used
  end

  def test_hook_commands_and_qm_skip_runs_are_not_uses
    _out, _err, status = run_hook("hook-session-end", "{}", "QM_SKIP" => nil)
    assert status.success?
    Quartermaster::FeatureUse.new.command("doctor")
    original = ENV.fetch("QM_SKIP", nil)
    begin
      ENV["QM_SKIP"] = "1"
      capture_io { Quartermaster::CLI.new.run(["list"]) }
    ensure
      ENV["QM_SKIP"] = original
    end

    assert_empty used
  end
end

# The read side: `qm feature-use [--days N]`.
class FeatureUseReportTest < Minitest::Test
  include QmTestHelpers

  NOW = Time.utc(2026, 10, 30, 12)

  def log(*uses)
    FileUtils.mkdir_p(Quartermaster::ROOT)
    File.write(Quartermaster::FeatureUse::FILE, uses.map do |kind, name, days_ago|
      "#{JSON.generate("v" => 1, "at" => (NOW - (days_ago * 86_400)).iso8601, "kind" => kind, "name" => name)}\n"
    end.join)
  end

  def report(argv = [])
    Quartermaster::FeatureUse.new(clock: -> { NOW }).report(argv)
  end

  def date(days_ago) = (NOW - (days_ago * 86_400)).localtime.strftime("%Y-%m-%d")

  def never_used(text, kind) = text[/^  #{kind}: (.*)$/, 1].split(", ")

  def test_counts_most_used_first_with_last_use_and_the_log_start
    log(["action", "note", 40], ["action", "note", 3], ["action", "note", 1], ["action", "resume", 2],
        ["get", "/api/diff", 5], ["cli", "list", 0])

    text = report

    assert_includes text, "last 30 days (log starts #{date(40)})"
    action = text[/^action \(3 uses\)\n((?:  .*\n)+)/, 1]
    assert_match(/\A\s+2  note\s+last #{date(1)}\n\s+1  resume\s+last #{date(2)}\n\z/, action)
    assert_match(%r{^get \(1 use\)\n\s+1  /api/diff\s+last #{date(5)}$}, text)
    assert_match(/^cli \(1 use\)\n\s+1  list\s+last #{date(0)}$/, text)
  end

  def test_never_used_lists_known_names_without_a_use_in_the_window
    log(["action", "note", 1], ["action", "resume", 45], ["get", "/api/diff", 2], ["cli", "list", 3])

    text = report

    assert_includes never_used(text, "action"), "resume", "a use outside the window doesn't count"
    refute_includes never_used(text, "action"), "note"
    assert_includes never_used(text, "get"), "/api/session"
    refute_includes never_used(text, "get"), "/api/diff"
    assert_includes never_used(text, "cli"), "show"
    refute_includes never_used(text, "cli"), "list"
  end

  def test_days_narrows_the_window
    log(["action", "note", 10], ["action", "note", 2])

    text = report(%w[--days 7])

    assert_includes text, "last 7 days"
    assert_match(/^action \(1 use\)\n\s+1  note/, text)
    assert_raises(ArgumentError) { report(%w[--days 0]) }
    assert_raises(ArgumentError) { report(%w[--days lots]) }
    assert_raises(ArgumentError, "a bare number doesn't silently fall back to 30 days") { report(%w[7]) }
  end

  def test_an_empty_log_still_lists_everything_as_unused
    text = report

    assert_includes text, "nothing logged yet"
    assert_includes never_used(text, "cli"), "list"
  end

  def test_known_names_are_read_from_the_dispatchers
    action = Quartermaster::FeatureUse.known_names("action")
    get = Quartermaster::FeatureUse.known_names("get")
    cli = Quartermaster::FeatureUse.known_names("cli")

    assert_operator action.size, :>, 40
    %w[resume pane-resume /api/drop].each { |name| assert_includes action, name }
    refute_includes action, "/api/action"
    %w[/api/diff /api/session].each { |name| assert_includes get, name }
    assert_equal get.uniq, get
    refute_includes get, "/api/state"
    refute_includes get, "/api/pulse"
    %w[note pane-start feature-use].each { |name| assert_includes cli, name }
    assert cli.none? { |word| word.start_with?("hook-", "-") }, "no hooks or flag aliases"
    refute_includes cli, "doctor", "doctor is never recorded, so it can't count as unused"
  end

  # The command tables are what known_names reads, so a stale entry would
  # list a command that dies with NoMethodError, and an explicit branch of
  # CLI#run naming a table word would silently win over its group.
  def test_every_table_command_has_its_method_and_no_explicit_branch_shadows_it
    commands = Quartermaster::CLI.commands
    assert_operator commands.size, :>, 40
    missing = commands.reject { |_, method| Quartermaster::CLI.private_method_defined?(method) }
    assert_empty missing, "CLI.commands names methods no command group defines"
    assert_empty commands.keys & Quartermaster::FeatureUse.cli_branches
  end

  def test_the_command_prints_the_report
    log(["cli", "list", 1])

    out, = capture_io { Quartermaster::CLI.new.run(%w[feature-use --days 3]) }

    assert_includes out, "Feature use, last 3 days"
    assert_includes out, "Never used in the last 3 days"
  end
end
