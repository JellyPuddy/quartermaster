# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/prompt_diff_test.rb`).
require_relative "test_helper"

class PromptDiffTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  HOOK = File.expand_path("../hooks/snapshot-worktree.sh", __dir__)

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def setup
    super
    @dir = Dir.mktmpdir("qm-prompt-diff-repo")
    FileUtils.mkdir_p(File.join(@dir, "repo"))
    @repo = make_repo(File.join(@dir, "repo"))
    File.write(File.join(@repo, ".gitignore"), "*.log\n")
    File.write(File.join(@repo, "tracked.txt"), "one\n")
    system("git", "-C", @repo, "add", ".")
    system("git", "-C", @repo, *GIT_ID, "commit", "-q", "-m", "init")
    @item = Quartermaster::WorkItem.create("Feat", project: "No project")
  end

  def teardown = FileUtils.rm_rf(@dir)

  # A live session of the item (this process stands in for claude), its
  # transcript holding the given prompts.
  def chat_session(id = "sess-1", prompts: [], pid: Process.pid, ts: Time.now.utc.iso8601)
    dir = File.join(Quartermaster::TRANSCRIPTS_DIR, "-repo")
    FileUtils.mkdir_p(dir)
    transcript = File.join(dir, "#{id}.jsonl")
    File.write(transcript, prompts.map do |text, ts|
      "#{JSON.generate("type" => "user", "timestamp" => ts, "message" => { "role" => "user", "content" => text })}\n"
    end.join)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => id, "cwd" => @repo, "transcript_path" => transcript,
                                         "pid" => pid, "ts" => ts)
    @item.attach_session(id)
  end

  def snapshot_now(id = "sess-1")
    _out, _err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_SKIP" => nil, "QM_ASIDE" => nil },
                                        "/bin/sh", HOOK, stdin_data: JSON.generate("session_id" => id, "cwd" => @repo))
    assert status.success?
  end

  def snapshot_line(tree, at, id = "sess-1")
    FileUtils.mkdir_p(Quartermaster::ROOT)
    File.open(Quartermaster::PromptSnapshots.path, "a") do |f|
      f.puts JSON.generate("v" => 1, "session_id" => id, "cwd" => @repo, "toplevel" => @repo, "tree" => tree, "at" => at)
    end
  end

  def prompt_diff(prompt: nil, moved: nil, rebase: true)
    Quartermaster::PromptDiff.new(tmux: FakeTmux.new).call(Quartermaster::WorkItem.find("feat"), prompt: prompt, moved: moved,
                                                                                                 rebase: rebase)
  end

  def paths(result) = result["files"].map { |f| f["path"] }

  def write(file, content) = File.write(File.join(@repo, file), content)

  def test_diffs_the_last_prompts_snapshot_against_the_worktree_now_without_touching_the_index
    chat_session(prompts: [["First ask", (Time.now.utc - 1).iso8601]])
    snapshot_now
    write("tracked.txt", "one\ntwo\n")
    write("new.txt", "fresh\n")
    write("noise.log", "ignored\n")
    status_before = `git -C #{@repo} status --porcelain`
    index_before = File.binread(File.join(@repo, ".git", "index"))

    result = prompt_diff

    assert_equal %w[new.txt tracked.txt], paths(result).sort
    assert_equal "prompt", result["scope"]
    assert_equal ["sess-1:1", "sess-1"], result.values_at("prompt", "session")
    assert_equal "prompt", result["base"]["kind"]
    assert_equal "before “First ask”", result["base"]["ref"]
    assert_equal File.realpath(@repo), result["path"]
    assert_equal [["sess-1:1", "First ask"]], result["prompts"].map { |p| p.values_at("id", "prompt") }
    assert_nil result["notice"]
    assert_equal result["base"]["sha"], result["oldRev"], "the old side is the snapshot's tree"
    assert_equal index_before, File.binread(File.join(@repo, ".git", "index")), "the real index is byte-identical"
    assert_equal status_before, `git -C #{@repo} status --porcelain`
  end

  def test_an_earlier_prompt_can_be_picked_and_the_list_is_newest_first
    chat_session
    snapshot_now
    write("first.txt", "1\n")
    snapshot_now
    write("second.txt", "2\n")

    latest = prompt_diff
    earlier = prompt_diff(prompt: "sess-1:1")
    stale = prompt_diff(prompt: "other-session:1")

    assert_equal ["second.txt"], paths(latest)
    assert_equal %w[first.txt second.txt], paths(earlier).sort
    assert_equal "sess-1:1", earlier["prompt"]
    assert_equal ["sess-1:2", "sess-1"], [stale["prompt"], stale["session"]], "another session's pick falls back to the last prompt"
    assert_equal %w[sess-1:2 sess-1:1], latest["prompts"].map { |p| p["id"] }
    assert(latest["prompts"].all? { |p| p["prompt"].nil? && p["at"] })
  end

  def test_the_session_is_the_one_running_in_the_chats_pane_not_the_newest
    chat_session("in-pane", pid: Process.ppid, ts: (Time.now.utc - 60).iso8601)
    chat_session("elsewhere", pid: Process.pid)
    tmux = FakeTmux.new(["feat"])
    tmux.pane_pids["feat"] = 4242
    lineage = ->(pid) { pid == Process.ppid ? [pid, 4242] : [pid] }

    in_pane = Quartermaster::PromptDiff.new(tmux: tmux, lineage: lineage).call(Quartermaster::WorkItem.find("feat"))
    no_pane = prompt_diff

    assert_equal "in-pane", in_pane["session"]
    assert_equal "elsewhere", no_pane["session"], "without a pane: the newest live session"
  end

  def test_says_why_when_there_is_nothing_to_diff_from
    none = prompt_diff
    chat_session
    no_snapshots = prompt_diff
    snapshot_line("0" * 40, "2026-10-27T10:00:00Z")
    pruned = prompt_diff

    assert_match(/no captured chat session/, none["notice"])
    assert_match(/No prompt snapshots/, no_snapshots["notice"])
    assert_equal [], no_snapshots["files"]
    assert_match(/snapshot is gone/, pruned["notice"])
    assert_equal [[], 1], [pruned["files"], pruned["prompts"].size]
    assert_equal [nil, nil, nil], [none, no_snapshots, pruned].map { |r| r["oldRev"] }, "nothing diffed, no old side"
  end

  # A commit on the branch checked out at `path`, dated (and so reflogged) at `at`.
  def commit_at(path, at, file, content)
    File.write(File.join(path, file), content)
    env = { "GIT_COMMITTER_DATE" => at.iso8601, "GIT_AUTHOR_DATE" => at.iso8601 }
    system(env, "git", "-C", path, "add", file)
    system(env, "git", "-C", path, *GIT_ID, "commit", "-q", "-m", "add #{file}")
  end

  def test_lists_the_branches_that_moved_since_the_prompt_and_diffs_their_new_commits
    chat_session
    agent = add_worktree(@repo, "agent", "agent-wt")
    commit_at(agent, Time.now - 30, "before.txt", "old\n")
    add_worktree(@repo, "idle", "idle-wt")
    prompt_at = Time.now + 100
    snapshot_line(`git -C #{@repo} write-tree`.strip, prompt_at.utc.iso8601)
    later = prompt_at + 100
    commit_at(agent, later, "agent.txt", "a\n")
    commit_at(agent, later + 1, "agent2.txt", "b\n")
    system({ "GIT_COMMITTER_DATE" => later.iso8601 }, "git", "-C", @repo, "worktree", "add", "-q", "-b", "fresh",
           File.join(@dir, "fresh-wt"))
    commit_at(File.join(@dir, "fresh-wt"), later + 2, "fresh.txt", "f\n")
    write("tracked.txt", "chat edit\n")

    folder = prompt_diff
    moved = prompt_diff(moved: "agent")
    created = prompt_diff(moved: "fresh")
    untouched = prompt_diff(moved: "idle")

    assert_equal [["fresh", 1], ["agent", 2]], folder["movedBranches"].map { |b| b.values_at("branch", "commits") }
    assert_equal [["tracked.txt"], nil], [paths(folder), folder["movedBranch"]]
    assert_equal [%w[agent.txt agent2.txt], "agent"], [paths(moved).sort, moved["movedBranch"]]
    assert_equal ["prompt-branch", "agent at the prompt"], moved["base"].values_at("kind", "ref")
    assert_equal `git -C #{agent} rev-parse agent~2^{tree}`.strip, moved["oldRev"], "the moved branch's tree at the prompt, as a sha"
    assert_equal ["fresh.txt"], paths(created), "a branch created after the prompt diffs from where it started"
    assert_equal [["tracked.txt"], nil], [paths(untouched), untouched["movedBranch"]], "an unmoved branch is not offered"
  end

  def test_the_route_serves_the_prompt_scope_and_the_page_offers_it
    chat_session
    snapshot_now
    write("tracked.txt", "changed\n")
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

    reply = JSON.parse(gui.respond("GET", "/api/diff/feat?scope=prompt&prompt=sess-1%3A1", ok_host, "")[2])

    assert_equal [true, "prompt", ["tracked.txt"]], [reply["ok"], reply["scope"], paths(reply)]
    commit_at(add_worktree(@repo, "agent", "agent-wt"), Time.now + 60, "agent.txt", "a\n")
    moved = JSON.parse(gui.respond("GET", "/api/diff/feat?scope=prompt&moved=agent", ok_host, "")[2])
    assert_equal [["agent.txt"], "agent"], [paths(moved), moved["movedBranch"]]
    page = served_page(gui, ok_host)
    ['["prompt", "Since prompt"', 'params.set("prompt"', "function renderDiffPrompts(", "if (d.notice)",
     'd.base && d.base.ref', 'params.set("moved"', "function renderDiffMoved(", '|${c.moved || ""}|'].each do |seam|
      assert_includes page, seam
    end
  end

  # The branch checked out at `path` rebased onto `onto`, reflogged at `at`.
  def rebase_at(path, at, onto)
    assert system({ "GIT_COMMITTER_DATE" => at.iso8601 }, "git", "-C", path, *GIT_ID, "rebase", "-q", onto,
                  out: File::NULL, err: File::NULL)
  end

  # main checked out in a worktree of its own, for upstream commits while
  # the chat's folder sits on feat.
  def main_worktree
    path = File.join(@dir, "main-wt")
    system("git", "-C", @repo, "worktree", "add", "-q", path, "main", err: File::NULL)
    File.realpath(path)
  end

  def test_hides_what_a_rebase_since_the_prompt_brought_in_unless_asked_to_show_it
    chat_session
    system("git", "-C", @repo, "checkout", "-q", "-b", "feat")
    commit_at(@repo, Time.now - 30, "own.txt", "mine\n")
    main = main_worktree
    prompt_at = Time.now + 100
    snapshot_line(`git -C #{@repo} write-tree`.strip, prompt_at.utc.iso8601)
    commit_at(main, prompt_at + 50, "upstream.txt", "theirs\n")

    write("tracked.txt", "chat edit\n")
    unrebased = prompt_diff
    system("git", "-C", @repo, "checkout", "-q", "--", "tracked.txt")
    rebase_at(@repo, prompt_at + 100, "main")
    write("tracked.txt", "chat edit\n")
    hidden = prompt_diff
    shown = prompt_diff(rebase: false)

    assert_equal [["tracked.txt"], nil], [paths(unrebased), unrebased["rebase"]], "main moving on alone is no rebase"
    assert_equal ["tracked.txt"], paths(hidden)
    assert_equal({ "onto" => "main", "commits" => 1, "hidden" => true }, hidden["rebase"])
    assert_nil hidden["rebaseNotice"]
    assert_equal %w[tracked.txt upstream.txt], paths(shown).sort
    assert_equal({ "onto" => "main", "commits" => 1, "hidden" => false }, shown["rebase"])
    assert_equal hidden["base"]["sha"], shown["oldRev"], "shown: the snapshot itself"
    refute_equal hidden["base"]["sha"], hidden["oldRev"], "hidden: the snapshot replayed onto main"
    assert_equal ["theirs"], Quartermaster::FileAtRevision.new(@repo).call(hidden["oldRev"], "upstream.txt")["lines"]
    assert_equal "feat", `git -C #{@repo} symbolic-ref --short HEAD`.strip, "the repo's refs are untouched"

    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    routed = JSON.parse(gui.respond("GET", "/api/diff/feat?scope=prompt&rebase=show", ok_host, "")[2])
    assert_equal [%w[tracked.txt upstream.txt], false], [paths(routed).sort, routed["rebase"]["hidden"]]
    page = served_page(gui, ok_host)
    ['params.set("rebase"', "function renderDiffRebase(", '|${c.rebase || ""}|', "d.rebaseNotice",
     'd.scope === "prompt" && d.rebase'].each do |seam|
      assert_includes page, seam
    end
  end

  def test_a_rebase_that_conflicts_with_the_prompts_state_shows_the_plain_diff_and_says_so
    chat_session
    system("git", "-C", @repo, "checkout", "-q", "-b", "feat")
    commit_at(@repo, Time.now - 30, "own.txt", "mine\n")
    main = main_worktree
    write("tracked.txt", "prompt\n")
    snapshot_now
    system("git", "-C", @repo, "checkout", "-q", "--", "tracked.txt")
    commit_at(main, Time.now + 50, "tracked.txt", "upstream\n")
    rebase_at(@repo, Time.now + 100, "main")

    result = prompt_diff

    assert_equal ["tracked.txt"], paths(result)
    assert_equal false, result["rebase"]["hidden"]
    assert_equal "Couldn't hide the rebase: tracked.txt conflict.", result["rebaseNotice"]
    assert_nil result["notice"]
  end

  def test_hides_a_rebase_of_a_branch_that_moved_since_the_prompt
    chat_session
    agent = add_worktree(@repo, "agent", "agent-wt")
    commit_at(agent, Time.now - 30, "agent.txt", "a\n")
    prompt_at = Time.now + 100
    snapshot_line(`git -C #{@repo} write-tree`.strip, prompt_at.utc.iso8601)
    commit_at(@repo, prompt_at + 50, "upstream.txt", "theirs\n")
    rebase_at(agent, prompt_at + 100, "main")
    commit_at(agent, prompt_at + 150, "agent2.txt", "b\n")

    folder = prompt_diff
    hidden = prompt_diff(moved: "agent")
    shown = prompt_diff(moved: "agent", rebase: false)

    assert_nil folder["rebase"], "the chat's folder is on main itself: nothing rebased under it"
    assert_equal ["agent2.txt"], paths(hidden)
    assert_equal({ "onto" => "main", "commits" => 1, "hidden" => true }, hidden["rebase"])
    assert_equal %w[agent2.txt upstream.txt], paths(shown).sort
  end
end
