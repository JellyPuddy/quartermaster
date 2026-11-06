# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/error_log_test.rb`).
require_relative "test_helper"

class ErrorLogTest < Minitest::Test
  include QmTestHelpers

  NOW = Time.utc(2026, 11, 6, 12, 0, 0)

  def setup
    super
    Quartermaster.ensure_setup
  end

  def log_path = Quartermaster::LOG_FILE
  def seen_path = File.join(Quartermaster::ROOT, "errors-seen-at")

  def write_log(text) = File.write(log_path, text)

  def error_log(**opts) = Quartermaster::ErrorLog.new(now: NOW, **opts)

  def at(hours_ago) = (NOW - (hours_ago * 3600)).iso8601

  def test_counts_errors_of_the_last_day_without_a_seen_marker
    write_log(<<~LOG)
      #{at(30)} [gui-client] TypeError: too old
      #{at(5)} [gh-stack-sync] TypeError: no implicit conversion of Hash into String
        lib/quartermaster/gh_stack.rb:12:in `sync'
        lib/quartermaster/gui.rb:40:in `block in run'
      #{at(4)} [pr-inbox] transient RuntimeError: gh: error connecting to api.github.com
      #{at(3)} [pr-inbox] recovered after 7 failures
      #{at(1)} [hook-session-start] Errno::ENOENT: No such file or directory
    LOG

    log = error_log
    assert_equal 2, log.count
    first, second = log.entries
    assert_equal ["#{at(5)} [gh-stack-sync] TypeError: no implicit conversion of Hash into String",
                  "  lib/quartermaster/gh_stack.rb:12:in `sync'",
                  "  lib/quartermaster/gui.rb:40:in `block in run'"], first["lines"]
    assert_equal "gh-stack-sync", first["context"]
    assert_equal at(5), first["at"]
    assert_equal ["#{at(1)} [hook-session-start] Errno::ENOENT: No such file or directory"], second["lines"]
  end

  def test_counts_only_errors_after_the_seen_marker
    File.write(seen_path, "#{at(2)}\n")
    write_log(<<~LOG)
      #{at(3)} [gui-client] TypeError: seen already
      #{at(1)} [gui-client] TypeError: new one
    LOG

    assert_equal 1, error_log.count
    assert_equal "#{at(1)} [gui-client] TypeError: new one", error_log.entries.first["lines"].first
  end

  def test_an_unreadable_seen_marker_falls_back_to_the_last_day
    File.write(seen_path, "garbage")
    write_log("#{at(30)} [x] RuntimeError: old\n#{at(1)} [x] RuntimeError: new\n")

    assert_equal 1, error_log.count
  end

  def test_mark_seen_writes_now_and_clears_the_count
    write_log("#{at(1)} [x] RuntimeError: boom\n")

    error_log.mark_seen

    assert_equal NOW.iso8601, File.read(seen_path).strip
    assert_equal 0, error_log.count
    assert_equal 0, Quartermaster::ErrorLog.new(now: NOW + 3600).count
  end

  def test_no_log_means_no_errors
    assert_equal 0, error_log.count
    assert_equal({ "count" => 0, "entries" => [] }, error_log.summary)
  end

  def test_reads_only_the_tail_and_skips_a_cut_entry
    old = "#{at(2)} [x] RuntimeError: early\n" * 50
    write_log("#{old}#{at(1)} [y] RuntimeError: late\n  lib/quartermaster/y.rb:1:in `y'\n")
    tail = "#{at(1)} [y] RuntimeError: late\n  lib/quartermaster/y.rb:1:in `y'\n".bytesize + 10

    log = error_log(tail_bytes: tail)

    assert_equal 1, log.count
    assert_equal "y", log.entries.first["context"]
  end

  def test_an_orphaned_continuation_at_the_tail_start_is_dropped
    write_log("#{at(1)} [x] RuntimeError: cut\n  lib/quartermaster/x.rb:1:in `x'\n#{at(1)} [z] RuntimeError: kept\n")
    tail = "  lib/quartermaster/x.rb:1:in `x'\n#{at(1)} [z] RuntimeError: kept\n".bytesize

    assert_equal ["z"], error_log(tail_bytes: tail).entries.map { |e| e["context"] }
  end

  def gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def mark_seen_body = JSON.generate("cmd" => "errors-seen")

  def test_the_gui_state_carries_the_badge_and_mark_seen_clears_it
    write_log("#{(Time.now - 60).iso8601} [gui-client] TypeError: boom\n  lib/quartermaster/gui.rb:1:in `x'\n")
    server = gui

    errors = JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])["errors"]
    assert_equal 1, errors["count"]
    assert_equal ["  lib/quartermaster/gui.rb:1:in `x'"], errors["entries"].first["lines"].drop(1)

    reply = JSON.parse(server.respond("POST", "/api/action", ok_host, mark_seen_body)[2])
    assert_equal({ "ok" => true, "errors" => { "count" => 0, "entries" => [] } }, reply)
    assert_in_delta Time.now.to_i, Time.iso8601(File.read(seen_path)).to_i, 5
    assert_equal 0, JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])["errors"]["count"]
  end

  def test_mark_seen_is_refused_from_another_origin_or_none
    status, = gui.respond("POST", "/api/action", ok_host.merge("origin" => "https://evil.example.com"), mark_seen_body)
    assert_equal "403 Forbidden", status
    status, = gui.respond("POST", "/api/action", { "host" => "127.0.0.1:4567" }, mark_seen_body)
    assert_equal "403 Forbidden", status
    refute File.exist?(seen_path)
  end

  def test_the_page_has_the_badge_and_its_mark_seen_call
    page = served_page(gui, ok_host)

    assert_includes page, 'id="errors-badge"'
    assert_includes page, 'act("errors-seen")'
    assert_includes page, "renderErrorBadge()"
  end

  def test_summary_lists_the_newest_twenty_newest_first
    write_log((1..25).map { |i| "#{(NOW - 3600 + i).iso8601} [c#{i}] RuntimeError: e#{i}\n" }.join)

    summary = error_log.summary

    assert_equal 25, summary["count"]
    assert_equal 20, summary["entries"].size
    assert_equal "c25", summary["entries"].first["context"]
    assert_equal "c6", summary["entries"].last["context"]
  end
end
