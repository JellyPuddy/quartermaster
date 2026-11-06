# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/automation_flows_test.rb`).
require_relative "test_helper"

# The flows a local automation's run takes: tmux is a FakeTmux, gh a
# FakeRunner, so the argv and env each flow hands tmux is what's asserted.
class AutomationFlowsTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  SID = "11111111-2222-3333-4444-555555555555"
  URL = "https://github.com/acme/WebApp/pull/42"
  PR = { "url" => URL, "number" => 42, "title" => "Add the thing", "repo" => "acme/WebApp",
         "author" => "someone", "head" => "feature-x", "base" => "main" }.freeze
  REVIEW = { "flow" => "pr-review", "repos" => ["acme/WebApp"] }.freeze

  def entry(record = {})
    Quartermaster::AutomationStore::Entry.new(slug: "nightly-triage", record: { "runner" => "local" }.merge(record),
                                              prompt: "Triage the inbox.\n")
  end

  def flows(tmux, runner: FakeRunner.new) = Quartermaster::AutomationFlows.new(tmux: tmux, runner: runner)

  def with_project
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      system("git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/WebApp.git")
      configure_projects({ "WebApp" => featured_project(repo) })
      yield repo
    end
  end

  def cache_prs(*prs)
    Quartermaster.ensure_setup
    File.write(Quartermaster::PrInbox::CACHE_FILE, JSON.generate("prs" => prs, "ts" => Time.now.to_i))
  end

  def test_a_chat_run_opens_its_own_tmux_session_with_the_session_id_flags_and_prompt_last
    Dir.mktmpdir do |cwd|
      tmux = FakeTmux.new
      record = { "flow" => "chat", "cwd" => cwd, "model" => "sonnet", "permission_mode" => "acceptEdits",
                 "allowed_tools" => ["Bash(gh:*)", "Read"] }

      reply = flows(tmux).start(entry(record), nil, "Triage the inbox.\n", run_id: "ab12cd34", session_id: SID)

      assert_equal({ item_slug: "nightly-triage", tmux: "nightly-triage--run-ab12cd34" }, reply)
      opened = tmux.opened.first
      assert_equal "nightly-triage--run-ab12cd34", opened[:name]
      assert_equal cwd, opened[:cwd]
      assert_equal ["claude", "--session-id", SID, "--model", "sonnet", "--permission-mode", "acceptEdits",
                    "--allowedTools", "Bash(gh:*),Read", "Triage the inbox.\n"], opened[:argv]
      assert_equal({ "QM_ITEM" => "nightly-triage" }, opened[:env])
    end
  end

  def test_a_chat_run_without_flags_passes_only_the_session_id
    tmux = FakeTmux.new

    flows(tmux).start(entry("cwd" => Dir.home), nil, "Go.", run_id: "r1", session_id: SID)

    assert_equal ["claude", "--session-id", SID, "Go."], tmux.opened.first[:argv]
  end

  def test_a_chat_run_honours_the_chat_command_swap
    ENV["QM_CHAT_COMMAND"] = "claude --model haiku"
    tmux = FakeTmux.new

    flows(tmux).start(entry("cwd" => Dir.home), nil, "Go.", run_id: "r1", session_id: SID)

    assert_equal ["claude", "--model", "haiku", "--session-id", SID, "Go."], tmux.opened.first[:argv]
  ensure
    ENV.delete("QM_CHAT_COMMAND")
  end

  def test_a_chat_run_starts_in_the_automations_project_root_by_default
    with_project do |repo|
      Quartermaster::WorkItem.create("Nightly triage", project: "WebApp")
      tmux = FakeTmux.new

      flows(tmux).start(entry, nil, "Go.", run_id: "r1", session_id: SID)

      assert_equal File.realpath(repo), File.realpath(tmux.opened.first[:cwd])
    end
  end

  def test_a_json_item_is_appended_pretty_printed_under_an_item_heading
    tmux = FakeTmux.new
    item = { "key" => "issue-7", "title" => "Crash on save" }

    flows(tmux).start(entry("cwd" => Dir.home), item, "Fix it.\n", run_id: "r1", session_id: SID)

    expected = "Fix it.\n\n## Item\n\n{\n  \"key\": \"issue-7\",\n  \"title\": \"Crash on save\"\n}"
    assert_equal expected, tmux.opened.first[:argv].last
  end

  def test_a_plain_guard_line_is_appended_as_the_line
    tmux = FakeTmux.new

    flows(tmux).start(entry("cwd" => Dir.home), { "key" => "logs/a.txt", "line" => "logs/a.txt" }, "Read it.",
                      run_id: "r1", session_id: SID)

    assert_equal "Read it.\n\n## Item\n\nlogs/a.txt", tmux.opened.first[:argv].last
  end

  def test_a_run_whose_tmux_session_already_runs_raises
    tmux = FakeTmux.new(["nightly-triage--run-r1"])

    assert_raises(ArgumentError) { flows(tmux).start(entry("cwd" => Dir.home), nil, "Go.", run_id: "r1", session_id: SID) }
    assert_empty tmux.opened
  end

  def test_problem_checks_the_item_against_the_flows_needs
    registry = flows(FakeTmux.new)

    assert_nil registry.problem("chat", nil)
    assert_nil registry.problem(nil, { "key" => "x" })
    assert_nil registry.problem("pr-review", { "key" => "pr", "url" => URL })
    assert_equal 'item "pr" lacks url, which the pr-review flow needs', registry.problem("pr-review", { "key" => "pr" })
    assert_equal 'item "pr" lacks url, which the pr-review flow needs', registry.problem("pr-review", { "key" => "pr", "url" => " " })
    assert_equal "a run without an item lacks url, which the pr-review flow needs", registry.problem("pr-review", nil)
    assert_equal 'unknown flow "branch-stats" (chat, pr-review)', registry.problem("branch-stats", nil)
  end

  def test_start_refuses_an_item_the_flow_cant_take
    tmux = FakeTmux.new

    error = assert_raises(ArgumentError) do
      flows(tmux).start(entry("flow" => "pr-review"), { "key" => "x" }, "", run_id: "r1", session_id: SID)
    end
    assert_includes error.message, "lacks url"
    assert_empty tmux.opened
  end

  def test_start_refuses_a_hand_edited_yml_with_bypass_permissions
    tmux = FakeTmux.new

    error = assert_raises(ArgumentError) do
      flows(tmux).start(entry("cwd" => Dir.home, "permission_mode" => "bypassPermissions"), nil, "Go.",
                        run_id: "r1", session_id: SID)
    end
    assert_includes error.message, "bypassPermissions is refused"
    assert_empty tmux.opened
  end

  def test_a_json_item_that_only_looks_like_a_plain_line_stays_json
    tmux = FakeTmux.new

    flows(tmux).start(entry("cwd" => Dir.home), { "key" => "k1", "line" => "something else" }, "Go.",
                      run_id: "r1", session_id: SID)

    assert_equal "Go.\n\n## Item\n\n{\n  \"key\": \"k1\",\n  \"line\": \"something else\"\n}", tmux.opened.first[:argv].last
  end

  def test_a_pr_review_run_opens_the_review_items_chat_with_flags_and_the_prompt_as_extra_instructions
    with_project do |repo|
      cache_prs(PR)
      tmux = FakeTmux.new
      runner = FakeRunner.new

      reply = flows(tmux, runner: runner).start(entry(REVIEW.merge("model" => "opus")), { "key" => URL, "url" => URL },
                                                "Focus on the migrations.", run_id: "r1", session_id: SID)

      assert_equal({ item_slug: "review-webapp-42-add-the-thing", tmux: "review-webapp-42-add-the-thing" }, reply)
      opened = tmux.opened.first
      assert_equal "review-webapp-42-add-the-thing", opened[:name]
      assert_equal ["claude", "--session-id", SID, "--model", "opus"], opened[:argv][0..-2]
      skill, instruction, extra = opened[:argv].last.split("\n\n")
      assert_equal "/review-app-pr #{URL}", skill
      assert_includes instruction, "qm draft add review-webapp-42-add-the-thing"
      assert_equal "Focus on the migrations.", extra
      assert_equal({ "QM_ITEM" => "review-webapp-42-add-the-thing" }, opened[:env])
      assert_equal File.realpath(repo), File.realpath(opened[:cwd])
      assert_empty runner.calls, "a cached PR needs no gh call"
    end
  end

  def test_a_pr_review_run_waits_while_the_review_chat_is_open
    with_project do
      cache_prs(PR)
      slug = Quartermaster::PrReviewStart.new(tmux: FakeTmux.new, pr_items: Quartermaster::PrItems.new).item_for(PR).slug
      tmux = FakeTmux.new([slug])

      reply = flows(tmux).start(entry(REVIEW), { "key" => URL, "url" => URL }, "", run_id: "r1", session_id: SID)

      assert_equal({ waiting: "Review chat for WebApp#42 is open" }, reply)
      assert_empty tmux.opened
    end
  end

  def test_a_pr_review_run_fetches_a_pr_the_inbox_doesnt_hold
    with_project do
      cache_prs
      view = { "number" => 42, "title" => "Add the thing", "url" => URL, "headRefName" => "feature-x",
               "baseRefName" => "main", "author" => { "login" => "someone" } }
      runner = FakeRunner.new(["gh", "pr", "view"] => [JSON.generate(view), "", true])
      tmux = FakeTmux.new

      reply = flows(tmux, runner: runner).start(entry(REVIEW), { "key" => URL, "url" => URL }, "",
                                                run_id: "r1", session_id: SID)

      assert_equal ["gh", "pr", "view", URL, "--json", "number,title,url,headRefName,baseRefName,author"], runner.argvs.first
      assert_equal "review-webapp-42-add-the-thing", reply[:item_slug]
      item = Quartermaster::WorkItem.find(reply[:item_slug])
      assert_includes item.description, "by @someone: `feature-x` → `main`"
    end
  end

  def test_a_pr_review_run_refuses_a_repo_its_automation_doesnt_list
    cache_prs(PR)
    tmux = FakeTmux.new
    runner = FakeRunner.new

    [{ "flow" => "pr-review" }, { "flow" => "pr-review", "repos" => ["acme/other"] }].each do |record|
      error = assert_raises(Quartermaster::AutomationFlows::Refused) do
        flows(tmux, runner: runner).start(entry(record), { "key" => URL, "url" => URL }, "", run_id: "r1", session_id: SID)
      end
      assert_includes error.message, "repo acme/WebApp isn't in this automation's repos"
    end
    assert_empty tmux.opened
    assert_empty runner.calls
  end

  def test_refusal_matches_repos_case_insensitively_and_refuses_a_non_pr_url
    registry = flows(FakeTmux.new)
    record = { "repos" => ["ACME/webapp"] }

    assert_nil registry.refusal("pr-review", record, { "key" => "k", "url" => URL })
    assert_equal '"https://github.com/acme" isn\'t a GitHub pull request URL',
                 registry.refusal("pr-review", record, { "key" => "k", "url" => "https://github.com/acme" })
    assert_nil registry.refusal("chat", {}, { "key" => "k" })
  end

  def test_a_pr_gh_cant_find_fails_the_run
    with_project do
      cache_prs
      runner = FakeRunner.new(["gh", "pr", "view"] => ["", "no pull requests found", false])
      tmux = FakeTmux.new

      error = assert_raises(ArgumentError) do
        flows(tmux, runner: runner).start(entry(REVIEW), { "key" => URL, "url" => URL }, "",
                                          run_id: "r1", session_id: SID)
      end
      assert_includes error.message, "no pull requests found"
      assert_empty tmux.opened
    end
  end
end
