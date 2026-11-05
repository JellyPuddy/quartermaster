# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/board_mirror_test.rb`).
require_relative "test_helper"

class BoardMirrorTest < Minitest::Test
  include QmTestHelpers

  BOARD = "https://claude.ai/artifact/ExampleBoard123"
  OTHER = "https://claude.ai/artifact/OtherBoard123"
  OK = "Database update committed: \"tasks\"/\"x\". The document is now at version 2."

  def setup
    super
    FileUtils.mkdir_p(Quartermaster::ROOT)
    @path = File.join(Quartermaster::ROOT, "board-writes.jsonl")
  end

  # The PostToolUse stdin a hook receives for one ArtifactData call.
  def payload(input, response: OK, agent: nil, tool: "ArtifactData")
    p = { "session_id" => "sess-1", "hook_event_name" => "PostToolUse", "tool_name" => tool,
          "tool_input" => { "url" => BOARD }.merge(input), "tool_response" => response,
          "tool_use_id" => "toolu_1" }
    p.merge!("agent_id" => agent, "agent_type" => "general-purpose") if agent
    p
  end

  def write_op(action, doc_id, data = nil, **opts)
    input = { "action" => action, "collection" => "tasks", "doc_id" => doc_id }
    input["data"] = data if data
    payload(input, **opts)
  end

  def append(*entries)
    File.open(@path, "a") { |f| entries.each { |e| f.puts(e.is_a?(String) ? e : JSON.generate(e)) } }
  end

  def mirror = Quartermaster::BoardMirror.new(@path)

  def test_set_update_and_delete_fold_to_the_current_rows
    append(
      write_op("set", "a", { "status" => "queued", "title" => "Alpha", "order" => 1, "batch" => "b1",
                             "batchLabel" => "Build", "dependsOn" => [], "updatedAt" => "t1" }),
      write_op("set", "b", { "status" => "queued", "title" => "Beta", "order" => 2 }),
      write_op("update", "a", { "status" => "running", "note" => "migrating", "updatedAt" => "t2" }),
      write_op("delete", "b")
    )

    rows = mirror.rows(BOARD)

    assert_equal [{ "doc_id" => "a", "status" => "running", "title" => "Alpha", "note" => "migrating", "order" => 1,
                    "dependsOn" => [], "batch" => "b1", "batchLabel" => "Build", "updatedAt" => "t2" }], rows
  end

  def test_set_replaces_the_whole_document
    append(write_op("set", "a", { "status" => "running", "note" => "old", "title" => "A" }),
           write_op("set", "a", { "status" => "review", "title" => "A" }))

    row = mirror.row_for(BOARD, "a")
    assert_equal "review", row["status"]
    assert_nil row["note"]
  end

  def test_update_deep_merges_and_drops_delete_markers
    append(write_op("set", "a", { "title" => "A", "note" => "x", "meta" => { "k" => 1, "j" => 2 } }),
           write_op("update", "a", { "note" => { "__delete__" => true }, "meta" => { "j" => { "__delete__" => true }, "m" => 3 } }))

    doc = mirror.refresh.dig("ExampleBoard123", "tasks", "a")
    assert_equal({ "title" => "A", "meta" => { "k" => 1, "m" => 3 } }, doc)
  end

  def test_batch_applies_each_entry_in_order
    append(payload({ "action" => "batch", "url" => BOARD, "writes" => [
                     { "op" => "set", "collection" => "tasks", "doc_id" => "a", "data" => { "status" => "queued", "order" => 2 } },
                     { "op" => "set", "collection" => "tasks", "doc_id" => "b", "data" => { "status" => "queued", "order" => 1 } },
                     { "op" => "update", "collection" => "tasks", "doc_id" => "a", "data" => { "status" => "running" } },
                     { "op" => "set", "collection" => "tasks", "doc_id" => "c", "data" => { "status" => "queued" } },
                     { "op" => "delete", "collection" => "tasks", "doc_id" => "c" }
                   ] }))

    rows = mirror.rows(BOARD)
    assert_equal %w[b a], rows.map { |r| r["doc_id"] }, "board order, not write order"
    assert_equal %w[queued running], rows.map { |r| r["status"] }
  end

  # Every batch numbers its rows from 0, so plan order alone interleaves an
  # old run's rows with the current one's.
  def test_rows_come_newest_batch_first_then_in_plan_order
    append(write_op("set", "old-b", { "order" => 1, "batch" => "2026-10-01T09:00" }),
           write_op("set", "loose", { "order" => 0 }),
           write_op("set", "new-b", { "order" => 1, "batch" => "2026-10-20T09:00" }),
           write_op("set", "old-a", { "order" => 0, "batch" => "2026-10-01T09:00" }),
           write_op("set", "new-a", { "order" => 0, "batch" => "2026-10-20T09:00" }))

    assert_equal %w[new-a new-b old-a old-b loose], mirror.rows(BOARD).map { |r| r["doc_id"] }
  end

  # Sub-agent calls carry agent_id/agent_type; they are writes like any other.
  def test_a_sub_agent_write_counts
    append(write_op("set", "a", { "status" => "queued" }),
           write_op("update", "a", { "status" => "blocked", "note" => "which db?" }, agent: "agent-42"))

    assert_equal "blocked", mirror.row_for(BOARD, "a")["status"]
  end

  def test_str_replace_edits_a_field_in_place_like_the_database_would
    append(write_op("set", "a", { "status" => "running", "note" => "migrating schema, schema 2" }),
           payload({ "action" => "str_replace", "collection" => "tasks", "doc_id" => "a",
                     "field" => "note", "old_str" => "migrating", "new_str" => "migrated" }),
           payload({ "action" => "str_replace", "collection" => "tasks", "doc_id" => "a",
                     "field" => "note", "old_str" => "schema", "new_str" => "x" }),
           payload({ "action" => "str_replace", "collection" => "tasks", "doc_id" => "a",
                     "field" => "note", "old_str" => "schema", "new_str" => "db", "replace_all" => true }),
           payload({ "action" => "str_replace", "collection" => "tasks", "doc_id" => "a",
                     "field" => "note", "old_str" => "absent", "new_str" => "y" }))

    assert_equal "migrated db, db 2", mirror.row_for(BOARD, "a")["note"],
                 "an ambiguous or missing old_str writes nothing; replace_all changes every occurrence"
  end

  def test_reads_failed_writes_and_other_tools_leave_no_trace
    append(write_op("set", "a", { "status" => "running" }),
           payload({ "action" => "get", "collection" => "tasks", "doc_id" => "a" }),
           payload({ "action" => "list", "collection" => "tasks" }),
           payload({ "action" => "query", "collection" => "tasks" }),
           write_op("update", "a", { "status" => "x1" },
                    response: "Version mismatch: the document is now at version 3; nothing was written."),
           write_op("update", "a", { "status" => "x2" }, response: { "is_error" => true, "content" => "boom" }),
           write_op("update", "a", { "status" => "x3" }, response: [{ "type" => "text", "text" => "Error: refused" }]),
           write_op("update", "a", { "status" => "x4" }, response: "<tool_use_error>InputValidationError</tool_use_error>"),
           write_op("update", "a", { "status" => "x5" }, tool: "Write"))

    assert_equal "running", mirror.row_for(BOARD, "a")["status"]
  end

  def test_a_successful_response_shaped_as_content_parts_counts
    append(write_op("set", "a", { "status" => "running" }, response: [{ "type" => "text", "text" => OK }]))

    assert_equal "running", mirror.row_for(BOARD, "a")["status"]
  end

  def test_a_committed_write_to_a_row_named_like_a_failure_counts
    ok = "Database update committed: \"tasks\"/\"merge-conflict\". The document is now at version 2."
    append(write_op("set", "merge-conflict", { "status" => "running" }, response: ok))

    assert_equal "running", mirror.row_for(BOARD, "merge-conflict")["status"]
  end

  def test_wrapped_and_ts_prefixed_lines_are_both_accepted
    append({ "ts" => "2026-10-21T17:00:00Z", "payload" => write_op("set", "a", { "status" => "queued" }) },
           { "ts" => "2026-10-21T17:05:00Z" }.merge(write_op("set", "b", { "status" => "running" })))

    rows = mirror.rows(BOARD)
    assert_equal({ "a" => "2026-10-21T17:00:00Z", "b" => "2026-10-21T17:05:00Z" },
                 rows.to_h { |r| [r["doc_id"], r["updatedAt"]] }, "the hook ts stands in for a missing updatedAt")
  end

  def test_rows_are_kept_apart_per_board_and_url_spellings_agree
    append(write_op("set", "a", { "status" => "running" }),
           payload({ "action" => "set", "url" => OTHER, "collection" => "tasks", "doc_id" => "a", "data" => { "status" => "review" } }))

    assert_equal "running", mirror.row_for("#{BOARD}/", "a")["status"]
    assert_equal "running", mirror.row_for("https://claude.ai/code/artifact/ExampleBoard123?x=1", "a")["status"]
    assert_equal "review", mirror.row_for(OTHER, "a")["status"]
  end

  def test_garbage_lines_are_skipped
    append("not json", "[1,2]", write_op("set", "a", { "status" => "running" }))

    assert_equal 1, mirror.rows(BOARD).size
  end

  def test_refresh_is_incremental_and_waits_for_a_complete_line
    m = mirror
    append(write_op("set", "a", { "status" => "queued" }))
    assert_equal "queued", m.row_for(BOARD, "a")["status"]

    line = JSON.generate(write_op("update", "a", { "status" => "running" }))
    File.open(@path, "a") { |f| f.write(line[0, 20]) }
    assert_equal "queued", m.row_for(BOARD, "a")["status"], "a half-appended line is not folded yet"

    File.open(@path, "a") { |f| f.puts(line[20..]) }
    assert_equal "running", m.row_for(BOARD, "a")["status"]

    # Folding only appended bytes: a rewrite of already-read content would be invisible.
    File.write(@path, File.read(@path).sub("queued", "QUEUED"))
    append(write_op("update", "a", { "note" => "n" }))
    assert_equal "running", m.row_for(BOARD, "a")["status"]
    assert_equal "n", m.row_for(BOARD, "a")["note"]
  end

  def test_a_shrunken_file_is_refolded_from_the_start
    m = mirror
    append(write_op("set", "a", { "status" => "queued" }), write_op("set", "b", { "status" => "queued" }))
    assert_equal 2, m.rows(BOARD).size

    File.write(@path, "#{JSON.generate(write_op("set", "c", { "status" => "running" }))}\n")
    assert_equal %w[c], m.rows(BOARD).map { |r| r["doc_id"] }
  end

  def test_a_missing_file_means_no_rows
    assert_empty mirror.rows(BOARD)
  end

  def test_rows_for_maps_an_item_through_its_board_record
    item = Quartermaster::WorkItem.create("Alpha", project: "MyApp")
    append(write_op("set", "a", { "status" => "running" }))
    assert_empty mirror.rows_for(Quartermaster::WorkItem.find("alpha"))

    item.link_board(BOARD)
    assert_equal ["a"], mirror.rows_for(Quartermaster::WorkItem.find("alpha")).map { |r| r["doc_id"] }
  end

  def blocked_item(answers_dir)
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")
    Quartermaster::WorkItem.find("alpha").link_board(BOARD, answers_dir: answers_dir)
    append(write_op("set", "a", { "status" => "blocked", "note" => "which db?" }),
           write_op("set", "r", { "status" => "running" }))
    Quartermaster::WorkItem.find("alpha")
  end

  def test_answer_writes_the_file_a_blocked_agent_waits_for
    dir = File.join(Dir.mktmpdir("qm-answers"), "answers")
    item = blocked_item(dir)

    path = mirror.answer(item, "a", "Use the test DB")

    assert_equal File.join(dir, "a.md"), path
    assert_equal "Use the test DB\n", File.read(path)
    assert_equal ["a.md"], Dir.children(dir), "no temp file left behind"
  end

  def test_answer_refuses_rows_that_are_not_blocked_and_unsafe_ids
    dir = Dir.mktmpdir("qm-answers")
    item = blocked_item(dir)

    assert_raises(ArgumentError) { mirror.answer(item, "r", "x") }
    assert_raises(ArgumentError) { mirror.answer(item, "missing", "x") }
    assert_raises(ArgumentError) { mirror.answer(item, "../a", "x") }
    assert_raises(ArgumentError) { mirror.answer(item, "a", "  ") }
    assert_empty Dir.children(dir)
  end

  def test_answer_needs_an_answers_dir
    Quartermaster::WorkItem.create("Alpha", project: "MyApp")
    Quartermaster::WorkItem.find("alpha").link_board(BOARD)
    append(write_op("set", "a", { "status" => "blocked" }))

    error = assert_raises(ArgumentError) { mirror.answer(Quartermaster::WorkItem.find("alpha"), "a", "x") }
    assert_includes error.message, "answers directory"
  end

  def test_the_answers_dir_follows_its_board
    item = Quartermaster::WorkItem.create("Alpha", project: "MyApp")
    item.link_board(BOARD, answers_dir: "/tmp/run-1/answers")
    assert_equal "/tmp/run-1/answers", Quartermaster::WorkItem.find("alpha").board_answers_dir

    Quartermaster::WorkItem.find("alpha").link_board(BOARD)
    assert_equal "/tmp/run-1/answers", Quartermaster::WorkItem.find("alpha").board_answers_dir, "same board keeps it"

    Quartermaster::WorkItem.find("alpha").link_board(OTHER)
    assert_nil Quartermaster::WorkItem.find("alpha").board_answers_dir, "a new board drops the old run's directory"

    Quartermaster::WorkItem.find("alpha").link_board(OTHER, answers_dir: "/tmp/run-2/answers")
    Quartermaster::WorkItem.find("alpha").unlink_board
    refute_includes Quartermaster::WorkItem.find("alpha").front, "board_answers_dir"
  end
end
