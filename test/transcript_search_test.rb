# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/transcript_search_test.rb`).
# Real rg over fake transcripts in
# QM_TRANSCRIPTS_DIR: it only reads, so it runs for real where installed.
require_relative "test_helper"

class TranscriptSearchTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    skip "rg not installed" unless rg_available?
  end

  def rg_available?
    (ENV.fetch("PATH", "").split(File::PATH_SEPARATOR) + Quartermaster::TranscriptSearch::RG_FALLBACK_DIRS)
      .any? { |dir| File.executable?(File.join(dir, "rg")) }
  end

  def transcript(id, entries, project: "-Users-dev-code-repo")
    dir = File.join(Quartermaster::TRANSCRIPTS_DIR, project)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{id}.jsonl")
    File.write(path, entries.map { |e| JSON.generate(e) }.join("\n") + "\n")
    path
  end

  def user(text, ts = "2026-10-01T10:00:00Z") = { "type" => "user", "timestamp" => ts, "message" => { "role" => "user", "content" => text } }

  def assistant(text, ts = "2026-10-01T10:01:00Z")
    { "type" => "assistant", "timestamp" => ts,
      "message" => { "id" => "m#{rand(1_000_000)}", "role" => "assistant", "content" => [{ "type" => "text", "text" => text }] } }
  end

  def tool_call(command)
    { "type" => "assistant", "timestamp" => "2026-10-01T10:02:00Z",
      "message" => { "role" => "assistant", "content" => [{ "type" => "tool_use", "name" => "Bash", "input" => { "command" => command } }] } }
  end

  def tool_result(output)
    { "type" => "user", "timestamp" => "2026-10-01T10:03:00Z", "toolUseResult" => { "stdout" => output },
      "message" => { "role" => "user", "content" => [{ "type" => "tool_result", "content" => output }] } }
  end

  def log_start(id, ts, extra = {})
    Quartermaster::SessionLog.new.append({ "event" => "start", "session_id" => id, "cwd" => "/repo", "pid" => 999_999_999,
                                           "ts" => ts }.merge(extra))
  end

  def search(query) = Quartermaster::TranscriptSearch.new.call(query)

  def test_matches_prompts_and_replies_grouped_by_item_with_unlinked_last
    item = Quartermaster::WorkItem.create("Fix flaky spec", project: "No project", session_id: "sess-linked")
    log_start("sess-linked", "2026-10-02T09:00:00Z")
    transcript("sess-linked", [user("why is the Flaky Spec red again?"), assistant("The flaky spec races the clock."),
                               assistant("unrelated")])
    transcript("sess-unlinked", [user("hello", "2026-09-01T08:00:00Z"), assistant("a flaky spec, maybe")])

    result = search("flaky spec")

    assert_equal [item.slug, nil], result["groups"].map { |g| g["slug"] }
    linked = result["groups"].first
    assert_equal ["Fix flaky spec", "in_progress"], [linked["title"], linked["state"]]
    hit = linked["sessions"].first
    assert_equal ["sess-linked", "2026-10-02T09:00:00Z", 2, "user"], hit.values_at("id", "date", "hits", "role")
    assert_equal ["why is the ", "Flaky Spec", " red again?"], hit.values_at("before", "match", "after")
    unlinked = result["groups"].last
    assert_equal "unlinked", unlinked["title"]
    assert_equal [["sess-unlinked", "2026-09-01T08:00:00Z", "assistant"]],
                 unlinked["sessions"].map { |s| s.values_at("id", "date", "role") }
    assert_equal 0, result["more"]
  end

  def test_tool_calls_results_sidechains_subagents_and_asides_never_match
    transcript("sess-tools", [user("run it"), tool_call("grep needle lib"), tool_result("needle found")])
    transcript("sess-side", [assistant("needle").merge("isSidechain" => true)])
    transcript("agent-1", [user("needle")], project: "-Users-dev-code-repo/sess-tools/subagents")
    log_start("sess-aside", "2026-10-02T09:00:00Z", "aside" => "some-item")
    transcript("sess-aside", [user("needle in an aside")])

    assert_empty search("needle")["groups"]
  end

  def test_phrases_match_through_json_escaping_and_snippets_are_clipped
    long = "#{"x " * 100}she said \"ship it\" #{"y " * 200}"
    transcript("sess-quote", [user(long)])

    hit = search("said \"ship it\"")["groups"].first["sessions"].first
    assert_equal "said \"ship it\"", hit["match"]
    assert hit["before"].start_with?("…")
    assert hit["after"].end_with?("…")
    assert_operator hit["before"].size + hit["after"].size, :<, 220
  end

  def test_newest_sessions_win_past_the_cap_and_the_rest_are_counted
    stub_const(:MAX_SESSIONS, 2) do
      3.times do |n|
        path = transcript("sess-#{n}", [user("needle #{n}", "2026-10-0#{n + 1}T10:00:00Z")])
        File.utime(Time.now - (10 - n), Time.now - (10 - n), path)
      end
      result = search("needle")
      assert_equal %w[sess-2 sess-1], result["groups"].first["sessions"].map { |s| s["id"] }
      assert_equal 1, result["more"]
    end
  end

  def test_rg_runs_through_the_runner_and_its_failures_surface
    FileUtils.mkdir_p(Quartermaster::TRANSCRIPTS_DIR)
    runner = FakeRunner.new
    Quartermaster::TranscriptSearch.new(runner: runner).call("needle")
    argv = runner.argvs.first
    assert_equal "rg", File.basename(argv.first)
    assert_includes argv, "--fixed-strings"
    assert_equal ["needle", Quartermaster::TRANSCRIPTS_DIR], argv.last(2)

    broken = FakeRunner.new
    broken.define_singleton_method(:call) { |argv, chdir: nil| Quartermaster::CommandRunner::Result.new(out: "", err: "rg: bad thing", success: false) }
    error = assert_raises(ArgumentError) { Quartermaster::TranscriptSearch.new(runner: broken).call("needle") }
    assert_match(/rg failed: rg: bad thing/, error.message)

    path = transcript("sess-partial", [user("needle")])
    partial = FakeRunner.new
    partial.define_singleton_method(:call) do |_argv, chdir: nil|
      Quartermaster::CommandRunner::Result.new(out: "#{path}\n", err: "rg: other.jsonl: Permission denied", success: false)
    end
    result = Quartermaster::TranscriptSearch.new(runner: partial).call("needle")
    assert_equal ["sess-partial"], result["groups"].flat_map { |g| g["sessions"].map { |s| s["id"] } }
    assert_raises(ArgumentError) { search("   ") }
  end

  def test_gui_grep_endpoint_answers_without_the_action_mutex
    transcript("sess-gui", [user("find the needle")])
    server = Quartermaster::Gui.new(port: 4567, runner: Quartermaster::CommandRunner.new)
    host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

    out = server.instance_variable_get(:@mutex).synchronize do
      Timeout.timeout(5) { server.respond("POST", "/api/grep", host, JSON.generate("query" => "needle"))[2] }
    end
    res = JSON.parse(out)
    assert res["ok"]
    assert_equal ["sess-gui"], res["groups"].flat_map { |g| g["sessions"].map { |s| s["id"] } }

    _s, _c, out = server.respond("POST", "/api/grep", host, JSON.generate("query" => ""))
    assert_equal({ "ok" => false, "error" => "query is empty" }, JSON.parse(out))
  end

  def test_the_page_offers_transcript_search_beside_ask
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner), { "host" => "127.0.0.1:4567" })
    assert_includes page, 'id="search-menu-grep"'
    assert_includes page, "/api/grep"
    assert_includes page, "Search transcripts for"
  end

  def test_qm_grep_prints_hits_by_item
    item = Quartermaster::WorkItem.create("Fix flaky spec", project: "No project", session_id: "sess-cli")
    transcript("sess-cli", [user("the needle is here")])
    transcript("sess-loose", [assistant("another needle")])

    out, err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                                      RbConfig.ruby, QM_BIN, "grep", "needle")
    assert status.success?, err
    assert_match(/^#{item.slug}  Fix flaky spec  \(in_progress\)$/, out)
    assert_includes out, "  sess-cli\n    you: the needle is here"
    assert_match(/^unlinked$/, out)
    assert_includes out, "claude: another needle"

    out, = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
                          RbConfig.ruby, QM_BIN, "grep", "absent-phrase")
    assert_equal "No transcript mentions that.\n", out
  end

  private

  def stub_const(name, value)
    klass = Quartermaster::TranscriptSearch
    original = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, original)
  end
end
