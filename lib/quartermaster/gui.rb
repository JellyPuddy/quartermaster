# frozen_string_literal: true

module Quartermaster
  # A loopback web UI: a kanban board over the work items with a detail
  # slide-over and an inbox rail. It runs until Ctrl-C — deliberately no
  # liveness timer; every self-shutdown scheme has cost a running server
  # (be28f20) — and never binds anything but 127.0.0.1. Every mutation routes
  # through the same WorkItem/Launcher/SessionLog operations the CLI uses, so
  # the two surfaces can't drift.
  class Gui
    PAGE_PATH = File.join(__dir__, "gui", "page.html")
    # The page's stylesheets and scripts: /assets/css/NAME.css and
    # /assets/js/NAME.js, nothing else — the pattern admits no path traversal.
    ASSET_DIR = File.join(__dir__, "gui")
    ASSET_ROUTE = %r{\A/assets/(css/[a-z0-9-]+\.css|js/[a-z0-9-]+\.js)\z}
    ASSET_TYPES = { ".css" => "text/css; charset=utf-8", ".js" => "text/javascript; charset=utf-8" }.freeze

    # The runner is the seam to the dev server, the IDE and worktrees; tests pass a stub. Off the live
    # data root (pf_live false) it is fenced: no dev-server command that changes what it serves (PfFence).
    # tmux is where the chat panes live (Tmux; tests pass one on a test
    # socket). The terminal token is minted per start and embedded in the page:
    # only a page this server rendered can open a terminal WebSocket.
    # caffeinate is the header's ☕ toggle (Caffeinate; tests pass stubbed spawns).
    def initialize(port: nil, runner: CommandRunner.new, tmux: Tmux.new, caffeinate: Caffeinate.new,
                   pr_deployment: PrDeployment.new, pr_memo: PrMemo.new, pf_live: Quartermaster.live_root?, benchmarks: nil)
      fence = PfFence.new(runner) unless pf_live
      @runner = runner = fence || runner
      # The diff pane's PR lookups and fetches, reused across requests.
      @pr_memo = pr_memo
      @pr_deployment = pr_deployment
      @tmux = tmux
      @caffeinate = caffeinate
      @terminal_token = SecureRandom.hex(24)
      @mutex = Mutex.new
      @jobs = GuiJobs.new
      @notifier = TurnNotifier.new(runner: runner)
      @state = GuiState.new(runner: runner, tmux: tmux, caffeinate: caffeinate, jobs: @jobs,
                            terminal_token: @terminal_token, notifier: @notifier, pf_off: fence&.reason, benchmarks: benchmarks)
      @pr_items = PrItems.new
      @actions = GuiActions.new(runner: runner, tmux: tmux, caffeinate: caffeinate, jobs: @jobs, state: @state,
                                pr_items: @pr_items)
      # Parsed transcripts for the chat history, shared across requests.
      @history_cache = {}
      @history_lock = Mutex.new
      set_port(port) if port
    end

    # A fixed loopback port so the URL is stable across launches (bookmarkable,
    # and the browser keeps one tab). Override with QM_GUI_PORT. If it's already
    # bound, that's almost certainly another qm gui — just open the existing one
    # rather than starting a rival server on a random port.
    DEFAULT_PORT = 49737

    def self.port = (ENV["QM_GUI_PORT"] || DEFAULT_PORT).to_i

    def run
      port = Gui.port
      begin
        @server = TCPServer.new("127.0.0.1", port)
      rescue Errno::EADDRINUSE
        url = "http://127.0.0.1:#{port}"
        puts "qm gui already running → #{url}   (opening the existing tab)"
        open_browser(url)
        return
      end
      set_port(@server.addr[1])
      url = "http://127.0.0.1:#{@port}"
      puts "qm gui → #{url}   (Ctrl-C to stop)"
      open_browser(url)
      trap("INT") { shutdown }
      watch_for_caffeinate
      watch_for_turns

      loop do
        client = begin
          @server.accept
        rescue StandardError
          break
        end
        Thread.new(client) { |c| handle_client(c) }
      end
    end

    # Open the page in the default browser, unless QM_GUI_NO_OPEN is set: the server
    # still serves, for tests or for driving it from an already-open tab.
    def open_browser(url)
      system("open", url) unless ENV["QM_GUI_NO_OPEN"]
    end

    def shutdown
      @server&.close
    rescue StandardError
      nil
    ensure
      exit(0)
    end

    # Pure request → response, no sockets: the router. Tested directly.
    def respond(method, path, headers, body)
      return ["403 Forbidden", "text/plain; charset=utf-8", "bad host"] unless @guard.allowed_host?(headers["host"])
      return ["403 Forbidden", "text/plain; charset=utf-8", "bad origin"] if method == "POST" && @guard.foreign_origin?(headers["origin"])

      route = path.split("?", 2).first
      if method == "POST" && headers["origin"].nil? && !@guard.local_action?(route, parse_json(body))
        return ["403 Forbidden", "text/plain; charset=utf-8", "no origin"]
      end
      FeatureUse.new.request(method, route, body)
      if method == "GET" && route == "/"
        ["200 OK", "text/html; charset=utf-8", page]
      elsif method == "GET" && (asset = route[ASSET_ROUTE, 1]) && File.file?(File.join(ASSET_DIR, asset))
        ["200 OK", ASSET_TYPES.fetch(File.extname(asset)), File.read(File.join(ASSET_DIR, asset))]
      elsif method == "GET" && route == "/api/state"
        json(@state.build)
      elsif method == "GET" && route == "/api/pulse"
        page_seen(path.split("?", 2)[1])
        json("pulse" => @state.pulse, "events" => @state.events_pulse, "issues" => IssueDrafts.signature)
      elsif method == "GET" && route == "/api/attention"
        json(@state.attention_payload)
      elsif method == "GET" && route.start_with?("/api/asides/")
        json(asides_payload(route.delete_prefix("/api/asides/")))
      elsif method == "GET" && route.start_with?("/api/session/")
        json(session_payload(route.delete_prefix("/api/session/")))
      elsif method == "POST" && route == "/api/action"
        json(action(parse_json(body)))
      elsif method == "POST" && route == "/api/drop"
        json(drop(path, body))
      elsif method == "POST" && route == "/api/ask"
        json(ask(parse_json(body)["query"]))
      elsif method == "POST" && route == "/api/grep"
        json(search_transcripts(parse_json(body)["query"]))
      elsif method == "GET" && route.start_with?("/api/history/")
        json(history_payload(route.delete_prefix("/api/history/"), path.split("?", 2)[1]))
      elsif method == "GET" && route == "/api/prs"
        json(prs_payload(path.split("?", 2)[1]))
      elsif method == "GET" && route.start_with?("/api/diff/")
        json(diff_payload(route.delete_prefix("/api/diff/"), path.split("?", 2)[1]))
      elsif method == "GET" && route.start_with?("/api/branch-stats/")
        json(branch_stats_payload(route.delete_prefix("/api/branch-stats/"), path.split("?", 2)[1]))
      elsif method == "GET" && route.start_with?("/api/benchmark/", "/api/benchmark-plan/", "/api/benchmark-log/")
        BenchmarkReport.respond(route, path.split("?", 2)[1], runner: @runner, tmux: @tmux)
      elsif method == "GET" && route.start_with?("/api/diff-file/")
        json(diff_file_payload(route.delete_prefix("/api/diff-file/"), path.split("?", 2)[1]))
      elsif method == "GET" && route == "/api/pr-threads"
        json(pr_threads_payload(path.split("?", 2)[1]))
      elsif method == "GET" && route == "/api/issues"
        json(issue_index_payload)
      elsif method == "GET" && route.start_with?("/api/issues/")
        json(issues_payload(route.delete_prefix("/api/issues/")))
      elsif method == "GET" && route.start_with?("/api/workspace/")
        json(workspace_payload(route.delete_prefix("/api/workspace/"), path.split("?", 2)[1]))
      elsif method == "POST" && route == "/api/cleanup-plan"
        json(@actions.cleanup_plan(parse_json(body)["scope"]))
      else
        ["404 Not Found", "text/plain; charset=utf-8", "not found"]
      end
    end

    attr_reader :terminal_token, :terminal, :actions, :state, :jobs, :notifier

    # A file dropped onto a terminal (Drops): the raw bytes as the body, its
    # name in the query. It carries the terminal token like the WebSocket
    # does — the path it returns is typed into a chat.
    def drop(path, body)
      params = URI.decode_www_form(path.split("?", 2)[1].to_s).to_h
      return { "ok" => false, "error" => "bad terminal token" } unless params["token"] == @terminal_token

      { "ok" => true, "path" => Drops.new.save(params["name"], body) }
    rescue ArgumentError => e
      { "ok" => false, "error" => e.message }
    end

    private

    # The page asset with the model's taxonomies injected at serve time — one
    # response, no fetch, and the JS constants can't drift from the Ruby ones.
    def page
      File.read(PAGE_PATH).sub("/*__TAXONOMIES__*/ null", JSON.generate(Quartermaster.taxonomies))
          .sub("/*__TERMINAL_TOKEN__*/ null", JSON.generate(@terminal_token))
    end

    def set_port(port)
      @port = port
      @guard = LoopbackGuard.new(port)
      @terminal = TerminalBridge.new(tmux: @tmux, token: @terminal_token, guard: @guard)
    end

    # Read-only and seconds long, so it stays off the action mutex: each
    # request already has its own thread, and a mutation landing meanwhile
    # only means the answer describes the items as they were a moment ago.
    def ask(query)
      { "ok" => true, "hits" => AskSearch.new.call(query) }
    rescue ArgumentError => e
      { "ok" => false, "error" => e.message }
    rescue StandardError => e
      Quartermaster.log_error("gui-ask", e)
      { "ok" => false, "error" => e.message }
    end

    # Transcript search: read-only like ask, so also off the mutex.
    def search_transcripts(query)
      { "ok" => true }.merge(TranscriptSearch.new(runner: @runner).call(query))
    rescue ArgumentError => e
      { "ok" => false, "error" => e.message }
    rescue StandardError => e
      Quartermaster.log_error("gui-grep", e)
      { "ok" => false, "error" => e.message }
    end

    def handle_client(client)
      request_line = client.gets
      return unless request_line

      method, path, = request_line.split
      headers = {}
      while (line = client.gets) && line != "\r\n" && line != "\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip if value
      end
      return @terminal.serve(client, path, headers) if headers["upgrade"].to_s.casecmp?("websocket")

      # A dropped file is the only big body; anything past its cap is
      # refused unread.
      length = headers["content-length"].to_i
      status, content_type, payload =
        if length > Drops::MAX_BYTES
          ["413 Content Too Large", "application/json", JSON.generate("ok" => false, "error" => "dropped file is over #{Drops::MAX_BYTES / 1024 / 1024} MB")]
        else
          respond(method, path, headers, length.positive? ? client.read(length).to_s : "")
        end
      client.write(
        "HTTP/1.1 #{status}\r\n" \
        "Content-Type: #{content_type}\r\n" \
        "Content-Length: #{payload.bytesize}\r\n" \
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
      )
      client.write(payload)
    rescue StandardError => e
      Quartermaster.log_error("gui-client", e)
    ensure
      begin
        client.close
      rescue StandardError
        nil
      end
    end

    # The drawer's earlier asides; a failure must not cost the drawer.
    def asides_payload(slug)
      rows = Aside.new(tmux: @tmux).history(WorkItem.find(slug))
      rows.each { |row| row["when"] = GuiState.relative_when(row["at"]) || "—" }
      { "asides" => rows }
    rescue StandardError => e
      Quartermaster.log_error("gui-asides", e)
      { "error" => e.message }
    end

    # The chat view's history above the live pane: GET /api/history/<slug> is
    # the timeline, /api/history/<slug>/<session>?before=N one page of a
    # session's entries. Read-only, so off the action mutex.
    def history_payload(rest, query)
      slug, session_id = rest.split("/", 2).map { |part| URI.decode_www_form_component(part) }
      item = WorkItem.find(slug.to_s)
      history = ChatHistory.new(cache: @history_cache, cache_lock: @history_lock)
      return { "ok" => true, "timeline" => history.timeline(item) } unless session_id

      before = URI.decode_www_form(query.to_s).to_h["before"]
      before &&= Integer(before, exception: false)
      { "ok" => true }.merge(history.page(item, session_id, before: before))
    rescue StandardError => e
      Quartermaster.log_error("gui-history", e) unless e.is_a?(ArgumentError)
      { "ok" => false, "error" => e.message }
    end

    # Where "work on this" would land, for the side panel: the target and the item's dev
    # server (command, modes, its mode) and IDE (label, command), each nil without one; ?branch=
    # is the panel's selected branch. Without one, the default selection (docs/areas/stacks.md) — the branch the chat
    # runs on when one of the item's chains holds it, else the top of the first chain —
    # returned as defaultBranch beside chatBranch: only this per-item fetch pays for asking
    # tmux and git where the chat runs. Resolving creates nothing; materializing happens in the action.
    def workspace_payload(slug, query = nil)
      item = WorkItem.find(slug)
      picked = URI.decode_www_form(query.to_s).to_h["branch"].to_s
      chat_branch = BranchDiff.new(tmux: @tmux, runner: @runner).chat_branch(item)
      default = default_selection(item, chat_branch)
      target = TargetWorktree.new(runner: @runner).resolve(item, branch: picked.empty? ? default : picked)
      { "ok" => true, "devServer" => (server = item.dev_server) && { "command" => server.command, "modes" => server.modes, "mode" => item.pf_mode },
        "ide" => ProjectConfig.current.ide(item.project)&.to_h, "root" => ProjectMap.new.root_for(item.project), "target" => target_payload(target),
        "chatBranch" => chat_branch, "defaultBranch" => default }
    rescue StandardError => e
      Quartermaster.log_error("gui-workspace", e) unless e.is_a?(ArgumentError)
      { "ok" => false, "error" => e.message }
    end

    def default_selection(item, chat_branch)
      chains = GhStack.chains(item)
      return chat_branch if chat_branch && chains.any? { |chain| chain["layers"].any? { |layer| layer["branch"] == chat_branch } }

      chains.first&.dig("layers", -1, "branch")
    end

    # The PR scope's review threads, fetched once its diff is shown:
    # GET /api/pr-threads?repo=OWNER/NAME&number=N&head=SHA[&fresh=1]. gh on
    # a request thread, never under the action mutex; cached briefly per PR
    # head (ReviewThreads).
    def pr_threads_payload(query)
      params = URI.decode_www_form(query.to_s).to_h
      { "ok" => true }.merge(ReviewThreads.new(runner: @runner).fetch(params["repo"], params["number"], head: params["head"],
                                                                        fresh: params["fresh"] == "1"))
    rescue ArgumentError => e
      { "ok" => false, "error" => e.message }
    rescue StandardError => e
      Quartermaster.log_error("gui-pr-threads", e)
      { "ok" => false, "error" => e.message }
    end

    # The chat view's diff pane: GET /api/diff/<slug>?branch=B&scope=uncommitted,
    # or ?scope=commits|pr&from=SHA&to=SHA (&base=LOWER for a stack span), or ?scope=prompt&prompt=SESSION:N&moved=BRANCH&rebase=show (show
    # what a rebase since the prompt brought in; hidden by default).
    # Each file carries its diff digest and whether it is marked viewed (ViewedMarks).
    # Read-only git (the prompt scope only adds objects, the pr scope fetches
    # the PR and gh may be asked which it is), so off the action mutex. The pr
    # scope reuses the last minute's lookup and fetch (PrMemo) unless fresh=1.
    def diff_payload(slug, query)
      params = URI.decode_www_form(query.to_s).to_h
      item = WorkItem.find(URI.decode_www_form_component(slug))
      result =
        if params["scope"] == "prompt"
          BranchDiff.new(tmux: @tmux, runner: @runner).require_checkout(item, params["branch"])
          PromptDiff.new(tmux: @tmux).call(item, prompt: params["prompt"], moved: params["moved"],
                                                 rebase: params["rebase"] != "show")
        else
          revisions = PrRevisions.new(runner: @runner, memo: @pr_memo)
          BranchDiff.new(tmux: @tmux, runner: @runner, pr_revisions: revisions)
                    .call(item, branch: params["branch"], scope: params["scope"], from: params["from"], to: params["to"],
                                fresh: params["fresh"] == "1", base: params["base"])
        end
      ViewedMarks.new(item.slug).apply(result["files"])
      { "ok" => true }.merge(result)
    rescue StandardError => e
      Quartermaster.log_error("gui-diff", e) unless e.is_a?(ArgumentError)
      { "ok" => false, "error" => e.message }
    end

    # The diff pane's branch stats modal: GET /api/branch-stats/<slug>?branch=B&refresh=1
    # (BranchStats). Read-only git and the stats script, so off the action mutex.
    def branch_stats_payload(slug, query)
      params = URI.decode_www_form(query.to_s).to_h
      item = WorkItem.find(URI.decode_www_form_component(slug))
      { "ok" => true }.merge(BranchStats.new(runner: @runner, tmux: @tmux).call(
                               item, branch: params["branch"], refresh: params["refresh"] == "1",
                                     running: @jobs.running.map { |job| job["key"] }
                             ))
    rescue StandardError => e
      Quartermaster.log_error("gui-branch-stats", e) unless e.is_a?(ArgumentError)
      { "ok" => false, "error" => e.message }
    end

    # The diff pane's context expanding: GET /api/diff-file/<slug>?rev=SHA&path=PATH,
    # the file at a diff's oldRev as lines (FileAtRevision), read in the
    # item's project root. Read-only git, so off the action mutex.
    def diff_file_payload(slug, query)
      params = URI.decode_www_form(query.to_s).to_h
      item = WorkItem.find(URI.decode_www_form_component(slug))
      root = ProjectMap.new.root_for(item.project)
      raise ArgumentError, "no repo root configured for project '#{item.project}'" unless root && File.directory?(root)

      { "ok" => true }.merge(FileAtRevision.new(root).call(params["rev"], params["path"]))
    rescue StandardError => e
      Quartermaster.log_error("gui-diff-file", e) unless e.is_a?(ArgumentError)
      { "ok" => false, "error" => e.message }
    end

    # The Issues pane: the item's issue drafts (IssueDrafts) and the GitHub
    # repo their numbers link into — its project's origin, nil when unknown.
    # Read-only apart from the revision snapshots, so off the action mutex.
    def issues_payload(slug)
      item = WorkItem.find(URI.decode_www_form_component(slug))
      root = ProjectMap.new.root_for(item.project)
      { "ok" => true, "slug" => item.slug, "repo" => root && Quartermaster.github_repo(root) }
        .merge(IssueDrafts.new(item.slug).read)
    rescue StandardError => e
      Quartermaster.log_error("gui-issues", e) unless e.is_a?(ArgumentError)
      { "ok" => false, "error" => e.message }
    end

    # The Issues view: every item's issue drafts (IssueIndex). Read-only
    # apart from the revision snapshots, so off the action mutex.
    def issue_index_payload
      { "ok" => true, "items" => IssueIndex.new.entries }
    rescue StandardError => e
      Quartermaster.log_error("gui-issues", e)
      { "ok" => false, "error" => e.message }
    end

    def target_payload(target)
      short = ->(path) { Quartermaster.shorten_home(path) }
      { "path" => target.path, "short" => short.call(target.path), "branch" => target.branch,
        "create" => target.create? ? true : false, "warning" => target.warning,
        "alternatives" => target.alternatives.map { |b, path| { "branch" => b, "path" => path, "short" => short.call(path) } } }
    end

    # The PRs view: the cached list (PrInbox), each PR tied to what qm knows about it — its
    # project (and its dev-server command and review skill), the work item holding its branch,
    # the review item, the worktree it is checked out in and whether the dev server serves
    # that. Read-only, so off the action mutex.
    def prs_payload(query)
      list = PrInbox.new.list(force: URI.decode_www_form(query.to_s).to_h["refresh"] == "1")
      project_map = ProjectMap.new
      worktrees = Hash.new { |cache, root| cache[root] = Quartermaster.branch_worktrees(root) }
      items = WorkItem.all
      pf = @state.pf_status
      panes = @tmux.sessions
      prerequisites = @pr_deployment.states
      list["prs"] = list["prs"].map do |pr|
        project = @pr_items.project_for_repo(pr["repo"], project_map)
        settings = project_map.settings_for(project)
        root = project && settings.root
        path = root && worktrees[root][pr["head"]]
        item = @pr_items.pr_item(pr, project, items)
        pr.merge("label" => @pr_items.pr_label(pr), "project" => project, "devServer" => project && settings.dev_server&.command,
                 "ide" => project && project_map.ide(project)&.label, "reviewSkill" => settings.review_skill,
                 "item" => item&.slug, "pane" => item ? panes.include?(item.slug) : false,
                 "reviewItem" => @pr_items.review_item(pr, items)&.slug,
                 "worktree" => path && Quartermaster.shorten_home(path),
                 "served" => path ? @state.served?(pf, [path]) : false, "jobKey" => item&.slug || @pr_items.pr_label(pr),
                 "prerequisites" => prerequisites.fetch(pr["url"], []))
      end
      { "ok" => true, "prerequisitesRefreshing" => @pr_deployment.refreshing? }.merge(list)
    rescue StandardError => e
      Quartermaster.log_error("gui-prs", e)
      { "ok" => false, "error" => e.message }
    end

    # The page's pulse says whether it is visible, has focus and which chat
    # it shows: the notifier's channel choice (TurnNotifier). A hidden tab
    # still polls (throttled) for its title's count, but can't show anything:
    # its pulse hands notifications back to macOS at once.
    def page_seen(query)
      params = URI.decode_www_form(query.to_s).to_h
      return @notifier.page_hidden unless params["visible"] == "1"

      @notifier.page_seen(focused: params["focused"] == "1", chat: params["chat"].to_s.empty? ? nil : params["chat"])
    rescue ArgumentError
      nil
    end

    TURN_CHECK_EVERY = 1.5

    # Notifications for chats that need the user, raised from hook output (events.jsonl
    # growing). Not a liveness timer: nothing here depends on a page being open, and nothing can stop the server.
    def watch_for_turns
      Thread.new do
        size = :unchecked
        loop do
          current = File.size?(EventLog.new.path)
          @notifier.check if current != size
          size = current
          sleep TURN_CHECK_EVERY
        rescue StandardError => e
          Quartermaster.log_error("turn watch", e)
          sleep TURN_CHECK_EVERY
        end
      end
    end

    CAFFEINATE_CHECK_EVERY = 15

    # Auto mode's verdict, re-checked on a server thread so it holds with no
    # tab open and when the mode was set from the CLI. Nothing here can stop
    # the server: it only switches the caffeinate child.
    def watch_for_caffeinate
      Thread.new do
        loop do
          sleep CAFFEINATE_CHECK_EVERY
          @caffeinate.sync(@actions.sessions_busy?) if @caffeinate.mode == "auto"
        rescue StandardError => e
          Quartermaster.log_error("caffeinate auto", e)
        end
      end
    end

    def json(object)
      ["200 OK", "application/json; charset=utf-8", JSON.generate(object)]
    end

    # Read-only actions that wait on the network (GuiActions::UNLOCKED) skip
    # the action mutex, like ask and grep do; every other action holds it.
    def action(payload)
      return @actions.dispatch(payload) if payload.is_a?(Hash) && GuiActions::UNLOCKED.include?(payload["cmd"])

      @mutex.synchronize { @actions.dispatch(payload) }
    end

    def parse_json(body)
      JSON.parse(body)
    rescue StandardError
      {}
    end

    def session_payload(session_id)
      Quartermaster.session_detail(session_id)
    rescue StandardError => e
      Quartermaster.log_error("gui-session", e)
      { "error" => e.message }
    end
  end
end
