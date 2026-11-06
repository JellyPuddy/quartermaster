# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/issue_start_test.rb`).
require_relative "test_helper"

# gh is scripted and `git fetch` stubbed; only `git worktree add` runs for
# real, against a throwaway repo whose origin/main is a local ref.
class IssueRunner < FakeRunner
  def call(argv, chdir: nil)
    return super unless argv.first(2) == %w[git worktree]

    @calls << { argv: argv, chdir: chdir }
    Quartermaster::CommandRunner.new.call(argv, chdir: chdir)
  end
end

module IssueStartHelpers
  include StackRepoHelpers

  ISSUE_URL = "https://github.com/acme/widget/issues/123"

  def issue_runner(state: "OPEN", title: "Export breaks on empty rows", known: true)
    view = if known
             [JSON.generate("number" => 123, "title" => title, "state" => state, "url" => ISSUE_URL), "", true]
           else
             ["", "GraphQL: Could not resolve to an issue with the number of 123.", false]
           end
    IssueRunner.new(%w[gh issue view] => view, %w[gh repo view] => ["main\n", "", true],
                    ["curl"] => ["", "", false], %w[pf status] => ["", "", false])
  end

  # A repo whose origin is acme/widget on GitHub, configured as project
  # "Widget" (and "WebApp", configured with a test-DB command).
  def with_widget_repo
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      system("git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/widget.git")
      system("git", "-C", repo, "update-ref", "refs/remotes/origin/main", "HEAD")
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Widget" => repo, "WebApp" => featured_project(repo) } }.to_yaml)
      yield repo
    end
  end

  def starter(runner) = Quartermaster::IssueStart.new(runner: runner)
end

class IssueStartTest < Minitest::Test
  include QmTestHelpers
  include IssueStartHelpers

  def test_preview_reads_the_issue_and_names_the_branch_it_would_create
    with_widget_repo do |repo|
      runner = issue_runner(title: "Export breaks on empty rows when the sheet has a frozen header")
      preview = starter(runner).preview("#123", "Widget")

      assert_equal({ "number" => 123, "title" => "Export breaks on empty rows when the sheet has a frozen header",
                     "state" => "open", "closed" => false, "url" => ISSUE_URL, "project" => "Widget",
                     "repo" => "acme/widget", "branch" => "issue/123-export-breaks-on-empty-rows-when-the",
                     "reuse_branch" => false,
                     "slug" => "export-breaks-on-empty-rows-when-the-sheet-has-a-frozen-header-123",
                     "existing" => nil }, preview)
      assert_equal [{ argv: %w[gh issue view 123 --repo acme/widget --json number,title,state,url], chdir: repo }],
                   runner.calls, "a preview only reads"
    end
  end

  def test_a_closed_issue_is_flagged_but_still_startable
    with_widget_repo do
      preview = starter(issue_runner(state: "CLOSED")).preview(123, "Widget")
      assert_equal true, preview["closed"]
      assert_equal "issue/123-export-breaks-on-empty-rows", preview["branch"]
    end
  end

  def test_a_title_without_letters_or_digits_gets_a_number_only_branch
    with_widget_repo do
      preview = starter(issue_runner(title: "日本語 タイトル")).preview(123, "Widget")
      assert_equal "issue/123", preview["branch"]
      assert_equal "123", preview["slug"]
    end
  end

  def test_unknown_issues_projects_and_repos_without_github_are_refused
    with_widget_repo do |repo|
      error = assert_raises(ArgumentError) { starter(issue_runner(known: false)).preview(123, "Widget") }
      assert_match(/no issue #123 in acme\/widget: GraphQL: Could not resolve/, error.message)
      assert_raises(ArgumentError) { starter(issue_runner).preview("12a", "Widget") }
      assert_match(/no repo root configured for project 'Nope'/,
                   assert_raises(ArgumentError) { starter(issue_runner).preview(123, "Nope") }.message)

      system("git", "-C", repo, "remote", "remove", "origin")
      assert_match(/has no GitHub origin remote/,
                   assert_raises(ArgumentError) { starter(issue_runner).preview(123, "Widget") }.message)
    end
  end

  def test_an_item_with_the_issue_branch_or_url_is_the_existing_one
    with_widget_repo do
      by_branch = Quartermaster::WorkItem.create("Old work", project: "Widget", branch: "issue/123-old-name")
      Quartermaster::WorkItem.create("Elsewhere", project: "WebApp", branch: "issue/123-other-repo")
      by_url = Quartermaster::WorkItem.create("Linked by URL", project: "No project", description: "See #{ISSUE_URL}.")
      Quartermaster::WorkItem.create("Neighbour", project: "Widget", branch: "issue/1234-x",
                                                  description: "#{ISSUE_URL}4")
      start = starter(issue_runner)

      preview = start.preview(123, "Widget")
      assert_equal({ "slug" => "old-work", "title" => "Old work", "state" => "in_progress" }, preview["existing"])
      assert_nil preview["branch"]

      by_branch.update_state("resolved")
      assert_equal "linked-by-url", start.existing_item("Widget", 123, url: ISSUE_URL).slug, "an unresolved item wins"
      by_url.update_state("resolved")
      assert_equal "old-work", start.existing_item("Widget", 123, url: ISSUE_URL).slug
      assert_nil start.existing_item("Widget", 12, url: "https://github.com/acme/widget/issues/12")
    end
  end

  def test_start_branches_off_fresh_origin_creates_the_worktree_then_the_linked_item
    with_widget_repo do |repo|
      Quartermaster::WorkItem.create("Drafting", project: "Widget")
      runner = issue_runner
      start = starter(runner)
      labels = []

      started = start.start(start.preview(123, "Widget"), from: "drafting", progress: ->(label) { labels << label })

      path = File.join(repo, ".claude", "worktrees", "issue-123-export-breaks-on-empty-rows")
      item = started[:item]
      assert_equal path, started[:target].path
      assert_equal "issue/123-export-breaks-on-empty-rows", Quartermaster.git(path, "rev-parse", "--abbrev-ref", "HEAD")
      assert_nil Quartermaster.git(path, "rev-parse", "--abbrev-ref", "@{upstream}"), "never tracks origin/main"
      assert_equal ["gh repo view acme/widget --json defaultBranchRef --jq .defaultBranchRef.name",
                    "git fetch origin main",
                    "git worktree add --no-track -b issue/123-export-breaks-on-empty-rows #{path} origin/main"],
                   runner.argvs.drop(1).map { |argv| argv.join(" ") }
      assert_equal ["fetching origin/main…", "creating the worktree…"], labels

      assert_equal "Export breaks on empty rows (#123)", item.title
      assert_equal "export-breaks-on-empty-rows-123", item.slug
      assert_equal "in_progress", item.state
      assert_equal "Widget", item.project
      assert_equal ["issue/123-export-breaks-on-empty-rows"], item.branches
      assert_equal "#{ISSUE_URL}\n\nExport breaks on empty rows", item.description
      assert_equal "#123 started as export-breaks-on-empty-rows-123",
                   Quartermaster::WorkItem.find("drafting").notes.first.text
      assert_equal "export-breaks-on-empty-rows-123", start.preview(123, "Widget")["existing"]["slug"]
    end
  end

  def test_an_unlinked_local_issue_branch_is_reused_and_a_test_db_project_gets_its_test_db
    with_widget_repo do |repo|
      system("git", "-C", repo, "branch", "-q", "issue/123-earlier-try")
      runner = issue_runner
      start = starter(runner)

      preview = start.preview(123, "WebApp")
      assert_equal "issue/123-earlier-try", preview["branch"]
      assert_equal true, preview["reuse_branch"]
      started = start.start(preview)

      path = File.join(repo, ".claude", "worktrees", "issue-123-earlier-try")
      assert_equal [["git", "worktree", "add", path, "issue/123-earlier-try"], %w[app-test-db prepare]],
                   runner.argvs.drop(1)
      assert_equal ["issue/123-earlier-try"], started[:item].branches
      refute(runner.argvs.any? { |argv| argv[1] == "fetch" }, "a reused branch is not re-based on origin")
    end
  end

  def test_a_fresh_chat_plan_carries_a_first_prompt
    item = Quartermaster::WorkItem.create("Kick off", project: "No project")
    plan = Quartermaster::Launcher.new.chat_plan(item, fresh: true, prompt: Quartermaster::IssueStart.kickoff(7))
    assert_equal ["claude", "Read issue #7 (`gh issue view 7 --comments`), summarise the problem, then " \
                            "run a grilling session (the grilling skill) with me on how to solve it. Don't change code yet."], plan[:argv]
  end
end

class GuiIssueStartTest < Minitest::Test
  include QmTestHelpers
  include IssueStartHelpers

  def host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def post(server, payload) = JSON.parse(server.respond("POST", "/api/action", host, JSON.generate(payload))[2])

  def finished_job(server)
    Timeout.timeout(10) { sleep 0.05 until server.jobs.running.empty? }
    server.jobs.take_finished.last
  end

  def test_preview_then_start_opens_the_chat_in_the_new_worktree_with_the_kickoff
    with_widget_repo do |repo|
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: issue_runner, tmux: tmux)

      preview = post(server, "cmd" => "issue-preview", "args" => { "number" => "123", "project" => "Widget" })
      assert_equal true, preview["ok"]
      assert_equal "issue/123-export-breaks-on-empty-rows", preview["issue"]["branch"]

      reply = post(server, "cmd" => "issue-start", "args" => { "number" => 123, "project" => "Widget" })
      assert_equal [true, true, "export-breaks-on-empty-rows-123"], reply.values_at("ok", "background", "slug")
      job = finished_job(server)

      path = File.join(repo, ".claude", "worktrees", "issue-123-export-breaks-on-empty-rows")
      assert_equal true, job["ok"], job["error"]
      assert_equal "export-breaks-on-empty-rows-123", job["slug"]
      assert_equal path, job["path"]
      assert_equal [{ name: "export-breaks-on-empty-rows-123", cwd: File.realpath(path),
                      argv: ["claude", Quartermaster::IssueStart.kickoff(123)],
                      env: { "QM_ITEM" => "export-breaks-on-empty-rows-123" } }],
                   tmux.opened.map { |o| o.merge(cwd: File.realpath(o[:cwd])) }
    end
  end

  def test_the_preview_reads_github_off_the_action_mutex
    with_widget_repo do
      server = Quartermaster::Gui.new(port: 4567, runner: issue_runner, tmux: FakeTmux.new)
      preview = server.instance_variable_get(:@mutex).synchronize do
        post(server, "cmd" => "issue-preview", "args" => { "number" => "123", "project" => "Widget" })
      end
      assert_equal "issue/123-export-breaks-on-empty-rows", preview["issue"]["branch"]
    end
  end

  def test_an_issue_already_held_opens_that_items_chat_instead
    with_widget_repo do
      Quartermaster::WorkItem.create("Old work", project: "Widget", branch: "issue/123-old").update_state("resolved")
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: issue_runner, tmux: tmux)

      reply = post(server, "cmd" => "issue-start", "args" => { "number" => 123, "project" => "Widget" })

      assert_equal [true, true, "old-work", "start"], reply.values_at("ok", "existing", "slug", "mode")
      assert_equal ["old-work"], tmux.opened.map { |o| o[:name] }
      assert_equal "in_progress", Quartermaster::WorkItem.find("old-work").state
      assert_empty server.jobs.running
    end
  end

  def test_an_unknown_drafting_item_is_refused_before_anything_is_made
    with_widget_repo do
      server = Quartermaster::Gui.new(port: 4567, runner: issue_runner, tmux: FakeTmux.new)
      reply = post(server, "cmd" => "issue-start", "args" => { "number" => 123, "project" => "Widget", "from" => "nope" })
      assert_equal({ "ok" => false, "error" => "no work item 'nope'" }, reply)
      assert_empty Quartermaster::WorkItem.all
    end
  end

  def page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)

  def test_the_page_loads_the_issue_start_script_after_what_it_calls_and_before_events
    html = page
    order = %w[long-actions prs modals issues issues-list issue-start transcript-search events]
      .map { |name| html.index(%(<script src="/assets/js/#{name}.js">)) }
    assert order.all?, "every script tag present"
    assert_equal order.sort, order, "classic scripts: issue-start.js after what it calls at load, before events.js"
    assert_includes html, '<link rel="stylesheet" href="/assets/css/issue-start.css">'
  end

  def test_every_entry_point_ends_in_the_preview_confirmation
    html = page
    ['cmd: "issue-preview"', "function issueStartModal(number, project, { from = null } = {})",
     "renderIssueStartPreview(box, res.issue, from)", "if (openModal !== shown) return;"].each { |seam| assert_includes html, seam }
    assert_includes html, "m.append(tf, pf, df, issueFromNewItemRow());", "＋ New item: the From issue row"
    assert_includes html, "issueStartModal(ref.number, ref.project || row.querySelector(\"select\").value || null);"
    assert_includes html, 'else if (issueRef(query)) startFromSearch(); else runAsk();', "⏎ on #1234 starts work, not an ask"
    assert_includes html, '<button type="button" id="search-menu-issue" hidden></button>'
    assert_includes html, '$("#search-menu-issue").addEventListener("mousedown"'
    assert_includes html, "issueStartModal(ref.number, ref.project || contextProject());", "plain #n: the open item's project"
    assert_includes html, "issueStartModal(number, project, { from: fromSlug });", "a draft's Start work passes its item"
  end

  def test_the_confirmation_shows_state_branch_project_and_the_held_item
    html = page
    ['iss.closed ? "closed" : "open"', "This issue is closed on GitHub. You can still start work on it.",
     'fact("Branch"', 'fact("Project", esc(iss.project));', 'iss.existing ? "Open its chat" : "Start"',
     'act("issue-start"'].each { |seam| assert_includes html, seam }
  end

  def test_start_follows_the_job_into_the_new_items_chat_or_opens_the_held_one
    html = page
    assert_includes html, 'act("issue-start", { args: { number: iss.number, project: iss.project, from } })'
    assert_includes html, 'toast(`#${iss.number} is already ${r.slug}: opened its chat`);', "A4 says so"
    assert_includes html, "if (!iss.existing) issueStarting.add(iss.slug);", "marked before act's refresh can carry the finish"
    assert_includes html, "issueStartFinished(r);\n}", "jobFinished hands every finish over"
    assert_includes html, "if (r.ok) setTimeout(() => openItemChat(r.slug || r.key), 0);"
    assert_match(/if \(!issueStarting\.has\(r\.slug\)\) \{[^}]*if \(openModal === shown\) closeModal\(\);/, html,
                 "a job finished within act's own refresh still closes the confirmation")
    assert_includes html, "line.querySelector(\".is-label\").textContent = job ? job.label", "progress from the job's label"
    assert_includes html, "openModal.onClose = () => clearInterval(timer);"
  end

  def test_created_drafts_offer_start_work_or_link_the_item_they_became
    html = page
    assert_includes html, "else if (i.number) acts.appendChild(draftStartControl(d.slug, i, d.repo));", "the Issues pane"
    assert_includes html, 'row.appendChild(draftStartControl(r.group.slug, r.issue, r.group.repo, "il-start"));', "the Issues tab"
    assert_includes html, 'if (e.target.closest("a, button")) return;', "the row's own click leaves its controls alone"
    assert_includes html, "/^#(\\d+) started as (\\S+)$/", "IssueStart's note on the drafting item names the item"
    assert_includes html, "it.slug !== fromSlug", "the drafting item never counts as what the issue became"
  end

  def test_project_hash_number_narrows_the_board_search_to_that_project
    html = page
    assert_includes html, 'if (ref) return { neg, field: "#", value: ref[2], project: ref[1] };'
    assert_includes html, "if (term.project && idx.project !== term.project) return null;"
  end
end

# qm start-issue: the preview, then the GUI's issue-start over a real
# loopback socket (no Origin), or the item and worktree made here.
class CliStartIssueTest < Minitest::Test
  include QmTestHelpers
  include IssueStartHelpers

  def setup
    super
    @port = ENV["QM_GUI_PORT"]
  end

  def teardown
    @port ? ENV["QM_GUI_PORT"] = @port : ENV.delete("QM_GUI_PORT")
  end

  def qm(runner, *argv)
    exited = nil
    out, err = capture_io do
      Quartermaster::CLI.new(runner: runner, cwd: Dir.home).run(argv)
    rescue SystemExit => e
      exited = e.status
    end
    [out, err, exited]
  end

  def without_gui
    free = TCPServer.new("127.0.0.1", 0)
    ENV["QM_GUI_PORT"] = free.addr[1].to_s
    free.close
  end

  def test_without_a_gui_it_makes_the_item_and_worktree_and_says_how_to_chat
    with_widget_repo do |repo|
      without_gui
      out, err, exited = qm(issue_runner(state: "CLOSED"), "start-issue", "#123", "--project", "Widget")

      assert_nil exited, err
      path = File.join(repo, ".claude", "worktrees", "issue-123-export-breaks-on-empty-rows")
      assert_includes out, "#123 Export breaks on empty rows (closed) — #{ISSUE_URL}\n  ⚠ the issue is closed\n"
      assert_includes out, "project Widget, branch issue/123-export-breaks-on-empty-rows\n"
      assert_includes out, "export-breaks-on-empty-rows-123: created"
      assert_includes out, "QM_ITEM=export-breaks-on-empty-rows-123 claude Read\\ issue\\ \\#123"
      assert File.directory?(path)

      again, = qm(issue_runner, "start-issue", "123", "--project", "Widget")
      assert_includes again, "already tracked: export-breaks-on-empty-rows-123 (in_progress)"
      assert_includes again, "export-breaks-on-empty-rows-123 already holds #123"
    end
  end

  def test_with_a_gui_the_gui_starts_it
    with_widget_repo do
      tmux = FakeTmux.new
      listener = TCPServer.new("127.0.0.1", 0)
      ENV["QM_GUI_PORT"] = listener.addr[1].to_s
      server = Quartermaster::Gui.new(port: listener.addr[1], runner: issue_runner, tmux: tmux)
      acceptor = Thread.new do
        loop { server.send(:handle_client, listener.accept) }
      rescue IOError, SystemCallError
        nil
      end

      out, err, exited = qm(issue_runner, "start-issue", "123", "--project", "Widget")
      assert_nil exited, err
      assert_includes out, "export-breaks-on-empty-rows-123: starting in the qm gui"
      Timeout.timeout(10) { sleep 0.05 until server.jobs.running.empty? }
      assert_equal true, server.jobs.take_finished.last["ok"]
      assert_equal ["export-breaks-on-empty-rows-123"], tmux.opened.map { |o| o[:name] }
    ensure
      listener&.close
      acceptor&.join(1)
    end
  end
end
