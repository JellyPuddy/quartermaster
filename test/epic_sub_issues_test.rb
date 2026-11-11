# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/epic_sub_issues_test.rb`).
require_relative "issue_start_helpers"

# An epic issue's GitHub sub-issues: the items already holding them join the
# epic it starts as, and the epic's view lists the rest to start inside it.
module EpicSubIssueHelpers
  WIDGET = "https://github.com/acme/widget/issues/"
  SUBS = [{ "number" => 124, "title" => "Empty rows", "state" => "OPEN", "url" => "#{WIDGET}124" },
          { "number" => 125, "title" => "Frozen header", "state" => "CLOSED", "url" => "#{WIDGET}125" },
          { "number" => 126, "title" => "Old epic", "state" => "OPEN", "url" => "#{WIDGET}126" },
          { "number" => 127, "title" => "Nightly export", "state" => "OPEN", "url" => "#{WIDGET}127" },
          { "number" => 9, "title" => "Elsewhere", "state" => "OPEN", "url" => "https://github.com/acme/api/issues/9" }].freeze

  # gh api graphql answering per issue number: #123 the epic with SUBS, any
  # other number a plain issue titled "Sub <n>".
  def sub_issue_runner
    reply = lambda do |argv|
      number = argv.find { |arg| arg.start_with?("number=") }.delete_prefix("number=").to_i
      issue = if number == 123
                { "number" => 123, "title" => "Export breaks on empty rows", "state" => "OPEN", "url" => "#{WIDGET}123",
                  "issueType" => { "name" => "Project" }, "subIssues" => { "nodes" => SUBS }, "comments" => { "nodes" => [] } }
              else
                { "number" => number, "title" => "Sub #{number}", "state" => "OPEN", "url" => "#{WIDGET}#{number}",
                  "issueType" => nil, "subIssues" => { "nodes" => [] }, "comments" => { "nodes" => [] } }
              end
      [JSON.generate("data" => { "repository" => { "issue" => issue } }), "", true]
    end
    IssueRunner.new(%w[gh api graphql] => reply, %w[gh repo view] => ["main\n", "", true],
                    ["curl"] => ["", "", false], %w[pf status] => ["", "", false])
  end

  # Items already holding sub-issues: #124 by branch (joins), #125 by URL
  # but in another epic, #126 is an epic itself, #127 an automation.
  def holders
    Quartermaster::WorkItem.create("Other epic", project: "Widget", front: { "kind" => "epic" })
    Quartermaster::WorkItem.create("Empty rows work", project: "Widget", branch: "issue/124-empty-rows")
    Quartermaster::WorkItem.create("Header work", project: "Widget", description: "#{WIDGET}125",
                                                  front: { "epic" => "other-epic" })
    Quartermaster::WorkItem.create("Old epic work", project: "Widget", description: "#{WIDGET}126", front: { "kind" => "epic" })
    Quartermaster::WorkItem.create("Nightly", project: "Widget", description: "#{WIDGET}127", front: { "kind" => "automation" })
  end

  SKIPPED = [{ "slug" => "header-work", "reason" => "already in epic other-epic" },
             { "slug" => "old-epic-work", "reason" => "an epic" },
             { "slug" => "nightly", "reason" => "an automation" }].freeze
end

class EpicSubIssuesTest < Minitest::Test
  include QmTestHelpers
  include IssueStartHelpers
  include EpicSubIssueHelpers

  def test_start_as_epic_attaches_the_items_holding_its_sub_issues_and_says_what_it_left
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do
      holders
      start = starter(sub_issue_runner)

      started = start.start(start.preview(123, "Widget"))

      epic = started[:item].slug
      assert_equal ["empty-rows-work"], started[:attached]
      assert_equal SKIPPED, started[:skipped]
      assert_equal epic, Quartermaster::WorkItem.find("empty-rows-work").epic
      assert_equal "other-epic", Quartermaster::WorkItem.find("header-work").epic
      assert_nil Quartermaster::WorkItem.find("old-epic-work").epic
      assert_nil Quartermaster::WorkItem.find("nightly").epic
    end
  end

  def test_the_sub_issues_of_an_epic_name_their_items_and_which_can_start_here
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do
      holders
      start = starter(sub_issue_runner)
      epic = start.start(start.preview(123, "Widget"))[:item].slug

      subs = start.sub_issues(epic)

      assert_equal [[124, "empty-rows-work", false, true], [125, "header-work", true, true],
                    [126, "old-epic-work", false, true], [127, "nightly", false, true], [9, nil, false, false]],
                   subs.map { |s| s.values_at("number", "item", "closed", "startable") }
      assert_equal({ "number" => 124, "title" => "Empty rows", "state" => "open", "url" => "#{WIDGET}124" },
                   subs.first.slice("number", "title", "state", "url"))
    end
  end

  def test_an_epic_titled_for_an_issue_lists_its_sub_issues
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do
      Quartermaster::WorkItem.create("Export epic (#123)", project: "Widget", description: "Tracks #123",
                                                           front: { "kind" => "epic" })

      subs = starter(sub_issue_runner).sub_issues("export-epic-123")

      assert_equal [124, 125, 126, 127, 9], subs.map { |s| s["number"] }
    end
  end

  def test_an_item_or_an_epic_without_an_issue_has_no_sub_issues_to_list
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do
      runner = sub_issue_runner
      Quartermaster::WorkItem.create("Plain epic", project: "Widget", front: { "kind" => "epic" })
      Quartermaster::WorkItem.create("Plain", project: "Widget", description: "#{WIDGET}123")

      assert_equal [], starter(runner).sub_issues("plain-epic")
      error = assert_raises(ArgumentError) { starter(runner).sub_issues("plain") }
      assert_equal "'plain' is not an epic (kind: epic)", error.message
      assert_empty runner.calls, "nothing read from GitHub"
    end
  end

  def test_a_sub_issue_starts_as_a_normal_item_inside_the_epic
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do |repo|
      start = starter(sub_issue_runner)
      epic = start.start(start.preview(123, "Widget"))[:item].slug

      started = start.start(start.preview(124, "Widget"), epic: epic)

      item = started[:item]
      assert_equal [epic, false, ["issue/124-sub-124"]], [item.epic, item.epic?, item.branches]
      assert File.directory?(File.join(repo, ".claude", "worktrees", "issue-124-sub-124"))
    end
  end

  def test_starting_inside_something_not_an_epic_is_refused_before_any_worktree
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do |repo|
      Quartermaster::WorkItem.create("Plain", project: "Widget")
      runner = sub_issue_runner
      start = starter(runner)
      preview = start.preview(124, "Widget")

      error = assert_raises(ArgumentError) { start.start(preview, epic: "plain") }
      assert_equal "'plain' is not an epic (kind: epic)", error.message
      error = assert_raises(ArgumentError) { start.start(start.preview(123, "Widget"), epic: "plain", as_epic: true) }
      assert_equal "an epic can't be inside another epic (one level only)", error.message
      assert_equal ["gh", "gh"], runner.argvs.map(&:first), "only the previews' reads"
      refute File.exist?(File.join(repo, ".claude", "worktrees"))
      assert_equal ["plain"], Quartermaster::WorkItem.all.map(&:slug)
    end
  end

  def test_an_epic_issue_started_inside_an_epic_starts_as_a_normal_item
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do
      Quartermaster::WorkItem.create("Big epic", project: "Widget", front: { "kind" => "epic" })
      start = starter(sub_issue_runner)

      item = start.start(start.preview(123, "Widget"), epic: "big-epic")[:item]

      assert_equal ["big-epic", false], [item.epic, item.epic?]
    end
  end
end

# The GUI's side: sub-issues read off the action mutex, a Start inside the
# epic, and the epic start's reply naming what joined.
class GuiEpicSubIssuesTest < Minitest::Test
  include QmTestHelpers
  include IssueStartHelpers
  include EpicSubIssueHelpers

  def host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def post(server, payload) = JSON.parse(server.respond("POST", "/api/action", host, JSON.generate(payload))[2])

  def test_the_epic_start_reply_names_the_items_that_joined_and_those_left_out
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do
      holders
      server = Quartermaster::Gui.new(port: 4567, runner: sub_issue_runner, tmux: FakeTmux.new)

      reply = post(server, "cmd" => "issue-start", "args" => { "number" => 123, "project" => "Widget" })

      assert_equal [["empty-rows-work"], SKIPPED], reply.values_at("attached", "skipped")
      assert_equal "#123 started as epic export-breaks-on-empty-rows-123 · joined: empty-rows-work · " \
                   "left out: header-work (already in epic other-epic), old-epic-work (an epic), nightly (an automation)",
                   reply["message"]
    end
  end

  def test_sub_issues_are_read_off_the_action_mutex
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do
      server = Quartermaster::Gui.new(port: 4567, runner: sub_issue_runner, tmux: FakeTmux.new)
      post(server, "cmd" => "issue-start", "args" => { "number" => 123, "project" => "Widget" })

      reply = server.instance_variable_get(:@mutex).synchronize do
        post(server, "cmd" => "epic-sub-issues", "args" => { "epic" => "export-breaks-on-empty-rows-123" })
      end

      assert_equal true, reply["ok"], reply["error"]
      assert_equal [124, 125, 126, 127, 9], reply["sub_issues"].map { |s| s["number"] }
    end
  end

  def test_a_sub_issue_started_with_an_epic_is_made_inside_it_with_its_chat
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: sub_issue_runner, tmux: tmux)
      epic = post(server, "cmd" => "issue-start", "args" => { "number" => 123, "project" => "Widget" })["slug"]

      refused = post(server, "cmd" => "issue-start", "args" => { "number" => 124, "project" => "Widget", "epic" => "nope" })
      assert_equal false, refused["ok"]
      assert_empty server.jobs.running

      reply = post(server, "cmd" => "issue-start", "args" => { "number" => 124, "project" => "Widget", "epic" => epic })
      assert_equal [true, true, "sub-124-124"], reply.values_at("ok", "background", "slug")
      Timeout.timeout(10) { sleep 0.05 until server.jobs.running.empty? }
      assert_equal true, server.jobs.take_finished.last["ok"]
      assert_equal epic, Quartermaster::WorkItem.find("sub-124-124").epic
      assert_equal ["sub-124-124"], tmux.opened.map { |o| o[:name] }
    end
  end

  def page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)

  def test_the_epic_block_lists_sub_issues_without_an_item_with_a_start_inside_the_epic
    html = page
    assert_includes html, 'body: JSON.stringify({ cmd: "epic-sub-issues", slug: null, args: { epic: slug } }),'
    assert_includes html, "issueStartModal(s.number, epic.project, { epic: epic.slug })"
    assert_includes html, "act(\"issue-start\", { args: { number: iss.number, project: iss.project, from, ...(iss.into ? { epic: iss.into } : { as_epic: asEpic }) } })",
                    "inside an epic: epic, never as_epic"
    assert_includes html, "const epicIssue = iss.epic && !iss.into;", "inside an epic: no ◆ Epic badge, no Start as epic switch"
  end
end

# qm start-issue --epic, and an epic start naming what joined.
class CliEpicSubIssuesTest < Minitest::Test
  include QmTestHelpers
  include IssueStartHelpers
  include EpicSubIssueHelpers

  def qm(runner, *argv)
    exited = nil
    out, err = capture_io do
      Quartermaster::CLI.new(runner: runner, cwd: Dir.home).run(argv)
    rescue SystemExit => e
      exited = e.status
    end
    [out, err, exited]
  end

  def setup
    super
    @port = ENV["QM_GUI_PORT"]
    free = TCPServer.new("127.0.0.1", 0)
    ENV["QM_GUI_PORT"] = free.addr[1].to_s
    free.close
  end

  def teardown
    @port ? ENV["QM_GUI_PORT"] = @port : ENV.delete("QM_GUI_PORT")
  end

  def test_an_epic_start_names_what_joined_and_epic_starts_a_sub_issue_inside_it
    with_widget_repo(epics: EPIC_SETTINGS, links: LINK_SETTINGS) do
      holders
      out, err, exited = qm(sub_issue_runner, "start-issue", "123", "--project", "Widget")
      assert_nil exited, err
      assert_includes out, "  joined: empty-rows-work\n"
      assert_includes out, "  left out: header-work (already in epic other-epic), old-epic-work (an epic), nightly (an automation)\n"

      out, err, exited = qm(sub_issue_runner, "start-issue", "128", "--project", "Widget",
                            "--epic", "export-breaks-on-empty-rows-123")
      assert_nil exited, err
      assert_includes out, "  inside epic export-breaks-on-empty-rows-123\n"
      assert_equal "export-breaks-on-empty-rows-123", Quartermaster::WorkItem.find("sub-128-128").epic
    end
  end
end
