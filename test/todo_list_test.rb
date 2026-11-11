# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/todo_list_test.rb`).
require_relative "test_helper"

# The user's own to-do list: todos.json under the data root, and `qm todo`.
class TodoListTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    FileUtils.mkdir_p(Quartermaster::ROOT)
    @now = Time.utc(2026, 11, 10, 9, 0, 0)
  end

  def file = File.join(Quartermaster::ROOT, "todos.json")

  # Each call ticks the clock a minute, so done_at orders by call.
  def list
    Quartermaster::TodoList.new(clock: -> { @now += 60 })
  end

  def texts(todos) = todos.map { |t| t["text"] }

  def test_a_missing_file_is_an_empty_list
    assert_empty list.todos
    refute File.exist?(file)
  end

  def test_new_todos_go_on_top_and_the_file_carries_v1
    list.add("first")
    todo = list.add("  second  ")

    assert_equal %w[second first], texts(list.open)
    data = JSON.parse(File.read(file))
    assert_equal 1, data["v"]
    assert_equal "second", data["todos"][0]["text"]
    assert_match(/\A\h{8}\z/, todo["id"])
    assert_equal "2026-11-10T09:02:00Z", todo["created"]
    refute todo.key?("done_at")
  end

  def test_text_is_required_and_kept_to_one_line
    assert_raises(ArgumentError) { list.add("   ") }
    assert_equal "call the bank about it", list.add("call the bank\nabout it")["text"]
  end

  def test_move_before_and_after_a_neighbour
    a, b, c = %w[a b c].map { |t| list.add(t) }
    assert_equal %w[c b a], texts(list.open)

    list.move(a["id"], before: c["id"])
    assert_equal %w[a c b], texts(list.open)
    list.move(a["id"], after: b["id"])
    assert_equal %w[c b a], texts(list.open)
    list.move(c["id"], after: a["id"])
    assert_equal %w[b a c], texts(list.open)
    assert_raises(ArgumentError) { list.move(a["id"]) }
    assert_raises(ArgumentError) { list.move(a["id"], before: "nope") }
  end

  def test_done_keeps_the_todo_and_undone_clears_it
    todo = list.add("pay the invoice")
    list.done(todo["id"])

    assert_empty list.open
    assert_equal ["pay the invoice"], texts(list.done_recent)
    assert_equal "2026-11-10T09:02:00Z", list.todos.first["done_at"]

    list.undone(todo["id"])
    assert_equal ["pay the invoice"], texts(list.open)
    refute list.todos.first.key?("done_at")
  end

  def test_delete_removes_a_todo_outright
    keep = list.add("keep")
    gone = list.add("gone")
    list.delete(gone["id"])

    assert_equal [keep["id"]], list.todos.map { |t| t["id"] }
    assert_raises(ArgumentError) { list.delete(gone["id"]) }
  end

  def test_done_recent_is_the_twenty_newest_by_done_at
    todos = (1..25).map { |n| list.add("t#{n}") }
    todos.each { |t| list.done(t["id"]) }

    recent = list.done_recent
    assert_equal 20, recent.size
    assert_equal %w[t25 t24 t23], texts(recent.first(3))
    assert_equal "t6", recent.last["text"]
    assert_equal 25, list.todos.size
  end

  def test_unknown_fields_survive_a_rewrite
    File.write(file, JSON.generate("v" => 1, "extra" => { "x" => 1 },
                                   "todos" => [{ "id" => "abc", "text" => "old", "created" => "2026-01-01T00:00:00Z",
                                                 "colour" => "red" }]))
    list.add("new")

    data = JSON.parse(File.read(file))
    assert_equal({ "x" => 1 }, data["extra"])
    assert_equal "red", data["todos"].find { |t| t["id"] == "abc" }["colour"]
  end

  def test_a_corrupt_file_reads_as_empty_and_is_never_overwritten_by_a_read
    File.write(file, "{not json")

    assert_empty list.todos
    assert_empty list.open
    assert_equal "{not json", File.read(file)
    assert_match(/todos/, File.read(Quartermaster::LOG_FILE))
    assert_raises(ArgumentError) { list.add("would clobber it") }
    assert_equal "{not json", File.read(file)
  end

  def test_a_corrupt_file_is_logged_once_per_outage_and_its_fix_once
    File.write(file, "{not json")
    3.times { list.todos }
    failures = File.readlines(Quartermaster::LOG_FILE, chomp: true).reject { |line| line.start_with?(" ") }
    assert_equal 1, failures.size
    assert_match(/\[todos\] JSON::ParserError/, failures.first)

    File.write(file, JSON.generate({ "v" => 1, "todos" => [] }))
    2.times { list.todos }
    headers = File.readlines(Quartermaster::LOG_FILE, chomp: true).reject { |line| line.start_with?(" ") }
    assert_equal 2, headers.size
    assert_match(/\[todos\] recovered after 3 failures\z/, headers.last)
  end

  def test_a_gui_state_build_reads_the_list_once
    reads = 0
    counting = list
    counting.define_singleton_method(:todos) { (reads += 1) && super() }
    counting.add("one")

    reads = 0
    Quartermaster::GuiTodoActions.payload(counting, items: {})
    assert_equal 1, reads
  end

  def test_the_project_is_dropped_when_an_item_is_set
    Quartermaster::WorkItem.create("Ship it", project: "App")
    on_item = list.add("check the deploy", item: "ship-it", project: "App")
    assert_equal "ship-it", on_item["item"]
    refute on_item.key?("project")

    todo = list.add("ask Sam", project: "App")
    assert_equal "App", todo["project"]
    list.done(todo["id"], item: "ship-it")
    stored = list.todos.find { |t| t["id"] == todo["id"] }
    assert_equal "ship-it", stored["item"]
    refute stored.key?("project")
    assert stored["done_at"]
  end

  def test_edit_changes_text_and_project
    todo = list.add("draft", project: "App")
    list.edit(todo["id"], text: "final")
    assert_equal "App", list.todos.first["project"]
    list.edit(todo["id"], project: "")
    assert_equal "final", list.todos.first["text"]
    refute list.todos.first.key?("project")
    assert_raises(ArgumentError) { list.edit(todo["id"], text: " ") }
  end

  def test_an_unknown_item_is_refused
    assert_raises(ArgumentError) { list.add("x", item: "no-such-item") }
  end

  def test_edit_moves_a_todo_onto_an_item_and_off_it_keeping_the_items_project
    Quartermaster::WorkItem.create("Ship it", project: "App")
    todo = list.add("check the deploy", project: "Home")

    list.edit(todo["id"], item: "ship-it")
    assert_equal({ "item" => "ship-it" }, list.todos.first.slice("item", "project"))
    list.edit(todo["id"], item: "")
    assert_equal({ "project" => "App" }, list.todos.first.slice("item", "project"))
  end

  def test_edit_off_an_item_without_a_project_leaves_none_and_an_unknown_item_is_refused
    Quartermaster::WorkItem.create("Loose thing", project: Quartermaster::ProjectMap::NO_PROJECT)
    todo = list.add("think", item: "loose-thing")

    assert_raises(ArgumentError) { list.edit(todo["id"], item: "no-such-item") }
    assert_equal "loose-thing", list.todos.first["item"]
    list.edit(todo["id"], item: "")
    assert_equal({}, list.todos.first.slice("item", "project"))
  end

  def qm(*argv)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_ITEM" => "ship-it", "QM_ASIDE" => nil, "QM_LOOSE" => nil },
                   RbConfig.ruby, QM_BIN, "todo", *argv)
  end

  def test_the_cli_adds_lists_by_number_and_ticks_by_number
    Quartermaster::WorkItem.create("Ship it", project: "App")
    assert qm("add", "renew the passport").last.success?
    assert qm("add", "check the deploy", "--item", "ship-it").last.success?
    assert qm("add", "--project", "Home", "- fix the tap").last.success?

    out, err, status = qm("list")
    assert status.success?, err
    assert_equal <<~OUT, out
      1. - fix the tap  [Home]
      2. check the deploy  [App · ship-it]
      3. renew the passport
    OUT
    refute list.todos.find { |t| t["text"] == "renew the passport" }.key?("item"), "QM_ITEM is never inferred"

    _out, err, status = qm("done", "2")
    assert status.success?, err
    out, = qm("list")
    assert_equal "1. - fix the tap  [Home]\n2. renew the passport\n", out
    assert_equal "check the deploy", list.done_recent.first["text"]
  end

  def test_the_cli_refuses_bad_input
    Quartermaster::WorkItem.create("Ship it", project: "App")
    _out, err, status = qm("add", "x", "--item", "nope")
    refute status.success?
    assert_includes err, "no work item 'nope'"

    _out, err, status = qm("add", "x", "--item", "ship-it", "--project", "App")
    refute status.success?
    assert_includes err, "--item or --project"

    _out, err, status = qm("done", "1")
    refute status.success?
    assert_includes err, "no open todo 1"
    refute qm("add").last.success?
    assert_empty list.todos
  end
end
