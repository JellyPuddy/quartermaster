# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/usage_test.rb`).
require_relative "test_helper"

module UsageHelpers
  PROJECT_DIR = "-usage-proj"

  def project_dir = File.join(Quartermaster::TRANSCRIPTS_DIR, PROJECT_DIR)

  def jsonl(entries) = entries.map { |e| "#{JSON.generate(e)}\n" }.join

  def write_session(session_id, entries)
    FileUtils.mkdir_p(project_dir)
    path = File.join(project_dir, "#{session_id}.jsonl")
    File.write(path, jsonl(entries))
    path
  end

  # A sub-agent transcript under the session's own directory; `nested` puts
  # it a level deeper, the way workflow agents are stored.
  def write_subagent(session_id, name, entries, nested: nil)
    dir = File.join(project_dir, session_id, "subagents", *nested)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{name}.jsonl")
    File.write(path, jsonl(entries))
    path
  end

  def spend(id, model: "claude-opus-5-5", input: 0, w5m: 0, w1h: 0, read: 0, output: 0, speed: nil)
    usage = { "input_tokens" => input, "cache_creation_input_tokens" => w5m + w1h, "cache_read_input_tokens" => read,
              "output_tokens" => output,
              "cache_creation" => { "ephemeral_5m_input_tokens" => w5m, "ephemeral_1h_input_tokens" => w1h } }
    usage["speed"] = speed if speed
    { "type" => "assistant", "uuid" => SecureRandom.hex(4),
      "message" => { "id" => id, "model" => model, "role" => "assistant", "content" => [], "usage" => usage } }
  end

  def log_start(id, transcript:, aside: nil, ended: true)
    log = Quartermaster::SessionLog.new
    event = { "event" => "start", "session_id" => id, "cwd" => "/", "transcript_path" => transcript,
              "pid" => 999_999_999, "ts" => Time.now.iso8601 }
    event["aside"] = aside if aside
    log.append(event)
    log.append("event" => "end", "session_id" => id, "ts" => Time.now.iso8601) if ended
  end

  def item_with(title, *ids)
    item = Quartermaster::WorkItem.create(title, project: "No project")
    ids.each { |id| item.attach_session(id) }
    Quartermaster::WorkItem.find(item.slug)
  end

  def tally(path, state = nil) = Quartermaster::TranscriptUsage.scan(path, state)
end

class TranscriptUsageTest < Minitest::Test
  include QmTestHelpers
  include UsageHelpers

  def test_a_message_counts_once_with_its_last_entrys_usage
    path = write_session("s-dedupe", [
      spend("m1", input: 5, w1h: 100, output: 3), # an early content block, still streaming
      spend("m1", input: 5, w1h: 100, output: 40),
      { "type" => "user", "message" => { "role" => "user", "content" => "next" } },
      spend("m2", input: 1, w5m: 20, read: 100, output: 7)
    ])

    totals = Quartermaster::TranscriptUsage.totals(tally(path))

    assert_equal({ "claude-opus-5-5" => { "input" => 6, "cache_write_5m" => 20, "cache_write_1h" => 100,
                                          "cache_read" => 100, "output" => 47 } }, totals)
  end

  def test_buckets_by_normalised_model_fast_mode_and_long_prompts
    path = write_session("s-buckets", [
      spend("a", model: "claude-haiku-4-5-20251001", input: 10),
      spend("b", model: "claude-opus-4-6[1m]", input: 10),
      spend("c", speed: "fast", output: 10),
      spend("d", model: "claude-haiku-5-5", read: 100_001),
      spend("e", model: "<synthetic>", input: 10)
    ])

    totals = Quartermaster::TranscriptUsage.totals(tally(path))

    assert_equal ["claude-haiku-4-5", "claude-haiku-5-5:long", "claude-opus-4-6", "claude-opus-5-5:fast"], totals.keys.sort
  end

  def test_cache_writes_without_a_split_count_as_the_5m_tier
    entry = spend("x")
    entry["message"]["usage"] = { "input_tokens" => 1, "cache_creation_input_tokens" => 50, "output_tokens" => 2 }
    path = write_session("s-nosplit", [entry])

    assert_equal 50, Quartermaster::TranscriptUsage.totals(tally(path))["claude-opus-5-5"]["cache_write_5m"]
  end

  def test_a_growing_transcript_is_read_on_from_its_offset_and_a_partial_line_waits
    path = write_session("s-grow", [spend("m1", output: 10)])
    state = tally(path)
    first_offset = state["offset"]

    File.open(path, "a") { |f| f.write(jsonl([spend("m1", output: 30), spend("m2", output: 5)]) + JSON.generate(spend("m3", output: 99))[0, 20]) }
    state = tally(path, state)

    assert_operator state["offset"], :>, first_offset
    assert_equal File.size(path) - 20, state["offset"], "the half-written line is left for the next read"
    assert_equal 35, Quartermaster::TranscriptUsage.totals(state)["claude-opus-5-5"]["output"]
    assert_same state, tally(path, state), "an unchanged file is not read again"
  end

  def test_a_shrunken_transcript_is_tallied_from_the_start
    path = write_session("s-shrink", [spend("m1", output: 10), spend("m2", output: 10)])
    state = tally(path)
    File.write(path, jsonl([spend("m9", output: 1)]))

    assert_equal 1, Quartermaster::TranscriptUsage.totals(tally(path, state))["claude-opus-5-5"]["output"]
  end
end

class PriceTableTest < Minitest::Test
  include QmTestHelpers

  def tokens(**kinds) = Quartermaster::TranscriptUsage::KINDS.to_h { |k| [k, kinds.fetch(k.to_sym, 0)] }

  def test_prices_every_token_kind_per_million
    table = Quartermaster::PriceTable.new
    dollars, unpriced = table.cost("claude-opus-5-5" => tokens(input: 1_000_000, cache_write_5m: 1_000_000,
                                                               cache_write_1h: 1_000_000, cache_read: 1_000_000,
                                                               output: 1_000_000))

    assert_in_delta 4 + 5 + 8 + 0.2 + 20, dollars
    assert_empty unpriced
  end

  def test_a_variant_without_its_own_rate_falls_back_to_the_model
    table = Quartermaster::PriceTable.new

    assert_equal table.rates_for("claude-opus-5-5"), table.rates_for("claude-opus-5-5:long")
    assert_equal 40, table.rates_for("claude-opus-5-5:fast:long")["output"]
    assert_equal 2.5, table.rates_for("claude-haiku-5-5:long")["output"]
  end

  def test_unknown_models_are_reported_unpriced
    dollars, unpriced = Quartermaster::PriceTable.new.cost("claude-opus-5-5" => tokens(output: 1_000_000),
                                                           "mystery-model" => tokens(output: 1_000_000))

    assert_in_delta 20, dollars
    assert_equal ["mystery-model"], unpriced
  end

  def test_config_overrides_and_adds_models
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, <<~YAML)
      prices:
        claude-opus-5-5: { output: 30 }
        mystery-model: { input: 1, cache_write_5m: 1, cache_write_1h: 1, cache_read: 1, output: 1 }
        half-model: { input: 1 }
    YAML
    table = Quartermaster::PriceTable.load

    assert_equal 30, table.rates_for("claude-opus-5-5")["output"]
    assert_equal 4, table.rates_for("claude-opus-5-5")["input"], "unnamed fields keep their default"
    assert_equal 1, table.rates_for("mystery-model")["output"]
    assert_nil table.rates_for("half-model"), "a model needs every rate before it is priced"
  end

  def test_a_broken_config_falls_back_to_the_defaults
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, "prices: [::")

    assert_equal 20, Quartermaster::PriceTable.load.rates_for("claude-opus-5-5")["output"]
  end
end

class ItemUsageTest < Minitest::Test
  include QmTestHelpers
  include UsageHelpers

  # A session with a sub-agent and a workflow agent, plus an aside about the
  # same item: everything the item's work spent.
  def build_item
    main = write_session("s-main", [spend("m1", input: 1_000_000)]) # $4
    write_subagent("s-main", "agent-a1", [spend("a1", model: "claude-haiku-4-5", output: 1_000_000)]) # $5
    write_subagent("s-main", "agent-w1", [spend("w1", model: "claude-sonnet-5", output: 100_000)], nested: %w[workflows wf_1]) # $1
    aside = write_session("s-aside", [spend("q1", model: "claude-sonnet-5-5", output: 200_000)]) # $2
    log_start("s-main", transcript: main)
    log_start("s-aside", transcript: aside, aside: "costly")
    item_with("Costly", "s-main")
  end

  def usage_for(item, ledger: Quartermaster::UsageLedger.new) = Quartermaster::ItemUsage.for(item, ledger: ledger)

  def test_sums_sessions_their_subagents_and_asides
    usage = usage_for(build_item)

    assert_equal 2_300_000, usage.tokens
    assert_in_delta 12, usage.cost
    refute usage.lower_bound?
    refute usage.partial?
    assert_equal "2.3M tok · ~$12", usage.line
    main, aside = usage.rows
    assert_equal 2, main["agents"]
    assert_equal({ "claude-opus-5-5" => 1_000_000, "claude-haiku-4-5" => 1_000_000, "claude-sonnet-5" => 100_000 },
                 main["models"])
    assert_equal [false, true], [main["aside"], aside["aside"]]
  end

  def test_totals_survive_the_transcripts_expiring
    item = build_item
    ledger = Quartermaster::UsageLedger.new
    usage_for(item, ledger: ledger)
    ledger.save
    FileUtils.rm_rf(project_dir)

    usage = usage_for(Quartermaster::WorkItem.find(item.slug))

    assert_in_delta 12, usage.cost
    assert_equal 2_300_000, usage.tokens
    refute usage.lower_bound?
  end

  def test_an_expired_session_never_tallied_makes_the_figure_a_lower_bound
    item = build_item
    log_start("s-gone", transcript: File.join(project_dir, "s-gone.jsonl"))
    item.attach_session("s-gone")

    usage = usage_for(Quartermaster::WorkItem.find(item.slug))

    assert usage.lower_bound?
    assert_equal "≥ 2.3M tok · ≥ $12", usage.line
  end

  def test_an_item_whose_every_session_expired_untallied_says_so
    log_start("s-gone", transcript: File.join(project_dir, "s-gone.jsonl"))

    usage = usage_for(item_with("Gone", "s-gone"))

    assert usage.lower_bound?
    assert_equal "usage unknown · sessions expired", usage.line
  end

  def test_token_labels_never_round_up_to_a_thousand_of_a_unit
    assert_equal ["999", "1k", "999k", "1.0M", "999.9M", "1.0B"],
                 [999, 1_000, 999_499, 999_500, 999_949_999, 999_950_000].map { |n| Quartermaster::ItemUsage.human_tokens(n) }
  end

  def test_an_unknown_model_counts_tokens_but_marks_the_cost_partial
    path = write_session("s-odd", [spend("x", model: "claude-future-9", output: 500), spend("y", output: 1_000_000)])
    log_start("s-odd", transcript: path)

    usage = usage_for(item_with("Odd", "s-odd"))

    assert_equal 1_000_500, usage.tokens
    assert_in_delta 20, usage.cost
    assert usage.partial?
    assert_equal ["claude-future-9"], usage.unpriced
    assert_equal "1.0M tok · ~$20 · partial", usage.line
  end

  def test_an_unchanged_session_is_not_reread
    item = build_item
    ledger = Quartermaster::UsageLedger.new
    usage_for(item, ledger: ledger)
    # A sub-agent written to without the main transcript moving is not looked
    # at again: the main transcript is the session's change signal.
    write_subagent("s-main", "agent-a1", [spend("a1", model: "claude-haiku-4-5", output: 9_000_000)])

    assert_equal 2_300_000, usage_for(item, ledger: ledger).tokens

    File.open(File.join(project_dir, "s-main.jsonl"), "a") { |f| f.write(jsonl([spend("m2", output: 1)])) }

    assert_equal 10_300_001, usage_for(item, ledger: ledger).tokens
  end
end

class UsageLedgerKeepTest < Minitest::Test
  include QmTestHelpers
  include UsageHelpers

  OLD_LEDGER = %q({"v":1,"sessions":{"old-session":{"main":["/x",1,1.0],"files":{}}}})
  TRUNCATED = OLD_LEDGER[0..-5]

  def ledger_path = File.join(Quartermaster::ROOT, Quartermaster::UsageLedger::FILE)
  def asides = Dir[File.join(Quartermaster::ROOT, "#{Quartermaster::UsageLedger::FILE}.corrupt-*")]

  def write_ledger(content)
    FileUtils.mkdir_p(Quartermaster::ROOT)
    File.write(ledger_path, content)
  end

  def tallied_ledger(session_id)
    log_start(session_id, transcript: write_session(session_id, [spend("#{session_id}-m", output: 10)]))
    ledger = Quartermaster::UsageLedger.new
    ledger.session_usage(Quartermaster::SessionLog.new.sessions.find { |s| s.id == session_id })
    ledger
  end

  def test_saving_over_an_unparseable_ledger_keeps_it_aside_and_logs_why
    write_ledger(TRUNCATED)

    tallied_ledger("s1").save

    assert_equal 1, asides.size
    assert_match(/\.corrupt-\d{8}T\d{6}Z\z/, asides.first)
    assert_equal TRUNCATED, File.read(asides.first), "the unreadable record is kept byte for byte"
    assert_equal ["s1"], JSON.parse(File.read(ledger_path))["sessions"].keys
    log = File.read(Quartermaster::LOG_FILE)
    assert_match(/\[usage-ledger\] \S+: .*corrupt-/, log)
    refute_match(/\[usage-ledger\] transient/, log)
  end

  def test_a_json_file_not_shaped_as_a_ledger_is_kept_aside_too
    write_ledger("[1, 2]")

    tallied_ledger("s1").save

    assert_equal ["[1, 2]"], asides.map { |path| File.read(path) }
  end

  def test_reading_an_unparseable_ledger_leaves_it_in_place
    write_ledger(TRUNCATED)
    ledger = tallied_ledger("s1")

    assert_empty asides
    assert_equal TRUNCATED, File.read(ledger_path)
    ledger.save
    ledger.save

    assert_equal 1, asides.size, "a second save finds a ledger, not the corrupt file"
  end

  def test_an_unchanged_ledger_never_saves_so_never_moves_a_corrupt_file
    write_ledger(TRUNCATED)

    Quartermaster::UsageLedger.new.save

    assert_empty asides
    assert_equal TRUNCATED, File.read(ledger_path)
  end

  # Two processes that both read the corrupt file before either saved: the
  # second save must merge over the first's fresh ledger, not move it aside.
  def test_two_savers_who_both_saw_the_corrupt_file_keep_each_others_sessions
    write_ledger(TRUNCATED)
    first = tallied_ledger("s1")
    second = tallied_ledger("s2")

    first.save
    second.save

    assert_equal [TRUNCATED], asides.map { |path| File.read(path) }
    assert_equal %w[s1 s2], JSON.parse(File.read(ledger_path))["sessions"].keys.sort
  end

  def test_concurrent_savers_set_the_corrupt_file_aside_once_and_lose_no_session
    ids = (1..6).map { |n| "s#{n}" }
    ids.each { |id| log_start(id, transcript: write_session(id, [spend("#{id}-m", output: 10)])) }
    write_ledger(TRUNCATED)

    pids = ids.map do |id|
      fork do
        ledger = Quartermaster::UsageLedger.new
        ledger.session_usage(Quartermaster::SessionLog.new.session_for(id))
        ledger.save
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }

    assert_equal [TRUNCATED], asides.map { |path| File.read(path) }
    assert_equal ids, JSON.parse(File.read(ledger_path))["sessions"].keys.sort
  end

  def test_saving_over_a_valid_ledger_merges_and_sets_nothing_aside
    write_ledger(OLD_LEDGER)

    tallied_ledger("s1").save

    assert_empty asides
    assert_equal %w[old-session s1], JSON.parse(File.read(ledger_path))["sessions"].keys.sort
  end
end

class UsageSurfacesTest < Minitest::Test
  include QmTestHelpers
  include UsageHelpers

  def test_the_state_carries_each_items_usage
    path = write_session("s-gui", [spend("m1", output: 1_000_000)])
    log_start("s-gui", transcript: path)
    item_with("Shown", "s-gui")
    Quartermaster::WorkItem.create("Idle", project: "No project")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

    items = JSON.parse(server.respond("GET", "/api/state", { "host" => "127.0.0.1:4567" }, "")[2])["items"]
    shown = items.find { |i| i["slug"] == "shown" }

    assert_equal "1.0M tok · ~$20", shown.dig("usage", "line")
    assert_equal ["s-gui"], shown.dig("usage", "sessions").map { |s| s["id"] }
    assert_equal "$20", shown.dig("usage", "sessions", 0, "costLabel")
    assert_nil items.find { |i| i["slug"] == "idle" }["usage"]
    assert File.exist?(File.join(Quartermaster::ROOT, Quartermaster::UsageLedger::FILE)), "the tally is kept"
  end

  def test_qm_show_prints_the_usage
    path = write_session("s-show", [spend("m1", output: 1_000_000)])
    write_subagent("s-show", "agent-z", [spend("z1", model: "claude-future-9", output: 10)])
    log_start("s-show", transcript: path)
    item_with("Printed", "s-show")

    stdout, = capture_io { Quartermaster::CLI.new.run(["show", "printed"]) }

    assert_includes stdout, "1.0M tok · ~$20 · partial"
    assert_includes stdout, "no price for claude-future-9"
    assert_includes stdout, "s-show · 1.0M tok · ~$20 · 1 sub-agent"
  end
end
