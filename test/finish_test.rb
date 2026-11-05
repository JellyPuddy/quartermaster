# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/finish_test.rb`).
require_relative "test_helper"
require_relative "history_rotation_test"

# Finish: Wrap up & close with the final wrap-up prompt, then the item resolved —
# only once the chat said DONE (its turn's Stop) and its pane exited.
class FinishTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include HistoryHelpers

  def setup
    super
    @now = Time.now
    @slept = 0
  end

  def live_chat(title = "Done work")
    log_session("s-chat", ago: 600, ended: false, pid: Process.pid)
    log_events("s-chat", [60, "UserPromptSubmit"], [30, "Stop"])
    item = item_with_sessions(title, "s-chat")
    item.add_note("handled already", kind: "open")
    item.add_note("still to do", kind: "open")
    Quartermaster::WorkItem.find(item.slug)
  end

  def rotation(tmux)
    Quartermaster::Rotation.new(tmux: tmux, distiller: ->(*) { flunk "a live chat is never distilled" },
                                sleeper: ->(s) { @slept += s }, clock: -> { @now + @slept })
  end

  # The fake chat answers only the final prompt: it retags `handled` notes
  # done, notes a decision, says DONE; /exit ends its pane.
  def play_final_wrap_up(tmux, item, handled: [1])
    tmux.on_submit = lambda do |text|
      case text
      when Quartermaster::Rotation::FINISH_PROMPT
        log_events("s-chat", [0, "UserPromptSubmit"])
        handled.each { |position| item.update_note_kind(position, "decision") }
        item.add_note("last decision")
        log_events("s-chat", [0, "Stop"])
      when "/exit"
        Quartermaster::SessionLog.new.append("event" => "end", "session_id" => "s-chat", "ts" => Time.now.iso8601)
        tmux.die(item.slug)
      end
    end
  end

  def state_of(item) = Quartermaster::WorkItem.find(item.slug).state

  def test_finish_types_the_final_prompt_closes_the_window_and_then_resolves
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    play_final_wrap_up(tmux, item)
    r = rotation(tmux)

    plan = r.plan(item, finish: true)
    assert plan.close, "finish closes the window"
    result = r.run(item, plan)

    slug = item.slug
    assert_equal [[:send_text, slug, Quartermaster::Rotation::FINISH_PROMPT], [:send_enter, slug],
                  [:keep_on_exit, slug, true], [:send_text, slug, "/exit"], [:send_enter, slug]], tmux.calls
    refute tmux.live?(slug)
    assert_equal "resolved", state_of(item)
    assert_equal "wrap-up", Quartermaster::WorkItem.find(slug).rotations.last["via"], "recorded as usual"
    assert_equal({ "ok" => true, "message" => "done-work: resolved — 1 open note remains" }, result)
  end

  def test_the_message_counts_every_open_note_left
    item = live_chat("Many open")
    item.add_note("third", kind: "open")
    tmux = RotationTmux.new([item.slug])
    play_final_wrap_up(tmux, item, handled: [])
    r = rotation(tmux)
    assert_equal "many-open: resolved — 3 open notes remain", r.run(item, r.plan(item, finish: true))["message"]
  end

  def test_the_message_drops_its_tail_when_no_open_note_is_left
    item = live_chat("All handled")
    tmux = RotationTmux.new([item.slug])
    play_final_wrap_up(tmux, item, handled: [1, 2])
    r = rotation(tmux)
    assert_equal "all-handled: resolved", r.run(item, r.plan(item, finish: true))["message"]
  end

  def test_no_done_within_the_timeout_resolves_nothing_and_leaves_the_chat_running
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    r = rotation(tmux)

    error = assert_raises(ArgumentError) { r.run(item, r.plan(item, finish: true)) }

    assert_match(/no Stop/, error.message)
    assert tmux.live?(item.slug)
    refute(tmux.calls.any? { |c| c[0] == :send_text && c[2] == "/exit" }, "the chat is left running")
    assert_equal "in_progress", state_of(item)
    assert_empty Quartermaster::WorkItem.find(item.slug).rotations
  end

  def test_a_chat_that_will_not_exit_is_not_resolved
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    tmux.on_submit = ->(text) { log_events("s-chat", [0, "UserPromptSubmit"], [0, "Stop"]) if text != "/exit" }
    r = rotation(tmux)

    assert_raises(ArgumentError) { r.run(item, r.plan(item, finish: true)) }

    assert tmux.live?(item.slug)
    assert_equal "in_progress", state_of(item)
  end

  def test_finish_needs_a_live_chat_in_its_pane
    item = live_chat
    error = assert_raises(ArgumentError) { rotation(RotationTmux.new).plan(item, finish: true) }
    assert_match(/no chat open to wrap up|runs outside the GUI/, error.message)
    assert_equal "in_progress", state_of(item)
  end

  def test_the_rotate_action_with_finish_runs_as_the_items_job_and_resolves
    item = live_chat
    tmux = RotationTmux.new([item.slug])
    play_final_wrap_up(tmux, item)
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

    started = server.actions.dispatch("cmd" => "rotate", "slug" => item.slug, "args" => { "finish" => true })
    assert started["ok"], started["error"]
    assert_equal true, started["close"]
    Timeout.timeout(10) { sleep 0.05 until server.jobs.running.empty? }
    job = server.jobs.take_finished.last

    assert job["ok"], job["error"]
    assert_equal "done-work: resolved — 1 open note remains", job["message"]
    assert_equal "resolved", state_of(item)
  end
end
