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

  NOTION_URL = "https://app.notion.com/p/Export-epic-3e6b2d0ad7f681a2"
  NOTES_BOT = { "author" => { "login" => "notes-bot" }, "body" => "Epic created in Notion: #{NOTION_URL}" }.freeze
  SUB_ISSUES = [{ "number" => 124, "title" => "Empty rows", "state" => "OPEN", "url" => "#{ISSUE_URL.chomp("123")}124" },
                { "number" => 125, "title" => "Frozen header", "state" => "CLOSED",
                  "url" => "#{ISSUE_URL.chomp("123")}125" }].freeze

  # Widget's issue settings for epics: which GitHub issue types are epics,
  # the tracker link's template, whose comment carries the Notion link.
  EPIC_SETTINGS = { "issue_types" => %w[Project Epic], "tracker_url" => "https://tracker.example/ws/{repo}/{number}",
                    "notion_author" => "notes-bot", "notion_label" => "Notion page" }.freeze

  # gh api graphql's answer, shaped like GitHub's (issueType null when unset).
  def issue_runner(state: "OPEN", title: "Export breaks on empty rows", known: true, type: nil, sub_issues: [], comments: [])
    issue = { "number" => 123, "title" => title, "state" => state, "url" => ISSUE_URL,
              "issueType" => type && { "name" => type }, "subIssues" => { "nodes" => sub_issues },
              "comments" => { "nodes" => comments } }
    view = if known
             [JSON.generate("data" => { "repository" => { "issue" => issue } }), "", true]
           else
             ["", "GraphQL: Could not resolve to an issue with the number of 123. (repository.issue)", false]
           end
    IssueRunner.new(%w[gh api graphql] => view, %w[gh repo view] => ["main\n", "", true],
                    ["curl"] => ["", "", false], %w[pf status] => ["", "", false])
  end

  def epic_runner(**rest) = issue_runner(type: "Project", sub_issues: SUB_ISSUES,
                                         comments: [{ "author" => { "login" => "someone" }, "body" => "https://notion.so/not-this" },
                                                    NOTES_BOT], **rest)

  # A repo whose origin is acme/widget on GitHub, configured as project
  # "Widget" (and "WebApp", configured with a test-DB command). epics:
  # Widget's epic settings.
  def with_widget_repo(epics: nil)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      system("git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/widget.git")
      system("git", "-C", repo, "update-ref", "refs/remotes/origin/main", "HEAD")
      Quartermaster.ensure_setup
      widget = epics ? { "root" => repo, "epics" => epics } : repo
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Widget" => widget, "WebApp" => featured_project(repo) } }.to_yaml)
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
                     "existing" => nil, "epic" => false, "links" => [], "sub_issues" => [] }, preview)
      assert_equal 1, runner.calls.size, "a preview only reads, in one call"
      call = runner.calls.first
      assert_equal repo, call[:chdir]
      assert_equal %w[gh api graphql], call[:argv].first(3)
      assert_equal [%w[-f owner=acme], %w[-f name=widget], %w[-F number=123]],
                   call[:argv].drop(3).each_slice(2).select { |flag, value| %w[-f -F].include?(flag) && !value.start_with?("query=") }
      assert_match(/issue\(number: \$number\).*issueType \{ name \}.*subIssues\(first: \d+\).*comments\(first: \d+\)/m,
                   call[:argv].last)
    end
  end

  def test_an_issue_whose_type_the_project_lists_is_an_epic_with_its_links
    with_widget_repo(epics: EPIC_SETTINGS) do
      preview = starter(epic_runner).preview(123, "Widget")

      assert_equal true, preview["epic"]
      assert_equal [{ "label" => "Tracker", "url" => "https://tracker.example/ws/acme/widget/123" },
                    { "label" => "Notion page", "url" => NOTION_URL }], preview["links"]
      assert_equal SUB_ISSUES, preview["sub_issues"]
      assert_equal "issue/123-export-breaks-on-empty-rows", preview["branch"], "still startable as a normal item"
    end
  end

  def test_no_listed_type_or_no_settings_is_never_an_epic_and_missing_links_are_skipped
    with_widget_repo(epics: EPIC_SETTINGS.merge("issue_types" => ["Epic"])) do
      assert_equal false, starter(epic_runner).preview(123, "Widget")["epic"]
      assert_equal false, starter(epic_runner(type: nil)).preview(123, "Widget")["epic"]
    end
    with_widget_repo do
      preview = starter(epic_runner).preview(123, "Widget")
      assert_equal [false, []], preview.values_at("epic", "links"), "no settings: no epic, no links"
    end
    with_widget_repo(epics: { "issue_types" => ["project"], "notion_author" => "notes-bot" }) do
      preview = starter(epic_runner(comments: [])).preview(123, "Widget")
      assert_equal [true, []], preview.values_at("epic", "links"), "type names match case-insensitively; no comment, no template"
      notion = starter(epic_runner).preview(123, "Widget")["links"]
      assert_equal [{ "label" => "Notion", "url" => NOTION_URL }], notion, "the Notion label defaults to Notion"
    end
  end

  def test_start_as_epic_makes_an_epic_item_with_its_links_and_no_branch_worktree_or_fetch
    with_widget_repo(epics: EPIC_SETTINGS) do |repo|
      Quartermaster::WorkItem.create("Drafting", project: "Widget")
      runner = epic_runner
      start = starter(runner)

      started = start.start(start.preview(123, "Widget"), from: "drafting")

      item = started[:item]
      assert_nil started[:target]
      assert_equal ["gh"], runner.argvs.map(&:first), "only the preview's read"
      refute File.exist?(File.join(repo, ".claude", "worktrees"))
      assert_equal ["Export breaks on empty rows (#123)", "export-breaks-on-empty-rows-123", "Widget", "in_progress"],
                   [item.title, item.slug, item.project, item.state]
      assert item.epic?
      assert_empty item.branches
      assert_equal "#{ISSUE_URL}\n\nExport breaks on empty rows", item.description
      assert_equal [{ "label" => "Tracker", "url" => "https://tracker.example/ws/acme/widget/123" },
                    { "label" => "Notion page", "url" => NOTION_URL }], item.links
      assert_equal "#123 started as export-breaks-on-empty-rows-123",
                   Quartermaster::WorkItem.find("drafting").notes.first.text
      assert_equal({ "slug" => item.slug, "title" => item.title, "state" => "in_progress", "epic" => true },
                   start.preview(123, "Widget")["existing"], "found again by its URL")
    end
  end

  def test_an_epic_issue_can_still_start_as_a_normal_item
    with_widget_repo(epics: EPIC_SETTINGS) do |repo|
      start = starter(epic_runner)
      item = start.start(start.preview(123, "Widget"), as_epic: false)[:item]
      refute item.epic?
      assert_equal ["issue/123-export-breaks-on-empty-rows"], item.branches
      assert File.directory?(File.join(repo, ".claude", "worktrees", "issue-123-export-breaks-on-empty-rows"))
    end
  end

  def test_an_epic_without_links_carries_none
    with_widget_repo(epics: { "issue_types" => ["Project"] }) do
      start = starter(epic_runner)
      item = start.start(start.preview(123, "Widget"))[:item]
      assert item.epic?
      refute item.front.key?("links")
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
      assert_equal({ "slug" => "old-work", "title" => "Old work", "state" => "in_progress", "epic" => false },
                   preview["existing"])
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

  def test_an_epic_issue_starts_as_an_epic_at_once_and_opens_no_chat_then_or_later
    with_widget_repo(epics: EPIC_SETTINGS) do
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: epic_runner, tmux: tmux)

      reply = post(server, "cmd" => "issue-start", "args" => { "number" => 123, "project" => "Widget" })

      assert_equal [true, true, "export-breaks-on-empty-rows-123"], reply.values_at("ok", "epic", "slug")
      assert_equal "#123 started as epic export-breaks-on-empty-rows-123", reply["message"]
      assert_nil reply["background"]
      assert_empty server.jobs.running
      assert Quartermaster::WorkItem.find("export-breaks-on-empty-rows-123").epic?

      again = post(server, "cmd" => "issue-start", "args" => { "number" => 123, "project" => "Widget" })
      assert_equal [true, true, true, "export-breaks-on-empty-rows-123"], again.values_at("ok", "existing", "epic", "slug")
      assert_empty tmux.opened, "an epic never gets a chat from an issue start"
    end
  end

  def test_as_epic_false_starts_an_epic_issue_as_a_normal_item_with_its_chat
    with_widget_repo(epics: EPIC_SETTINGS) do
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: epic_runner, tmux: tmux)

      reply = post(server, "cmd" => "issue-start", "args" => { "number" => 123, "project" => "Widget", "as_epic" => false })

      assert_equal [true, true], reply.values_at("ok", "background")
      assert_equal true, finished_job(server)["ok"]
      assert_equal ["export-breaks-on-empty-rows-123"], tmux.opened.map { |o| o[:name] }
      refute Quartermaster::WorkItem.find("export-breaks-on-empty-rows-123").epic?
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
    ['cmd: "issue-preview"', "function issueStartModal(number, project, { from = null, epic = null } = {})",
     "renderIssueStartPreview(box, { ...res.issue, into: epic }, from)", "if (openModal !== shown) return;"].each { |seam| assert_includes html, seam }
    assert_includes html, "m.append(kindRow, tf, pf, epicField, df, issueFromNewItemRow());", "＋ New item: the From issue row"
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
     'fact("Branch"', 'fact("Project", esc(iss.project));', 'iss.existing ? (iss.existing.epic ? "Open the epic" : "Open its chat")',
     'act("issue-start"'].each { |seam| assert_includes html, seam }
  end

  def test_start_follows_the_job_into_the_new_items_chat_or_opens_the_held_one
    html = page
    assert_includes html, 'act("issue-start", { args: { number: iss.number, project: iss.project, from, as_epic: asEpic, epic: iss.into } })'
    assert_includes html, 'toast(`#${iss.number} is already ${r.slug}: opened its chat`);', "A4 says so"
    assert_includes html, "if (!iss.existing && !asEpic) issueStarting.add(iss.slug);", "marked before act's refresh can carry the finish"
    assert_includes html, "issueStartFinished(r);\n}", "jobFinished hands every finish over"
    assert_includes html, "if (r.ok) setTimeout(() => openItemChat(r.slug || r.key), 0);"
    assert_match(/if \(!issueStarting\.has\(r\.slug\)\) \{[^}]*if \(openModal === shown\) closeModal\(\);/, html,
                 "a job finished within act's own refresh still closes the confirmation")
    assert_includes html, "line.querySelector(\".is-label\").textContent = job ? job.label", "progress from the job's label"
    assert_includes html, "openModal.onClose = () => clearInterval(timer);"
  end

  def test_an_epic_issue_previews_with_the_badge_and_an_on_switch_and_starting_it_opens_the_epic
    html = page
    assert_includes html, 'if (iss.epic) m.querySelector(".sub").prepend(el("span", "epic-kind is-epic-badge", "◆ Epic"));'
    assert_includes html, "const asEpicSwitch = iss.epic && !iss.existing ? issueEpicSwitch() : null;",
                    "every entry point: the switch lives in the one preview they all end in"
    assert_includes html, '<input type="checkbox" role="switch" checked>', "on by default"
    assert_includes html, "startIssue(m, iss, from, asEpic())", "Start sends the switch"
    assert_includes html, 'dd.appendChild(linkChips({ links: iss.links || [] }));', "the would-be links, as epics.js draws them"
    assert_match(/if \(r\.epic\) \{\n\s*if \(openModal === shown\) closeModal\(\);\n.*\n\s*openItemChat\(r\.slug\);/, html,
                 "an epic opens at once, no job")
    assert_includes html, "if (isEpic(it)) { chatSlug = it.slug; setMode(\"chat\"); selectChat(it.slug); } else openChat(it);",
                    "an epic opens on its Epic block, the terminal unfocused"
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

  def test_an_epic_issue_starts_as_an_epic_here
    with_widget_repo(epics: EPIC_SETTINGS) do |repo|
      without_gui
      out, err, exited = qm(epic_runner, "start-issue", "123", "--project", "Widget")

      assert_nil exited, err
      assert_includes out, "  ◆ an epic: starts as an epic item (--as-item: a normal item with branch and chat)\n"
      assert_includes out, "  links: Tracker https://tracker.example/ws/acme/widget/123, Notion page #{NOTION_URL}\n"
      assert_includes out, "export-breaks-on-empty-rows-123: created as an epic (no branch, worktree or chat)"
      refute_includes out, "QM_ITEM="
      refute File.exist?(File.join(repo, ".claude", "worktrees"))

      again, = qm(epic_runner, "start-issue", "123", "--project", "Widget")
      assert_includes again, "export-breaks-on-empty-rows-123: the epic already holding #123"
      refute_includes again, "◆ an epic", "an epic already made is not offered again"
      refute_includes again, "qm resume", "an epic has no chat to continue"
    end
  end

  def test_as_item_starts_an_epic_issue_as_a_normal_item
    with_widget_repo(epics: EPIC_SETTINGS) do |repo|
      without_gui
      out, err, exited = qm(epic_runner, "start-issue", "123", "--project", "Widget", "--as-item")

      assert_nil exited, err
      assert_includes out, "QM_ITEM=export-breaks-on-empty-rows-123 claude"
      assert File.directory?(File.join(repo, ".claude", "worktrees", "issue-123-export-breaks-on-empty-rows"))
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

# ↻ links on an epic started from (or describing) a GitHub issue: the
# links IssueLinks derives are added when missing, never replacing or
# removing one the user set; from IssueStart, the GUI job and qm link --refresh.
class EpicLinksRefreshTest < Minitest::Test
  include QmTestHelpers
  include IssueStartHelpers

  MINE = { "label" => "Tracker", "url" => "https://mine.example/board/7" }.freeze

  def epic!(links: [MINE], description: "#{ISSUE_URL}\n\nExport", kind: "epic")
    front = { "kind" => kind, "links" => links }.reject { |_, v| v.nil? || v == [] }
    Quartermaster::WorkItem.create("Export", project: "Widget", description: description, front: front)
  end

  def test_refresh_adds_only_the_missing_links_and_keeps_the_users
    with_widget_repo(epics: EPIC_SETTINGS) do
      epic!(links: [MINE, { "label" => "Docs", "url" => "https://docs.example/x" }])
      runner = epic_runner
      added = starter(runner).refresh_links(Quartermaster::WorkItem.find("export"))

      assert_equal [{ "label" => "Notion page", "url" => NOTION_URL }], added
      assert_equal [MINE, { "label" => "Docs", "url" => "https://docs.example/x" },
                    { "label" => "Notion page", "url" => NOTION_URL }], Quartermaster::WorkItem.find("export").links
      argv = runner.argvs.first
      assert_equal %w[gh api graphql], argv.first(3)
      assert_includes argv, "owner=acme"
      assert_includes argv, "number=123"
      assert_empty starter(epic_runner).refresh_links(Quartermaster::WorkItem.find("export")), "nothing left to add"
    end
  end

  def test_a_link_already_carried_under_another_label_is_not_added_again
    with_widget_repo(epics: EPIC_SETTINGS) do
      epic!(links: [{ "label" => "Board", "url" => "https://tracker.example/ws/acme/widget/123" }])
      added = starter(epic_runner).refresh_links(Quartermaster::WorkItem.find("export"))
      assert_equal ["Notion page"], added.map { |link| link["label"] }
    end
  end

  def test_refresh_is_refused_for_a_plain_item_or_an_epic_without_an_issue_url
    with_widget_repo(epics: EPIC_SETTINGS) do
      epic!(kind: nil)
      error = assert_raises(ArgumentError) { starter(epic_runner).refresh_links(Quartermaster::WorkItem.find("export")) }
      assert_equal "'export' is not an epic", error.message
      Quartermaster::WorkItem.create("Loose", project: "Widget", description: "see https://github.com/acme/widget/pull/9",
                                              front: { "kind" => "epic" })
      error = assert_raises(ArgumentError) { starter(epic_runner).refresh_links(Quartermaster::WorkItem.find("loose")) }
      assert_equal "'loose' has no GitHub issue URL in its description", error.message
    end
  end

  def host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def test_the_gui_refreshes_on_a_job_keyed_by_the_epic
    with_widget_repo(epics: EPIC_SETTINGS) do
      epic!
      server = Quartermaster::Gui.new(port: 4567, runner: epic_runner, tmux: FakeTmux.new)
      reply = JSON.parse(server.respond("POST", "/api/action", host,
                                        JSON.generate("cmd" => "epic-links-refresh", "slug" => "export"))[2])
      assert_equal [true, true], reply.values_at("ok", "background")
      Timeout.timeout(10) { sleep 0.05 until server.jobs.running.empty? }
      job = server.jobs.take_finished.last

      assert_equal [true, "export", "export: added Notion page"], job.values_at("ok", "key", "message")
      assert_equal [MINE, { "label" => "Notion page", "url" => NOTION_URL }], Quartermaster::WorkItem.find("export").links
    end
  end

  def test_qm_link_refresh_says_what_it_added
    with_widget_repo(epics: EPIC_SETTINGS) do
      epic!
      out, = capture_io { Quartermaster::CLI.new(runner: epic_runner, cwd: Dir.home).run(%w[link export --refresh]) }
      assert_equal "export: added Notion page → Tracker, Notion page\n", out
      again, = capture_io { Quartermaster::CLI.new(runner: epic_runner, cwd: Dir.home).run(%w[link export --refresh]) }
      assert_equal "export: no links to add → Tracker, Notion page\n", again
    end
  end

  def test_the_link_chips_carry_the_refresh_button_for_an_epic_with_an_issue
    html = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
    assert_includes html, 'if (isEpic(it) && GITHUB_ISSUE_URL.test(it.description || "")) box.appendChild(linksRefreshButton(it));'
    assert_includes html, 'act("epic-links-refresh", { slug: it.slug })'
  end
end
