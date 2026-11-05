# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/prs_view_test.rb`).
require_relative "test_helper"

class PrInboxTest < Minitest::Test
  include QmTestHelpers

  def node(url, updated, number: 1)
    { "url" => url, "number" => number, "title" => "T", "updatedAt" => updated, "headRefName" => "h",
      "baseRefName" => "main", "isDraft" => false, "reviewDecision" => nil,
      "author" => { "login" => "someone" }, "repository" => { "nameWithOwner" => "acme/WebApp" } }
  end

  def test_merge_gives_each_pr_every_role_it_matched_newest_first
    merged = Quartermaster::PrInbox.merge(
      "author" => [node("u/1", "2026-10-01T00:00:00Z")],
      "review" => [node("u/2", "2026-10-03T00:00:00Z")],
      "assignee" => [node("u/1", "2026-10-01T00:00:00Z")]
    )

    assert_equal %w[u/2 u/1], merged.map { |pr| pr["url"] }
    assert_equal %w[author assignee], merged.last["roles"]
    assert_equal "acme/WebApp", merged.last["repo"]
    assert_equal "h", merged.last["head"]
  end

  def test_without_a_review_decision_the_latest_reviews_decide
    decision = ->(own, *states) { Quartermaster::PrInbox.review_decision("reviewDecision" => own, "latestReviews" => { "nodes" => states.map { |st| { "state" => st } } }) }

    assert_equal "APPROVED", decision.(nil, "COMMENTED", "APPROVED")
    assert_equal "CHANGES_REQUESTED", decision.(nil, "APPROVED", "CHANGES_REQUESTED")
    assert_nil decision.(nil, "COMMENTED")
    assert_equal "REVIEW_REQUIRED", decision.("REVIEW_REQUIRED", "APPROVED"), "GitHub's own decision wins"
  end

  def test_ci_counts_each_checks_latest_run_like_github
    run = ->(name, conclusion, at, workflow: "CI") do
      { "name" => name, "status" => conclusion ? "COMPLETED" : "IN_PROGRESS", "conclusion" => conclusion, "startedAt" => at,
        "checkSuite" => { "workflowRun" => { "workflow" => { "name" => workflow } } } }
    end
    ci = ->(*contexts) { Quartermaster::PrInbox.ci("commits" => { "nodes" => [{ "commit" => { "statusCheckRollup" => { "contexts" => { "nodes" => contexts } } } }] }) }

    rerun = [run.("rspec", "CANCELLED", "2026-10-22T10:00:00Z"), run.("rspec", "SUCCESS", "2026-10-22T11:00:00Z"),
             run.("lint", "SKIPPED", "2026-10-22T10:00:00Z"), { "context" => "ci/circle", "state" => "SUCCESS", "createdAt" => "2026-10-22T10:00:00Z" }]
    assert_equal({ "state" => "SUCCESS", "ok" => 3, "total" => 3 }, ci.(*rerun), "a re-run supersedes the cancelled attempt")
    assert_equal({ "state" => "FAILURE", "ok" => 3, "total" => 4 }, ci.(*rerun, run.("rspec", "FAILURE", "2026-10-22T10:00:00Z", workflow: "Nightly")))
    assert_equal({ "state" => "PENDING", "ok" => 3, "total" => 4 }, ci.(*rerun, run.("deploy", nil, "2026-10-22T12:00:00Z")))
    assert_nil ci.()
    assert_nil Quartermaster::PrInbox.ci({}), "no commits fetched"

    old_suite = { "databaseId" => 1, "createdAt" => "2026-10-22T10:00:00Z", "workflowRun" => { "workflow" => { "name" => "CI" } } }
    new_suite = old_suite.merge("databaseId" => 2, "createdAt" => "2026-10-22T10:00:02Z")
    pushed_twice = [run.("rspec", "CANCELLED", "2026-10-22T10:08:00Z").merge("checkSuite" => old_suite),
                    run.("setup", "CANCELLED", "2026-10-22T10:08:00Z").merge("checkSuite" => old_suite),
                    run.("rspec", "SUCCESS", "2026-10-22T10:01:00Z").merge("checkSuite" => new_suite)]
    assert_equal({ "state" => "SUCCESS", "ok" => 1, "total" => 1 }, ci.(*pushed_twice),
                 "only the workflow's newest suite counts, though its cancelled predecessor's jobs started later")
  end

  def test_a_fresh_cache_is_served_without_fetching_and_a_failed_fetch_keeps_the_last_list
    fetches = 0
    inbox = Quartermaster::PrInbox.new(fetcher: -> { (fetches += 1) == 1 ? [{ "url" => "u/1" }] : raise("offline") })

    inbox.refresh
    listed = inbox.list
    assert_equal [{ "url" => "u/1" }], listed["prs"]
    assert_equal false, listed["refreshing"]
    assert_equal 1, fetches

    inbox.refresh
    listed = inbox.list
    assert_equal [{ "url" => "u/1" }], listed["prs"]
    assert_equal "offline", listed["error"]
    assert_equal({ "url" => "u/1" }, inbox.find("u/1"))
    assert_raises(ArgumentError) { inbox.find("u/2") }
  end

  def test_an_expired_cache_is_served_while_it_refetches_on_a_thread
    Quartermaster::PrInbox.new(fetcher: -> { [{ "url" => "old" }] }).refresh
    gate = Queue.new
    later = Quartermaster::PrInbox.new(fetcher: -> { gate.pop && [{ "url" => "new" }] },
                                       now: Time.now + Quartermaster::PrInbox::TTL_SECONDS + 1)

    listed = later.list
    assert_equal [{ "url" => "old" }], listed["prs"]
    assert_equal true, listed["refreshing"]

    gate << true
    Timeout.timeout(5) { sleep 0.01 while Quartermaster::PrInbox.in_flight }
    assert_equal [{ "url" => "new" }], Quartermaster::PrInbox.new.list["prs"]
  end
end

# The PRs view: the list tied to items and worktrees, and its chat / review /
# IDE / pf buttons. GitHub is a seeded cache, tmux a FakeTmux, every
# other tool a FakeRunner.
class GuiPrsTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  URL = "https://github.com/acme/WebApp/pull/42"

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def post(server, payload)
    JSON.parse(server.respond("POST", "/api/action", ok_host, JSON.generate(payload))[2])
  end

  def prs_of(server) = JSON.parse(server.respond("GET", "/api/prs", ok_host, "")[2])

  def with_featured_pr(head: "feature-x")
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      system("git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/WebApp.git")
      Quartermaster.ensure_setup
      configure_projects({ "WebApp" => featured_project(repo) }, ide_command: ["zsh", "-ic", "myide PATH"], ide_label: "MyIDE")
      pr = { "url" => URL, "number" => 42, "title" => "Add the thing", "repo" => "acme/WebApp",
             "author" => "someone", "head" => head, "base" => "main", "draft" => false,
             "reviewDecision" => nil, "updatedAt" => "2026-10-22T08:00:00Z", "roles" => ["review"] }
      Quartermaster::PrInbox.new(fetcher: -> { [pr] }).refresh
      yield repo
    end
  end

  def test_the_list_names_the_project_item_and_worktree_of_each_pr
    with_featured_pr do |repo|
      worktree = add_worktree(repo, "feature-x", "wt-x")
      Quartermaster::WorkItem.create("Thing", project: "WebApp", branch: "feature-x")
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new(["thing"]))

      pr = prs_of(server)["prs"].first

      assert_equal "WebApp", pr["project"]
      assert_equal "pf", pr["devServer"]
      assert_equal "/review-app-pr", pr["reviewSkill"]
      assert_equal "WebApp#42", pr["label"]
      assert_equal "thing", pr["item"]
      assert_equal true, pr["pane"]
      assert_equal "thing", pr["jobKey"]
      assert_equal worktree, File.realpath(File.expand_path(pr["worktree"]))
    end
  end

  def test_chat_starts_a_new_item_with_the_branch_and_reuses_it_after
    with_featured_pr do
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      reply = post(server, "cmd" => "pr-chat", "args" => { "url" => URL })

      assert_equal true, reply["ok"], reply["error"]
      item = Quartermaster::WorkItem.find(reply["slug"])
      assert_equal "WebApp", item.project
      assert_equal ["feature-x"], item.branches
      assert_includes item.description, URL
      assert_equal [reply["slug"]], tmux.opened.map { |o| o[:name] }

      again = post(server, "cmd" => "pr-chat", "args" => { "url" => URL })
      assert_equal reply["slug"], again["slug"]
      assert_equal true, again["attached"]
      assert_equal 1, Quartermaster::WorkItem.all.size
    end
  end

  def test_chat_opens_the_item_that_already_holds_the_branch
    with_featured_pr do
      Quartermaster::WorkItem.create("Mine", project: "WebApp", branch: "feature-x")
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

      assert_equal "mine", post(server, "cmd" => "pr-chat", "args" => { "url" => URL })["slug"]
      assert_equal 1, Quartermaster::WorkItem.all.size
    end
  end

  def test_review_runs_the_projects_review_skill_in_a_chat_of_its_own
    with_featured_pr do |repo|
      Quartermaster::WorkItem.create("Mine", project: "WebApp", branch: "feature-x")
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      reply = post(server, "cmd" => "pr-review", "args" => { "url" => URL })

      assert_equal true, reply["ok"], reply["error"]
      refute_equal "mine", reply["slug"]
      review = Quartermaster::WorkItem.find(reply["slug"])
      assert_empty review.branches, "a branch on two items makes auto-matching ambiguous"
      opened = tmux.opened.first
      skill, instruction = opened[:argv].last.split("\n\n", 2)
      assert_equal "/review-app-pr #{URL}", skill
      assert_includes instruction, "Record each finding as a qm draft with `qm draft add #{reply["slug"]} …` " \
                                   "(see `qm draft add --help`) instead of posting to GitHub"
      assert_equal repo, File.realpath(opened[:cwd])
      assert_equal reply["slug"], prs_of(server)["prs"].first["reviewItem"]

      again = post(server, "cmd" => "pr-review", "args" => { "url" => URL })
      assert_equal [reply["slug"], true], [again["slug"], again["attached"]]
    end
  end

  def test_the_ide_opens_the_prs_branch_in_a_new_worktree
    with_featured_pr do |repo|
      system("git", "-C", repo, "branch", "feature-x")
      runner = FakeRunner.new(["curl"] => ["", "", false], %w[pf status] => ["", "", false])
      server = Quartermaster::Gui.new(port: 4567, runner: runner, tmux: FakeTmux.new)

      assert_equal true, post(server, "cmd" => "pr-ide", "args" => { "url" => URL })["ok"]
      result = Timeout.timeout(5) do
        loop do
          finished = JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])["finished"]
          break finished.first if finished.any?

          sleep 0.01
        end
      end

      assert_equal true, result["ok"], result["error"]
      assert_equal "WebApp#42", result["key"]
      path = File.join(repo, ".claude", "worktrees", "feature-x")
      assert_includes runner.argvs, ["git", "worktree", "add", path, "feature-x"]
      assert_includes runner.argvs, ["zsh", "-ic", "myide #{Shellwords.escape(path)}"]
      assert_equal "MyIDE", prs_of(server)["prs"].first["ide"]
    end
  end

  def test_pr_actions_refuse_a_pr_not_in_the_list_or_a_repo_qm_does_not_know
    with_featured_pr do
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
      assert_match(/no open PR/, post(server, "cmd" => "pr-chat", "args" => { "url" => "nope" })["error"])

      File.write(Quartermaster::CONFIG_FILE, { "projects" => {} }.to_yaml)
      fresh = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
      assert_match(/not a project/, post(fresh, "cmd" => "pr-pf", "args" => { "url" => URL })["error"])
    end
  end

  def test_page_wires_the_prs_route_and_actions
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)

    ["/api/prs", "pr-chat", "pr-review", "`pr-${a}`", 'data-mode="prs"', "prCi(pr)",
     'const label = el("a", "slug pr-link", esc(pr.label));', "label.href = pr.url;",
     'if (e.target.closest(".pr-req a, .pr-link")) return;'].each { |wire| assert_includes page, wire }
  end

  EARLIER = "https://github.com/acme/WebApp/pull/41"
  SHA = "abc1234def5678901234567890abcdef12345678"

  def store = Quartermaster::PrPrerequisites.new(gh: ->(*) { raise ArgumentError, "no gh in tests" })

  # The deploy check answered from a stub GitHub; refreshed up front so
  # the payload reads a warm cache and starts no thread.
  def prereq_server
    github = FakeGitHub.new(
      pulls: { URL => { "state" => "OPEN", "mergeCommit" => nil },
               EARLIER => { "state" => "MERGED", "mergeCommit" => "1" * 40 } },
      compares: { ["2026.10.8", "1" * 40] => "behind", ["2026.10.8", SHA] => "ahead" }
    )
    deployment = Quartermaster::PrDeployment.new(store: store, fetcher: github)
    deployment.refresh
    Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new, pr_deployment: deployment)
  end

  def test_the_list_carries_each_prs_prerequisites_with_their_states
    with_featured_pr do
      store.add(URL, kind: "pr", ref: EARLIER)
      store.add(URL, kind: "commit", ref: SHA, note: "run backfill <X>\nthen merge")
      store.add("https://github.com/acme/WebApp/pull/99", kind: "commit", ref: SHA)

      payload = prs_of(prereq_server)
      reqs = payload["prs"].first["prerequisites"]

      assert_equal false, payload["prerequisitesRefreshing"]
      assert_equal [%w[pr deployed 2026.10.8], %w[commit pending 2026.10.8]],
                   reqs.map { |req| req.values_at("kind", "state", "tag") }
      assert_equal [EARLIER, SHA], reqs.map { |req| req["ref"] }
      assert_equal ["acme/WebApp"], reqs.map { |req| req["repo"] }.uniq
      assert_equal [nil, "run backfill <X>\nthen merge"], reqs.map { |req| req["note"] }
      assert_equal 1, payload["prs"].size, "a PR outside the inbox stays in the store, not on the tab"
    end
  end

  def test_the_cross_removes_a_prerequisite_through_the_store
    with_featured_pr do
      store.add(URL, kind: "pr", ref: EARLIER)
      store.add(URL, kind: "commit", ref: SHA)
      server = prereq_server

      assert_equal true, post(server, "cmd" => "pr-unrequire", "args" => { "url" => URL, "ref" => SHA })["ok"]
      assert_equal [EARLIER], store.for_pr(URL).map { |entry| entry["ref"] }
      assert_equal [EARLIER], prs_of(server)["prs"].first["prerequisites"].map { |req| req["ref"] }

      assert_match(/no prerequisite/, post(server, "cmd" => "pr-unrequire", "args" => { "url" => URL, "ref" => SHA })["error"])

      foreign = server.respond("POST", "/api/action", ok_host.merge("origin" => "https://evil.example.com"),
                               JSON.generate("cmd" => "pr-unrequire", "args" => { "url" => URL, "ref" => EARLIER }))
      assert_equal "403 Forbidden", foreign[0]
      assert_equal [EARLIER], store.for_pr(URL).map { |entry| entry["ref"] }
    end
  end

  def test_page_has_the_prerequisite_chips
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)

    ["prReqs(pr)", '"pr-unrequire"', "pr.prerequisites", "prsMeta.prerequisitesRefreshing", ".pr-req.deployed",
     "/commit/${req.ref}", "not in ${req.tag}", "deployed in ${req.tag}", "not merged"].each { |seam| assert_includes page, seam }
  end

  def test_page_shows_a_prerequisites_note_in_a_popover
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), ok_host)

    ["if (req.note)", '"pr-req-note"', "📝", "prReqNote(noted, req)", "popAt(anchor", 'el("div", "pop-note", esc(req.note))',
     ".pop-note { white-space: pre-wrap", '"pop-link"', "link.href = prReqUrl(req)"].each { |seam| assert_includes page, seam }
  end
end
