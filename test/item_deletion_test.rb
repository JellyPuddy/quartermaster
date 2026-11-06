# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/item_deletion_test.rb`).
require_relative "test_helper"

class ItemDeletionTest < Minitest::Test
  include QmTestHelpers

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def path(slug) = Quartermaster::WorkItem.path_for(slug)

  def socket = ENV.fetch("QM_TMUX_SOCKET")

  # Both chat names answered as not running, unless the test scripts otherwise.
  def runner(live: [])
    FakeRunner.new(["tmux"] => ->(argv) { ["", "", live.include?(argv.last.delete_prefix("="))] })
  end

  def qm(runner, *argv)
    exited = nil
    out, err = capture_io do
      Quartermaster::CLI.new(runner: runner).run(argv)
    rescue SystemExit => e
      exited = e.status
    end
    [out, err, exited]
  end

  # An item holding a bit of everything the guard looks at.
  def busy_item
    item = Quartermaster::WorkItem.create("Busy", project: "MyApp", branch: "issue/1-a", session_id: "s1",
                                                  description: "Real work")
    item.attach_session("s2")
    item.link_branch("issue/1-b")
    item.add_note("first")
    item.add_note("second")
    item.add_note("third")
    item.link_board("https://claude.ai/artifact/abc")
    item
  end

  def test_deletes_an_item_qm_new_left_empty
    Quartermaster::WorkItem.create("Oops", project: "MyApp", session_id: "s1")

    out, err, exited = qm(runner, "delete", "oops")

    assert_nil exited, err
    assert_equal "deleted oops\n", out
    refute File.exist?(path("oops"))
    assert_nil Quartermaster::WorkItem.for_session("s1")
  end

  def test_refuses_an_item_holding_work_and_names_what_it_holds
    busy_item
    fake = runner

    out, err, exited = qm(fake, "delete", "busy")

    assert_equal 1, exited
    assert_equal "", out
    assert_includes err, "'busy' holds 3 notes, 2 branches, 2 sessions, board set, a description"
    assert_includes err, "--force"
    assert_includes err, "qm cleanup busy"
    assert File.exist?(path("busy"))
    assert_empty fake.calls, "a refusal kills no chat"
  end

  def test_each_kind_of_content_alone_refuses
    { "a note" => ->(i) { i.add_note("x") }, "a branch" => ->(i) { i.link_branch("b") },
      "a second session" => ->(i) { i.attach_session("s2") }, "a board" => ->(i) { i.link_board("https://b") },
      "a description" => ->(i) { i.describe("Something real") } }.each do |what, add|
      item = Quartermaster::WorkItem.create("Item", project: "MyApp", session_id: "s1")
      add.call(item)

      assert_raises(Quartermaster::ItemDeletion::NotEmpty, what) { Quartermaster::ItemDeletion.new(runner: runner).call("item") }
      File.delete(path("item"))
    end
  end

  def test_force_deletes_an_item_holding_work
    busy_item

    out, err, exited = qm(runner, "delete", "busy", "--force")

    assert_nil exited, err
    assert_equal "deleted busy\n", out
    refute File.exist?(path("busy"))
  end

  def test_kills_the_items_chat_and_aside_through_the_runner
    Quartermaster::WorkItem.create("Chatty", project: "MyApp")
    fake = runner(live: ["chatty"])

    killed = Quartermaster::ItemDeletion.new(runner: fake).call("chatty")

    assert_equal ["chatty"], killed, "the aside wasn't running, which is no error"
    assert_equal [["tmux", "-L", socket, "kill-session", "-t", "=chatty"],
                  ["tmux", "-L", socket, "kill-session", "-t", "=chatty--aside"]], fake.argvs
  end

  def test_leaves_the_append_only_logs_alone
    Quartermaster::WorkItem.create("Logged", project: "MyApp", session_id: "s1")
    logs = %w[sessions.jsonl events.jsonl board-writes.jsonl].to_h do |name|
      file = File.join(Quartermaster::ROOT, name)
      File.write(file, "{\"v\":1,\"slug\":\"logged\"}\n")
      [file, File.read(file)]
    end

    Quartermaster::ItemDeletion.new(runner: runner).call("logged")

    logs.each { |file, before| assert_equal before, File.read(file), file }
  end

  def test_an_unknown_or_unusable_slug_errors_cleanly
    fake = runner
    _out, err, exited = qm(fake, "delete", "nope")
    assert_equal 1, exited
    assert_includes err, "no work item 'nope'"

    _out, err, exited = qm(fake, "delete", "../config")
    assert_equal 1, exited
    assert_includes err, "not a work item slug"

    _out, err, exited = qm(fake, "delete")
    assert_equal 1, exited
    assert_includes err, "usage: qm delete SLUG [--force]"
    assert_empty fake.calls
  end

  def test_gui_delete_refuses_with_what_it_holds_then_deletes_when_forced
    busy_item
    fake = runner(live: ["busy"])
    server = Quartermaster::Gui.new(port: 4567, runner: fake)

    refused = post(server, "cmd" => "delete", "slug" => "busy")
    assert_equal false, refused["ok"]
    assert_equal true, refused["needs_force"]
    assert_equal ["3 notes", "2 branches", "2 sessions", "board set", "a description"], refused["held"]
    assert File.exist?(path("busy"))

    forced = post(server, "cmd" => "delete", "slug" => "busy", "args" => { "force" => true })
    assert_equal({ "ok" => true, "deleted" => "busy", "killed" => ["busy"] }, forced)
    refute File.exist?(path("busy"))
    refute(server.respond("GET", "/api/state", ok_host, "")[2].then { |b| JSON.parse(b)["items"] }.any? { |i| i["slug"] == "busy" })
  end

  def test_gui_delete_of_an_empty_item_needs_no_force
    Quartermaster::WorkItem.create("Oops", project: "MyApp")

    reply = post(Quartermaster::Gui.new(port: 4567, runner: runner), "cmd" => "delete", "slug" => "oops")

    assert_equal true, reply["ok"]
    refute File.exist?(path("oops"))
  end

  def test_gui_refuses_a_delete_posted_without_our_origin
    Quartermaster::WorkItem.create("Oops", project: "MyApp")
    server = Quartermaster::Gui.new(port: 4567, runner: runner)

    status, = server.respond("POST", "/api/action", { "host" => "127.0.0.1:4567" }, JSON.generate("cmd" => "delete", "slug" => "oops"))

    assert_equal "403 Forbidden", status
    assert File.exist?(path("oops"))
  end

  def test_the_detail_sheet_offers_delete_with_an_in_page_confirmation
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner), ok_host)

    assert_includes page, "deleteItemModal(it)"
    assert_includes page, 'act("delete"'
    refute_match(/window\.confirm|[^.\w]confirm\(/, page[/function deleteItemModal.*?\n}\n/m])
  end

  private

  def post(server, payload)
    status, _type, body = server.respond("POST", "/api/action", ok_host, JSON.generate(payload))
    assert_equal "200 OK", status
    JSON.parse(body)
  end
end
