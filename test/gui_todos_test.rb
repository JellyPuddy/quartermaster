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
end
