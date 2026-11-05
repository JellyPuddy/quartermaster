# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/prompt_snapshots_test.rb`).
require_relative "test_helper"

class SnapshotWorktreeHookTest < Minitest::Test
  include QmTestHelpers

  HOOK = File.expand_path("../hooks/snapshot-worktree.sh", __dir__)

  def setup
    super
    @dir = Dir.mktmpdir("qm-snapshot-repo")
    @repo = File.join(@dir, "repo")
    @tmp = File.join(@dir, "tmp")
    FileUtils.mkdir_p([File.join(@repo, "sub"), @tmp])
    git("init", "-q")
    File.write(File.join(@repo, ".gitignore"), "ignored.log\n")
    File.write(File.join(@repo, "tracked.txt"), "one\n")
    git("add", ".")
    git("-c", "commit.gpgsign=false", "commit", "-qm", "init")
    File.write(File.join(@repo, "tracked.txt"), "two\n")
    File.write(File.join(@repo, "sub", "untracked.txt"), "new\n")
    File.write(File.join(@repo, "ignored.log"), "noise\n")
  end

  def teardown = FileUtils.rm_rf(@dir)

  def git(*args)
    out, err, status = Open3.capture3("git", "-C", @repo, *args)
    raise "git #{args.join(" ")}: #{err}" unless status.success?

    out
  end

  def run_hook(cwd, env = {}, session_id: "sess-1")
    payload = JSON.generate("session_id" => session_id, "transcript_path" => "/t.jsonl", "cwd" => cwd,
                            "hook_event_name" => "UserPromptSubmit",
                            "prompt" => "a \"cwd\":\"/decoy\" and \"session_id\":\"decoy\"")
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_SKIP" => nil, "QM_ASIDE" => nil, "TMPDIR" => @tmp }.merge(env),
                   "/bin/sh", HOOK, stdin_data: payload)
  end

  def lines
    path = File.join(Quartermaster::ROOT, "prompt-snapshots.jsonl")
    File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  def index_bytes = File.binread(File.join(@repo, ".git", "index"))

  def test_records_tracked_and_untracked_files_and_leaves_the_real_index_alone
    status_before = git("status", "--porcelain") # refreshes the index's stat data, so it goes first
    before = index_bytes
    # Another session's snapshot, mid-flight in the shared temp dir.
    stranger = Tempfile.create("qm-snapshot.", Dir.tmpdir)
    out, err, status = run_hook(File.join(@repo, "sub"))

    assert status.success?
    assert_empty out
    assert_empty err
    assert_equal before, index_bytes, "the real index is byte-identical"
    assert_equal status_before, git("status", "--porcelain")
    assert_equal 1, lines.size
    line = lines.first
    assert_equal 1, line["v"]
    assert_equal ["sess-1", File.join(@repo, "sub"), File.realpath(@repo)], line.values_at("session_id", "cwd", "toplevel")
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, line["at"])
    files = git("ls-tree", "-r", "--name-only", line["tree"]).lines.map(&:chomp)
    assert_equal %w[.gitignore sub/untracked.txt tracked.txt], files.sort
    assert_equal "two\n", git("show", "#{line["tree"]}:tracked.txt")
    assert_empty Dir.children(@tmp), "the throwaway index is removed"
  ensure
    File.unlink(stranger) if stranger
  end

  def test_a_quick_snapshot_never_waits_out_the_time_limit
    started = Time.now
    5.times { run_hook(@repo, { "QM_SNAPSHOT_TIMEOUT" => "3" }) }

    assert_operator Time.now - started, :<, 3
    assert_equal 5, lines.size
  end

  def test_a_repo_without_an_index_yet_still_snapshots
    FileUtils.rm(File.join(@repo, ".git", "index"))
    _out, _err, status = run_hook(@repo)

    assert status.success?
    refute File.exist?(File.join(@repo, ".git", "index")), "never creates the real index"
    files = git("ls-tree", "-r", "--name-only", lines.first["tree"]).lines.map(&:chomp)
    assert_equal %w[.gitignore sub/untracked.txt tracked.txt], files.sort
  end

  def test_skips_outside_git_and_under_skip_or_aside
    [[@dir, {}], [@repo, { "QM_SKIP" => "1" }], [@repo, { "QM_ASIDE" => "item" }],
     [File.join(@dir, "missing"), {}]].each do |cwd, env|
      out, err, status = run_hook(cwd, env)

      assert status.success?
      assert_empty out
      assert_empty err
    end
    assert_empty lines
  end

  def test_garbage_stdin_prints_nothing_and_exits_zero
    out, err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT }, "/bin/sh", HOOK, stdin_data: "not json")

    assert status.success?
    assert_empty out + err
    assert_empty lines
  end

  def test_a_snapshot_past_its_time_limit_writes_nothing
    stub = File.join(@dir, "bin")
    FileUtils.mkdir_p(stub)
    real_git = `command -v git`.strip
    File.write(File.join(stub, "git"), "#!/bin/sh\n[ \"$1\" = add ] && sleep 5\nexec #{real_git} \"$@\"\n")
    File.chmod(0o755, File.join(stub, "git"))
    started = Time.now
    _out, _err, status = run_hook(@repo, { "QM_SNAPSHOT_TIMEOUT" => "1", "PATH" => "#{stub}:#{ENV.fetch("PATH")}" })

    assert status.success?
    assert_operator Time.now - started, :<, 4
    assert_empty lines
  end
end

class PromptSnapshotsTest < Minitest::Test
  include QmTestHelpers

  TREE_A = "a" * 40
  TREE_B = "b" * 40
  TREE_C = "c" * 40

  def snapshot(session, tree, at, extra = {})
    JSON.generate({ "v" => 1, "session_id" => session, "cwd" => "/repo", "toplevel" => "/repo",
                    "tree" => tree, "at" => at }.merge(extra))
  end

  def write_snapshots(*lines, tail: "")
    FileUtils.mkdir_p(Quartermaster::ROOT)
    File.write(Quartermaster::PromptSnapshots.path, lines.map { |l| "#{l}\n" }.join + tail)
  end

  def user(text, ts, extra = {})
    { "type" => "user", "timestamp" => ts, "message" => { "role" => "user", "content" => text } }.merge(extra)
  end

  def transcript(entries)
    dir = File.join(Quartermaster::TRANSCRIPTS_DIR, "-repo")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "sess-1.jsonl")
    File.write(path, entries.map { |e| "#{JSON.generate(e)}\n" }.join)
    path
  end

  def test_labels_each_snapshot_with_its_prompt_in_order
    write_snapshots(snapshot("sess-1", TREE_A, "2026-10-27T10:00:01Z", "future" => "field"),
                    snapshot("other", TREE_C, "2026-10-27T10:00:30Z"),
                    snapshot("sess-1", TREE_B, "2026-10-27T10:05:00Z"),
                    tail: '{"v":1,"session_id":"sess-1","tree":"ccc')
    transcript([user("Fix the bug\nwith details below", "2026-10-27T10:00:00.900Z"),
                { "type" => "assistant", "timestamp" => "2026-10-27T10:00:05Z", "message" => { "content" => "ok" } },
                user("tool output", "2026-10-27T10:00:06Z", "toolUseResult" => {}),
                user("#{"x" * 100} long", "2026-10-27T10:05:00.200Z")])

    snaps = Quartermaster::PromptSnapshots.new.for_session("sess-1")

    assert_equal [TREE_A, TREE_B], snaps.map { |s| s["tree"] }
    assert_equal "Fix the bug", snaps[0]["prompt"]
    assert_equal "2026-10-27T10:00:00.900Z", snaps[0]["prompt_at"]
    assert_equal "#{"x" * 80}…", snaps[1]["prompt"]
    assert_equal %w[/repo /repo], snaps.map { |s| s["toplevel"] }
  end

  def test_a_snapshot_without_its_prompt_stays_unlabelled_and_does_not_take_the_next
    write_snapshots(snapshot("sess-1", TREE_A, "2026-10-27T10:00:00Z"),
                    snapshot("sess-1", TREE_B, "2026-10-27T10:05:00Z"))
    transcript([user("<command-name>/foo</command-name>", "2026-10-27T10:00:00.100Z"),
                user("Second", "2026-10-27T10:04:59.500Z")])

    snaps = Quartermaster::PromptSnapshots.new.for_session("sess-1")

    assert_equal [nil, "Second"], snaps.map { |s| s["prompt"] }
    assert_equal ["2026-10-27T10:00:00Z", "2026-10-27T10:05:00Z"], snaps.map { |s| s["at"] }
  end

  def test_without_a_transcript_snapshots_still_show_by_time
    write_snapshots(snapshot("sess-1", TREE_A, "2026-10-27T10:00:00Z"))

    snaps = Quartermaster::PromptSnapshots.new.for_session("sess-1")

    assert_equal [[TREE_A, nil, nil]], snaps.map { |s| s.values_at("tree", "prompt", "prompt_at") }
  end

  def test_no_file_or_no_session_gives_nothing_and_bad_lines_are_skipped
    assert_empty Quartermaster::PromptSnapshots.new.for_session("sess-1")

    write_snapshots("not json", snapshot("sess-1", "not-a-tree", "2026-10-27T10:00:00Z"),
                    snapshot("sess-1", TREE_A, "yesterday"), "[1]")
    assert_empty Quartermaster::PromptSnapshots.new.for_session("sess-1")
    assert_empty Quartermaster::PromptSnapshots.new.for_session("nobody")
  end
end
