# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/pr_deployment_test.rb`).
require_relative "test_helper"

class PrDeploymentTest < Minitest::Test
  include QmTestHelpers

  REPO = "Acme/Widget"
  PR = "https://github.com/Acme/Widget/pull/200"
  EARLIER = "https://github.com/Acme/Widget/pull/120"
  MERGE_SHA = "1111111111111111111111111111111111111111"
  SHA = "abc1234def5678901234567890abcdef12345678"

  def setup
    super
    @clock = Time.utc(2026, 10, 23, 12)
    @store = Quartermaster::PrPrerequisites.new(gh: ->(*) { raise ArgumentError, "no gh in tests" }, now: -> { @clock })
  end

  def deployment(github)
    Quartermaster::PrDeployment.new(store: @store, fetcher: github, now: -> { @clock })
  end

  def open_pr = { "state" => "OPEN", "mergeCommit" => nil }
  def merged_pr(sha = MERGE_SHA) = { "state" => "MERGED", "mergeCommit" => sha }

  def states(github) = deployment(github).states(refresh: false)[PR].to_h { |entry| [entry["ref"], entry.slice("state", "tag")] }

  def test_every_state
    closed = "https://github.com/Acme/Widget/pull/130"
    unmerged = "https://github.com/Acme/Widget/pull/140"
    never_fetched = "1234567890123456789012345678901234567890"
    [EARLIER, closed, unmerged].each { |ref| @store.add(PR, kind: "pr", ref: ref) }
    [SHA, never_fetched].each { |ref| @store.add(PR, kind: "commit", ref: ref) }
    github = FakeGitHub.new(
      pulls: { PR => open_pr, EARLIER => merged_pr, closed => { "state" => "CLOSED", "mergeCommit" => nil }, unmerged => open_pr },
      compares: { ["2026.10.8", MERGE_SHA] => "behind", ["2026.10.8", SHA] => "ahead" }
    )

    assert_equal({ "state" => "unknown" }, states(github)[EARLIER], "nothing fetched yet is unknown, never deployed")
    deployment(github).refresh

    assert_equal({ EARLIER => { "state" => "deployed", "tag" => "2026.10.8" },
                   closed => { "state" => "closed" }, unmerged => { "state" => "unmerged" },
                   SHA => { "state" => "pending", "tag" => "2026.10.8" },
                   never_fetched => { "state" => "unknown" } }, states(github))
    refute(github.calls.any? { |call| call[0] == :compare && [closed, unmerged].include?(call[3]) })
  end

  def test_identical_counts_as_deployed_and_diverged_does_not
    @store.add(PR, kind: "commit", ref: SHA)
    @store.add(PR, kind: "commit", ref: MERGE_SHA)
    github = FakeGitHub.new(pulls: { PR => open_pr },
                            compares: { ["2026.10.8", SHA] => "identical", ["2026.10.8", MERGE_SHA] => "diverged" })
    deployment(github).refresh

    assert_equal "deployed", states(github)[SHA]["state"]
    assert_equal "pending", states(github)[MERGE_SHA]["state"]
  end

  def test_a_deployed_verdict_is_cached_for_good_and_pending_rechecks_when_the_tag_moves
    @store.add(PR, kind: "commit", ref: SHA)
    @store.add(PR, kind: "pr", ref: EARLIER)
    github = FakeGitHub.new(pulls: { PR => open_pr, EARLIER => merged_pr },
                            compares: { ["2026.10.8", MERGE_SHA] => "behind", ["2026.10.8", SHA] => "ahead" })
    deployment(github).refresh

    @clock += 60
    github.calls.clear
    deployment(github).refresh
    assert_empty github.calls, "nothing is stale within the TTL"

    @clock += Quartermaster::PrDeployment::TTL_SECONDS
    github.tag = "2026.10.9"
    github.compares[["2026.10.9", SHA]] = "behind"
    github.calls.clear
    deployment(github).refresh

    compares = github.calls.select { |call| call[0] == :compare }
    assert_equal [[:compare, REPO, "2026.10.9", SHA]], compares, "the deployed merge commit is never compared again"
    refute_includes github.calls, [:pull, EARLIER], "a merged PR's merge commit never changes"
    assert_equal({ EARLIER => { "state" => "deployed", "tag" => "2026.10.8" },
                   SHA => { "state" => "deployed", "tag" => "2026.10.9" } }, states(github))
  end

  def test_a_failed_fetch_keeps_the_last_good_answer
    @store.add(PR, kind: "commit", ref: SHA)
    @store.add(PR, kind: "pr", ref: EARLIER)
    github = FakeGitHub.new(pulls: { PR => open_pr, EARLIER => open_pr }, compares: { ["2026.10.8", SHA] => "ahead" })
    deployment(github).refresh

    @clock += Quartermaster::PrDeployment::TTL_SECONDS
    offline = FakeGitHub.new(tag: RuntimeError.new("offline"), pulls: { PR => RuntimeError.new("offline"), EARLIER => RuntimeError.new("offline") })
    deployment(offline).refresh

    assert_equal({ SHA => { "state" => "pending", "tag" => "2026.10.8" }, EARLIER => { "state" => "unmerged" } }, states(offline))
    assert_equal [PR], @store.all.keys, "a failed lookup never prunes"
  end

  def test_a_lookup_that_keeps_failing_waits_out_the_ttl
    @store.add(PR, kind: "commit", ref: SHA)
    no_releases = FakeGitHub.new(tag: RuntimeError.new("404 Not Found"), pulls: { PR => RuntimeError.new("offline") })
    deployment(no_releases).refresh

    @clock += 60
    refute deployment(no_releases).states.empty?
    refute deployment(no_releases).refreshing?, "a repo without releases must not refetch on every GUI poll"
    assert_equal "unknown", states(no_releases)[SHA]["state"]
  end

  def test_a_merged_pr_without_its_merge_commit_is_asked_again
    @store.add(PR, kind: "pr", ref: EARLIER)
    github = FakeGitHub.new(pulls: { PR => open_pr, EARLIER => { "state" => "MERGED", "mergeCommit" => nil } })
    deployment(github).refresh

    @clock += Quartermaster::PrDeployment::TTL_SECONDS
    github.pulls[EARLIER] = merged_pr
    github.compares[["2026.10.8", MERGE_SHA]] = "behind"
    deployment(github).refresh

    assert_equal({ "state" => "deployed", "tag" => "2026.10.8" }, states(github)[EARLIER])
  end

  def test_refresh_prunes_dependent_prs_github_confirms_merged_or_closed
    merged = "https://github.com/Acme/Widget/pull/300"
    closed = "https://github.com/Acme/Widget/pull/400"
    unanswered = "https://github.com/Acme/Widget/pull/500"
    [PR, merged, closed, unanswered].each { |url| @store.add(url, kind: "commit", ref: SHA) }
    github = FakeGitHub.new(pulls: { PR => open_pr, merged => merged_pr, closed => { "state" => "CLOSED", "mergeCommit" => nil } },
                            compares: { ["2026.10.8", SHA] => "ahead" })

    deployment(github).refresh

    assert_equal [PR, unanswered], @store.all.keys
  end

  def test_states_never_wait_on_github_and_refresh_in_the_background
    @store.add(PR, kind: "commit", ref: SHA)
    gate = Queue.new
    github = FakeGitHub.new(pulls: { PR => open_pr }, compares: { ["2026.10.8", SHA] => "behind" })
    github.define_singleton_method(:latest_release) { |repo| gate.pop && super(repo) }

    answer = Timeout.timeout(2) { deployment(github).states }
    assert_equal "unknown", answer[PR].first["state"]
    assert deployment(github).refreshing?

    gate << true
    Timeout.timeout(5) { sleep 0.01 while Quartermaster::PrDeployment.in_flight }
    assert_equal "deployed", deployment(github).states[PR].first["state"]
    refute deployment(github).refreshing?, "a fresh cache starts no refresh"
  end

  def test_cli_list_shows_the_cached_state_without_asking_github
    @store.add(PR, kind: "commit", ref: SHA)
    @store.add(PR, kind: "pr", ref: EARLIER)
    deployment(FakeGitHub.new(pulls: { PR => open_pr, EARLIER => open_pr }, compares: { ["2026.10.8", SHA] => "behind" })).refresh

    out, = capture_io { Quartermaster::CLI.new(prerequisites: @store, cwd: Dir.mktmpdir).run(["pr-requires", "--list"]) }

    assert_includes out, "needs abc1234 deployed — added 2026-10-23T12:00:00Z — ✓ deployed in 2026.10.8"
    assert_includes out, "needs #120 deployed — added 2026-10-23T12:00:00Z — not merged"
    refute Quartermaster::PrDeployment.in_flight, "the CLI starts no refresh"
  end
end
