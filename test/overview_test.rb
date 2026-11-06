# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/overview_test.rb`).
#rb (its helpers).
require_relative "test_helper"

class OverviewTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  # The tmux seam: which item chats have a live pane, without a tmux server.
  FakePanes = Struct.new(:sessions)

  def overview(panes: [], **opts)
    Quartermaster::Overview.new(tmux: FakePanes.new(panes), now: Time.utc(2026, 10, 23, 12), **opts)
  end

  def item(title, state: "in_progress", **opts)
    made = Quartermaster::WorkItem.create(title, project: "MyApp", **opts)
    made.update_state(state) unless state == "in_progress"
    made
  end

  def test_snapshot_shape_pins_every_field_the_page_reads
    blocked = live_item("Blocked chat", "s-blocked")
    blocked.link_branch("issue/7-blocked")
    blocked.add_note("Waiting on the user about the copy", kind: "open")
    blocked.add_note("Chose the simple path")
    blocked.link_board("https://claude.ai/artifact/board1")
    log_events("s-blocked", [60, "UserPromptSubmit"], [40, "PermissionRequest", "Bash"])

    doc = overview(panes: ["blocked-chat"]).snapshot

    assert_equal %w[v generatedAt counts rateLimits items], doc.keys
    assert_nil doc["rateLimits"], "no status line snapshot yet"
    assert_equal 1, doc["v"]
    assert_equal "2026-10-23T12:00:00Z", doc["generatedAt"]
    row = doc["items"].first
    assert_equal %w[slug title state project branches chat paneLive lastActivity openNotes board], row.keys
    assert_equal "blocked-chat", row["slug"]
    assert_equal ["issue/7-blocked"], row["branches"]
    assert_equal "blocked", row["chat"]["state"]
    assert_equal %w[state since snoozed waitingOn], row["chat"].keys
    assert row["chat"]["since"], "a blocked chat says since when"
    assert_equal true, row["paneLive"]
    assert row["lastActivity"]
    assert_equal [{ "position" => 1, "stamp" => Date.today.iso8601, "text" => "Waiting on the user about the copy" }],
                 row["openNotes"], "only open notes, addressed by file position"
    assert_equal "https://claude.ai/artifact/board1", row["board"]
  end

  def test_in_progress_by_whose_move_then_fridge_by_recency_and_resolved_only_counted
    item("Quiet in progress")
    live_item("Working chat", "s-work")
    log_events("s-work", [30, "UserPromptSubmit"])
    live_item("Your turn chat", "s-turn")
    log_events("s-turn", [30, "UserPromptSubmit"], [20, "Stop"])
    item("Old fridge", state: "fridge")
    live_item("Fresh fridge", "s-fridge", state: "fridge")
    item("Done", state: "resolved")

    doc = overview.snapshot

    assert_equal %w[your-turn-chat working-chat quiet-in-progress fresh-fridge old-fridge], doc["items"].map { |r| r["slug"] }
    assert_equal({ "in_progress" => 3, "active" => 0, "fridge" => 2, "resolved" => 1 }, doc["counts"]["states"])
    assert_equal 5, doc["counts"]["shown"]
    assert_equal 0, doc["counts"]["omitted"]
    assert_equal 1, doc["counts"]["chats"]["your_turn"]
    assert_equal false, doc["items"].first["paneLive"], "no tmux session, no live pane"
  end

  def test_long_text_is_clipped_and_the_tail_is_dropped_to_fit_the_caps
    long = item("Long")
    long.retitle("Long #{"t" * 300}")
    long.add_note("n" * 1000, kind: "open")
    3.times { |i| item("Fridge #{i}", state: "fridge") }

    row = overview.snapshot["items"].first
    assert_operator row["title"].length, :<=, Quartermaster::Overview::TITLE_CHARS + 1
    assert_operator row["openNotes"].first["text"].length, :<=, Quartermaster::Overview::NOTE_CHARS + 1

    capped = overview(max_items: 2).snapshot
    assert_equal 2, capped["counts"]["shown"]
    assert_equal 2, capped["counts"]["omitted"]
    assert_equal long.slug, capped["items"].first["slug"], "the cap drops the quiet end, never the top"

    budget = JSON.generate(overview.snapshot).bytesize - 1
    trimmed = overview(max_bytes: budget).snapshot
    assert_operator JSON.generate(trimmed).bytesize, :<=, budget
    assert_equal 3, trimmed["counts"]["shown"]
    assert_equal 1, trimmed["counts"]["omitted"]
  end

  def test_carries_the_status_lines_rate_limits
    FileUtils.mkdir_p(Quartermaster::ROOT)
    File.write(File.join(Quartermaster::ROOT, "rate-limits.json"), JSON.generate(
      "v" => 1, "captured_at" => "2026-10-23T11:00:00Z",
      "five_hour" => { "used_percentage" => 42, "resets_at" => Time.utc(2026, 10, 23, 14).to_i },
      "seven_day" => { "used_percentage" => 61.5, "resets_at" => Time.utc(2026, 10, 26).to_i }
    ))

    doc = overview.snapshot

    assert_equal({ "fiveHour" => { "usedPercentage" => 42, "resetsAt" => "2026-10-23T14:00:00Z" },
                   "sevenDay" => { "usedPercentage" => 61.5, "resetsAt" => "2026-10-26T00:00:00Z" },
                   "capturedAt" => "2026-10-23T11:00:00Z" }, doc["rateLimits"])
  end

  def test_cli_writes_the_snapshot_atomically_to_a_path_or_prints_it
    item("Cli item")
    path = File.join(Quartermaster::ROOT, "out", "overview.json")

    out, err, status = run_qm("overview", "--json", path)
    assert status.success?, err
    assert_equal "1 item: 1 in progress, 0 fridge → #{path}\n", out, "a summary the skill can reply with unread"
    assert_equal ["cli-item"], JSON.parse(File.read(path))["items"].map { |r| r["slug"] }
    assert_equal ["overview.json"], Dir.children(File.dirname(path)), "no temp file left behind"

    out, _err, status = run_qm("overview", "--json")
    assert status.success?
    assert_equal "cli-item", JSON.parse(out)["items"].first["slug"]
  end

  def test_url_comes_from_config_and_refuses_clearly_while_unset
    Quartermaster.ensure_setup
    _out, err, status = run_qm("overview", "--url")
    refute status.success?
    assert_match "qm config set overview_artifact <its claude.ai URL>", err

    File.write(Quartermaster::CONFIG_FILE, "overview_artifact: https://claude.ai/artifact/abc\n", mode: "a")
    out, _err, status = run_qm("overview", "--url")
    assert status.success?
    assert_equal "https://claude.ai/artifact/abc\n", out
  end

  def test_page_reads_as_unpublished_until_recorded_and_again_after_it_changes
    Quartermaster.ensure_setup
    out, _err, status = run_qm("overview", "--page")
    assert status.success?
    assert_equal "#{Quartermaster::Overview::PAGE}\n", out

    _out, _err, status = run_qm("overview", "--page-published")
    assert status.success?
    out, = run_qm("overview", "--page")
    assert_equal "", out

    page = File.join(Quartermaster::ROOT, "page.html")
    record = File.join(Quartermaster::ROOT, "page.sha256")
    File.write(page, "v1")
    Quartermaster::Overview.page_published(page, record)
    assert_nil Quartermaster::Overview.unpublished_page(page, record)
    File.write(page, "v2")
    assert_equal page, Quartermaster::Overview.unpublished_page(page, record)
  end

  def run_qm(*argv)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                   RbConfig.ruby, QM_BIN, *argv)
  end
end
