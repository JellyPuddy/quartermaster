# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/launcher_test.rb`).
require_relative "test_helper"

class LauncherTest < Minitest::Test
  include QmTestHelpers

  def log_start(session_id, cwd: "/", transcript: nil, pid: 999_999_999)
    Quartermaster::SessionLog.new.append(
      "event" => "start", "session_id" => session_id, "cwd" => cwd,
      "transcript_path" => transcript, "pid" => pid, "ts" => Time.now.iso8601
    )
  end

  def log_end(session_id)
    Quartermaster::SessionLog.new.append("event" => "end", "session_id" => session_id, "ts" => Time.now.iso8601)
  end

  def test_resume_plan_picks_the_newest_session_with_a_living_transcript
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      File.write(transcript, "")
      item = Quartermaster::WorkItem.create("My item", project: "No project", session_id: "sess-old")
      item.attach_session("sess-new")
      log_start("sess-old", cwd: dir, transcript: transcript)
      log_end("sess-old")
      log_start("sess-new", cwd: dir, transcript: transcript)
      log_end("sess-new")

      plan = Quartermaster::Launcher.new.resume_plan(item)
      assert_equal({ mode: :resume, session_id: "sess-new", cwd: dir }, plan)
    end
  end

  # adopt-worktree removes the worktree a session ran in, but its transcript
  # lives under the main checkout's project directory and resumes fine there.
  def test_resume_plan_falls_back_to_the_directory_the_transcript_is_filed_under
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      dir = File.join(Quartermaster::TRANSCRIPTS_DIR, root.gsub(/[^A-Za-z0-9]/, "-"))
      FileUtils.mkdir_p(dir)
      transcript = File.join(dir, "sess-wt.jsonl")
      File.write(transcript, "")
      item = Quartermaster::WorkItem.create("My item", project: "No project", session_id: "sess-wt")
      log_start("sess-wt", cwd: File.join(root, ".claude/worktrees/gone"), transcript: transcript)
      log_end("sess-wt")

      plan = Quartermaster::Launcher.new.resume_plan(item)
      assert_equal({ mode: :resume, session_id: "sess-wt", cwd: root }, plan)
    end
  end

  def test_resume_plan_rehydrates_when_all_transcripts_are_gone
    item = Quartermaster::WorkItem.create("My item", project: "No project", session_id: "sess-gone")
    log_start("sess-gone", transcript: "/nonexistent/t.jsonl")
    log_end("sess-gone")

    plan = Quartermaster::Launcher.new.resume_plan(item)
    assert_equal :rehydrate, plan[:mode]
  end

  def test_resume_plan_never_resumes_a_live_session
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      File.write(transcript, "")
      item = Quartermaster::WorkItem.create("My item", project: "No project", session_id: "sess-live")
      log_start("sess-live", cwd: dir, transcript: transcript, pid: Process.pid)

      plan = Quartermaster::Launcher.new.resume_plan(item)
      assert_equal({ mode: :live, session_id: "sess-live" }, plan)
    end
  end

  def test_session_resume_plan_resumes_an_unlinked_session_in_its_own_cwd
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      File.write(transcript, "")
      log_start("sess-loose", cwd: dir, transcript: transcript)
      log_end("sess-loose")

      plan = Quartermaster::Launcher.new.session_resume_plan("sess-loose")
      assert_equal({ mode: :resume, cwd: dir }, plan)
    end
  end

  def test_session_resume_plan_refuses_live_and_gone_sessions
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      File.write(transcript, "")
      log_start("sess-live", cwd: dir, transcript: transcript, pid: Process.pid)
      log_start("sess-pruned", cwd: dir, transcript: "/nonexistent/t.jsonl")
      log_end("sess-pruned")

      launcher = Quartermaster::Launcher.new
      assert_equal :live, launcher.session_resume_plan("sess-live")[:mode]
      assert_equal :gone, launcher.session_resume_plan("sess-pruned")[:mode]
      assert_equal :gone, launcher.session_resume_plan("sess-unknown")[:mode]
    end
  end

  def test_start_cwd_prefers_the_worktree_on_the_items_branch
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      worktree = File.join(dir, "repo-wt")
      system("git", "init", "-q", "-b", "main", repo)
      system("git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      system("git", "-C", repo, "worktree", "add", "-q", "-b", "issue/9-x", worktree)

      map = Quartermaster::ProjectMap.new(roots: { "Repo" => repo })
      launcher = Quartermaster::Launcher.new(project_map: map)
      on_branch = Quartermaster::WorkItem.create("On branch", project: "Repo", branch: "issue/9-x")
      no_branch = Quartermaster::WorkItem.create("No branch", project: "Repo")

      assert_equal File.realpath(worktree), File.realpath(launcher.start_cwd(on_branch))
      assert_equal repo, launcher.start_cwd(no_branch)
    end
  end

  def test_start_cwd_falls_back_to_the_last_session_cwd_then_home
    Dir.mktmpdir do |dir|
      item = Quartermaster::WorkItem.create("My item", project: "No project", session_id: "sess-1")
      log_start("sess-1", cwd: dir)

      assert_equal dir, Quartermaster::Launcher.new.start_cwd(item)

      homeless = Quartermaster::WorkItem.create("Nowhere", project: "No project")
      assert_equal Dir.home, Quartermaster::Launcher.new.start_cwd(homeless)
    end
  end
end
