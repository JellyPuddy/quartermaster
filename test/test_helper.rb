# frozen_string_literal: true

# Shared setup for every test file: env, the qm load, helpers and fake runners.

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

ENV["QM_ROOT"] = Dir.mktmpdir("qm-test")
ENV["QM_TRANSCRIPTS_DIR"] = Dir.mktmpdir("qm-test-transcripts")
ENV["QM_WARP_TAB_CONFIGS"] = Dir.mktmpdir("qm-test-warp")
# Code asking ConfigReader for a key ConfigSchema doesn't list fails the test.
ENV["QM_CONFIG_STRICT"] = "1"
# Every GUI built here lists chats on this socket; never the user's `tmux -L qm`.
ENV["QM_TMUX_SOCKET"] = "qm-test-#{Process.pid}"
at_exit { Quartermaster::Tmux.new.kill_server }
QM_BIN = File.expand_path("../quartermaster", __dir__)
load QM_BIN

require "minitest/autorun"
require "stringio"
require "time"
require "timeout"

# Every GUI a test builds answers "no PR" for each branch unless the test passes
# its own pr_fetcher, so no state build or cleanup plan starts a real `gh pr view`.
module GuiWithoutGh
  NO_PR = ->(_item, _branch) {}

  def initialize(pr_fetcher: NO_PR, **options)
    super
  end
end
Quartermaster::Gui.prepend(GuiWithoutGh)

module QmTestHelpers
  def before_setup
    @threads_before_test = Thread.list
    super
  end

  # Background work a test started and left running (a GUI state build's PR
  # refetch, say) dies with its test, so it can't write into the next test's
  # QM_ROOT.
  def after_teardown
    leaked = Thread.list - @threads_before_test.to_a - [Thread.current]
    # Killing one (a capture3 caller, say) closes streams its helper threads still read.
    leaked.each { |thread| thread.report_on_exception = false }
    leaked.each(&:kill).each do |thread|
      thread.join
    rescue StandardError
      nil
    end
    super
  end

  def setup
    FileUtils.rm_rf(Quartermaster::ROOT)
    FileUtils.rm_rf(Dir[File.join(Quartermaster::TRANSCRIPTS_DIR, "*")])
    # A background PR refetch leaked from a prior test must not make this
    # test's #refreshing? true (a thread's own cleanup deletes are harmless).
    Quartermaster::PrStatus::IN_FLIGHT_MUTEX.synchronize { Quartermaster::PrStatus::IN_FLIGHT.clear }
    # An outage left open by a prior test would swallow this test's failures.
    Quartermaster::FailureLog.reset
    # Each test's transcripts dir starts empty, so what a prior test found or missed is void.
    Quartermaster::TranscriptMemo.clear
    Quartermaster::WorkItemFile.clear
  end

  def run_hook(command, stdin, env = {})
    # QM_ITEM leaks in when the suite itself runs inside a qm-launched session;
    # a nil value unsets it for the child so tests control linking explicitly.
    Open3.capture3(
      { "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR,
        "QM_ITEM" => nil, "QM_ASIDE" => nil, "QM_LOOSE" => nil }.merge(env),
      RbConfig.ruby, QM_BIN, command,
      stdin_data: stdin
    )
  end

  def logged_events
    File.readlines(File.join(Quartermaster::ROOT, "sessions.jsonl")).map { |line| JSON.parse(line) }
  end

  def with_picked(value)
    viewer = Quartermaster::Viewer
    original = viewer.method(:pick)
    viewer.define_singleton_method(:pick) { |*, **| value }
    yield
  ensure
    viewer.define_singleton_method(:pick, original)
  end

  # A project's config.yml settings with every feature key on: a dev server
  # (command `pf`, which quiet_runner answers), a test-DB command, a review
  # skill and the pr-requires hint.
  def featured_project(root, **overrides)
    { "root" => root,
      "dev_server" => { "command" => "pf", "modes" => %w[dev ngrok tunnel], "default_mode" => "dev",
                        "status_url" => "http://localhost:3000/status", "state_file" => "/nonexistent/current" },
      "test_db" => "app-test-db", "review_skill" => "/review-app-pr", "pr_prerequisites" => true }
      .merge(overrides.transform_keys(&:to_s))
  end

  # A project's config.yml settings with benchmarks on.
  def benchmarked_project(root)
    { "root" => root, "benchmark" => { "database" => "app_benchmark", "skill" => "/skills/bench",
                                       "notes" => "Use nothing outside the app's bundle." } }
  end

  # Writes config.yml: projects (name → path or settings), plus top-level keys.
  def configure_projects(projects, **top)
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, { "projects" => projects }.merge(top.transform_keys(&:to_s)).to_yaml)
  end

  # A GUI's runner when the test doesn't care about the dev server: nothing
  # serves, and no real curl or pf ever runs.
  def quiet_runner
    FakeRunner.new(["curl"] => ["", "", false], %w[pf status] => ["", "", false])
  end

  # The page as the browser assembles it, /assets/ included, so a seam is found in any file.
  def served_page(gui, headers)
    html = gui.respond("GET", "/", headers, "")[2]
    assets = html.scan(%r{"(/assets/[^"]+)"}).flatten.map do |path|
      status, _type, body = gui.respond("GET", path, headers, "")
      raise "#{path}: #{status}" unless status == "200 OK"

      body
    end
    ([html] + assets).join("\n")
  end

  def with_stdin(text)
    $stdin = StringIO.new(text)
    yield
  ensure
    $stdin = STDIN
  end

  def write_transcript(session_id, entries)
    dir = File.join(Quartermaster::TRANSCRIPTS_DIR, "-proj")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{session_id}.jsonl")
    File.write(path, entries.map { |e| "#{JSON.generate(e)}\n" }.join)
    path
  end
end

# Records every external command and answers from a script, so no test
# touches a real pf, IDE, repo worktree or test database.
class FakeRunner
  attr_reader :calls

  def initialize(responses = {})
    @responses = responses
    @calls = []
  end

  # streams (out:/err: file paths): the answer's text is appended there, as
  # CommandRunner streams a long run, and the Result holds neither. timeout:
  # is recorded, never waited on.
  def call(argv, chdir: nil, timeout: nil, **streams)
    @calls << { argv: argv, chdir: chdir }.merge(timeout ? { timeout: timeout } : {}).merge(streams)
    answer = @responses.find { |prefix, _| argv.first(prefix.size) == prefix }&.last
    answer = answer.call(argv) if answer.respond_to?(:call)
    out, err, success = answer || ["", "", true]
    return Quartermaster::CommandRunner::Result.new(out: out, err: err, success: success) if streams.empty?

    { out: out, err: err }.each { |key, text| File.write(streams[key], text.to_s, mode: "a") if streams[key] }
    Quartermaster::CommandRunner::Result.new(out: "", err: "", success: success)
  end

  def argvs = calls.map { |c| c[:argv] }
end

module StackRepoHelpers
  GIT_ID = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"].freeze

  def make_repo(dir)
    repo = File.realpath(dir)
    system("git", "init", "-q", "-b", "main", repo)
    system("git", "-C", repo, *GIT_ID, "commit", "-q", "--allow-empty", "-m", "init")
    repo
  end

  def add_worktree(repo, branch, name)
    path = File.join(File.dirname(repo), name)
    system("git", "-C", repo, "worktree", "add", "-q", "-b", branch, path)
    File.realpath(path)
  end

  def commit_on(repo, branch, message)
    system("git", "-C", repo, "checkout", "-q", branch)
    system("git", "-C", repo, *GIT_ID, "commit", "-q", "--allow-empty", "-m", message)
    system("git", "-C", repo, "checkout", "-q", "main")
  end

  def branch_off(repo, branch, from)
    system("git", "-C", repo, "branch", branch, from)
  end

  def write_stack(repo, *stacks, version: 1)
    File.write(File.join(repo, ".git", "gh-stack"), JSON.generate(
      "schemaVersion" => version, "repository" => "github.com:x/y",
      "stacks" => stacks.map do |branches|
        { "trunk" => { "branch" => "main" },
          "branches" => branches.each_with_index.map do |b, i|
            { "branch" => b, "head" => "h#{i}", "pullRequest" => { "number" => 100 + i, "url" => "https://pr/#{100 + i}" } }
          end }
      end
    ))
  end
end

# Cleanup runs real git against throwaway repos (worktree remove, branch -D
# included) and stubs everything else: the dev server, the test-DB command, gh.
class GitPassThroughRunner < FakeRunner
  def call(argv, chdir: nil)
    return super unless argv.first == "git"

    @calls << { argv: argv, chdir: chdir }
    Quartermaster::CommandRunner.new.call(argv, chdir: chdir)
  end
end

# Records what the GUI asks tmux for; the sessions it "opened" count as live.
class FakeTmux
  attr_reader :opened, :typed, :socket
  attr_accessor :pane_pids, :pane_paths

  def initialize(live = [])
    @live = live.dup
    @opened = []
    @typed = []
    @socket = "fake"
    @pane_pids = {}
    @pane_paths = {}
  end

  def send_text(name, text) = live?(name) && (@typed << [name, text])
  def send_enter(name) = live?(name) && (@typed << [name, :enter])
  def paste(name, text) = live?(name) && (@typed << [name, :paste, text])

  def sessions = @live.dup
  def live?(name) = @live.include?(name)
  def pane_pid(name) = @pane_pids[name]
  def pane_path(name) = @pane_paths[name]
  def attach_command(name) = ["tmux", "-L", "fake", "attach-session", "-t", "=#{name}"]
  def kill(name) = !@live.delete(name).nil?
  def pane_dead?(_name) = false

  def rename(old, new)
    return false unless live?(old) && !live?(new)

    @live[@live.index(old)] = new
    true
  end

  def open(name, cwd:, argv:, env: {})
    return false if live?(name)

    @opened << { name: name, cwd: cwd, argv: argv, env: env }
    @live << name
    true
  end
end

module ChatAttentionHelpers
  HOOKS_DIR = File.expand_path("../hooks", __dir__)

  def events_path = File.join(Quartermaster::ROOT, "events.jsonl")

  def stamp(time) = time.utc.iso8601

  # The test's one reading of the clock: fixtures and expectations both count
  # back from it, so they agree even when a second ticks over mid-test.
  def fixed_now = @fixed_now ||= Time.now

  # A clock that starts just before a second boundary and moves on with every
  # read, so a test that reads Time.now twice sees two different seconds.
  def with_ticking_clock(step: 0.25)
    original = Time.method(:now)
    tick = Time.at(original.call.to_i + 0.9)
    Time.define_singleton_method(:now) { |*, **| (tick += step) - step }
    yield
  ensure
    Time.define_singleton_method(:now, original)
  end

  # [seconds_ago, event, tool, agent] tuples, in hook order.
  def log_events(session_id, *events)
    FileUtils.mkdir_p(Quartermaster::ROOT)
    File.open(events_path, "a") do |f|
      events.each do |ago, event, tool, agent|
        f.puts JSON.generate("v" => 1, "ts" => stamp(fixed_now - ago), "session_id" => session_id,
                             "event" => event, "tool" => tool.to_s, "agent" => agent.to_s)
      end
    end
  end

  def turn(session_id) = Quartermaster::EventLog.new.turn_for(session_id)

  def assistant(ago, input: 10, read: 0, created: 0, tier: "1h", model: "claude-opus")
    creation = tier == "1h" ? { "ephemeral_1h_input_tokens" => created, "ephemeral_5m_input_tokens" => 0 }
                            : { "ephemeral_1h_input_tokens" => 0, "ephemeral_5m_input_tokens" => created }
    { "type" => "assistant", "timestamp" => stamp(fixed_now - ago),
      "message" => { "model" => model, "content" => [{ "type" => "text", "text" => "ok" }],
                     "usage" => { "input_tokens" => input, "cache_read_input_tokens" => read,
                                  "cache_creation_input_tokens" => created, "cache_creation" => creation } } }
  end

  def user_text(ago, text)
    { "type" => "user", "timestamp" => stamp(fixed_now - ago),
      "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => text }] } }
  end

  # A live session (this test process's pid) linked to a new item.
  def live_item(title, session_id, state: "in_progress", transcript: nil, pid: Process.pid)
    Quartermaster::SessionLog.new.append(
      "event" => "start", "session_id" => session_id, "cwd" => "/", "transcript_path" => transcript,
      "pid" => pid, "ts" => Time.now.iso8601
    )
    item = Quartermaster::WorkItem.create(title, project: "No project", session_id: session_id)
    item.update_state(state) unless state == "in_progress"
    item
  end

  def notified(ago, id) = user_text(ago, "<task-notification>\n<task-id>#{id}</task-id>\n<status>completed</status>\n</task-notification>")

  # A Bash call (assistant tool_use) and its result; `background:` is the
  # backgroundTaskId a backgrounded (or timed-out) command's result carries.
  def bash_call(ago, use_id, command, description: nil)
    input = { "command" => command, "description" => description, "run_in_background" => true }.compact
    { "type" => "assistant", "timestamp" => stamp(fixed_now - ago),
      "message" => { "role" => "assistant",
                     "content" => [{ "type" => "tool_use", "id" => use_id, "name" => "Bash", "input" => input }] } }
  end

  def bash_result(ago, use_id, background: nil, timed_out: false)
    result = { "stdout" => "", "stderr" => "", "interrupted" => false, "backgroundTaskId" => background,
               "timedOutAfterMs" => (120_000 if timed_out) }.compact
    text = background ? "Command running in background with ID: #{background}." : "ok"
    { "type" => "user", "timestamp" => stamp(fixed_now - ago), "toolUseResult" => result,
      "message" => { "role" => "user", "content" => [{ "tool_use_id" => use_id, "type" => "tool_result", "content" => text }] } }
  end

  # A background shell launched `ago` seconds back: its call and result.
  def shell_launched(ago, task_id, description, command: "bin/long-thing")
    use_id = "toolu_#{task_id}"
    [bash_call(ago, use_id, command, description: description), bash_result(ago, use_id, background: task_id)]
  end

  def run_sh(script, stdin, env = {})
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_SKIP" => nil, "QM_ASIDE" => nil, "QM_LOOSE" => nil }.merge(env),
                   "/bin/sh", File.join(HOOKS_DIR, script), stdin_data: stdin)
  end
end

# A throwaway "GitHub": a bare repo at <dir>/acme/widgets.git (so the
# checkout's origin reads as acme/widgets) holding a PR as refs/pull/<n>/head.
module PrRepoHelpers
  include StackRepoHelpers

  def commit(path, file, content, message: "change #{file}")
    File.write(File.join(path, file), content)
    system("git", "-C", path, "add", file)
    system("git", "-C", path, *GIT_ID, "commit", "-q", "-m", message)
  end

  def sha_of(path, rev) = `git -C #{path} rev-parse #{rev}`.strip

  def push(path, refspec) = system("git", "-C", path, "push", "-q", "origin", refspec, exception: true)

  def with_pr_repo
    Dir.mktmpdir do |dir|
      origin = File.join(dir, "acme", "widgets.git")
      FileUtils.mkdir_p(origin)
      system("git", "init", "-q", "--bare", origin)
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      commit(repo, "base.txt", "base\n")
      system("git", "-C", repo, "remote", "add", "origin", origin)
      push(repo, "main")
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Qm" => repo } }.to_yaml)
      yield repo
    end
  end

  def cache_prs(*prs)
    Quartermaster.ensure_setup
    File.write(Quartermaster::PrInbox::CACHE_FILE, JSON.generate("prs" => prs, "ts" => Time.now.to_i))
  end

  def pr_entry(number: 7, head: "feature", base: "main")
    { "url" => "https://github.com/acme/widgets/pull/#{number}", "repo" => "acme/widgets", "number" => number,
      "title" => "Add widgets", "head" => head, "base" => base }
  end
end

# Answers GitHub's three questions from hashes; a missing answer or an
# Exception value raises like a failed gh call. Records every call.
class FakeGitHub
  attr_accessor :tag, :pulls, :compares
  attr_reader :calls

  def initialize(tag: "2026.10.8", pulls: {}, compares: {})
    @tag = tag
    @pulls = pulls
    @compares = compares
    @calls = []
  end

  def latest_release(repo)
    @calls << [:release, repo]
    answer(@tag)
  end

  def pull(url)
    @calls << [:pull, url]
    answer(@pulls.fetch(url) { raise "gh pr view failed" })
  end

  def compare(repo, tag, sha)
    @calls << [:compare, repo, tag, sha]
    answer(@compares.fetch([tag, sha]) { raise "gh api compare failed" })
  end

  private

  def answer(value)
    raise value if value.is_a?(Exception)

    value
  end
end

# A drafted diff comment and a 20-line file, shared by the draft and review-anchor tests.
DRAFT_COMMENT = { "path" => "lib/a.rb", "side" => "new", "line" => 2, "code" => "x = 1", "comment" => "rename x" }.freeze
ANCHOR_LINES = (1..20).map { |i| "line #{i}\n" }.join
