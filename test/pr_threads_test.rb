# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/pr_threads_test.rb`).
require_relative "test_helper"

# A scripted `gh api graphql`: answers by what the query asks for, records
# every call, never reaches GitHub.
module ReviewThreadsHelpers
  def thread_node(id, path: "lib/a.rb", line: 3, side: "RIGHT", resolved: false, outdated: false, comments: nil, **extra)
    { "id" => id, "path" => path, "line" => line, "originalLine" => line || 9, "startLine" => nil, "originalStartLine" => nil,
      "diffSide" => side, "subjectType" => extra.fetch(:subject, "LINE"), "isResolved" => resolved, "isOutdated" => outdated,
      "viewerCanResolve" => !resolved, "viewerCanUnresolve" => resolved, "viewerCanReply" => true,
      "resolvedBy" => resolved ? { "login" => "octo" } : nil,
      "comments" => { "nodes" => comments || [comment_node("#{id}-c1")] } }
  end

  def comment_node(id, author: "octo", state: "SUBMITTED", body: "why?")
    { "id" => id, "body" => body, "createdAt" => "2026-10-27T10:00:00Z", "url" => "https://github.com/acme/widgets/pull/7#r#{id}",
      "state" => state, "diffHunk" => "@@ -1,2 +1,3 @@\n a\n+b\n+the line", "author" => { "login" => author } }
  end

  def threads_page(nodes, next_cursor: nil, pending: [])
    { "data" => { "viewer" => { "login" => "user" }, "repository" => { "pullRequest" => {
      "id" => "PR_7", "reviews" => { "nodes" => pending },
      "reviewThreads" => { "pageInfo" => { "hasNextPage" => !next_cursor.nil?, "endCursor" => next_cursor }, "nodes" => nodes },
    } } } }
  end

  # pages: what each successive thread query answers; mutations: the
  # mutation name → its data.
  def graphql_runner(pages, mutations = {})
    pages = pages.dup
    FakeRunner.new(%w[gh api graphql] => lambda do |argv|
      query = argv.find { |arg| arg.start_with?("query=") }.to_s
      name = mutations.keys.find { |key| query.match?(/\b#{key}\(/) }
      body = name ? { "data" => { name => mutations[name] } } : (pages.size > 1 ? pages.shift : pages.first)
      [JSON.generate(body), "", true]
    end)
  end

  def var(argv, name) = argv.each_cons(2).find { |flag, value| %w[-f -F].include?(flag) && value.start_with?("#{name}=") }&.last&.split("=", 2)&.last
end

class ReviewThreadsTest < Minitest::Test
  include QmTestHelpers
  include ReviewThreadsHelpers

  def setup
    super
    Quartermaster::ReviewThreads::CACHE_MUTEX.synchronize { Quartermaster::ReviewThreads::CACHE.clear }
  end

  def threads(runner, clock: -> { Time.at(1000) }) = Quartermaster::ReviewThreads.new(runner: runner, clock: clock)

  def test_fetch_shapes_each_thread_for_the_pane_and_finds_the_viewers_pending_review
    nodes = [thread_node("T1"), thread_node("T2", side: "LEFT", line: nil, outdated: true, resolved: true),
             thread_node("T3", comments: [comment_node("C3", author: "user", state: "PENDING", body: "mine")]),
             thread_node("T4", subject: "FILE", line: nil)]
    pending = [{ "id" => "R_other", "viewerDidAuthor" => false }, { "id" => "R_mine", "viewerDidAuthor" => true }]
    runner = graphql_runner([threads_page(nodes, pending: pending)])

    data = threads(runner).fetch("acme/widgets", "7", head: "abc")

    assert_equal({ "id" => "R_mine" }, data["pendingReview"])
    assert_equal ["user", "PR_7"], data.values_at("viewer", "prId")
    first, outdated, mine, file = data["threads"]
    assert_equal({ "id" => "T1", "path" => "lib/a.rb", "side" => "new", "line" => 3, "startLine" => nil, "originalLine" => 3,
                   "file" => false, "resolved" => false, "outdated" => false, "resolvedBy" => nil, "canResolve" => true,
                   "canUnresolve" => false, "canReply" => true, "quote" => "+the line",
                   "comments" => [{ "id" => "T1-c1", "author" => "octo", "body" => "why?", "createdAt" => "2026-10-27T10:00:00Z",
                                    "url" => "https://github.com/acme/widgets/pull/7#rT1-c1", "pending" => false }] }, first)
    assert_equal ["old", nil, 9, true, true, "octo"], outdated.values_at("side", "line", "originalLine", "outdated", "resolved", "resolvedBy")
    assert_equal [true], mine["comments"].map { |c| c["pending"] }, "a PENDING comment is the viewer's own"
    assert file["file"]
    argv = runner.argvs.first
    assert_equal %w[gh api graphql], argv.first(3)
    assert_equal ["acme", "widgets", "7"], %w[owner name number].map { |name| var(argv, name) }
    assert_includes argv, "-F", "the number goes typed, an Int"
  end

  def test_fetch_follows_pages_and_caches_per_pr_head_briefly
    runner = graphql_runner([threads_page([thread_node("T1")], next_cursor: "CUR"), threads_page([thread_node("T2")])])
    now = 1000
    source = threads(runner, clock: -> { Time.at(now) })

    assert_equal %w[T1 T2], source.fetch("acme/widgets", 7, head: "abc")["threads"].map { |t| t["id"] }
    assert_equal [nil, "CUR"], runner.argvs.map { |argv| var(argv, "cursor") }

    source.fetch("acme/widgets", 7, head: "abc")
    assert_equal 2, runner.calls.size, "a second load within the TTL asks GitHub nothing"
    source.fetch("acme/widgets", 7, head: "def")
    assert_equal 3, runner.calls.size, "a new head is a new key"
    source.fetch("acme/widgets", 7, head: "def", fresh: true)
    assert_equal 4, runner.calls.size, "↻ skips the cache"
    now += Quartermaster::ReviewThreads::TTL
    source.fetch("acme/widgets", 7, head: "def")
    assert_equal 5, runner.calls.size, "an old entry is refetched"
  end

  def test_fetch_failures_are_errors_with_the_reason
    failing = FakeRunner.new(%w[gh api graphql] => ["", "HTTP 401: Bad credentials", false])
    error = assert_raises(ArgumentError) { threads(failing).fetch("acme/widgets", 7) }
    assert_includes error.message, "Bad credentials"

    graphql_error = FakeRunner.new(%w[gh api graphql] => [JSON.generate("errors" => [{ "message" => "Could not resolve" }]), "", true])
    assert_includes assert_raises(ArgumentError) { threads(graphql_error).fetch("acme/widgets", 7) }.message, "Could not resolve"

    nothing = graphql_runner([{ "data" => { "repository" => { "pullRequest" => nil } } }])
    assert_raises(ArgumentError) { threads(nothing).fetch("acme/widgets", 7) }

    assert_raises(ArgumentError) { threads(failing).fetch("acme/widgets; rm", 7) }
    assert_raises(ArgumentError) { threads(failing).fetch("acme/widgets", "7x") }
    assert_raises(ArgumentError) { threads(failing).fetch("acme/widgets", 0) }
    assert_equal 1, failing.calls.size, "a bad repo or number never reaches gh"
  end

  def test_resolve_and_unresolve_go_to_github_at_once_and_forget_the_cached_threads
    runner = graphql_runner([threads_page([thread_node("T1")])],
                            "resolveReviewThread" => { "thread" => { "id" => "T1", "isResolved" => true } },
                            "unresolveReviewThread" => { "thread" => { "id" => "T1", "isResolved" => false } })
    source = threads(runner)
    source.fetch("acme/widgets", 7, head: "abc")

    assert_equal true, source.resolve("acme/widgets", 7, "T1")
    assert_includes runner.argvs.last.join(" "), "resolveReviewThread(input: {threadId: $id})"
    assert_equal "T1", var(runner.argvs.last, "id")
    assert_equal false, source.resolve("acme/widgets", 7, "T1", resolved: false)
    assert_includes runner.argvs.last.join(" "), "unresolveReviewThread"

    source.fetch("acme/widgets", 7, head: "abc")
    assert_equal 4, runner.calls.size, "the next load after a resolve is fresh"

    assert_raises(ArgumentError) { source.resolve("acme/widgets", 7, "T1; x") }
    gone = graphql_runner([], "resolveReviewThread" => { "thread" => nil })
    assert_raises(ArgumentError) { threads(gone).resolve("acme/widgets", 7, "T1") }
  end

  def test_a_reply_goes_into_the_given_pending_review_and_a_silent_one_raises
    reply = { "comment" => { "id" => "C9", "url" => "https://github.com/x" } }
    args = ["acme/widgets", 7]
    opts = { review_id: "R_mine", thread_id: "T1", body: "done" }

    runner = graphql_runner([], "addPullRequestReviewThreadReply" => reply)
    assert_equal reply["comment"], threads(runner).reply(*args, **opts)
    assert_equal ["R_mine", "T1", "done"], %w[review thread body].map { |name| var(runner.argvs.last, name) }

    silent = graphql_runner([], "addPullRequestReviewThreadReply" => { "comment" => nil })
    assert_raises(ArgumentError) { threads(silent).reply(*args, **opts) }
    assert_raises(ArgumentError) { threads(silent).reply(*args, **opts, body: " ") }
  end
end

class ThreadReplyDraftsTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include ReviewThreadsHelpers

  REPLY = { "thread" => "PRRT_1", "repo" => "acme/widgets", "number" => "7", "url" => "https://github.com/acme/widgets/pull/7",
            "path" => "lib/a.rb", "line" => 3, "comment" => "fixed in abc" }.freeze

  def setup
    super
    Quartermaster::ReviewThreads::CACHE_MUTEX.synchronize { Quartermaster::ReviewThreads::CACHE.clear }
  end

  def act(gui, cmd, args = {}, slug = "drafted") = gui.actions.dispatch("cmd" => cmd, "slug" => slug, "args" => args)

  def test_a_thread_holds_one_reply_draft_and_a_blank_one_removes_it
    drafts = Quartermaster::Drafts.new("item")
    first = drafts.put_thread_reply(REPLY.merge("author" => "claude", "evil" => 1))
    again = drafts.put_thread_reply(REPLY.merge("comment" => "fixed in def"))

    assert_equal first["id"], again["id"]
    assert_equal({ "kind" => "thread-reply", "thread" => "PRRT_1", "repo" => "acme/widgets", "number" => 7,
                   "url" => "https://github.com/acme/widgets/pull/7", "path" => "lib/a.rb", "line" => 3, "author" => "user",
                   "comment" => "fixed in def", "rev" => 2 }, again.slice("kind", *Quartermaster::Drafts::REPLY_FIELDS, "comment", "rev"))
    refute again.key?("evil")
    assert_nil drafts.put_thread_reply(REPLY.merge("comment" => ""))
    assert_empty drafts.entries
    assert_equal "claude", drafts.put_thread_reply(REPLY.merge("author" => "claude"))["author"]
    assert_raises(ArgumentError) { drafts.put_thread_reply(REPLY.merge("thread" => "a b")) }
    assert_raises(ArgumentError) { drafts.put_thread_reply(REPLY.merge("repo" => "nope")) }
    assert_raises(ArgumentError) { drafts.put_thread_reply(REPLY.merge("number" => "0")) }
  end

  def test_the_gui_puts_replies_as_the_users_and_send_leaves_them_for_github
    live_item("Drafted", "s-drafted")
    tmux = FakeTmux.new(["drafted"])
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

    put = act(gui, "thread-reply-put", REPLY.merge("author" => "claude"))
    assert_equal "user", put["draft"]["author"], "a reply typed in the GUI is the user's"
    assert_equal({ "ok" => false, "error" => "no drafts to send" }, act(gui, "drafts-send"))

    Quartermaster::Drafts.new("drafted").put_diff_comment("path" => "lib/a.rb", "side" => "new", "line" => 2, "comment" => "x")
    assert_equal({ "ok" => true, "sent" => 1 }, act(gui, "drafts-send"))
    assert_equal ["thread-reply"], Quartermaster::Drafts.new("drafted").entries.map { |entry| entry["kind"] }
    refute_includes tmux.typed.first[2], "fixed in abc"
  end

  def test_resolve_runs_off_the_action_mutex_and_threads_come_from_their_own_route
    runner = graphql_runner([threads_page([thread_node("T1")])],
                            "resolveReviewThread" => { "thread" => { "id" => "T1", "isResolved" => true } })
    gui = Quartermaster::Gui.new(port: 4567, runner: runner, tmux: FakeTmux.new)
    host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

    status, _type, body = gui.respond("GET", "/api/pr-threads?repo=acme%2Fwidgets&number=7&head=abc", host, "")
    assert_equal "200 OK", status
    assert_equal %w[T1], JSON.parse(body)["threads"].map { |t| t["id"] }
    bad = JSON.parse(gui.respond("GET", "/api/pr-threads?repo=nope&number=7", host, "")[2])
    assert_equal false, bad["ok"]

    assert_includes Quartermaster::GuiActions::UNLOCKED, "pr-thread-resolve"
    reply = gui.instance_variable_get(:@mutex).synchronize do
      JSON.parse(gui.respond("POST", "/api/action", host, JSON.generate(
        "cmd" => "pr-thread-resolve", "args" => { "repo" => "acme/widgets", "number" => 7, "thread" => "T1", "resolve" => true }
      ))[2])
    end
    assert_equal({ "ok" => true, "resolved" => true }, reply, "answered while the mutex was held elsewhere")
  end

  def test_the_page_fetches_threads_after_the_pr_diff_and_wires_reply_and_resolve
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    page = served_page(gui, { "host" => "127.0.0.1:4567" })

    ["/api/pr-threads?", "loadPrThreads(fresh)", "reload.onclick = () => loadDiff(true)", 'draftAction("thread-reply-put"',
     'act("pr-thread-resolve"', "on unchanged lines", "pending (yours)", "prThreadsElsewhere(d)", "replyTrayEntry(d)",
     "chatDrafts(itemDrafts(slug))", 'href="/assets/css/pr-threads.css"'].each { |seam| assert_includes page, seam }
    assert_operator page.index("/assets/js/pr-threads.js"), :<, page.index("/assets/js/drafts.js")
  end
end
