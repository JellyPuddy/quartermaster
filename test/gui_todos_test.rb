# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/gui_todos_test.rb`).
require_relative "test_helper"

# The Todos tab's server side: the todo-* actions through the router, the
# state's todos and the pulse a CLI add moves.
class GuiTodosTest < Minitest::Test
  include QmTestHelpers

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def server = @server ||= Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
  def file = File.join(Quartermaster::ROOT, "todos.json")

  def respond(payload, headers = ok_host)
    status, _type, body = server.respond("POST", "/api/action", headers, JSON.generate(payload))
    [status, status == "200 OK" ? JSON.parse(body) : body]
  end

  def act(cmd, **args) = respond({ "cmd" => cmd, "args" => args.transform_keys(&:to_s) })[1]
  def todos = JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])["todos"]
  def pulse = JSON.parse(server.respond("GET", "/api/pulse", ok_host, "")[2])
  def texts = todos.map { |t| t["text"] }
  def stored = JSON.parse(File.read(file))["todos"]

  def setup
    super
    FileUtils.mkdir_p(Quartermaster::ROOT)
  end

  def test_add_puts_the_todo_on_top_with_its_project
    act("todo-add", text: "first")
    reply = act("todo-add", text: "  call the bank  ", project: "Home")

    assert_equal true, reply["ok"]
    assert_equal "call the bank", reply["todo"]["text"]
    assert_equal ["call the bank", "first"], texts
    assert_equal({ "text" => "call the bank", "project" => "Home" }, stored[0].slice("text", "project", "item"))
  end

  def test_add_on_an_item_shows_the_items_project_and_title
    item = Quartermaster::WorkItem.create("Fix the login", project: "WebApp")
    act("todo-add", text: "ask Sam about SSO", item: item.slug, project: "Ignored")

    todo = todos.first
    assert_equal ["ask Sam about SSO", item.slug, "WebApp", "Fix the login", nil],
                 todo.values_at("text", "item", "project", "itemTitle", "done_at")
    refute stored[0].key?("project")
    assert_match(/\A\d{4}-\d\d-\d\dT/, todo["created"])
    assert_match(/\A\h{8}\z/, todo["id"])
  end

  def test_add_refuses_empty_text_and_an_unknown_item
    assert_equal [false, "a todo needs text"], act("todo-add", text: "  ").values_at("ok", "error")
    refute act("todo-add", text: "x", item: "no-such-item")["ok"]
    refute File.exist?(file)
  end

  def test_edit_changes_text_and_project_and_clears_the_project_on_empty
    id = act("todo-add", text: "draft", project: "Home")["todo"]["id"]

    assert act("todo-edit", id: id, text: "final")["ok"]
    assert_equal ["final", "Home"], todos.first.values_at("text", "project")
    act("todo-edit", id: id, project: "Work")
    assert_equal ["final", "Work"], todos.first.values_at("text", "project")
    act("todo-edit", id: id, project: "")
    assert_nil todos.first["project"]
  end

  def test_edit_moves_a_todo_to_an_epic_or_item_and_back_and_refuses_an_unknown_slug
    epic = Quartermaster::WorkItem.create("Epic Alpha", project: "WebApp", front: { "kind" => "epic" })
    id = act("todo-add", text: "write the brief", project: "Home")["todo"]["id"]

    assert act("todo-edit", id: id, item: epic.slug)["ok"]
    assert_equal [epic.slug, "WebApp", "Epic Alpha"], todos.first.values_at("item", "project", "itemTitle")
    refute act("todo-edit", id: id, item: "no-such-item")["ok"]
    assert_equal epic.slug, stored.first["item"]
    assert act("todo-edit", id: id, item: "")["ok"]
    assert_equal [nil, "WebApp"], stored.first.values_at("item", "project")
  end

  def test_move_places_a_todo_before_or_after_a_neighbour
    c, b, a = %w[c b a].map { |t| act("todo-add", text: t)["todo"]["id"] }
    assert_equal %w[a b c], texts

    assert act("todo-move", id: a, after: c)["ok"]
    assert_equal %w[b c a], texts
    act("todo-move", id: c, before: b)
    assert_equal %w[c b a], texts
    assert_equal [false, "move needs before or after"], act("todo-move", id: a).values_at("ok", "error")
  end

  def test_done_ticks_and_unticks_and_the_todo_stays
    id = act("todo-add", text: "pay rent")["todo"]["id"]

    assert act("todo-done", id: id, done: true)["ok"]
    assert_match(/\A\d{4}-\d\d-\d\dT.*Z\z/, todos.first["done_at"])
    act("todo-done", id: id, done: false)
    assert_nil todos.first["done_at"]
    assert_equal 1, stored.size
  end

  def test_delete_removes_a_todo_and_an_unknown_id_is_an_error
    id = act("todo-add", text: "gone soon")["todo"]["id"]

    assert act("todo-delete", id: id)["ok"]
    assert_empty todos
    assert_equal [false, "no todo '#{id}'"], act("todo-delete", id: id).values_at("ok", "error")
  end

  def test_a_foreign_or_missing_origin_is_refused
    payload = { "cmd" => "todo-add", "args" => { "text" => "sneaky" } }

    assert_equal ["403 Forbidden", "bad origin"],
                 respond(payload, { "host" => "127.0.0.1:4567", "origin" => "https://evil.example" })
    assert_equal ["403 Forbidden", "no origin"], respond(payload, { "host" => "127.0.0.1:4567" })
    refute File.exist?(file)
  end

  def test_the_plain_todo_actions_skip_the_action_mutex
    assert_empty %w[todo-add todo-edit todo-move todo-done todo-delete] - Quartermaster::GuiActions::UNLOCKED
  end

  def test_to_item_creates_the_item_starts_its_chat_in_the_main_checkout_and_ties_the_todo
    root = Dir.mktmpdir("qm-webapp")
    configure_projects({ "WebApp" => root })
    id = act("todo-add", text: "renew the cert", project: "Home")["todo"]["id"]

    reply = act("todo-to-item", id: id, title: "Renew the TLS cert", project: "WebApp", prompt: "renew the cert")

    assert_equal [true, "renew-the-tls-cert", "start"], reply.values_at("ok", "slug", "mode")
    item = Quartermaster::WorkItem.find("renew-the-tls-cert")
    assert_equal ["Renew the TLS cert", "WebApp"], [item.title, item.project]
    opened = server.instance_variable_get(:@tmux).opened
    assert_equal 1, opened.size
    assert_equal ["renew-the-tls-cert", root, "renew-the-tls-cert"],
                 [opened[0][:name], opened[0][:cwd], opened[0][:env]["QM_ITEM"]]
    assert_equal "renew the cert", opened[0][:argv].last
    todo = stored.first
    assert_equal "renew-the-tls-cert", todo["item"]
    refute todo.key?("project")
    assert_match(/\A\d{4}-\d\d-\d\dT/, todo["done_at"])
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_to_item_on_an_epics_todo_or_a_childs_puts_the_new_item_in_that_epic
    epic = Quartermaster::WorkItem.create("Epic Alpha", project: "WebApp", front: { "kind" => "epic" })
    child = Quartermaster::WorkItem.create("First slice", project: "WebApp", front: { "epic" => epic.slug })
    plain = Quartermaster::WorkItem.create("Lone item", project: "WebApp")
    on_epic, on_child, on_plain = [epic, child, plain].map { |it| act("todo-add", text: "x", item: it.slug)["todo"]["id"] }

    act("todo-to-item", id: on_epic, title: "From the epic", project: "WebApp")
    act("todo-to-item", id: on_child, title: "From the child", project: "WebApp")
    act("todo-to-item", id: on_plain, title: "From the lone item", project: "WebApp")

    assert_equal [epic.slug, epic.slug, nil],
                 %w[from-the-epic from-the-child from-the-lone-item].map { |slug| Quartermaster::WorkItem.find(slug).epic }
  end

  def test_to_item_without_a_prompt_starts_a_bare_chat
    id = act("todo-add", text: "tidy the garage")["todo"]["id"]

    reply = act("todo-to-item", id: id, title: "Tidy the garage", project: "Home", prompt: "  ")

    assert reply["ok"], reply["error"]
    assert_equal Quartermaster::Launcher.new.chat_command, server.instance_variable_get(:@tmux).opened[0][:argv]
  end

  def test_to_item_with_an_unknown_todo_or_no_title_creates_nothing
    assert_equal [false, "no todo 'nope'"], act("todo-to-item", id: "nope", title: "Anything", project: "Home").values_at("ok", "error")
    id = act("todo-add", text: "keep me open")["todo"]["id"]
    assert_equal [false, "title is required"], act("todo-to-item", id: id, title: " ", project: "Home").values_at("ok", "error")

    assert_empty Quartermaster::WorkItem.all
    assert_empty server.instance_variable_get(:@tmux).opened
    assert_nil todos.first["done_at"]
  end

  def test_to_item_ties_the_todo_even_when_the_chat_fails_to_start
    id = act("todo-add", text: "call the bank")["todo"]["id"]
    broken = Object.new
    def broken.open(*, **) = raise(StandardError, "tmux is gone")

    assert_raises(StandardError) { Quartermaster::GuiTodoActions.new.to_item({ "id" => id, "title" => "Call the bank" }, tmux: broken) }

    assert_equal "call-the-bank", stored.first["item"]
  end

  def test_to_item_is_refused_from_a_foreign_origin_and_not_local
    payload = { "cmd" => "todo-to-item", "args" => { "id" => "x", "title" => "t" } }

    assert_equal ["403 Forbidden", "no origin"], respond(payload, { "host" => "127.0.0.1:4567" })
    refute_includes Quartermaster::LoopbackGuard::LOCAL_ACTIONS, "todo-to-item"
    assert_empty Quartermaster::WorkItem.all
  end

  def test_state_lists_open_todos_in_order_then_the_twenty_newest_done
    clock = Time.utc(2026, 11, 10, 9, 0, 0)
    list = Quartermaster::TodoList.new(clock: -> { clock += 60 })
    ids = (1..23).map { |n| list.add("done #{n}")["id"] }
    ids.each { |id| list.done(id) }
    list.add("open low")
    list.add("open top")

    assert_equal ["open top", "open low"] + (4..23).to_a.reverse.map { |n| "done #{n}" }, texts
  end

  def test_an_empty_list_is_an_empty_array
    assert_equal [], todos
  end

  def test_a_cli_add_moves_the_pulse
    before = pulse
    Quartermaster::TodoList.new.add("from the terminal")
    after = pulse

    refute_equal before["pulse"], after["pulse"]
    refute_equal before["todos"], after["todos"]
  end

  def page = served_page(server, ok_host)

  def test_the_todos_tab_is_a_header_mode_after_issues_on_t
    html = page

    ['<button data-mode="todos" aria-pressed="false" title="Your own to-do list (t)">Todos <span id="todos-badge"></span></button>',
     '<link rel="stylesheet" href="/assets/css/todos.css">', '<input id="todo-add-input"', '<select id="todo-add-project"',
     '<div class="td-filters" id="todo-filters"', '<div class="td-body" id="todo-body"></div>',
     '<span class="grp"><kbd>t</kbd><span>todos</span></span>', '<span class="grp todos-only"><kbd>x</kbd><span>done</span></span>',
     'if (e.key === "t") { e.preventDefault(); setMode(mode === "todos" ? "board" : "todos"); return; }',
     'if (mode === "todos") return todoKey(e);', '["chat", "prs", "issues", "todos", "settings"].includes(savedMode)',
     'else if (m === "todos") renderTodos();', "renderTodosBadge();", 'if (mode === "todos") renderTodos();',
     "todos = st.todos || [];", 'body:not([data-mode="todos"]) .td-wrap'].each { |seam| assert_includes html, seam }
    assert_operator html.index('data-mode="issues"'), :<, html.index('data-mode="todos"')
    assert_operator html.index("/assets/js/todos.js"), :<, html.index("/assets/js/events.js")
  end

  def test_the_todos_tab_posts_the_todo_actions_and_moves_against_the_visible_neighbour
    html = page

    ['act("todo-add", { args: { text, project } })', 'act("todo-done", { args: { id: t.id, done: !t.done_at } })',
     'act("todo-delete", { args: { id: t.id } })', 'act("todo-edit", { args })',
     'moveTodoNextTo(t, d > 0 ? "after" : "before", neighbour.id)',
     'optimisticAct(change, "todo-move", { args: { id: t.id, [where]: neighbourId } })',
     "const open = todoVisibleOpen();",
     'act("todo-to-item", { args: { id: t.id, title, project, prompt: ta.value.trim() } })',
     "if (it) openChat(it);", 'localStorage.setItem("qm-todo-project", project)'].each { |seam| assert_includes html, seam }
  end

  def test_the_todos_tab_draws_the_epic_outline_and_moves_a_todo_with_todo_edit
    html = page

    ["renderTodoOutline(body);", "const todoVisibleOpen = () => todoOutlineRows();",
     "const open = todoVisibleOpen().filter(r => todoGroup(r) === todoGroup(t));",
     'act("todo-add", { args: { text, item: e.slug } })', 'const pick = o => { closePop(); moveTodoTo(t, o.slug); };',
     'optimisticAct(change, "todo-edit", { args: { id: t.id, item: slug } })',
     'add("Move to epic / item…", () => todoMovePicker(anchor, t));', 'localStorage.setItem("qm-todo-epics-collapsed"',
     '{ slug: "", label: "— nothing (just its project)", cls: "none" }', ".tde-node {"].each { |seam| assert_includes html, seam }
    assert_operator html.index("/assets/js/todos.js"), :<, html.index("/assets/js/todos-outline.js")
    assert_operator html.index("/assets/js/todos-outline.js"), :<, html.index("/assets/js/events.js")
  end

  def page_function(html, name)
    html[/^function #{name}\(.*?^}$/m] or flunk("no function #{name} on the page")
  end

  # A todo's drag: between rows of its own group it reorders; on an epic's head,
  # an item row, "Not in an epic" or another group's row it moves the todo onto
  # that item with the todo-edit ⋯ → Move to posts. Its own drag type keeps an
  # item's drag or a file out, and an item's drag stays epic-drop.js's.
  def test_a_todo_drag_moves_it_onto_a_head_and_reorders_between_rows
    html = page

    {
      "todoEpicNode" => "todoDropTarget(head, e.slug);",
      "todoChildRow" => "todoDropTarget(r, it.slug);",
      "renderTodoOutline" => 'todoDropTarget(head, "");'
    }.each { |fn, seam| assert_includes page_function(html, fn), seam, fn }
    drop = page_function(html, "todoDropAt")
    assert_includes drop, "e.dataTransfer.types.includes(TODO_DRAG_TYPE)", "an item's drag or a file is not a todo's"
    assert_includes drop, 'const onto = e.target.closest("[data-todo-drop]");'
    assert_includes drop, "if (row && row.dataset.group === todoGroup(t)) {", "its own group's rows reorder"
    assert_includes drop, 'row.dataset.group === "loose" ? ""', "a loose row takes it off its item"
    assert_includes drop, 'const bare = e.target.id === "todo-body";', "so does the body's bare part, as for an item"
    assert_includes drop, ': bare ? "" : null;'
    assert_includes drop, "if (slug === null || slug === (t.item || \"\")) return null;", "a drop where it already is posts nothing"
    assert_includes html, "e.dataTransfer.setData(TODO_DRAG_TYPE, t.id);"
    assert_includes html, "if (d.row) moveTodoNextTo(d.t, d.where, d.row.dataset.id);\n  else moveTodoTo(d.t, d.item);"
    assert_includes page_function(html, "todoDropMark"), "epicDropMark(d && d.head);", "a move lights the head up, a reorder draws a line"
    assert_operator html.index("/assets/js/epic-drop.js"), :<, html.index("/assets/js/todos-drag.js"), "it marks the body with epicDropTarget at load"
    assert_operator html.index("/assets/js/todos-drag.js"), :<, html.index("/assets/js/events.js")
  end

  # Plan decision 13: resolving an epic from the Todos outline opens the cleanup plan like the board.
  def test_the_todos_outline_resolves_an_epic_through_changestate
    html = page
    node = html[/^function todoEpicNode\(.*?^}$/m] or flunk("no todoEpicNode on the page")
    assert_includes node, "const suggest = resolveSuggestion(e);"
    assert_includes node, "head.appendChild(linkChips(e));"
    refute_includes node, 'act("state"', "no resolve that skips changeState's cleanup modal"
    assert_includes html[/^function resolveSuggestion\(.*?^}$/m].to_s, 'changeState(e, "resolved")'
  end

  def test_the_todos_badge_is_not_in_the_tab_title
    refute_match(/document\.title[^\n]*todo/i, page)
  end
end
