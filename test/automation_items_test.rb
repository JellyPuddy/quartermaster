# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/automation_items_test.rb`).
require_relative "test_helper"

# Work items of `kind: automation` (docs/areas/work-items.md): ordinary items
# that stay off every list of the user's work — one test per surface.
class AutomationItemsTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  FakePanes = Struct.new(:sessions)

  def automation(title, state: "active", session_id: nil)
    item = if session_id
             live_item(title, session_id)
           else
             Quartermaster::WorkItem.create(title, project: "MyApp")
           end
    item.front.merge!("kind" => "automation", "routine" => "trig_01JJ", "runner" => "cloud")
    item.save
    item.update_state(state) unless state == "in_progress"
    Quartermaster::WorkItem.find(item.slug)
  end

  def test_the_frontmatter_round_trips_and_active_is_a_state
    automation("Shipped digest")
    item = Quartermaster::WorkItem.find("shipped-digest")

    assert item.automation?
    assert_equal %w[automation trig_01JJ cloud], [item.kind, item.routine, item.runner]
    assert_equal "active", item.state
    assert_equal({ "kind" => "automation", "routine" => "trig_01JJ", "runner" => "cloud" },
                 item.to_h.slice("kind", "routine", "runner"), "the GUI payload carries the kind to filter on")
    refute Quartermaster::WorkItem.create("Plain", project: "MyApp").automation?
    assert_equal "Active", Quartermaster.taxonomies["states"].find { |s| s["key"] == "active" }["label"]
  end

  def test_qm_state_sets_active_on_any_item
    Quartermaster::WorkItem.create("Plain", project: "MyApp")
    capture_io { Quartermaster::CLI.new.run(%w[state plain active]) }

    assert_equal "active", Quartermaster::WorkItem.find("plain").state
  end

  def test_qm_list_leaves_automations_out_unless_asked_for_by_kind
    Quartermaster::WorkItem.create("Plain work", project: "MyApp")
    automation("Shipped digest")

    plain, = capture_io { Quartermaster::CLI.new.run(%w[list]) }
    assert_includes plain, "plain-work"
    refute_includes plain, "shipped-digest"

    kinded, = capture_io { Quartermaster::CLI.new.run(%w[list --kind automation]) }
    assert_includes kinded, "shipped-digest"
    refute_includes kinded, "plain-work"

    help, = capture_io { Quartermaster::CLI.new.run(%w[help]) }
    assert_includes help, "qm list [--kind automation]"
  end

  def test_qm_show_names_kind_routine_and_runner
    automation("Shipped digest")

    out, = capture_io { Quartermaster::CLI.new.run(%w[show shipped-digest]) }
    assert_includes out.lines[1], "automation trig_01JJ (cloud)"
  end

  def test_attention_skips_automations
    automation("Quiet automation", state: "in_progress")
    Quartermaster::WorkItem.create("Quiet work", project: "MyApp")
    attention = Quartermaster::Attention.new(now: Time.now + (30 * 86_400))

    assert_equal ["quiet-work"], attention.entries.map(&:slug)
  end

  def test_chats_list_and_its_rotate_offers_skip_automations_even_with_a_live_chat
    automation("Live automation", session_id: "s-auto")
    live_item("Live work", "s-work")

    assert_equal ["live-work"], Quartermaster::ChatAttention.new.entries.map(&:slug)
  end

  def test_phone_page_neither_shows_nor_counts_automations
    automation("Running digest")
    automation("Paused digest", state: "fridge")
    Quartermaster::WorkItem.create("Plain work", project: "MyApp")

    doc = Quartermaster::Overview.new(tmux: FakePanes.new([])).snapshot

    assert_equal ["plain-work"], doc["items"].map { |r| r["slug"] }
    assert_equal({ "in_progress" => 1, "active" => 0, "fridge" => 0, "resolved" => 0 }, doc["counts"]["states"])
    assert_equal 0, doc["counts"]["omitted"], "a paused automation is not a left-out fridge item"
  end

  # The state payload keeps automation items (the automation's chat view finds
  # its item there); the board drops them when it draws.
  def test_board_draws_only_items_that_are_not_automations
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner),
                       { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" })
    render = page[/^function render\(\).*?^}$/m]

    assert_includes render, 'const boardItems = items.filter(it => it.kind !== "automation");'
    refute_match(/\bitems\.(forEach|filter)/, render.sub("items.filter(it => it.kind", ""))
    assert_includes page, ".dot-active"
  end
end
