# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/gui_epic_test.rb`).
require_relative "test_helper"

# The board's epic actions through the router: a new item that is an epic or
# sits in one, setting and clearing an item's epic, an epic's links.
class GuiEpicTest < Minitest::Test
  include QmTestHelpers

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  def server = @server ||= Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

  def respond(payload, headers = ok_host)
    status, _type, body = server.respond("POST", "/api/action", headers, JSON.generate(payload))
    [status, status == "200 OK" ? JSON.parse(body) : body]
  end

  def act(cmd, slug = nil, **args) = respond({ "cmd" => cmd, "slug" => slug, "args" => args.transform_keys(&:to_s) })[1]
  def item(slug) = Quartermaster::WorkItem.find(slug)
  def epic!(title = "Epic Alpha") = Quartermaster::WorkItem.create(title, project: "Nowhere", front: { "kind" => "epic" })

  def test_new_makes_an_epic_when_asked_for_that_kind
    reply = act("new", title: "Epic Alpha", project: "Nowhere", kind: "epic")

    assert_equal({ "ok" => true, "slug" => "epic-alpha" }, reply)
    assert item("epic-alpha").epic?
  end

  def test_new_refuses_any_other_kind
    reply = act("new", title: "Sneaky", project: "Nowhere", kind: "automation")

    assert_equal false, reply["ok"]
    assert_match(/kind/, reply["error"])
    refute File.exist?(Quartermaster::WorkItem.path_for("sneaky"))
  end

  def test_new_puts_the_item_in_the_chosen_epic
    epic!
    reply = act("new", title: "First slice", project: "Nowhere", epic: "epic-alpha")

    assert reply["ok"]
    assert_equal "epic-alpha", item("first-slice").epic
  end

  def test_new_refuses_an_epic_target_that_is_not_an_epic
    Quartermaster::WorkItem.create("Plain", project: "Nowhere")
    reply = act("new", title: "First slice", project: "Nowhere", epic: "plain")

    assert_equal false, reply["ok"]
    assert_match(/not an epic/, reply["error"])
    refute File.exist?(Quartermaster::WorkItem.path_for("first-slice"))
  end

  def test_new_with_a_blank_epic_makes_a_plain_item
    act("new", title: "Loose", project: "Nowhere", epic: "", kind: "")

    assert_nil item("loose").epic
    refute item("loose").epic?
  end

  def test_epic_set_moves_an_item_into_an_epic_and_clear_takes_it_out
    epic!
    Quartermaster::WorkItem.create("Child", project: "Nowhere")

    assert_equal true, act("epic-set", "child", epic: "epic-alpha")["ok"]
    assert_equal "epic-alpha", item("child").epic

    assert_equal true, act("epic-set", "child", epic: "")["ok"]
    assert_nil item("child").epic
  end

  def test_epic_set_refuses_an_epic_inside_an_epic
    epic!
    epic!("Epic Beta")
    reply = act("epic-set", "epic-beta", epic: "epic-alpha")

    assert_equal false, reply["ok"]
    assert_match(/one level/, reply["error"])
    assert_nil item("epic-beta").epic
  end

  def test_epic_make_and_unmake_turn_an_item_into_an_epic_and_back
    Quartermaster::WorkItem.create("Big plan", project: "Nowhere")

    assert_equal true, act("epic-make", "big-plan")["ok"]
    assert item("big-plan").epic?
    assert_equal true, act("epic-unmake", "big-plan")["ok"]
    refute item("big-plan").epic?
  end

  def test_epic_make_and_unmake_refuse_what_the_rules_forbid
    epic!
    Quartermaster::WorkItem.create("Child", project: "Nowhere", front: { "epic" => "epic-alpha" })

    reply = act("epic-make", "child")
    assert_equal false, reply["ok"]
    assert_match(/--clear/, reply["error"])
    reply = act("epic-unmake", "epic-alpha")
    assert_equal false, reply["ok"]
    assert_match(/1 item is still in 'epic-alpha'/, reply["error"])
    assert item("epic-alpha").epic?
    refute item("child").epic?
  end

  def test_link_set_adds_and_replaces_by_label_and_remove_drops_it
    epic!
    act("link-set", "epic-alpha", label: "Tracker", url: "https://example.com/t/1")
    act("link-set", "epic-alpha", label: "Tracker", url: "https://example.com/t/2")
    act("link-set", "epic-alpha", label: "Notes", url: "https://example.com/n")

    assert_equal [{ "label" => "Tracker", "url" => "https://example.com/t/2" }, { "label" => "Notes", "url" => "https://example.com/n" }],
                 item("epic-alpha").links

    assert_equal true, act("link-remove", "epic-alpha", label: "Tracker")["ok"]
    assert_equal ["Notes"], item("epic-alpha").links.map { |l| l["label"] }
  end

  def test_link_set_refuses_a_url_that_is_not_http
    epic!
    reply = act("link-set", "epic-alpha", label: "Bad", url: "javascript:alert(1)")

    assert_equal false, reply["ok"]
    assert_empty item("epic-alpha").links
  end

  def test_epic_actions_from_another_origin_are_refused
    epic!
    Quartermaster::WorkItem.create("Child", project: "Nowhere")
    %w[epic-set link-set link-remove epic-make epic-unmake].each do |cmd|
      status, = respond({ "cmd" => cmd, "slug" => "child", "args" => { "epic" => "epic-alpha" } },
                        ok_host.merge("origin" => "https://evil.example.com"))
      assert_equal "403 Forbidden", status, cmd
      status, = respond({ "cmd" => cmd, "slug" => "child", "args" => { "epic" => "epic-alpha" } }, { "host" => "127.0.0.1:4567" })
      assert_equal "403 Forbidden", status, "#{cmd} without an Origin"
    end
    assert_nil item("child").epic
    refute item("child").epic?
  end

  def test_the_state_carries_kind_epic_and_links_for_the_board
    epic!
    item("epic-alpha").set_link("Tracker", "https://example.com/t")
    Quartermaster::WorkItem.create("Child", project: "Nowhere", front: { "epic" => "epic-alpha" })

    items = JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])["items"].to_h { |i| [i["slug"], i] }

    assert_equal ["epic", nil, [{ "label" => "Tracker", "url" => "https://example.com/t" }]],
                 items["epic-alpha"].values_at("kind", "epic", "links")
    assert_equal [nil, "epic-alpha", []], items["child"].values_at("kind", "epic", "links")
  end

  # A drop into an epic posts epic-set: it moves the item in and out of epics
  # and leaves its state alone.
  def test_epic_set_from_a_drop_keeps_the_item_state
    epic!
    Quartermaster::WorkItem.create("Child", project: "Nowhere").update_state("fridge")

    act("epic-set", "child", epic: "epic-alpha")
    assert_equal %w[epic-alpha fridge], [item("child").epic, item("child").state]
    act("epic-set", "child", epic: "")
    assert_equal [nil, "fridge"], [item("child").epic, item("child").state]
  end

  # A refused drop toasts the error qm epic prints.
  def test_epic_set_refuses_automations_and_an_epic_dropped_on_itself_with_the_cli_text
    epic!
    Quartermaster::WorkItem.create("Nightly", project: "Nowhere", front: { "kind" => "automation" })

    assert_equal({ "ok" => false, "error" => "an automation can't join an epic" }, act("epic-set", "nightly", epic: "epic-alpha").slice("ok", "error"))
    assert_equal({ "ok" => false, "error" => "an epic can't be inside another epic (one level only)" },
                 act("epic-set", "epic-alpha", epic: "epic-alpha").slice("ok", "error"))
    assert_nil item("nightly").epic
    assert_nil item("epic-alpha").epic
  end

  def page_function(page, name)
    page[/^(?:async )?function #{name}\(.*?^}$/m] or flunk("no function #{name} on the page")
  end

  # Drag and drop into an epic (epic-drop.js): every surface marks its sources
  # and targets, and a drop posts epic-set through the one helper ⋯ → Epic… uses.
  def test_the_page_wires_drag_into_an_epic_on_the_board_todos_and_chats
    page = served_page(server, ok_host)

    move = page_function(page, "moveToEpic")
    assert_includes move, 'act("epic-set", { slug: it.slug, args: { epic } })'
    refute_includes move, "state"
    assert_includes page_function(page, "epicMenu"), "moveToEpic(it, epic)"
    {
      "card" => "epicDragSource(c, it.slug);",
      "epicCard" => "epicDropTarget(c, e.slug);",
      "epicChildRow" => "epicDragSource(r, it.slug);",
      "render" => 'epicDropTarget(col, "");',
      "todoChildRow" => "epicDragSource(r, it.slug);",
      "todoEpicNode" => "epicDropTarget(head, e.slug);",
      "chatRow" => "epicDragSource(row, a.slug);",
      "chatEpicBlock" => "epicDropTarget(head, epic.slug);"
    }.each { |fn, seam| assert_includes page_function(page, fn), seam, fn }
    assert_includes page_function(page, "epicCard"), "epicDragSource(c, e.slug);"
    drop = page_function(page, "epicDropAt")
    assert_includes drop, "ev.dataTransfer.types.includes(EPIC_DRAG_TYPE)", "a file or todo drag never lands in an epic"
    assert_includes drop, 'if (!it || epic === (it.epic || "")) return null;', "a drop where it already is posts nothing"
    assert_includes page, "moveToEpic(d.it, d.epic);"
    assert_includes page, 'act("todo-move", { args: { id, [where]: row.dataset.id } });', "todos keep their reorder drag"
  end

  # The board's epic card is client-side; the page must carry it and its hooks.
  def test_the_page_carries_the_epic_card_and_its_controls
    page = served_page(server, ok_host)

    %w[function epicCard( function epicResolvable( function epicMenu( function linksEditor( function epicTurnEntry( epic-set epic-make epic-unmake link-set link-remove].each do |needle|
      assert_includes page, needle
    end
  end
end
