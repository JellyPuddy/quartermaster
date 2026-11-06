# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/gui_test.rb`).
require_relative "test_helper"

class GuiTest < Minitest::Test
  include QmTestHelpers

  def gui
    Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
  end

  def ok_host
    { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  end

  def test_rejects_requests_from_a_foreign_host
    status, = gui.respond("GET", "/", { "host" => "evil.example.com" }, "")
    assert_equal "403 Forbidden", status

    status, = gui.respond("GET", "/", {}, "")
    assert_equal "403 Forbidden", status
  end

  def test_rejects_actions_posted_from_another_origin
    body = JSON.generate("cmd" => "nope")
    status, = gui.respond("POST", "/api/action", ok_host.merge("origin" => "https://evil.example.com"), body)
    assert_equal "403 Forbidden", status

    status, = gui.respond("POST", "/api/action", ok_host.merge("origin" => "http://127.0.0.1:4567"), body)
    assert_equal "200 OK", status
  end

  def test_takes_only_the_local_tools_actions_without_an_origin
    no_origin = { "host" => "127.0.0.1:4567" }
    %w[set-state cleanup distill].each do |cmd|
      status, = gui.respond("POST", "/api/action", no_origin, JSON.generate("cmd" => cmd, "slug" => "x"))
      assert_equal "403 Forbidden", status, cmd
    end
    ["/api/drop", "/api/ask", "/api/grep"].each do |route|
      status, = gui.respond("POST", route, no_origin, JSON.generate("query" => "q"))
      assert_equal "403 Forbidden", status, route
    end
    %w[caffeinate pane-start pane-resume rotate issue-start page-annotations].each do |cmd|
      status, = gui.respond("POST", "/api/action", no_origin, JSON.generate("cmd" => cmd, "args" => { "mode" => "status" }))
      assert_equal "200 OK", status, cmd
    end
  end

  # The page renders the model's taxonomies from a serve-time JSON bootstrap;
  # this is where a new state/kind/tier without labels or copy fails loudly.
  def test_page_bootstraps_the_model_taxonomies
    _status, _ct, body = gui.respond("GET", "/", ok_host, "")

    refute_includes body, "__TAXONOMIES__"
    json = JSON.parse(body[/const TAXONOMIES = (.*);/, 1])
    assert_equal Quartermaster::STATES, json["states"].map { |s| s["key"] }
    assert(json["states"].all? { |s| s["label"] && !s["label"].empty? })
    assert_equal Quartermaster::NOTE_KINDS, json["noteKinds"].map { |k| k["key"] }
    assert(json["noteKinds"].all? { |k| k["hint"] && !k["hint"].empty? })
    assert_equal Quartermaster::DEFAULT_NOTE_KIND, json["defaultNoteKind"]
    %w[expired uncaptured].each { |tier| assert json["tierFallbacks"][tier] }
  end

  def test_serves_the_page_at_root
    status, content_type, body = gui.respond("GET", "/", ok_host, "")
    assert_equal "200 OK", status
    assert_includes content_type, "text/html"
    assert_includes body, "qm — work items"
    assert_includes served_page(gui, ok_host), "/api/state"
  end

  def test_serves_the_page_assets_in_load_order_with_their_content_types
    body = gui.respond("GET", "/", ok_host, "")[2]
    styles = body.scan(%r{href="/assets/(css/[\w-]+\.css)"}).flatten
    scripts = body.scan(%r{src="/assets/(js/[\w-]+\.js)"}).flatten
    assert_equal "css/base.css", styles.first, "the tokens come before every rule that reads them"
    assert_equal "js/events.js", scripts.last, "the boot code runs once everything it calls is defined"
    assert_equal Dir.children(File.join(Quartermaster::Gui::ASSET_DIR, "css")).sort, styles.map { |s| File.basename(s) }.sort
    assert_equal Dir.children(File.join(Quartermaster::Gui::ASSET_DIR, "js")).sort, scripts.map { |s| File.basename(s) }.sort
    refute_match(/type="module"/, body, "classic scripts share globals and inline handlers; modules would not")

    status, content_type, css = gui.respond("GET", "/assets/css/base.css", ok_host, "")
    assert_equal ["200 OK", "text/css; charset=utf-8"], [status, content_type]
    assert_includes css, "--accent"
    status, content_type, js = gui.respond("GET", "/assets/js/events.js?v=1", ok_host, "")
    assert_equal ["200 OK", "text/javascript; charset=utf-8"], [status, content_type]
    assert js.start_with?(%("use strict";))
  end

  def test_assets_are_only_the_gui_stylesheets_and_scripts
    ["/assets/js/../../gui.rb", "/assets/../gui.rb", "/assets/%2e%2e/gui.rb", "/assets/page.html",
     "/assets/js/nope.js", "/assets/css/base.js", "/assets/js/core.css", "/assets//etc/passwd",
     "/assets/js/CORE.js", "/assets/js/core.js/"].each do |path|
      assert_equal "404 Not Found", gui.respond("GET", path, ok_host, "")[0], path
    end
    assert_equal "403 Forbidden", gui.respond("GET", "/assets/js/core.js", { "host" => "evil.example.com" }, "")[0]
  end

  def test_unknown_route_is_404
    status, = gui.respond("GET", "/nope", ok_host, "")
    assert_equal "404 Not Found", status
  end

  def test_state_endpoint_returns_items_inbox_and_projects
    Quartermaster::WorkItem.create("Alpha", project: "WebApp", description: "desc a")
    status, content_type, body = gui.respond("GET", "/api/state", ok_host, "")

    assert_equal "200 OK", status
    assert_includes content_type, "application/json"
    state = JSON.parse(body)
    assert_equal %w[items inbox projects defaultProject looseStarters attention loose pulse refreshing distilling distilled pf jobs buildActive buildProgress finished panes terminalToken asideModels caffeinate notifications rateLimits errors benchmark].sort, state.keys.sort
    alpha = state["items"].find { |i| i["slug"] == "alpha" }
    assert_equal "desc a", alpha["description"]
    assert_includes state["projects"], "No project"
  end

  def test_state_maps_an_items_branch_to_its_worktree
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      worktree = File.join(dir, "repo-wt")
      FileUtils.mkdir_p(repo)
      system("git", "-C", repo, "init", "-q")
      system("git", "-C", repo, "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "init")
      system("git", "-C", repo, "worktree", "add", "-q", "-b", "issue/9-x", worktree)
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Repo" => repo } }.to_yaml)

      item = Quartermaster::WorkItem.create("Delta", project: "Repo", branch: "issue/9-x")
      item.link_branch("gone/branch")
      _status, _ct, body = gui.respond("GET", "/api/state", ok_host, "")

      delta = JSON.parse(body)["items"].find { |i| i["slug"] == "delta" }
      assert_equal ["issue/9-x"], delta["worktrees"].keys
      assert_equal File.realpath(worktree), File.realpath(delta["worktrees"]["issue/9-x"].sub("~", Dir.home))
    end
  end

  def test_state_carries_an_items_chains_with_their_worktrees
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      worktree = File.join(dir, "repo-wt")
      FileUtils.mkdir_p(repo)
      git_id = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
      system("git", "-C", repo, "init", "-q", "-b", "main")
      system("git", "-C", repo, *git_id, "commit", "-q", "--allow-empty", "-m", "init")
      system("git", "-C", repo, "branch", "s1")
      system("git", "-C", repo, "worktree", "add", "-q", "-b", "s2", worktree)
      system("git", "-C", worktree, *git_id, "commit", "-q", "--allow-empty", "-m", "s2 work")
      File.write(File.join(repo, ".git", "gh-stack"), JSON.generate(
        "stacks" => [{ "trunk" => { "branch" => "main" },
                       "branches" => [{ "branch" => "s1", "pullRequest" => { "number" => 7, "url" => "u7" } },
                                      { "branch" => "s2" }] }]
      ))
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Repo" => repo } }.to_yaml)
      item = Quartermaster::WorkItem.create("Chained", project: "Repo", branch: "s2")
      item.link_branch("solo")

      _status, _ct, body = gui.respond("GET", "/api/state", ok_host, "")

      chains = JSON.parse(body)["items"].find { |i| i["slug"] == "chained" }["chains"]
      assert_equal %w[stack loose], chains.map { |c| c["kind"] }
      s1, s2 = chains[0]["layers"]
      assert_equal ["s1", 7, "u7", "main", 0, false, nil], s1.values_at("branch", "pr_number", "pr_url", "parent", "ahead", "needsRestack", "worktree")
      assert_equal ["s2", "s1", 1, false], s2.values_at("branch", "parent", "ahead", "needsRestack")
      assert_equal File.realpath(worktree), File.realpath(s2["worktree"].sub("~", Dir.home))
      assert_equal "solo", chains[1]["layers"][0]["branch"]
    end
  end

  def test_action_dispatch_routes_a_note_into_the_work_item
    Quartermaster::WorkItem.create("Beta", project: "Nowhere")
    body = JSON.generate("cmd" => "note", "slug" => "beta", "args" => { "text" => "from the web" })
    status, _ct, out = gui.respond("POST", "/api/action", ok_host, body)

    assert_equal "200 OK", status
    assert_equal true, JSON.parse(out)["ok"]
    assert_equal "from the web", Quartermaster::WorkItem.find("beta").notes.first.text
  end

  def test_action_dispatch_routes_a_state_change
    Quartermaster::WorkItem.create("Gamma", project: "Nowhere")
    body = JSON.generate("cmd" => "state", "slug" => "gamma", "args" => { "state" => "fridge" })
    gui.respond("POST", "/api/action", ok_host, body)

    assert_equal "fridge", Quartermaster::WorkItem.find("gamma").state
  end

  def test_action_dispatch_detaches_a_session_from_the_work_item
    item = Quartermaster::WorkItem.create("Epsilon", project: "Nowhere")
    item.attach_session("sess-x")
    body = JSON.generate("cmd" => "detach", "slug" => "epsilon", "args" => { "session" => "sess-x" })
    status, _ct, out = gui.respond("POST", "/api/action", ok_host, body)

    assert_equal "200 OK", status
    assert_equal true, JSON.parse(out)["ok"]
    assert_empty Quartermaster::WorkItem.find("epsilon").sessions
  end

  def test_action_dispatch_reports_errors_instead_of_crashing
    Quartermaster::WorkItem.create("Delta", project: "Nowhere")
    bad_state = JSON.generate("cmd" => "state", "slug" => "delta", "args" => { "state" => "bogus" })
    _status, _ct, out = gui.respond("POST", "/api/action", ok_host, bad_state)
    result = JSON.parse(out)
    refute result["ok"]
    assert_includes result["error"], "state must be one of"

    unknown = JSON.generate("cmd" => "frobnicate", "slug" => "delta", "args" => {})
    _s, _c, out2 = gui.respond("POST", "/api/action", ok_host, unknown)
    assert_includes JSON.parse(out2)["error"], "unknown action"
  end

  def test_dismiss_action_reports_ok_and_records_the_dismissal
    # Regression: SessionLog#append returned nil, so `dismiss(...) && ok`
    # short-circuited and the endpoint answered "null" — the web UI read that
    # as a network error even though the dismissal was written.
    body = JSON.generate("cmd" => "dismiss", "slug" => nil, "args" => { "session" => "sess-noise" })
    status, _ct, out = gui.respond("POST", "/api/action", ok_host, body)

    assert_equal "200 OK", status
    assert_equal true, JSON.parse(out)["ok"]
    assert_includes Quartermaster::SessionLog.new.dismissed_ids, "sess-noise"
  end

  def test_new_item_action_creates_a_work_item
    body = JSON.generate("cmd" => "new", "args" => { "title" => "Fresh Idea", "project" => "Nowhere" })
    _s, _c, out = gui.respond("POST", "/api/action", ok_host, body)
    result = JSON.parse(out)

    assert result["ok"]
    assert_equal "fresh-idea", result["slug"]
    assert_equal "Fresh Idea", Quartermaster::WorkItem.find("fresh-idea").title
  end

  def test_resume_session_action_reports_dead_ends_as_json_errors
    body = JSON.generate("cmd" => "resume-session", "slug" => nil, "args" => { "session" => "sess-ghost" })
    _s, _c, out = gui.respond("POST", "/api/action", ok_host, body)
    result = JSON.parse(out)

    refute result["ok"]
    assert_includes result["error"], "no surviving transcript"
  end

  def test_session_endpoint_returns_the_turns_of_a_captured_session
    dir = File.join(Quartermaster::TRANSCRIPTS_DIR, "proj")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "sess-web.jsonl")
    File.write(path, JSON.generate("type" => "user", "timestamp" => "2026-08-10T09:00:00Z",
                                   "message" => { "content" => "hello web" }))
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "sess-web", "cwd" => "/x",
                                         "transcript_path" => path, "pid" => nil, "ts" => Time.now.iso8601)

    status, content_type, body = gui.respond("GET", "/api/session/sess-web", ok_host, "")

    assert_equal "200 OK", status
    assert_includes content_type, "application/json"
    detail = JSON.parse(body)
    assert_equal "resumable", detail["tier"]
    assert_equal ["hello web"], detail["turns"].map { |t| t["prompt"] }
  end

  def test_session_endpoint_degrades_to_metadata_when_no_transcript_survives
    status, _ct, body = gui.respond("GET", "/api/session/sess-ghost", ok_host, "")

    assert_equal "200 OK", status
    detail = JSON.parse(body)
    assert_equal "uncaptured", detail["tier"]
    assert_nil detail["turns"]
  end
end

# The chat view's side panel and header: pf badge, Work on this / Switch pf /
# Open in the IDE as background jobs, the mirrored board with its answer
# box, and the cleanup checklist. Every external tool is a FakeRunner.
class GuiPanelTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  BOARD = "https://example.com/artifact/test-board"

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def state_of(server) = JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])

  def post(server, route, payload)
    JSON.parse(server.respond("POST", route, ok_host, JSON.generate(payload))[2])
  end

  # The first state with no job running: the one carrying the finished results.
  def settled(server)
    Timeout.timeout(5) do
      loop do
        state = state_of(server)
        return state if state["jobs"].empty?

        sleep 0.01
      end
    end
  end

  # A repo whose project has every feature key on (featured_project).
  def with_featured_repo
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      configure_projects({ "WebApp" => featured_project(repo) }, ide_command: ["myide", "PATH"], ide_label: "MyIDE")
      yield repo
    end
  end

  # The page and the server must agree on the panel's routes and actions.
  def test_page_wires_the_panel_routes_and_actions
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner), ok_host)
    ["/api/workspace/", "/api/cleanup-plan", '"work-on"', '"pf-switch"', '"ide"', '"terminal"', '"pf-stop"', '"pf-mode"',
     '"run-update"', '"board-answer"', '"cleanup"', 'id="pf-badge"', 'cleanupModal("sweep")'].each do |seam|
      assert_includes page, seam
    end
  end

  def test_state_carries_the_pf_badge_and_marks_the_served_item
    with_featured_repo do |repo|
      wt = add_worktree(repo, "b1", "wt-b1")
      Quartermaster::WorkItem.create("Served", project: "WebApp", branch: "b1")
      Quartermaster::WorkItem.create("Idle", project: "WebApp")
      runner = FakeRunner.new(["curl"] => [JSON.generate("mode" => "ngrok", "root" => wt), "", true])

      state = state_of(Quartermaster::Gui.new(port: 4567, runner: runner, pf_live: true))

      assert_equal({ "mode" => "ngrok", "root" => wt, "running" => true, "switching" => false,
                     "worktree" => "wt-b1", "short" => Quartermaster.shorten_home(wt), "command" => "pf" }, state["pf"])
      served = state["items"].to_h { |i| [i["slug"], i["served"]] }
      assert_equal({ "served" => true, "idle" => false }, served)
    end
  end

  def test_without_a_configured_dev_server_the_state_runs_nothing_and_hides_the_badge
    Dir.mktmpdir do |dir|
      configure_projects({ "Docs" => dir })
      Quartermaster::WorkItem.create("Plain", project: "Docs")
      runner = FakeRunner.new
      server = Quartermaster::Gui.new(port: 4567, runner: runner, pf_live: true)

      state = state_of(server)

      assert_equal({ "running" => false, "command" => nil }, state["pf"])
      assert_empty runner.calls, "no curl, no status command"
      assert_nil JSON.parse(server.respond("GET", "/api/workspace/plain", ok_host, "")[2])["devServer"]
      refused = post(server, "/api/action", "cmd" => "pf-switch", "slug" => "plain", "args" => {})
      assert_equal true, refused["ok"]
      assert_match(/Docs has no dev server: set projects.Docs.dev_server in config.yml/, settled(server)["finished"].first["error"])
    end
  end

  def test_state_carries_the_default_project
    configure_projects({ "First" => "/code/first", "Second" => "/code/second" }, default_project: "Second")
    assert_equal "Second", state_of(Quartermaster::Gui.new(port: 4567, runner: quiet_runner))["defaultProject"]
    configure_projects({ "First" => "/code/first", "Second" => "/code/second" })
    assert_equal "First", state_of(Quartermaster::Gui.new(port: 4567, runner: quiet_runner))["defaultProject"]
  end

  def test_workspace_names_the_target_and_the_other_worktrees
    with_featured_repo do |repo|
      first = add_worktree(repo, "b1", "wt-b1")
      second = add_worktree(repo, "b2", "wt-b2")
      item = Quartermaster::WorkItem.create("Two", project: "WebApp", branch: "b1", pf_mode: "ngrok")
      item.link_branch("b2")
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

      reply = JSON.parse(server.respond("GET", "/api/workspace/two", ok_host, "")[2])

      assert_equal({ "command" => "pf", "modes" => %w[dev ngrok tunnel], "mode" => "ngrok" }, reply["devServer"])
      assert_equal({ "label" => "MyIDE", "command" => %w[myide PATH] }, reply["ide"])
      assert_equal second, File.realpath(reply.dig("target", "path"))
      assert_equal false, reply.dig("target", "create")
      assert_equal [["b1", first]], reply.dig("target", "alternatives").map { |a| [a["branch"], File.realpath(a["path"])] }
      assert_equal false, JSON.parse(server.respond("GET", "/api/workspace/nope", ok_host, "")[2])["ok"]
    end
  end

  def test_switch_pf_runs_as_a_background_job_with_a_badge_and_reports_once
    with_featured_repo do |repo|
      wt = add_worktree(repo, "b1", "wt-b1")
      Quartermaster::WorkItem.create("Sw", project: "WebApp", branch: "b1")
      gate = Queue.new
      runner = FakeRunner.new(["curl"] => ["", "", false], %w[pf status] => ["", "", false],
                              %w[pf switch] => ->(_argv) { gate.pop && ["", "", true] })
      server = Quartermaster::Gui.new(port: 4567, runner: runner, pf_live: true)

      reply = post(server, "/api/action", "cmd" => "pf-switch", "slug" => "sw", "args" => { "mode" => "tunnel" })
      assert_equal({ "ok" => true, "background" => true }, reply)
      assert_equal [{ "key" => "sw", "label" => "switching the dev server…", "pf" => true }], state_of(server)["jobs"]

      busy = post(server, "/api/action", "cmd" => "pf-stop", "slug" => nil, "args" => {})
      assert_equal false, busy["ok"]
      assert_match(/the dev server is busy/, busy["error"])

      gate << true
      finished = settled(server)["finished"]
      assert_equal 1, finished.size
      assert_equal true, finished.first["switched"]
      assert_equal wt, File.realpath(finished.first["path"])
      assert_match(/pf tunnel @/, finished.first["message"])
      assert_includes runner.argvs, ["pf", "switch", finished.first["path"], "tunnel"]
      assert_empty state_of(server)["finished"], "a result is handed out once"
    end
  end

  # The dev server is the user's one real server whatever QM_ROOT says: a GUI on a
  # throwaway data root (every test's) shows its controls off and never runs them.
  def test_a_gui_off_the_live_data_root_never_drives_pf
    with_featured_repo do |repo|
      add_worktree(repo, "b1", "wt-b1")
      Quartermaster::WorkItem.create("Off", project: "WebApp", branch: "b1")
      runner = FakeRunner.new(["curl"] => ["", "", false], %w[pf status] => ["", "", true])
      server = Quartermaster::Gui.new(port: 4567, runner: runner)

      assert_match(/the dev server is off in this GUI: .* is not the live qm data root/, state_of(server).dig("pf", "off"))
      post(server, "/api/action", "cmd" => "pf-stop", "slug" => nil, "args" => {})
      stopped = settled(server)["finished"].first
      post(server, "/api/action", "cmd" => "pf-switch", "slug" => "off", "args" => { "mode" => "dev" })
      switched = settled(server)["finished"].first

      assert_equal [false, false], [stopped["ok"], switched["ok"]]
      assert_match(/pf stop failed: the dev server is off in this GUI/, stopped["error"])
      assert_match(/pf switch failed: the dev server is off in this GUI/, switched["error"])
      assert_equal [%w[pf status]], runner.argvs.select { |argv| argv.first == "pf" }.uniq
    end
  end

  def test_the_live_gui_drives_pf_and_shows_its_controls_on
    with_featured_repo do
      runner = FakeRunner.new(["curl"] => ["", "", false], %w[pf status] => ["", "", false])
      server = Quartermaster::Gui.new(port: 4567, runner: runner, pf_live: true)

      refute state_of(server)["pf"].key?("off")
      post(server, "/api/action", "cmd" => "pf-stop", "slug" => nil, "args" => {})

      assert_equal "pf stopped", settled(server)["finished"].first["message"]
      assert_includes runner.argvs, %w[pf stop]
    end
  end

  def test_only_the_default_data_root_under_home_is_live
    assert Quartermaster.live_root?(File.expand_path("~/.claude/quartermaster"))
    refute Quartermaster.live_root?(Dir.tmpdir)
    refute Quartermaster.live_root?, "tests run on a temporary QM_ROOT"
  end

  def test_workspace_defaults_to_the_chats_branch_else_the_first_chains_top
    with_featured_repo do |repo|
      lower = add_worktree(repo, "s1", "wt-s1")
      top = add_worktree(repo, "s2", "wt-s2")
      write_stack(repo, %w[s1 s2])
      item = Quartermaster::WorkItem.create("Stk", project: "WebApp", branch: "s1")
      item.link_branch("s2")
      tmux = FakeTmux.new(["stk"])
      tmux.pane_paths["stk"] = lower
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
      workspace = ->(query = "") { JSON.parse(server.respond("GET", "/api/workspace/stk#{query}", ok_host, "")[2]) }

      on_layer = workspace.call
      assert_equal %w[s1 s1], on_layer.values_at("chatBranch", "defaultBranch"), "the chat runs on a stack layer: that one"
      assert_equal ["s1", lower], [on_layer.dig("target", "branch"), File.realpath(on_layer.dig("target", "path"))]

      tmux.pane_paths["stk"] = repo
      on_main = workspace.call
      assert_equal %w[main s2], on_main.values_at("chatBranch", "defaultBranch"), "the chat runs on no chain: the first chain's top"
      assert_equal ["s2", top], [on_main.dig("target", "branch"), File.realpath(on_main.dig("target", "path"))]

      picked = workspace.call("?branch=s1")
      assert_equal "s2", picked["defaultBranch"]
      assert_equal "s1", picked.dig("target", "branch"), "a picked branch wins over the default"
    end
  end

  def test_state_names_the_branch_whose_checkout_pf_serves
    with_featured_repo do |repo|
      add_worktree(repo, "b1", "wt-b1")
      served = add_worktree(repo, "b2", "wt-b2")
      item = Quartermaster::WorkItem.create("Two", project: "WebApp", branch: "b1")
      item.link_branch("b2")
      Quartermaster::WorkItem.create("Idle", project: "WebApp")
      runner = FakeRunner.new(["curl"] => [JSON.generate("mode" => "ngrok", "root" => served), "", true])

      state = state_of(Quartermaster::Gui.new(port: 4567, runner: runner))

      assert_equal({ "two" => "b2", "idle" => nil }, state["items"].to_h { |i| [i["slug"], i["servedBranch"]] })
      refute state["items"].first.key?("stack"), "the rails read chains; the single-stack field is gone"
    end
  end

  def page_function(page, name)
    page[/^(?:async )?function #{name}\(.*?^}$/m] or flunk("no function #{name} on the page")
  end

  # Stacks (docs/areas/stacks.md): one selected branch drives the diff and the
  # Workspace; the rails replace the "other" picker and the Stack section.
  def test_page_wires_the_selected_branch_rails_and_chats_list_bars
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner), ok_host)
    order = %w[stacks.js chat.js chat-side.js diff.js].map { |f| page.index(%(src="/assets/js/#{f}")) }
    assert_equal order.sort, order, "stacks.js loads before its callers"
    assert_includes page, %(href="/assets/css/stacks.css")

    assert_includes page, 'sessionStorage.setItem("qm-branch-picks", JSON.stringify(branchPicks))'
    assert_includes page_function(page, "diffKey"), "${diffBranchFor(slug) || \"\"}"
    assert_includes page_function(page, "diffParams"), "const branch = diffBranchFor(slug);"
    refute_match(/wsChoice|other ▾|branchesSection|choice\.branch/, page)

    section = page_function(page, "workspaceSection")
    assert_includes section, "if (itemChains(it).length) sec.appendChild(workspaceRails(it));"
    assert_includes section, 'line.appendChild(el("span", "path new", "@ new worktree"));'
    assert_includes section, "const args = branch ? { branch } : {};"
    assert_includes section, "if (ws.root && !t.create && t.path !== ws.root) {", "no Adopt for a worktree yet to be created"
    assert_includes section, "const stale = stalePfText(it);"
    assert_includes page, "`${devCmd()} serves ${circled(served + 1)} while the chat is on ${circled(on + 1)}`"
    assert_includes page_function(page, "workspaceFor"), '(branch ? "?branch=" + encodeURIComponent(branch) : "")'

    node = page_function(page, "railNode")
    assert_includes node, "node.onclick = () => { if (!isSelected) setSelectedBranch(it.slug, l.branch); };"
    assert_includes node, "if (isSelected) meta.appendChild(railTools(it, l.branch));"
    tools = page_function(page, "railTools")
    assert_includes tools, 'const link = el("button", "rail-diff", "Diff ›");'
    assert_includes tools, "tools.onclick = e => e.stopPropagation();", "a tool's click never selects the node"
    assert_includes tools, "[branchStatsButton(it.slug, branch), benchmarkButton(it, branch)]", "the diff bar's builders"
    flag = page_function(page, "benchmarkButton")
    assert_includes flag, "const done = !mine && (it.benchmarked || {})[branch];", "a live run of the branch wins over the dot"
    assert_includes flag, "`Benchmarked ${agoText(done.finishedAt) || \"earlier\"} — open for the results`"
    assert_includes node, "r.onclick = e => { e.stopPropagation(); restackStack(it, l.branch); };"
    assert_includes node, "s.title = stalePfText(it) ||", "the 🖥 marker's tooltip carries the warning"
    assert_includes page_function(page, "restackStack"), 'act("restack", { slug: it.slug, args: { branch } })'
    assert_includes page_function(page, "workspaceRails"), "const fold = chains.length >= 3;"

    list = page_function(page, "renderChat")
    assert_includes list, "const segs = chainSegmentBar(it);"
    assert_includes list, "const behind = restackCount(it);"
    assert_includes page, "body.chats-min .att-row > :not(.att-dot):not(.att-short) { display: none; }", "the shrunk strip hides the bar"
  end

  def test_workspace_and_its_actions_follow_the_selected_branch
    with_featured_repo do |repo|
      first = add_worktree(repo, "b1", "wt-b1")
      add_worktree(repo, "b2", "wt-b2")
      item = Quartermaster::WorkItem.create("Pick", project: "WebApp", branch: "b1")
      item.link_branch("b2")
      runner = FakeRunner.new(["curl"] => ["", "", false], %w[pf status] => ["", "", false])
      server = Quartermaster::Gui.new(port: 4567, runner: runner, pf_live: true)

      reply = JSON.parse(server.respond("GET", "/api/workspace/pick?branch=b1", ok_host, "")[2])
      assert_equal "b1", reply.dig("target", "branch")
      assert_equal first, File.realpath(reply.dig("target", "path"))
      unlinked = JSON.parse(server.respond("GET", "/api/workspace/pick?branch=nope", ok_host, "")[2])
      assert_equal({ "ok" => false, "error" => "branch nope is not linked to 'pick'" }, unlinked)

      refused = post(server, "/api/action", "cmd" => "pf-switch", "slug" => "pick", "args" => { "branch" => "nope" })
      assert_equal false, refused["ok"]
      assert_equal "branch nope is not linked to 'pick'", refused["error"]
      assert_empty state_of(server)["jobs"], "an unlinked branch never starts a job"

      post(server, "/api/action", "cmd" => "pf-switch", "slug" => "pick", "args" => { "branch" => "b1", "mode" => "ngrok" })
      finished = settled(server)["finished"].first
      assert_equal first, File.realpath(finished["path"])
      assert_includes runner.argvs, ["pf", "switch", finished["path"], "ngrok"]
    end
  end

  def test_a_failing_job_reports_its_error
    with_featured_repo do |repo|
      add_worktree(repo, "b1", "wt-b1")
      Quartermaster::WorkItem.create("Bad", project: "WebApp", branch: "b1")
      runner = FakeRunner.new(["curl"] => ["", "", false], %w[pf status] => ["", "", false],
                              ["myide"] => ["", "myide: command not found", false])
      server = Quartermaster::Gui.new(port: 4567, runner: runner)

      post(server, "/api/action", "cmd" => "ide", "slug" => "bad", "args" => {})
      result = settled(server)["finished"].first

      assert_equal false, result["ok"]
      assert_match(/opening MyIDE failed: myide: command not found/, result["error"])
    end
  end

  def test_without_an_ide_command_the_panel_has_no_ide_and_the_action_refuses
    configure_projects({ "WebApp" => featured_project("/repo") })
    Quartermaster::WorkItem.create("Plain", project: "WebApp")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

    refused = post(server, "/api/action", "cmd" => "ide", "slug" => "plain", "args" => {})

    assert_match(/set ide_command/, refused["error"])
    assert_equal true, JSON.parse(server.respond("GET", "/api/workspace/plain", ok_host, "")[2]).key?("ide")
    assert_nil JSON.parse(server.respond("GET", "/api/workspace/plain", ok_host, "")[2])["ide"]
    assert_empty state_of(server)["jobs"], "a refused IDE never starts a job"
  end

  def test_pf_mode_is_set_from_the_panel_chip
    configure_projects({ "WebApp" => featured_project("/repo") })
    Quartermaster::WorkItem.create("Chip", project: "WebApp")
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

    assert_equal true, post(server, "/api/action", "cmd" => "pf-mode", "slug" => "chip", "args" => { "mode" => "ngrok" })["ok"]
    assert_equal "ngrok", Quartermaster::WorkItem.find("chip").pf_mode
    assert_equal false, post(server, "/api/action", "cmd" => "pf-mode", "slug" => "chip", "args" => { "mode" => "nope" })["ok"]
  end

  def test_run_update_opens_bin_update_in_a_tmux_session_of_its_own
    Dir.mktmpdir("qm.update") do |dir|
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      refused = post(server, "/api/action", "cmd" => "run-update", "args" => { "path" => dir })
      assert_match(%r{no bin/update}, refused["error"])

      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin", "update"), "#!/bin/sh\n")
      File.chmod(0o755, File.join(dir, "bin", "update"))
      reply = post(server, "/api/action", "cmd" => "run-update", "args" => { "path" => dir })
      name = "bin-update-#{File.basename(dir).tr(".", "-")}"
      assert_equal name, reply["session"], "the page opens a terminal on it"
      opened = tmux.opened.first
      assert_equal [name, dir], opened.values_at(:name, :cwd)
      assert_match(%r{\Abin/update; .*read _\z}, opened[:argv].last, "waits for Enter so the output stays visible")
    end
  end

  def test_state_mirrors_the_board_and_the_answer_box_writes_the_answer_file
    dir = Dir.mktmpdir("qm-answers")
    item = Quartermaster::WorkItem.create("Boarded", project: "WebApp")
    item.link_board(BOARD, answers_dir: dir)
    line = { "tool_name" => "ArtifactData", "tool_response" => "Database set committed",
             "tool_input" => { "action" => "set", "url" => BOARD, "collection" => "tasks", "doc_id" => "t1",
                               "data" => { "status" => "blocked", "title" => "Task one", "note" => "which way?",
                                           "dependsOn" => ["t0"], "order" => 1 } } }
    File.open(File.join(Quartermaster::ROOT, "board-writes.jsonl"), "a") { |f| f.puts(JSON.generate(line)) }
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

    boarded = state_of(server)["items"].find { |i| i["slug"] == "boarded" }
    assert_equal dir, boarded["board_answers_dir"]
    row = boarded["boardRows"].first
    assert_equal ["t1", "blocked", "Task one", "which way?"], row.values_at("doc_id", "status", "title", "note")
    assert_equal ["t0"], row["dependsOn"]

    reply = post(server, "/api/action", "cmd" => "board-answer", "slug" => "boarded",
                                        "args" => { "doc_id" => "t1", "text" => "left" })
    assert_equal true, reply["ok"]
    assert_equal "left\n", File.read(File.join(dir, "t1.md"))
  end

  class FixedCleanup
    attr_reader :executed, :planned, :labels
    attr_writer :jobs

    def initialize(plan)
      @plan = plan
      @planned = []
    end

    def plan_item(item)
      @planned << item.slug
      @plan
    end

    def plan_sweep
      @planned << "sweep"
      @plan
    end

    def execute(plan, selected:, force: [], on_start: nil)
      @executed = { selected: selected, force: force }
      on_start&.call(plan.entries.first, 1, 2)
      @labels = @jobs&.running&.map { |job| job["label"] }
      [Quartermaster::Cleanup::Outcome.new(id: selected.first, kind: "worktree", result: "removed", message: "removed"),
       Quartermaster::Cleanup::Outcome.new(id: force.first, kind: "worktree", result: "failed", message: "git said no")]
    end
  end

  def with_cleanup(fake)
    klass = Quartermaster::Cleanup
    original = klass.method(:new)
    klass.define_singleton_method(:new) { |*, **| fake }
    yield
  ensure
    klass.define_singleton_method(:new, original)
  end

  def plan
    entry = Quartermaster::Cleanup::Entry.new(id: "worktree:#{Dir.home}/r/a", kind: "worktree", repo: "/r",
                                              path: "#{Dir.home}/r/a", branch: "a", status: "ok",
                                              reasons: [], notes: [], ticked: true, db_names: [], db_status: "ok")
    Quartermaster::Cleanup::Plan.new(scope: "x", entries: [entry], notes: [])
  end

  def test_cleanup_plan_endpoint_serves_the_item_or_sweep_checklist
    Quartermaster::WorkItem.create("Tidy", project: "Other")
    fake = FixedCleanup.new(plan)
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

    reply = with_cleanup(fake) { post(server, "/api/cleanup-plan", "scope" => "tidy") }
    assert_equal true, reply["ok"]
    assert_equal "~/r/a", reply.dig("plan", "entries", 0, "short")
    with_cleanup(fake) { post(server, "/api/cleanup-plan", "scope" => "sweep") }
    assert_equal %w[tidy sweep], fake.planned
    assert_equal false, post(server, "/api/cleanup-plan", "scope" => "nope")["ok"]
  end

  def test_cleanup_action_replans_and_executes_on_a_thread
    Quartermaster::WorkItem.create("Tidy", project: "Other")
    fake = FixedCleanup.new(plan)
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
    fake.jobs = server.jobs

    with_cleanup(fake) do
      assert_equal false, post(server, "/api/action", "cmd" => "cleanup", "args" => { "scope" => "tidy" })["ok"]
      reply = post(server, "/api/action", "cmd" => "cleanup",
                                          "args" => { "scope" => "tidy", "selected" => ["w:a"], "force" => ["w:b"] })
      assert_equal true, reply["background"]
      result = settled(server)["finished"].first

      assert_equal({ selected: ["w:a"], force: ["w:b"] }, fake.executed)
      assert_equal ["tidy"], fake.planned, "executes against a fresh plan"
      assert_equal false, result["ok"]
      assert_equal "cleanup: 1 removed, 1 failed", result["message"]
      assert_match(/b: git said no/, result["error"])
      assert_equal ["cleaning up 1/2…"], fake.labels, "the job's badge counts the entries"
    end
  end
end
