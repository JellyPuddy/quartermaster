# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/restack_test.rb`).
require_relative "test_helper"

# The ⟳ restack action (docs/areas/stacks.md): a prompt for the item's chat, never
# git or gh run by qm itself.
class RestackActionTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include StackRepoHelpers

  PROMPT = "Restack the gh-stack main ← a ← b ← c (bottom → top; behind their parent: b) " \
           "with `gh stack rebase` (see the gh-stack skill). Resolve the conflicts it hits, " \
           "or stop and report any you can't resolve safely."

  # Stack a ← b ← c on main, with a moved on after b branched off it.
  def stacked_item(dir, session_id: nil)
    repo = make_repo(dir)
    branch_off(repo, "a", "main")
    commit_on(repo, "a", "a1")
    branch_off(repo, "b", "a")
    commit_on(repo, "b", "b1")
    branch_off(repo, "c", "b")
    commit_on(repo, "c", "c1")
    commit_on(repo, "a", "a2 after b branched")
    write_stack(repo, %w[a b c], %w[x y])
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Repo" => repo } }.to_yaml)
    if session_id
      Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => repo,
                                           "pid" => Process.pid, "ts" => Time.now.iso8601)
    end
    Quartermaster::WorkItem.create("Stacked", project: "Repo", branch: "c", session_id: session_id)
    repo
  end

  def restack(tmux, args = {})
    Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux).actions
                      .dispatch("cmd" => "restack", "slug" => "stacked", "args" => args)
  end

  def test_types_the_restack_prompt_into_a_live_pane_once_it_is_the_users_turn
    Dir.mktmpdir do |dir|
      stacked_item(dir, session_id: "s-stack")
      log_events("s-stack", [60, "UserPromptSubmit"], [30, "Stop"])
      tmux = FakeTmux.new(["stacked"])

      assert_equal({ "ok" => true, "attached" => true }, restack(tmux))
      assert_equal [["stacked", PROMPT], ["stacked", :enter]], tmux.typed
      assert_empty tmux.opened
    end
  end

  def test_refuses_while_the_chat_is_mid_turn_or_waits_on_background_work
    Dir.mktmpdir do |dir|
      stacked_item(dir, session_id: "s-stack")
      tmux = FakeTmux.new(["stacked"])

      log_events("s-stack", [5, "UserPromptSubmit"])
      assert_match(/mid-turn \(working\)/, restack(tmux)["error"])

      Quartermaster::BackgroundJobs.reset!
      path = write_transcript("s-stack", [user_text(60, "build it"), *shell_launched(50, "b1", "Run the full suite")])
      Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "s-stack", "cwd" => dir,
                                           "transcript_path" => path, "pid" => Process.pid, "ts" => Time.now.iso8601)
      log_events("s-stack", [1, "Stop"])
      assert_match(/waiting on background work \(Run the full suite\)/, restack(tmux)["error"])

      assert_empty tmux.typed
      assert_empty tmux.opened
    end
  end

  def test_starts_a_fresh_chat_with_the_prompt_without_a_pane
    Dir.mktmpdir do |dir|
      repo = stacked_item(dir)
      tmux = FakeTmux.new

      assert_equal({ "ok" => true, "mode" => "start" }, restack(tmux))
      assert_equal({ name: "stacked", cwd: repo, argv: ["claude", PROMPT], env: { "QM_ITEM" => "stacked" } },
                   tmux.opened.first)
    end
  end

  def test_picks_the_stack_by_branch_and_refuses_one_the_item_lacks
    Dir.mktmpdir do |dir|
      stacked_item(dir)
      Quartermaster::WorkItem.find("stacked").link_branches(["y"])
      tmux = FakeTmux.new

      assert_match(/\ARestack the gh-stack main ← x ← y \(bottom → top; no layer is flagged/,
                   restack(tmux, "branch" => "x").then { tmux.opened.first[:argv].last })
      assert_match(/nope is in none of stacked's stacks/, restack(FakeTmux.new, "branch" => "nope")["error"])
    end
  end

  def test_refuses_an_item_without_a_stack
    Quartermaster::WorkItem.create("Stacked", project: "No project")

    assert_equal({ "ok" => false, "error" => "stacked has no stack to restack" }, restack(FakeTmux.new))
  end
end
