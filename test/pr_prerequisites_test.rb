# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/pr_prerequisites_test.rb`).
require_relative "test_helper"

class PrPrerequisitesTest < Minitest::Test
  include QmTestHelpers

  PR = "https://github.com/Acme/Widget/pull/200"
  EARLIER = "https://github.com/Acme/Widget/pull/120"
  SHA = "abc1234def5678901234567890abcdef12345678"

  # gh answers keyed by the args' first two words; every call is recorded.
  def fake_gh(answers = {})
    calls = []
    gh = lambda do |args, chdir|
      calls << { args: args, chdir: chdir }
      answer = answers.find { |prefix, _| args.first(prefix.size) == prefix }&.last
      raise ArgumentError, "gh #{args.first(2).join(" ")} failed: not stubbed" unless answer

      answer.respond_to?(:call) ? answer.call(args) : answer
    end
    [gh, calls]
  end

  # gh pr view: a URL comes back in GitHub's casing; no URL is the branch's PR.
  def pr_view(branch_pr = PR)
    lambda do |args|
      url = args[2] == "--json" ? branch_pr : args[2].sub(%r{acme/widget}i, "Acme/Widget")
      JSON.generate("url" => url)
    end
  end

  def store(answers = {}, now: Time.utc(2026, 10, 23, 12))
    gh, @gh_calls = fake_gh(answers)
    Quartermaster::PrPrerequisites.new(gh: gh, now: -> { now })
  end

  def origin_repo(url = "git@github.com:Acme/Widget.git")
    dir = Dir.mktmpdir("qm-prereq-repo")
    system("git", "-C", dir, "init", "-q", exception: true)
    system("git", "-C", dir, "remote", "add", "origin", url, exception: true)
    dir
  end

  def file = JSON.parse(File.read(Quartermaster::PrPrerequisites::FILE))

  def test_add_stores_a_versioned_entry_once_and_remove_drops_it
    prereqs = store

    entry = prereqs.add(PR, kind: "pr", ref: EARLIER, session: "sess-1")
    assert_equal({ "kind" => "pr", "ref" => EARLIER, "repo" => "Acme/Widget",
                   "addedAt" => "2026-10-23T12:00:00Z", "session" => "sess-1" }, entry)
    assert_nil prereqs.add(PR, kind: "pr", ref: EARLIER), "adding it twice is a no-op"
    prereqs.add(PR, kind: "commit", ref: SHA)

    assert_equal 1, file["v"]
    assert_equal [EARLIER, SHA], prereqs.for_pr(PR).map { |e| e["ref"] }
    assert_nil prereqs.for_pr(PR).last["session"]
    assert_equal [], prereqs.for_pr(EARLIER)

    assert prereqs.remove(PR, EARLIER)
    refute prereqs.remove(PR, EARLIER), "already gone"
    assert prereqs.remove(PR, SHA)
    assert_equal({}, prereqs.all, "a PR without prerequisites leaves no empty entry")
    assert_empty Dir[File.join(Quartermaster::ROOT, "*.tmp")], "the atomic write leaves no temp file"
  end

  def test_a_note_round_trips_and_old_entries_read_as_no_note
    Quartermaster.ensure_setup
    File.write(Quartermaster::PrPrerequisites::FILE, JSON.generate(
      "v" => 1, "prs" => { PR => [{ "kind" => "pr", "ref" => EARLIER, "repo" => "Acme/Widget",
                                    "addedAt" => "2026-10-01T00:00:00Z", "session" => nil }] }
    ))
    prereqs = store

    refute prereqs.for_pr(PR).first.key?("note"), "an entry from before notes has none"
    entry = prereqs.add(PR, kind: "commit", ref: SHA, note: "  run backfill X\nthen Y  ")
    assert_equal "run backfill X\nthen Y", entry["note"], "trimmed, line breaks kept"
    assert_equal "run backfill X\nthen Y", file["prs"][PR].last["note"]
    refute prereqs.add(PR, kind: "pr", ref: "https://github.com/Acme/Widget/pull/7", note: " ").key?("note"),
           "a blank note stores none"

    assert_equal "backfill Z", prereqs.set_note(PR, EARLIER, "backfill Z")["note"]
    assert_equal "backfill Z", prereqs.for_pr(PR).first["note"]
    refute prereqs.set_note(PR, EARLIER, "")&.key?("note"), "blank clears"
    refute prereqs.for_pr(PR).first.key?("note")
    assert_nil prereqs.set_note(PR, "https://github.com/Acme/Widget/pull/999", "x")
    assert_equal 1, file["v"]
  end

  def test_cli_note_adds_replaces_clears_and_lists
    answers = { %w[pr view] => pr_view }

    out, = run_cli("pr-requires", "#120", "--note", "run the backfill", answers: answers)
    assert_equal "Acme/Widget#200 now requires #120 deployed before merging\n", out
    assert_equal "run the backfill", store.for_pr(PR).first["note"]

    out, = run_cli("pr-requires", "#120", answers: answers)
    assert_includes out, "already requires #120", "without --note an existing prerequisite is still refused"
    assert_equal "run the backfill", store.for_pr(PR).first["note"]

    out, = run_cli("pr-requires", "#120", "--note", "backfill A\nthen B", answers: answers)
    assert_equal "Acme/Widget#200: note on #120 set\n", out
    assert_equal "backfill A\nthen B", store.for_pr(PR).first["note"]

    out, = run_cli("pr-requires", "--list", answers: answers)
    assert_includes out, "needs #120 deployed"
    assert_includes out, "\n    note: backfill A\n          then B\n"

    out, = run_cli("pr-requires", "#120", "--note", "", answers: answers)
    assert_equal "Acme/Widget#200: note on #120 cleared\n", out
    refute store.for_pr(PR).first.key?("note")
    out, = run_cli("pr-requires", "--list", answers: answers)
    refute_includes out, "note:"

    _, err = run_cli("pr-requires", "--list", "--note", "x", answers: answers)
    assert_equal 1, @exit
    assert_includes err, "usage: qm pr-requires"
  end

  def test_add_refuses_cross_repo_self_and_short_sha
    prereqs = store

    error = assert_raises(ArgumentError) { prereqs.add(PR, kind: "pr", ref: "https://github.com/Acme/Gadget/pull/9") }
    assert_includes error.message, "same repo"
    assert_raises(ArgumentError) { prereqs.add(PR, kind: "pr", ref: PR) }
    assert_raises(ArgumentError) { prereqs.add(PR, kind: "commit", ref: "abc1234") }
    assert_raises(ArgumentError) { prereqs.add("not-a-url", kind: "pr", ref: EARLIER) }
    assert_equal({}, prereqs.all)
  end

  def test_prune_drops_only_the_confirmed_closed_prs
    prereqs = store
    prereqs.add(PR, kind: "pr", ref: EARLIER)
    prereqs.add("https://github.com/Acme/Widget/pull/300", kind: "pr", ref: EARLIER)

    assert_equal [], prereqs.prune([])
    assert_equal ["https://github.com/Acme/Widget/pull/300"],
                 prereqs.prune(["https://github.com/Acme/Widget/pull/300", "https://github.com/Acme/Widget/pull/999"])
    assert_equal [PR], prereqs.all.keys
  end

  def test_the_pr_inbox_never_prunes
    store.add(PR, kind: "pr", ref: EARLIER)

    Quartermaster::PrInbox.new(fetcher: -> { [] }).refresh
    assert_equal [PR], store.all.keys, "absence from the user's inbox says nothing about a PR being open"
  end

  def test_resolve_pr_accepts_every_form
    repo = origin_repo
    prereqs = store({ %w[pr view] => pr_view })

    assert_equal PR, prereqs.resolve_pr(PR, cwd: repo)
    assert_equal PR, prereqs.resolve_pr("Acme/Widget#200", cwd: repo)
    assert_equal PR, prereqs.resolve_pr("acme/widget#200", cwd: repo),
                 "GitHub's casing, or the inbox's and deploy check's URLs would never match"
    assert_equal ["pr", "view", "https://github.com/acme/widget/pull/200", "--json", "url"], @gh_calls.last[:args]
    assert_equal PR, prereqs.resolve_pr("#200", cwd: repo)
    assert_equal PR, prereqs.resolve_pr("200", cwd: repo)
    assert_equal "https://github.com/Acme/Widget/pull/200",
                 prereqs.resolve_pr("200", cwd: origin_repo("https://github.com/Acme/Widget")), "https origin"
    assert_equal PR, prereqs.resolve_pr(nil, cwd: repo), "omitted: the current branch's PR"
    assert_equal({ args: %w[pr view --json url], chdir: repo }, @gh_calls.last)
    assert_raises(ArgumentError) { prereqs.resolve_pr("nonsense", cwd: repo) }
    assert_raises(ArgumentError) { prereqs.resolve_pr("#1", cwd: Dir.mktmpdir) }
  end

  def test_resolve_prerequisite_takes_pr_forms_in_the_prs_repo_and_resolves_short_shas
    prereqs = store({ %w[pr view] => pr_view, ["api", "repos/Acme/Widget/commits/abc1234"] => "#{SHA}\n" })

    assert_equal({ "kind" => "pr", "ref" => EARLIER }, prereqs.resolve_prerequisite("#120", repo: "Acme/Widget", cwd: Dir.mktmpdir))
    assert_equal({ "kind" => "pr", "ref" => EARLIER }, prereqs.resolve_prerequisite("120", repo: "Acme/Widget", cwd: nil),
                 "a bare number is a PR, never a sha")
    assert_equal({ "kind" => "commit", "ref" => SHA }, prereqs.resolve_prerequisite("abc1234", repo: "Acme/Widget", cwd: nil))
    assert_equal ["api", "repos/Acme/Widget/commits/abc1234", "--jq", ".sha"], @gh_calls.last[:args]
    assert_raises(ArgumentError) { prereqs.resolve_prerequisite("fff0000", repo: "Acme/Widget", cwd: nil) }
    assert_raises(ArgumentError) { prereqs.resolve_prerequisite("main", repo: "Acme/Widget", cwd: nil) }
  end

  def run_cli(*argv, answers: {})
    prereqs = store(answers)
    out, err = capture_io do
      Quartermaster::CLI.new(prerequisites: prereqs, cwd: Dir.mktmpdir).run(argv)
    rescue SystemExit => e
      @exit = e.status
    end
    [out, err]
  end

  def test_cli_adds_to_the_current_branchs_pr_lists_and_removes_by_short_sha
    answers = { %w[pr view] => pr_view, ["api", "repos/Acme/Widget/commits/abc1234"] => SHA }
    original = ENV.delete("CLAUDE_CODE_SESSION_ID")
    ENV["CLAUDE_CODE_SESSION_ID"] = "sess-cli"

    out, = run_cli("pr-requires", "#120", answers: answers)
    assert_equal "Acme/Widget#200 now requires #120 deployed before merging\n", out
    out, = run_cli("pr-requires", "#120", answers: answers)
    assert_includes out, "already requires #120"
    run_cli("pr-requires", "abc1234", "--pr", "Acme/Widget#200", answers: answers)
    assert_equal "sess-cli", store.for_pr(PR).first["session"]

    out, = run_cli("pr-requires", "--list", answers: answers)
    assert_includes out, "needs #120 deployed"
    assert_includes out, "needs abc1234 deployed"

    out, = run_cli("pr-requires", "--remove", "abc1234d", "--pr", PR, answers: answers)
    assert_equal "Acme/Widget#200 no longer requires abc1234\n", out
    assert_equal [EARLIER], store.for_pr(PR).map { |e| e["ref"] }

    out, = run_cli("pr-requires", "--remove", "acme/widget#120", "--pr", "acme/widget#200", answers: answers)
    assert_equal "Acme/Widget#200 no longer requires #120\n", out
    assert_equal({}, store.all)
  ensure
    original ? ENV["CLAUDE_CODE_SESSION_ID"] = original : ENV.delete("CLAUDE_CODE_SESSION_ID")
  end

  def test_cli_list_without_a_branch_pr_lists_everything
    store.add(PR, kind: "pr", ref: EARLIER)

    out, = run_cli("pr-requires", "--list")
    assert_includes out, "Acme/Widget#200 (#{PR})"
  end

  def test_cli_errors_abort_with_one_line_and_exit_1
    _, err = run_cli("pr-requires", "https://github.com/Acme/Gadget/pull/9", "--pr", PR, answers: { %w[pr view] => pr_view })
    assert_equal 1, @exit
    assert_equal 1, err.lines.size
    assert_match(/\Aqm: .*same repo/, err)

    _, err = run_cli("pr-requires", "#120")
    assert_equal 1, @exit
    assert_includes err, "not stubbed", "no branch PR: gh's failure surfaces"

    _, err = run_cli("pr-requires", "--remove", "#999", "--pr", PR, answers: { %w[pr view] => pr_view })
    assert_includes err, "has no prerequisite"

    _, err = run_cli("pr-requires")
    assert_includes err, "usage: qm pr-requires"
    assert_equal({}, store.all)
  end

  def test_help_lists_pr_requires
    out, = capture_io { Quartermaster::CLI.new.run(["help"]) }
    assert_includes out, "qm pr-requires"
  end
end
