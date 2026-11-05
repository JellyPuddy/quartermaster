# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/rate_limits_test.rb`).
require_relative "test_helper"
class RateLimitsTest < Minitest::Test
  include QmTestHelpers

  def snapshot_path
    File.join(Quartermaster::ROOT, "rate-limits.json")
  end

  def write_snapshot(doc)
    FileUtils.mkdir_p(Quartermaster::ROOT)
    File.write(snapshot_path, doc.is_a?(String) ? doc : JSON.generate(doc))
  end

  def payload = Quartermaster::RateLimits.new.payload

  def test_nil_without_a_snapshot
    assert_nil payload
  end

  def test_reads_what_the_status_line_writes
    stdin = JSON.generate("workspace" => { "current_dir" => Dir.tmpdir },
                          "rate_limits" => { "five_hour" => { "used_percentage" => 12.5, "resets_at" => 1_792_756_800 },
                                             "seven_day" => { "used_percentage" => 80, "resets_at" => 1_793_000_000 } })
    FileUtils.mkdir_p(Quartermaster::ROOT)
    _out, err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "COLUMNS" => "120" }, RbConfig.ruby,
                                       File.expand_path("../statusline/statusline.rb", __dir__), stdin_data: stdin)
    assert status.success?, err

    limits = payload
    assert_equal({ "usedPercentage" => 12.5, "resetsAt" => Time.at(1_792_756_800).utc.iso8601 }, limits["fiveHour"])
    assert_equal({ "usedPercentage" => 80, "resetsAt" => Time.at(1_793_000_000).utc.iso8601 }, limits["sevenDay"])
    assert_in_delta Time.now.to_i, Time.parse(limits["capturedAt"]).to_i, 30
  end

  def test_a_missing_window_reads_as_nil_and_no_windows_as_no_limits
    write_snapshot("captured_at" => "2026-10-23T11:00:00Z", "five_hour" => { "used_percentage" => 5 }, "seven_day" => nil)
    assert_equal({ "fiveHour" => { "usedPercentage" => 5, "resetsAt" => nil }, "sevenDay" => nil,
                   "capturedAt" => "2026-10-23T11:00:00Z" }, payload)

    write_snapshot("captured_at" => "2026-10-23T11:00:00Z", "five_hour" => nil, "seven_day" => nil)
    assert_nil payload
  end

  def test_a_broken_snapshot_reads_as_no_limits
    write_snapshot("{not json")
    assert_nil payload

    write_snapshot("five_hour" => { "used_percentage" => 5, "resets_at" => 1 })
    assert_nil payload, "no captured_at: its age is unknown"
  end

  def test_gui_state_carries_them_for_the_header_chip
    write_snapshot("captured_at" => "2026-10-23T11:00:00Z",
                   "five_hour" => { "used_percentage" => 42, "resets_at" => 1_792_756_800 })
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

    state = JSON.parse(server.respond("GET", "/api/state", { "host" => "127.0.0.1:4567" }, "")[2])

    assert_equal 42, state["rateLimits"]["fiveHour"]["usedPercentage"]
    assert_equal "2026-10-23T11:00:00Z", state["rateLimits"]["capturedAt"]
  end
end
