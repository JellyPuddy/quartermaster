# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/quiet_runs_test.rb`).
require_relative "test_helper"

# A `notify: quiet` local automation's run sessions stay out of attention:
# no chat-list row state and no turn notification. A run of a loud one (or
# any other session) still counts. A pr-review run lives in its Review
# item's own chat, so that is where it would otherwise show.
class QuietRunsTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  def run_in(slug, session_id, notify:)
    Quartermaster::AutomationStore.new.write(slug, { "runner" => "local", "name" => slug, "notify" => notify,
                                                     "flow" => "pr-review" }, "")
    run_log = Quartermaster::RunLog.new(slug)
    id = run_log.enqueue(key: "k", item: { "key" => "k", "url" => "u" }, flow: "pr-review", trigger: "guard")
    run_log.started(id, session_id: session_id, tmux: "review-x", item_slug: "review-x")
  end

  def test_a_quiet_automations_run_session_is_left_out_of_its_items_attention_row
    item = live_item("Review acme#1", "s-run")
    run_in("reviews", "s-run", notify: "quiet")
    log_events("s-run", [120, "UserPromptSubmit"], [60, "Stop"])

    entry = Quartermaster::ChatAttention.new.entries.find { _1.slug == item.slug }

    assert_equal "none", entry.state
  end

  def test_a_loud_automations_run_session_shows_like_any_chat
    item = live_item("Review acme#1", "s-run")
    run_in("reviews", "s-run", notify: "attention")
    log_events("s-run", [120, "UserPromptSubmit"], [60, "Stop"])

    entry = Quartermaster::ChatAttention.new.entries.find { _1.slug == item.slug }

    assert_equal "your_turn", entry.state
  end

  def test_a_quiet_automations_run_raises_no_notification
    live_item("Review acme#1", "s-run")
    run_in("reviews", "s-run", notify: "quiet")
    runner = FakeRunner.new
    notifier = Quartermaster::TurnNotifier.new(runner: runner, terminal_notifier: nil)
    log_events("s-run", [300, "UserPromptSubmit"])
    notifier.check

    log_events("s-run", [10, "PermissionRequest", "Bash"])

    assert_empty notifier.check
    assert_empty runner.calls
  end

  def test_the_event_fold_counts_a_sessions_prompts
    log_events("s1", [300, "UserPromptSubmit"], [200, "Stop"], [100, "UserPromptSubmit"])

    assert_equal 2, turn("s1")["prompts"]
  end
end
