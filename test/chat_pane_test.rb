# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/chat_pane_test.rb`).
require_relative "test_helper"

class WebSocketCodecTest < Minitest::Test
  WS = Quartermaster::WebSocket

  # A client frame as a browser sends it: always masked.
  def client_frame(payload, opcode, fin: true, mask: [1, 2, 3, 4])
    payload = payload.b
    len = payload.bytesize
    head = [(fin ? 0x80 : 0) | opcode].pack("C")
    head << if len < 126 then [0x80 | len].pack("C")
            elsif len < 65_536 then [0x80 | 126, len].pack("Cn")
            else [0x80 | 127, len].pack("CQ>")
            end
    masked = payload.bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack("C*")
    head + mask.pack("C*") + masked
  end

  def messages_from(bytes)
    out = StringIO.new
    socket = WS.new(DuplexIO.new(StringIO.new(bytes.b), out))
    seen = []
    socket.each_message { |op, data| seen << [op, data] }
    [seen, out.string.b]
  end

  # Reads from one stream and writes to another, like a socket.
  DuplexIO = Struct.new(:input, :output) do
    def read(count) = input.read(count)
    def write(*parts) = output.write(*parts)
  end

  def test_accept_key_matches_the_rfc_example
    assert_equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", WS.accept_key("dGhlIHNhbXBsZSBub25jZQ==")
    assert_match(/\AHTTP\/1.1 101 .*Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=\r\n\r\n\z/m,
                 WS.handshake_response("dGhlIHNhbXBsZSBub25jZQ=="))
  end

  def test_encode_uses_the_three_length_forms
    assert_equal [0x82, 5].pack("CC") + "hello", WS.encode("hello", WS::BINARY)
    medium = WS.encode("x" * 300, WS::TEXT)
    assert_equal [0x81, 126, 300].pack("CCn"), medium[0, 4]
    large = WS.encode("x" * 70_000, WS::BINARY)
    assert_equal [0x82, 127, 70_000].pack("CCQ>"), large[0, 10]
    assert_equal 70_010, large.bytesize
  end

  def test_decodes_masked_frames_of_every_length
    ["hi", "y" * 300, "z" * 70_000].each do |payload|
      seen, = messages_from(client_frame(payload, WS::BINARY))
      assert_equal [[WS::BINARY, payload]], seen
    end
  end

  def test_joins_fragments_and_answers_ping_between_them
    bytes = client_frame("ab", WS::TEXT, fin: false) + client_frame("p", WS::PING) + client_frame("cd", 0)
    seen, written = messages_from(bytes)
    assert_equal [[WS::TEXT, "abcd"]], seen
    assert_equal WS.encode("p", WS::PONG), written
  end

  def test_close_is_echoed_and_ends_the_stream
    bytes = client_frame([1000].pack("n"), WS::CLOSE) + client_frame("never", WS::BINARY)
    seen, written = messages_from(bytes)
    assert_empty seen
    assert_equal WS.encode([1000].pack("n"), WS::CLOSE), written
  end

  def test_refuses_unmasked_and_oversized_frames
    assert_raises(WS::ProtocolError) { messages_from([0x82, 2].pack("CC") + "hi") }
    assert_raises(WS::ProtocolError) { messages_from([0x82, 0x80 | 127, 1 << 40].pack("CCQ>")) }
    # Each fragment fits, but the message they build would not.
    half = "x" * ((WS::MAX_PAYLOAD / 2) + 1)
    fragments = client_frame(half, WS::BINARY, fin: false) + client_frame(half, 0, fin: false) + client_frame("", 0)
    assert_raises(WS::ProtocolError) { messages_from(fragments) }
  end
end

class TmuxTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    skip "tmux not installed" unless system("command -v tmux >/dev/null")
    @tmux = Quartermaster::Tmux.new(socket: "qm-test-lifecycle-#{Process.pid}")
  end

  def teardown
    @tmux&.kill_server
  end

  def screen(name)
    Open3.capture2("tmux", "-L", @tmux.socket, "capture-pane", "-p", "-t", "=#{name}:")[0]
  end

  def wait_for(timeout = 5)
    Timeout.timeout(timeout) { sleep 0.05 until yield }
  end

  def test_a_session_lives_until_its_program_ends
    assert_empty @tmux.sessions, "no server yet means no sessions"
    Dir.mktmpdir do |dir|
      assert @tmux.open("an-item", cwd: dir, argv: %w[sh -c] + ["pwd; echo $QM_ITEM; sleep 30"], env: { "QM_ITEM" => "an-item" })
      assert @tmux.live?("an-item")
      refute @tmux.live?("an"), "names match exactly, not by prefix"
      refute @tmux.open("an-item", cwd: dir, argv: %w[true]), "one live session per name"
      wait_for { screen("an-item").include?("an-item") }
      assert_includes screen("an-item"), File.basename(dir)

      assert @tmux.kill("an-item")
      refute @tmux.live?("an-item")
      assert_empty @tmux.sessions
    end
  end

  def test_the_program_runs_without_claude_variables
    ENV["CLAUDECODE"] = "1"
    @tmux.open("scrubbed", cwd: Dir.home, argv: ["sh", "-c", 'echo "marker:${CLAUDECODE:-unset}"; sleep 30'])
    wait_for { screen("scrubbed").include?("marker:") }
    assert_includes screen("scrubbed"), "marker:unset"
  ensure
    ENV.delete("CLAUDECODE")
  end

  def test_server_options_suit_a_chat
    @tmux.open("opts", cwd: Dir.home, argv: %w[sleep 30])
    options = Open3.capture2("tmux", "-L", @tmux.socket, "show-options", "-g")[0]
    assert_match(/^status off$/, options)
    assert_match(/^mouse on$/, options)
    assert_match(/^prefix None$/, options)
  end

  def test_session_ends_with_its_program_and_odd_names_are_refused
    @tmux.open("short-lived", cwd: Dir.home, argv: %w[true])
    wait_for { !@tmux.live?("short-lived") }
    assert_raises(ArgumentError) { @tmux.open("a:b", cwd: Dir.home, argv: %w[true]) }
    refute @tmux.live?("=x")
  end
end

class PaneFollowsSessionTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    skip "tmux not installed" unless system("command -v tmux >/dev/null")
    @tmux = Quartermaster::Tmux.new(socket: "qm-test-follow-#{Process.pid}")
  end

  def teardown
    @tmux&.kill_server
  end

  # A pane running a long-lived dummy, recorded as `session_id`'s claude.
  def chat(name, session_id, pid: nil)
    @tmux.open(name, cwd: Dir.home, argv: %w[sleep 300])
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => "/",
                                         "pid" => pid || @tmux.pane_pid(name), "ts" => Time.now.iso8601)
  end

  def window_name(name)
    Open3.capture2("tmux", "-L", @tmux.socket, "display-message", "-p", "-t", "=#{name}:", '#{window_name}')[0].strip
  end

  def follow(session_id, from:, to:)
    Quartermaster::PaneFollowsSession.new(tmux: @tmux).move(session_id, from: from, to: to)
  end

  def test_the_pane_running_the_session_is_renamed_with_its_window
    chat("old-item", "sess-a")

    assert_nil follow("sess-a", from: ["old-item"], to: "new-item")

    assert @tmux.live?("new-item")
    refute @tmux.live?("old-item")
    assert_equal "new-item", window_name("new-item")
  end

  def test_a_pane_running_another_process_stays
    chat("old-item", "sess-a", pid: 999_999_999)

    assert_nil follow("sess-a", from: ["old-item"], to: "new-item")

    assert @tmux.live?("old-item")
    refute @tmux.live?("new-item")
  end

  def test_a_live_target_keeps_both_panes_and_warns
    chat("old-item", "sess-a")
    @tmux.open("new-item", cwd: Dir.home, argv: %w[sleep 300])

    warning = follow("sess-a", from: ["old-item"], to: "new-item")

    assert_match(/new-item already has a chat running/, warning)
    assert @tmux.live?("old-item")
    refute @tmux.rename("old-item", "new-item"), "rename itself refuses a live target"
  end

  def test_the_gui_attach_reply_carries_the_warning
    chat("old-item", "sess-a")
    @tmux.open("new-item", cwd: Dir.home, argv: %w[sleep 300])
    Quartermaster::WorkItem.create("Old item", project: "MyApp", session_id: "sess-a")
    Quartermaster::WorkItem.create("New item", project: "MyApp")
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: @tmux)
    body = JSON.generate({ "cmd" => "attach", "slug" => "new-item", "args" => { "session" => "sess-a" } })
    _s, _c, out = gui.respond("POST", "/api/action", { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }, body)

    reply = JSON.parse(out)
    assert reply["ok"]
    assert_equal ["old-item"], reply["detached"]
    assert_match(/already has a chat running/, reply["warning"])
  end

  def test_an_aside_pane_is_left_alone
    @tmux.open("old-item--aside", cwd: Dir.home, argv: %w[sleep 300])
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "sess-a", "cwd" => "/",
                                         "aside" => "old-item", "pid" => @tmux.pane_pid("old-item--aside"),
                                         "ts" => Time.now.iso8601)

    # Even named as vacated, the aside's own pane never moves.
    assert_nil follow("sess-a", from: ["old-item--aside"], to: "new-item")

    assert @tmux.live?("old-item--aside")
    refute @tmux.live?("new-item")
  end

  def test_no_tmux_server_is_a_quiet_no_op
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "sess-a", "cwd" => "/",
                                         "pid" => Process.pid, "ts" => Time.now.iso8601)

    assert_nil follow("sess-a", from: ["old-item"], to: "new-item")
    assert_empty @tmux.sessions
    refute @tmux.rename("old-item", "new-item")
    refute @tmux.rename("a:b", "new-item"), "odd names are refused"
  end
end

class ChatPlanTest < Minitest::Test
  include QmTestHelpers

  def log_start(id, cwd:, transcript: nil, pid: 999_999_999)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => id, "cwd" => cwd,
                                         "transcript_path" => transcript, "pid" => pid, "ts" => Time.now.iso8601)
  end

  def log_end(id) = Quartermaster::SessionLog.new.append("event" => "end", "session_id" => id, "ts" => Time.now.iso8601)

  def test_start_is_a_fresh_qm_item_session
    item = Quartermaster::WorkItem.create("Fresh", project: "No project")
    plan = Quartermaster::Launcher.new.chat_plan(item, fresh: true)
    assert_equal :start, plan[:mode]
    assert_equal ["claude"], plan[:argv]
    assert_equal({ "QM_ITEM" => "fresh" }, plan[:env])
  end

  def test_resume_continues_the_newest_resumable_session_in_its_cwd
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      File.write(transcript, "")
      item = Quartermaster::WorkItem.create("Again", project: "No project", session_id: "sess-a")
      log_start("sess-a", cwd: dir, transcript: transcript)
      log_end("sess-a")

      plan = Quartermaster::Launcher.new.chat_plan(item)
      assert_equal({ mode: :resume, session_id: "sess-a", cwd: dir, argv: %w[claude --resume sess-a], env: {} }, plan)
    end
  end

  def test_chat_command_can_be_swapped
    item = Quartermaster::WorkItem.create("Haiku", project: "No project")
    ENV["QM_CHAT_COMMAND"] = "claude --model haiku"
    assert_equal %w[claude --model haiku], Quartermaster::Launcher.new.chat_plan(item, fresh: true)[:argv]
  ensure
    ENV.delete("QM_CHAT_COMMAND")
  end

  # A Warp-tab session must end before the pane takes over: resuming an older
  # transcript beside it would make two live chats for one item.
  def test_a_live_session_elsewhere_blocks_start_and_resume
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      File.write(transcript, "")
      item = Quartermaster::WorkItem.create("Busy", project: "No project", session_id: "sess-old")
      item.attach_session("sess-live")
      log_start("sess-old", cwd: dir, transcript: transcript)
      log_end("sess-old")
      log_start("sess-live", cwd: dir, transcript: transcript, pid: Process.pid)

      launcher = Quartermaster::Launcher.new
      assert_equal :live, launcher.chat_plan(item)[:mode]
      assert_equal :live, launcher.chat_plan(item, fresh: true)[:mode]
    end
  end
end

class GuiChatPaneTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  def host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def post(server, payload) = JSON.parse(server.respond("POST", "/api/action", host, JSON.generate(payload))[2])
  def state_of(server) = JSON.parse(server.respond("GET", "/api/state", host, "")[2])

  def upgrade_headers(origin: "http://127.0.0.1:4567")
    { "host" => "127.0.0.1:4567", "origin" => origin, "upgrade" => "websocket",
      "sec-websocket-key" => "dGhlIHNhbXBsZSBub25jZQ==" }.compact
  end

  def test_start_and_resume_open_the_items_tmux_session_once
    tmux = FakeTmux.new
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    Quartermaster::WorkItem.create("Pane me", project: "No project")

    reply = post(server, "cmd" => "pane-start", "slug" => "pane-me")
    assert_equal({ "ok" => true, "mode" => "start" }, reply)
    assert_equal({ name: "pane-me", cwd: Dir.home, argv: ["claude"], env: { "QM_ITEM" => "pane-me" } }, tmux.opened.first)

    again = post(server, "cmd" => "pane-resume", "slug" => "pane-me")
    assert_equal true, again["attached"], "one live chat per item: the pane is just shown again"
    assert_equal 1, tmux.opened.size

    state = state_of(server)
    assert_equal true, state["items"].find { |i| i["slug"] == "pane-me" }["pane"]
    assert_equal ["pane-me"], state["panes"]
    assert_equal server.terminal_token, state["terminalToken"]
  end

  def adopt_fixture(dir)
    repo = make_repo(dir)
    worktree = add_worktree(repo, "feature", "repo-feature")
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Repo" => repo } }.to_yaml)
    Quartermaster::WorkItem.create("Adopt me", project: "Repo", branch: "feature")
    [repo, worktree]
  end

  def test_adopt_starts_a_chat_in_the_main_checkout_running_the_skill
    Dir.mktmpdir do |dir|
      repo, worktree = adopt_fixture(File.join(dir, "repo").tap { |r| FileUtils.mkdir_p(r) })
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      reply = post(server, "cmd" => "adopt", "slug" => "adopt-me", "args" => { "worktree" => worktree })

      assert_equal({ "ok" => true, "mode" => "start", "branch" => "feature" }, reply)
      assert_equal({ name: "adopt-me", cwd: repo, argv: ["claude", "/adopt-worktree #{worktree}"],
                     env: { "QM_ITEM" => "adopt-me" } }, tmux.opened.first)
    end
  end

  def test_adopt_types_the_skill_into_a_live_pane
    Dir.mktmpdir do |dir|
      _repo, worktree = adopt_fixture(File.join(dir, "repo").tap { |r| FileUtils.mkdir_p(r) })
      tmux = FakeTmux.new(["adopt-me"])
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      reply = post(server, "cmd" => "adopt", "slug" => "adopt-me", "args" => { "worktree" => worktree })

      assert_equal({ "ok" => true, "attached" => true }, reply)
      assert_equal [["adopt-me", "/adopt-worktree #{worktree}"], ["adopt-me", :enter]], tmux.typed
      assert_empty tmux.opened
    end
  end

  def test_adopt_refuses_the_main_checkout_and_strangers
    Dir.mktmpdir do |dir|
      repo, = adopt_fixture(File.join(dir, "repo").tap { |r| FileUtils.mkdir_p(r) })
      tmux = FakeTmux.new
      server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      main = post(server, "cmd" => "adopt", "slug" => "adopt-me", "args" => { "worktree" => repo })
      assert_match(/main checkout/, main["error"])
      stranger = post(server, "cmd" => "adopt", "slug" => "adopt-me", "args" => { "worktree" => dir })
      assert_match(/not a worktree/, stranger["error"])
      assert_empty tmux.opened
    end
  end

  def test_a_chat_running_in_warp_is_not_taken_over_while_it_lives
    tmux = FakeTmux.new
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    Quartermaster::WorkItem.create("Elsewhere", project: "No project", session_id: "sess-warp")
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "sess-warp", "cwd" => Dir.home,
                                         "pid" => Process.pid, "ts" => Time.now.iso8601)

    reply = post(server, "cmd" => "pane-resume", "slug" => "elsewhere")
    assert_equal false, reply["ok"]
    assert_match(/outside the GUI/, reply["error"])
    assert_empty tmux.opened
    assert_equal false, state_of(server)["items"].first["pane"]
  end

  def test_a_dropped_file_is_saved_under_a_quote_free_name_and_needs_the_token
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    drop = ->(query) { JSON.parse(server.respond("POST", "/api/drop?#{query}", host, "PNGDATA")[2]) }

    saved = drop.call(URI.encode_www_form(token: server.terminal_token, name: "Screenshot 2026-10-22 at 10.50.45.png"))
    assert saved["ok"], saved["error"]
    assert_match(%r{/drops/\d{8}-\d{6}-\h{6}-Screenshot-2026-10-22-at-10.50.45.png\z}, saved["path"])
    assert_equal "PNGDATA", File.binread(saved["path"])

    refused = drop.call(URI.encode_www_form(token: "guess", name: "x.png"))
    assert_equal({ "ok" => false, "error" => "bad terminal token" }, refused)
  end

  def test_drops_older_than_a_week_are_pruned_on_the_next_drop
    Dir.mktmpdir do |dir|
      old = File.join(dir, "old.png")
      File.write(old, "x")
      File.utime(Time.now - 8 * 24 * 3600, Time.now - 8 * 24 * 3600, old)
      path = Quartermaster::Drops.new(dir: dir).save("../../etc/passwd", "y")
      refute File.exist?(old)
      assert_equal dir, File.dirname(path)
      assert path.end_with?("-passwd")
    end
  end

  def test_the_page_carries_the_token_and_the_pane_seams
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    page = served_page(server, host)
    assert_includes page, "let terminalToken = #{JSON.generate(server.terminal_token)};"
    ['"pane-resume"', '"pane-start"', '"pane-warp"', "/ws/terminal", "cdn.jsdelivr.net/npm/@xterm/xterm", "registerLinkProvider(urlLinks", "linkHandler",
     "addon-fit", "terminalModal(r.session"].each { |seam| assert_includes page, seam }
    refute_equal server.terminal_token, Quartermaster::Gui.new(port: 4567, tmux: FakeTmux.new).terminal_token,
                 "minted per GUI start"
  end

  def test_the_page_can_maximize_the_chat_pane
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
    ["attachCustomKeyEventHandler", "isMaxChord", 'sessionStorage.getItem("qm-pane-max")', 'id = "pane-max-btn"',
     "body[data-mode=\"chat\"].pane-max .att-list", "togglePaneMax()"].each { |seam| assert_includes page, seam }
    refute_includes page, "requestFullscreen", "CSS fill, not the Fullscreen API"
  end

  def test_a_chat_row_leads_with_the_title_and_cut_off_text_tells_the_rest_on_hover
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
    ['el("span", "att-name", esc(it.title || a.slug))', "row.title = a.slug;",
     'getComputedStyle(node).textOverflow !== "ellipsis"', "node.title = base ? `${text}\\n${base}` : text;"]
      .each { |seam| assert_includes page, seam }
  end

  def test_the_chats_list_shrinks_to_a_strip_of_dots_and_initials
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
    ['id="att-min"', 'localStorage.setItem("qm-chats-min", on ? "1" : "0")', 'el("span", "att-short", esc(chatInitials(it.title, a.slug)))',
     "body.chats-min .att-row > :not(.att-dot):not(.att-short) { display: none; }"].each { |seam| assert_includes page, seam }
  end

  def test_cmd_shift_esc_hands_focus_back_to_the_page
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
    assert_includes page,
                    'const isLeaveChord = e => e.key === "Escape" && e.metaKey && e.shiftKey && !e.ctrlKey && !e.altKey;',
                    "exactly ⌘⇧Esc: plain Esc stays claude's"
    assert_includes page, "const leave = !max && isLeaveChord(e);", "swallowed in the terminal's own key handler"
    assert_includes page, "leave ? this.xt.blur()", "blurs, so focus falls to the page body"
    assert_includes page, "<kbd>⌘⇧esc</kbd>", "the legend names it"
  end

  def test_an_explicit_chat_selection_focuses_its_terminal_and_list_keys_do_not
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
    ["row.onclick = () => selectChat(a.slug, { focusTerm: true });",
     'function openChat(it) { chatSlug = it.slug; setMode("chat"); selectChat(it.slug, { focusTerm: true }); }',
     "if (wantsTermFocus === it.slug) focusChatTermSoon(it.slug);",
     "chatSlug === slug && focusIsIdle()) chatTerm.focus()"].each { |seam| assert_includes page, seam }
    assert_includes page, "selectChat(rows[i < 0 ? 0 : Math.min(rows.length - 1, Math.max(0, i + d))]);",
                    "j/k move the highlight without focusing the terminal"
    assert_match(/renderChat\(\);\n  wantsTermFocus = null;/, page, "only the selection's own render may focus, never a poll's")
    assert_includes page, 'case "Enter": if ((it || looseOf(chatSlug)) && panes.includes(chatSlug)) { e.preventDefault(); focusChatTermSoon(chatSlug); } break;',
                    "Enter on a highlighted row goes into its terminal"
    assert_includes page, 'case "i": if (it) openDetail(it); break;', "full detail moved to i"
  end

  def page_function(page, name)
    page[/^(?:async )?function #{name}\(.*?^}$/m] or flunk("no function #{name} on the page")
  end

  # Plan decision 11: the chats list grouped by epic, the Epic block in the side
  # panel and the crumb in the chat head (chat-epic.js).
  def test_the_chats_list_groups_rows_by_epic_with_foldable_blocks
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
    order = %w[chat.js chat-epic.js events.js].map { |f| page.index(%(<script src="/assets/js/#{f}">)) }
    assert_equal order.sort, order
    assert_includes page, %(href="/assets/css/chat-epic.css")

    assert_includes page_function(page, "renderChat"), "renderChatList(list, rows);\n    renderLooseGroup(list);",
                    "epic blocks and no-epic rows first, loose chats and runs after as before"
    groups = page_function(page, "chatListGroups")
    assert_includes groups, "if (!epic) { plain.push(a); return; }"
    assert_includes groups, %(if (a.slug !== epic.slug || a.state !== "none") blocks.get(epic.slug).rows.push(a);),
                    "the epic's own entry joins its block only with a turn; the header stands for it otherwise"
    assert_includes page_function(page, "chatEpicOf"), %(items.find(i => i.slug === it.epic && i.kind === "epic")),
                    "a dangling epic slug reads as no epic"
    list = page_function(page, "renderChatList")
    assert_includes list, %(list.appendChild(el("div", "att-group", "no epic")); labelled = true;)
    assert_includes list, "else if (blocks.length && !labelled)", "no label at all while no epic has a chat"

    block = page_function(page, "chatEpicBlock")
    assert_includes block, "head.onclick = () => selectChat(epic.slug);", "the header opens the epic itself"
    assert_includes block, "chev.onclick = e => { e.stopPropagation(); toggleChatEpicFold(epic.slug); };"
    assert_includes block, "`${live} live · ${open} todo${open === 1 ? \"\" : \"s\"}`"
    assert_includes block, "if (!folded) { rows.forEach(a => box.appendChild(chatRow(a))); return box; }"
    assert_includes page, 'localStorage.setItem("qm-chat-epic-folds", JSON.stringify([...chatEpicFolds]))', "folds remembered per browser"
    assert_includes page_function(page, "moveChat"), "const rows = [...chatListSlugs(), ...looseChats.map(l => l.name)];",
                    "j/k walk the list as it shows, skipping folded rows"
    assert_includes page_function(page, "chatListSlugs"), "b.rows.filter(a => a.slug === chatSlug)",
                    "a folded block keeps the selected chat, so j/k go on from its dot"
    assert_includes page, "body.chats-min .chat-epic-head > :not(.chat-epic-chev):not(.chat-epic-glyph) { display: none; }",
                    "the shrunk strip keeps a glyph and the fold per block"
  end

  def test_an_item_in_an_epic_opens_its_side_panel_with_the_epic_and_crumbs_to_it
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
    assert_includes page_function(page, "renderChatSide"), "body.append(...[chatEpicSection(it)].filter(Boolean), workspaceSection(it));"
    side = page_function(page, "chatEpicSection")
    assert_includes side, %(sec.appendChild(el("h3", "", isEpic ? "This epic" : "Epic"));)
    assert_includes side, "if (!isEpic && desc)", "the epic's description only for a child; the epic's own shows below"
    assert_includes side, %(const open = children.filter(c => c.state !== "resolved");)
    assert_includes side, "r.onclick = () => selectChat(c.slug);"
    assert_includes side, %(if (!isEpic) chatEpicTodoList(sec, "Todos on this item", chatOpenTodosOn(it.slug), true);)
    assert_includes side, %(chatEpicTodoList(sec, "Todos on the epic", chatOpenTodosOn(epic.slug), false);)
    assert_includes page_function(page, "chatEpicTodoList"), '{ box.blur(); act("todo-done", { args: { id: t.id, done: true } }); }',
                    "a ticked box lets go of focus, or renderChatSide would hold the panel still"
    assert_includes page_function(page, "chatEpicTodoAdd"), 'act("todo-add", { args: { text: input.value.trim(), item: epic.slug } })'
    resolvable = page_function(page, "chatEpicResolvable")
    assert_includes resolvable, %(epic.state !== "resolved" && children.length > 0 &&)
    assert_includes resolvable, %(children.every(c => c.state === "resolved") && chatEpicOpenTodos(epic).length === 0)
    assert_includes page_function(page, "resolveEpic"), 'act("state", { slug: epic.slug, args: { state: "resolved" } })',
                    "suggest-only: the click runs the normal state change"
    chips = page_function(page, "epicLinkChips")
    assert_includes chips, %(a.href = l.url; a.target = "_blank"; a.rel = "noopener"; a.title = l.label;)

    assert_includes page_function(page, "renderChatMain"), "const crumb = chatEpicCrumb(it);\n    if (crumb) title.prepend(crumb);"
    crumb = page_function(page, "chatEpicCrumb")
    assert_includes crumb, %(const epic = it.kind === "epic" ? null : chatEpicOf(it);)
    assert_includes crumb, "c.onclick = () => selectChat(epic.slug);"
  end

  def test_the_epic_side_blocks_todo_actions_land_on_the_epic
    epic = Quartermaster::WorkItem.create("Epic Alpha", project: "WebApp", front: { "kind" => "epic" })
    epic.set_link("Tracker", "https://tracker.example/1")
    Quartermaster::WorkItem.create("First slice", project: "WebApp", front: { "epic" => epic.slug })
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    post = ->(payload) { JSON.parse(server.respond("POST", "/api/action", host, JSON.generate(payload))[2]) }

    added = post.call("cmd" => "todo-add", "args" => { "text" => "Write the rollout note", "item" => epic.slug })
    assert added["ok"], added["error"]
    state = JSON.parse(server.respond("GET", "/api/state", host, "")[2])
    todo = state["todos"].find { |t| t["text"] == "Write the rollout note" }
    assert_equal epic.slug, todo["item"]
    by_slug = state["items"].to_h { |i| [i["slug"], i] }
    assert_equal "epic", by_slug[epic.slug]["kind"]
    assert_equal epic.slug, by_slug["first-slice"]["epic"]
    assert_equal [{ "label" => "Tracker", "url" => "https://tracker.example/1" }], by_slug[epic.slug]["links"]

    assert post.call("cmd" => "todo-done", "args" => { "id" => todo["id"], "done" => true })["ok"]
    state = JSON.parse(server.respond("GET", "/api/state", host, "")[2])
    assert state["todos"].find { |t| t["id"] == todo["id"] }["done_at"], "the side block's checkbox ticks it"
  end

  def test_terminal_upgrades_need_our_origin_our_token_and_a_live_chat
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new(["live-one"]))
    path = ->(token, session = "live-one") { "/ws/terminal?session=#{session}&token=#{token}" }
    token = server.terminal_token

    assert_nil server.terminal.refusal(path.call(token), upgrade_headers)
    assert_nil server.terminal.refusal(path.call(token), upgrade_headers(origin: "http://localhost:4567"))
    assert_equal "bad origin", server.terminal.refusal(path.call(token), upgrade_headers(origin: "https://evil.example"))
    assert_equal "bad origin", server.terminal.refusal(path.call(token), upgrade_headers(origin: nil)),
                 "a browser always sends Origin on a WebSocket; none at all is not a page of ours"
    assert_equal "bad origin", server.terminal.refusal(path.call(token), upgrade_headers(origin: "http://127.0.0.1:9999"))
    assert_equal "bad token", server.terminal.refusal(path.call("nope"), upgrade_headers)
    assert_equal "bad token", server.terminal.refusal(path.call(""), upgrade_headers)
    assert_equal "bad token", server.terminal.refusal("/ws/terminal?session=live-one", upgrade_headers)
    assert_equal "bad host", server.terminal.refusal(path.call(token), upgrade_headers.merge("host" => "evil.example"))
    assert_equal "no such chat", server.terminal.refusal(path.call(token, "gone"), upgrade_headers)
    assert_equal "not found", server.terminal.refusal("/ws/other?token=#{token}", upgrade_headers)
  end

  def test_a_refused_upgrade_gets_a_403_over_the_wire
    server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new(["live-one"]))
    ours, theirs = UNIXSocket.pair
    request = "GET /ws/terminal?session=live-one&token=stolen HTTP/1.1\r\n" +
              upgrade_headers.map { |k, v| "#{k}: #{v}\r\n" }.join + "\r\n"
    theirs.write(request)
    server.send(:handle_client, ours)
    assert_match(/\AHTTP\/1.1 403 Forbidden.*bad token\z/m, theirs.read)
  end
end

# The whole pane path against a real tmux server: handshake, keystrokes in,
# screen out, resize, and the chat outliving the connection.
class TerminalBridgeTest < Minitest::Test
  include QmTestHelpers
  WS = Quartermaster::WebSocket

  def setup
    super
    skip "tmux not installed" unless system("command -v tmux >/dev/null")
    @tmux = Quartermaster::Tmux.new(socket: "qm-test-bridge-#{Process.pid}")
    @server = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: @tmux)
  end

  def teardown
    @tmux&.kill_server
  end

  def masked(payload, opcode)
    mask = [9, 8, 7, 6]
    [0x80 | opcode, 0x80 | payload.bytesize].pack("CC") + mask.pack("C*") +
      payload.bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }.pack("C*")
  end

  # Opens a pane connection and returns [socket, server thread] after the 101.
  def connect(name, cols: 90, rows: 30)
    ours, theirs = UNIXSocket.pair
    thread = Thread.new { @server.send(:handle_client, ours) }
    theirs.write("GET /ws/terminal?session=#{name}&token=#{@server.terminal_token}&cols=#{cols}&rows=#{rows} HTTP/1.1\r\n" \
                 "Host: 127.0.0.1:4567\r\nOrigin: http://127.0.0.1:4567\r\nUpgrade: websocket\r\n" \
                 "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
    response = +""
    response << theirs.readpartial(1) until response.end_with?("\r\n\r\n")
    assert_match(/101 Switching Protocols.*s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=/m, response)
    [theirs, thread]
  end

  # Collects server frames until the screen shows `text`.
  def read_until(sock, text, timeout = 5)
    seen = +""
    Timeout.timeout(timeout) do
      until seen.include?(text)
        b0, b1 = sock.read(2).unpack("CC")
        len = b1 & 0x7f
        len = sock.read(2).unpack1("n") if len == 126
        len = sock.read(8).unpack1("Q>") if len == 127
        data = sock.read(len)
        return [seen, :closed] if (b0 & 0x0f) == WS::CLOSE

        seen << data
      end
    end
    seen
  end

  def test_keystrokes_reach_the_chat_and_its_screen_comes_back
    @tmux.open("echo-chat", cwd: Dir.home, argv: %w[cat])
    sock, thread = connect("echo-chat")
    sock.write(masked("hello pane\r", WS::BINARY))
    assert_includes read_until(sock, "hello pane"), "hello pane"

    sock.write(masked(JSON.generate("cols" => 120, "rows" => 40), WS::TEXT))
    Timeout.timeout(5) do
      sleep 0.05 until Open3.capture2("tmux", "-L", @tmux.socket, "display", "-p", "-t", "=echo-chat:",
                                      '#{window_width}')[0].strip == "120"
    end

    sock.write(masked([1000].pack("n"), WS::CLOSE))
    thread.join(5)
    assert @tmux.live?("echo-chat"), "a closed pane (reload, GUI restart) leaves the chat running"

    again, = connect("echo-chat")
    assert_includes read_until(again, "hello pane"), "hello pane", "a reattach redraws the screen"
    again.close
  end

  def window_size(name)
    Open3.capture2("tmux", "-L", @tmux.socket, "display", "-p", "-t", "=#{name}:", '#{window_width}x#{window_height}')[0].strip
  end

  def assert_window_size(name, want, msg = nil)
    Timeout.timeout(5) { sleep 0.05 until window_size(name) == want }
  rescue Timeout::Error
    flunk "#{msg}: tmux window is #{window_size(name)}, wanted #{want}"
  end

  # window-size latest hands the window to whichever client attached or
  # resized last; re-sending an unchanged size must win it back.
  def test_a_repeated_size_takes_the_window_back_from_another_client
    @tmux.open("shared-chat", cwd: Dir.home, argv: %w[cat])
    mine, = connect("shared-chat", cols: 90, rows: 14)
    assert_window_size("shared-chat", "90x14", "the first client sizes the window")
    other, = connect("shared-chat", cols: 90, rows: 30)
    assert_window_size("shared-chat", "90x30", "a second client takes the window")

    mine.write(masked(JSON.generate("cols" => 90, "rows" => 14), WS::TEXT))
    assert_window_size("shared-chat", "90x14", "the pane re-sending its size reclaims the window")
  ensure
    mine&.close
    other&.close
  end

  def test_a_pane_smaller_than_five_rows_gets_that_many
    @tmux.open("short-chat", cwd: Dir.home, argv: %w[cat])
    sock, = connect("short-chat", cols: 90, rows: 2)
    assert_window_size("short-chat", "90x2", "a two-row pane")
    sock.write(masked(JSON.generate("cols" => 90, "rows" => 3), WS::TEXT))
    assert_window_size("short-chat", "90x3", "a resize to three rows")
  ensure
    sock&.close
  end

  def test_the_connection_closes_when_the_chat_ends
    @tmux.open("ending-chat", cwd: Dir.home, argv: ["sh", "-c", "read _; echo bye"])
    sock, thread = connect("ending-chat")
    sock.write(masked("\r", WS::BINARY))
    _, closed = read_until(sock, "\u0000never")
    assert_equal :closed, closed
    sock.close
    thread.join(5)
  end
end
