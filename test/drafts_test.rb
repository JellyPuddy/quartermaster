# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/drafts_test.rb`).
require_relative "test_helper"

# The per-item store diff comments and page annotations wait in.
class DraftsTest < Minitest::Test
  include QmTestHelpers

  COMMENT = DRAFT_COMMENT

  def test_a_diff_comment_is_stored_once_per_line_and_a_blank_one_removes_it
    drafts = Quartermaster::Drafts.new("item")
    first = drafts.put_diff_comment(COMMENT)
    again = drafts.put_diff_comment(COMMENT.merge("comment" => "call it count"))
    other_range = drafts.put_diff_comment(COMMENT.merge("range" => "abc1234"))

    assert_equal first["id"], again["id"], "the same line keeps its draft"
    assert_equal [2, 1], [again["rev"], other_range["rev"]]
    assert_equal ["call it count", "rename x"], drafts.entries.map { |entry| entry["comment"] }
    assert_equal({ "kind" => "diff-comment", "path" => "lib/a.rb", "side" => "new", "line" => 2, "code" => "x = 1" },
                 again.slice("kind", *Quartermaster::Drafts::DIFF_FIELDS))

    assert_nil drafts.put_diff_comment(COMMENT.merge("comment" => "  "))
    assert_equal [other_range["id"]], drafts.entries.map { |entry| entry["id"] }
    assert_raises(ArgumentError) { drafts.put_diff_comment(COMMENT.merge("path" => "")) }
  end

  def test_a_diff_comment_keeps_the_branch_it_was_written_on
    drafts = Quartermaster::Drafts.new("item")
    entry = drafts.put_diff_comment(COMMENT.merge("branch" => "feature/x", "committed" => true))
    assert_equal ["feature/x", true], entry.values_at("branch", "committed")
    refute drafts.put_diff_comment(COMMENT.merge("line" => 3, "committed" => "yes")).key?("committed")
    assert_raises(ArgumentError) { drafts.put_diff_comment(COMMENT.merge("branch" => "a b")) }
    assert_raises(ArgumentError) { drafts.put_diff_comment(COMMENT.merge("branch" => ["x"])) }
  end

  def test_the_pane_records_a_comments_branch_and_the_tray_switches_to_it
    html = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new),
                       { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" })
    ["if (diffView.data && diffView.data.branch) address.branch = diffView.data.branch;",
     "if (diffView.data && diffView.data.checkout === false) address.committed = true;",
     "|| !!diffDraftBranch(d);", "if (other) pickBranch(chatSlug, other.branch);",
     'if (other && other.checkout === false && diffNeedsCheckout(scope)) scope = "branch";',
     "return data.branches.find(b => b.branch === d.branch) || null;"].each { |seam| assert_includes html, seam }
  end

  def test_the_message_names_each_comments_branch_when_they_differ
    on_a = COMMENT.merge("branch" => "a")
    on_b = COMMENT.merge("line" => 9, "branch" => "b", "committed" => true)

    one = Quartermaster::DiffComments.message([on_a], branch: "b", base: "main")
    assert_match(/\AReview comments on the diff of a — 1 comment:/, one, "where it was written beats what the pane shows")
    refute_includes one, "vs main", "the pane's base is another branch's"
    assert_match(/\AReview comments on the diff of a \(vs main\)/, Quartermaster::DiffComments.message([on_a], branch: "a", base: "main"))

    both = Quartermaster::DiffComments.message([on_a, on_b], branch: "a", base: "main")
    assert_match(/\AReview comments on the diff — 2 comments:/, both)
    assert_includes both, "lib/a.rb:2 (on branch a)\n"
    assert_includes both, "lib/a.rb:9 (on branch b, as committed, not on disk)\n"
    assert_includes Quartermaster::DiffComments.message([COMMENT], branch: "a"), "diff of a —", "an older comment takes the pane's branch"
  end

  def test_annotations_keep_what_the_message_needs_and_the_batchs_page
    owners = [{ "name" => "Card", "file" => "app/card.tsx", "line" => 4, "code" => "<Card />", "secret" => "x" }, "junk"]
    added = Quartermaster::Drafts.new("item").add_annotations(
      [{ "comment" => " bigger ", "selector" => "#a", "owners" => owners, "onclick" => "evil()" }, { "comment" => "" }],
      url: "http://localhost:3000/", title: "Home"
    )

    assert_equal 1, added.size
    entry = added.first
    assert_equal ["annotation", "bigger", "#a", "http://localhost:3000/", "Home"],
                 entry.values_at("kind", "comment", "selector", "url", "title")
    assert_equal [{ "name" => "Card", "file" => "app/card.tsx", "line" => 4, "code" => "<Card />" }], entry["owners"]
    refute entry.key?("onclick")
    assert_raises(ArgumentError) { Quartermaster::Drafts.new("item").add_annotations([{ "comment" => " " }]) }
    assert_raises(ArgumentError) { Quartermaster::Drafts.new("item").add_annotations("nope") }
  end

  def test_edit_delete_and_removal_by_rev
    drafts = Quartermaster::Drafts.new("item")
    kept, edited, gone = drafts.add_annotations([{ "comment" => "a" }, { "comment" => "b" }, { "comment" => "c" }])
    snapshot = drafts.entries.to_h { |entry| [entry["id"], entry["rev"]] }

    assert_equal 2, drafts.edit(edited["id"], "b, but more")["rev"]
    assert_equal 1, drafts.edit(kept["id"], "a")["rev"], "an unchanged text is no edit"
    assert_raises(ArgumentError) { drafts.edit(gone["id"], " ") }
    assert drafts.delete(gone["id"])
    refute drafts.delete(gone["id"])
    assert_raises(ArgumentError) { drafts.edit(gone["id"], "x") }

    assert_equal 1, drafts.remove(snapshot), "only the unedited entry matched the snapshot"
    assert_equal ["b, but more"], drafts.entries.map { |entry| entry["comment"] }
    assert_equal 1, drafts.remove
    assert_empty drafts.entries
  end

  def test_the_file_is_versioned_and_goes_away_when_empty
    drafts = Quartermaster::Drafts.new("item")
    drafts.put_diff_comment(COMMENT)

    data = JSON.parse(File.read(drafts.path))
    assert_equal 1, data["v"]
    assert_equal File.join(Quartermaster::ROOT, "drafts", "item.json"), drafts.path
    assert_empty Dir[File.join(Quartermaster::ROOT, "drafts", "*.tmp")]

    drafts.remove
    refute File.exist?(drafts.path)
  end

  def test_a_slug_is_never_a_path
    ["../x", "a/b", "", nil, ".hidden"].each do |slug|
      assert_raises(ArgumentError, slug.inspect) { Quartermaster::Drafts.new(slug) }
    end
  end

  def test_counts_and_the_signature_follow_every_change
    empty = Quartermaster::Drafts.signature
    Quartermaster::Drafts.new("one").add_annotations([{ "comment" => "a" }, { "comment" => "b" }])
    after_add = Quartermaster::Drafts.signature
    Quartermaster::Drafts.new("two").put_diff_comment(COMMENT)

    assert_equal({ "one" => 2, "two" => 1 }, Quartermaster::Drafts.counts)
    refute_equal empty, after_add
    refute_equal after_add, Quartermaster::Drafts.signature
    Quartermaster::Drafts.new("two").remove
    assert_equal after_add, Quartermaster::Drafts.signature
    assert_equal({ "one" => 2 }, Quartermaster::Drafts.counts)

    File.write(File.join(Quartermaster::ROOT, "drafts", "not a slug.json"), "{}")
    assert_equal({ "one" => 2 }, Quartermaster::Drafts.counts, "a stray file doesn't break the counts")
  end
end

# A page overlay's relay: annotations land as drafts of the item checked out
# where the dev server serves, and nothing is typed into any chat.
class PageAnnotationsActionTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers
  include StackRepoHelpers

  ANNOTATIONS = [{ "comment" => "rename this", "selector" => "#x" }].freeze

  def with_checkouts
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Qm" => repo } }.to_yaml)
      yield add_worktree(repo, "feature", "wt-feature"), add_worktree(repo, "other", "wt-other")
    end
  end

  # An item on branch with a session, live (this process's pid) by default.
  def item_on(branch, title, session_id, pid: Process.pid, ts: Time.now)
    Quartermaster::SessionLog.new.append("event" => "start", "session_id" => session_id, "cwd" => "/",
                                         "pid" => pid, "ts" => ts.iso8601)
    Quartermaster::WorkItem.create(title, project: "Qm", branch: branch, session_id: session_id)
  end

  def send_annotations(gui, root, annotations = ANNOTATIONS)
    gui.actions.dispatch("cmd" => "page-annotations",
                         "args" => { "root" => root, "url" => "http://localhost:3000/", "title" => "Home",
                                     "annotations" => annotations })
  end

  def comments_of(slug) = Quartermaster::Drafts.new(slug).entries.map { |entry| entry["comment"] }

  def test_lands_as_drafts_of_the_one_item_without_any_chat_open
    with_checkouts do |feature, _other|
      item_on("feature", "Feat", "s-feat", pid: 999_999)
      tmux = FakeTmux.new
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      reply = send_annotations(gui, "#{feature}/")

      assert_equal({ "ok" => true, "slug" => "feat" }, reply)
      entry = Quartermaster::Drafts.new("feat").entries.first
      assert_equal ["annotation", "rename this", "#x", "http://localhost:3000/", "Home"],
                   entry.values_at("kind", "comment", "selector", "url", "title")
      assert_empty tmux.typed
    end
  end

  def test_never_types_into_a_live_chat
    with_checkouts do |feature, _other|
      item_on("feature", "Feat", "s-feat")
      tmux = FakeTmux.new(["feat"])
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

      assert_equal "feat", send_annotations(gui, feature)["slug"]
      assert_equal ["rename this"], comments_of("feat")
      assert_empty tmux.typed
    end
  end

  def test_several_items_go_to_the_first_in_attention_order
    with_checkouts do |feature, _other|
      item_on("feature", "Busy", "s-busy")
      item_on("feature", "Recent", "s-recent")
      item_on("feature", "Waiting", "s-waiting")
      item_on("feature", "Ended", "s-ended", pid: 999_999)
      item_on("other", "Elsewhere", "s-elsewhere")
      log_events("s-busy", [5, "UserPromptSubmit"])
      log_events("s-recent", [10, "Stop"])
      log_events("s-waiting", [100, "Stop"])
      log_events("s-elsewhere", [1000, "Stop"])
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

      reply = send_annotations(gui, feature)

      assert_equal "waiting", reply["slug"], reply["error"]
      assert_equal ["rename this"], comments_of("waiting")
    end
  end

  def test_without_live_chats_the_most_recently_active_item_wins
    with_checkouts do |feature, _other|
      item_on("feature", "Old", "s-old", pid: 999_999, ts: Time.now - 7200)
      item_on("feature", "Recent", "s-recent", pid: 999_999, ts: Time.now - 60)
      Quartermaster::WorkItem.create("Never", project: "Qm", branch: "feature")
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

      assert_equal "recent", send_annotations(gui, feature)["slug"]
    end
  end

  def test_refuses_a_checkout_without_any_item_and_empty_annotations
    with_checkouts do |feature, other|
      item_on("feature", "Feat", "s-feat")
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new(["feat"]))

      no_item = send_annotations(gui, other)
      assert_equal false, no_item["ok"]
      assert_match(/no work item has .*wt-other checked out/, no_item["error"])

      no_root = gui.actions.dispatch("cmd" => "page-annotations", "args" => { "annotations" => ANNOTATIONS })
      assert_equal({ "ok" => false, "error" => "no checkout root given" }, no_root)

      assert_equal({ "ok" => false, "error" => "no annotations to send" }, send_annotations(gui, feature, []))
      assert_empty Quartermaster::Drafts.counts
    end
  end
end

# The page's draft actions and the one combined Send.
class DraftActionsTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  COMMENT = DRAFT_COMMENT

  # Edits a draft and adds one while the paste is in flight, as another tab
  # (or a pf relay) could between the snapshot and the removal.
  class MeddlingTmux < FakeTmux
    attr_accessor :meddle

    def paste(name, text)
      meddle&.call
      super
    end
  end

  def act(gui, cmd, args = {}, slug = "drafted") = gui.actions.dispatch("cmd" => cmd, "slug" => slug, "args" => args)

  def test_put_edit_delete_and_discard_through_the_actions
    live_item("Drafted", "s-drafted")
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

    put = act(gui, "draft-put", COMMENT)
    assert_equal true, put["ok"], put["error"]
    id = put["draft"]["id"]
    assert_equal "shorter", act(gui, "draft-edit", "id" => id, "comment" => "shorter")["draft"]["comment"]
    assert_equal({ "ok" => true, "deleted" => true }, act(gui, "draft-delete", "id" => id))
    assert_equal({ "ok" => true, "deleted" => false }, act(gui, "draft-delete", "id" => id))

    act(gui, "draft-put", COMMENT)
    act(gui, "draft-put", COMMENT.merge("line" => 3))
    assert_equal({ "ok" => true, "discarded" => 2 }, act(gui, "drafts-discard"))
    assert_empty Quartermaster::Drafts.new("drafted").entries

    assert_equal false, act(gui, "draft-put", COMMENT, "nobody")["ok"], "only an item's drafts"
    refute File.exist?(File.join(Quartermaster::ROOT, "drafts", "nobody.json"))
  end

  def test_send_pastes_comments_then_annotations_as_one_message
    live_item("Drafted", "s-drafted")
    tmux = FakeTmux.new(["drafted"])
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    drafts = Quartermaster::Drafts.new("drafted")
    drafts.add_annotations([{ "comment" => "bigger", "selector" => "#a" }], url: "http://localhost:3000/a", title: "A")
    drafts.put_diff_comment(COMMENT)
    drafts.add_annotations([{ "comment" => "smaller", "selector" => "#b" }], url: "http://localhost:3000/b", title: "B")

    reply = act(gui, "drafts-send", "branch" => "feature", "base" => "main")

    assert_equal({ "ok" => true, "sent" => 3 }, reply)
    comments = Quartermaster::DiffComments.message([COMMENT], branch: "feature", base: "main")
    annotations = Quartermaster::PageAnnotations.message(
      [{ "comment" => "bigger", "selector" => "#a", "page" => "http://localhost:3000/a" },
       { "comment" => "smaller", "selector" => "#b", "page" => "http://localhost:3000/b" }],
      url: "http://localhost:3000/b", title: "B"
    )
    assert_equal [["drafted", :paste, "#{comments}\n\n#{annotations}"], ["drafted", :enter]], tmux.typed
    assert_includes annotations, "smaller\npage: http://localhost:3000/b\nselector: #b"
    assert_empty drafts.entries
  end

  def test_send_orders_diff_comments_by_path_and_line_as_the_tray_does
    live_item("Drafted", "s-drafted")
    tmux = FakeTmux.new(["drafted"])
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    drafts = Quartermaster::Drafts.new("drafted")
    later = COMMENT.merge("line" => 10, "comment" => "later")
    other = COMMENT.merge("path" => "app/b.rb", "comment" => "other file")
    [later, COMMENT, other].each { |comment| drafts.put_diff_comment(comment) }

    assert_equal true, act(gui, "drafts-send")["ok"]

    expected = Quartermaster::DiffComments.message([other, COMMENT, later])
    assert_equal ["drafted", :paste, expected], tmux.typed.first
  end

  def test_send_of_annotations_alone_and_of_the_ids_shown
    live_item("Drafted", "s-drafted")
    tmux = FakeTmux.new(["drafted"])
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    drafts = Quartermaster::Drafts.new("drafted")
    shown, = drafts.add_annotations([{ "comment" => "shown" }], url: "http://localhost:3000/", title: "Home")
    drafts.add_annotations([{ "comment" => "arrived later" }], url: "http://localhost:3000/", title: "Home")

    assert_equal({ "ok" => true, "sent" => 1 }, act(gui, "drafts-send", "ids" => [shown["id"]]))

    text = Quartermaster::PageAnnotations.message([{ "comment" => "shown" }], url: "http://localhost:3000/", title: "Home")
    assert_equal ["drafted", :paste, text], tmux.typed.first
    assert_equal ["arrived later"], drafts.entries.map { |entry| entry["comment"] }
  end

  def test_only_the_entries_sent_are_removed
    live_item("Drafted", "s-drafted")
    tmux = MeddlingTmux.new(["drafted"])
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    drafts = Quartermaster::Drafts.new("drafted")
    sent, edited = drafts.add_annotations([{ "comment" => "as is" }, { "comment" => "to edit" }])
    tmux.meddle = lambda do
      drafts.edit(edited["id"], "edited mid-send")
      drafts.put_diff_comment(COMMENT)
    end

    assert_equal true, act(gui, "drafts-send")["ok"]

    assert_includes tmux.typed.first[2], "to edit"
    assert_equal ["edited mid-send", "rename x"], drafts.entries.map { |entry| entry["comment"] }
    refute_includes drafts.entries.map { |entry| entry["id"] }, sent["id"]
  end

  def test_send_refuses_without_an_open_chat_mid_turn_or_without_drafts
    live_item("Drafted", "s-drafted")
    Quartermaster::Drafts.new("drafted").put_diff_comment(COMMENT)

    closed = act(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), "drafts-send")
    assert_match(/no chat open in the GUI/, closed["error"])

    tmux = FakeTmux.new(["drafted"])
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    log_events("s-drafted", [5, "UserPromptSubmit"])
    busy = act(gui, "drafts-send")
    assert_match(/mid-turn \(working\)/, busy["error"])
    assert_empty tmux.typed
    assert_equal 1, Quartermaster::Drafts.new("drafted").entries.size, "a refused send keeps the drafts"

    log_events("s-drafted", [1, "Stop"])
    Quartermaster::Drafts.new("drafted").remove
    assert_equal({ "ok" => false, "error" => "no drafts to send" }, act(gui, "drafts-send"))
  end

  def test_the_state_and_pulse_carry_the_drafts
    live_item("Drafted", "s-drafted")
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
    get = ->(route) { JSON.parse(gui.respond("GET", route, host, "")[2]) }
    before = get.call("/api/pulse")

    Quartermaster::Drafts.new("drafted").add_annotations([{ "comment" => "hi" }])

    after = get.call("/api/pulse")
    refute_equal before["pulse"], after["pulse"]
    refute_equal before["events"], after["events"], "a page off the chat view notices arrivals too"
    item = get.call("/api/state")["items"].find { |candidate| candidate["slug"] == "drafted" }
    assert_equal ["hi"], item["drafts"].map { |entry| entry["comment"] }
    assert_equal({ "drafted" => 1 }, get.call("/api/attention")["draftCounts"])
  end

  def test_the_old_diff_comments_action_is_gone
    live_item("Drafted", "s-drafted")
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

    assert_equal "unknown action 'diff-comments'", act(gui, "diff-comments", "comments" => [COMMENT])["error"]
  end
end

# The page side: the diff pane's tray works on the server store, collapsed by
# default, with a chip beside Diff and a toast when drafts arrive.
class DraftTrayPageTest < Minitest::Test
  include QmTestHelpers

  def page
    host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
    served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
  end

  def test_the_tray_reads_and_writes_the_server_store_only
    html = page

    ['draftAction("draft-put"', 'draftAction("draft-edit"', 'draftAction("draft-delete"', 'act("drafts-send"',
     'act("drafts-discard"', "const args = { ids: drafts.map(x => x.id) };", "it.drafts"].each { |seam| assert_includes html, seam }
    refute_includes html, 'act("diff-comments"'
    refute_includes html, "localStorage.setItem(DIFF_DRAFTS_KEY", "diff comments no longer live in the browser"
  end

  def test_the_tray_starts_collapsed_and_holds_both_kinds_with_edit_and_delete
    html = page

    ["let trayOpen = false;", "list.open = trayOpen;", '`${drafts.length} to send · ${esc(draftMix(drafts))}`',
     'el("div", `dt-entry ${annotation ? "annot" : "comment"}`)', "PAGE_ICON + annotationWhere(d)",
     'el("details", "dt-details")', "openTrayEdit(d)", "deleteDraft(d)", "send.disabled = !!blocker;",
     'confirm(`Discard ${plural(drafts.length, "draft")}?`)'].each { |seam| assert_includes html, seam }
  end

  def test_a_chip_beside_diff_opens_the_tray_and_arrivals_only_toast
    html = page

    [%q{bar.querySelector('.act[data-act="diff"]').after(draftsChip(it))}, 'case "drafts": openDraftsTray();',
     "trayOpen = true;", "noticeDraftsInState(items);", "noticeDraftCounts(st.draftCounts);",
     "toast(`${what} arrived for ${slug}"].each { |seam| assert_includes html, seam }
    refute_match(/function toastDraftsArrived[^}]*setMode/, html, "an arrival never switches the view")
  end

  def test_old_browser_drafts_are_imported_once
    html = page

    ['LEGACY_DRAFTS_PREFIX = "qm-diff-comments:"', 'postQuietly("draft-put", slug, args)', "localStorage.removeItem(key)",
     "importLegacyDiffDrafts();"].each { |seam| assert_includes html, seam }
  end

  def test_annotations_anchor_by_owner_code_in_the_whole_diff_only
    html = page

    assert_operator html.index('<script src="/assets/js/anchors.js">'), :<, html.index('<script src="/assets/js/diff.js">')
    ["if (!draft || !diff || diff.range || !Array.isArray(diff.files)) return null;",
     'if (sameCode(o.code, line.s)) return { at: "line", path: f.path, line: line.n };',
     'return { at: "file", path: files.get(repoRelative(owners[0].file)).path };',
     "if (l.t !== \"-\" && l.n === want) return l;",
     'typeof code === "string" && code.trim() !== "" && code.trim() === String(text == null ? "" : text).trim()',
     'const repoRelative = path => String(path || "").trim().replace(/^(?:\.?\/)+/, "");'].each { |seam| assert_includes html, seam }
  end

  def test_a_review_summary_is_one_per_pr_found_and_removed_by_its_pr
    drafts = Quartermaster::Drafts.new("item")
    summary = { "repo" => "acme/widgets", "number" => 7, "verdict" => "approve", "author" => "claude", "comment" => "LGTM" }
    first = drafts.put_review_summary(summary)
    other = drafts.put_review_summary(summary.merge("number" => 8, "verdict" => nil))
    again = drafts.put_review_summary(summary.merge("verdict" => "request-changes", "comment" => "Needs a test"))

    assert_equal first["id"], again["id"], "the PR keeps its summary"
    assert_equal [2, nil], [again["rev"], other["verdict"]]
    assert_equal again, drafts.review_summary("Acme/Widgets", 7)
    assert_nil drafts.review_summary("acme/widgets", 9)
    refused = assert_raises(ArgumentError) { drafts.put_review_summary(summary.merge("verdict" => "lgtm")) }
    assert_equal "'lgtm' is not a verdict: approve, comment or request-changes", refused.message,
                 "the same refusal as a submitted review's verdict"
    assert_raises(ArgumentError) { drafts.put_review_summary(summary.merge("verdict" => "APPROVE")) }
    assert_raises(ArgumentError) { drafts.put_review_summary(summary.merge("repo" => "widgets")) }
    assert_raises(ArgumentError) { drafts.put_review_summary(summary.merge("number" => 0)) }
    assert_equal "user", drafts.put_review_summary(summary.merge("number" => 9, "author" => "bob"))["author"]

    refute drafts.forget_review_summary("acme/widgets", 7, rev: 1), "edited since: it stays"
    assert drafts.forget_review_summary("acme/widgets", 7)
    assert_nil drafts.review_summary("acme/widgets", 7)
    assert_nil drafts.put_review_summary(summary.merge("number" => 8, "comment" => " "))
    assert_equal [9], drafts.entries.map { |entry| entry["number"] }
  end

  def test_anchored_annotations_are_rows_and_badges_in_the_diff_and_links_in_the_tray
    html = page

    ['if (line.t !== "-") (annotated.get(line.n) || []).forEach(a => tbody.appendChild(renderDiffAnnotationRow(a)));',
     'summary.querySelector(".d-stat").before(diffAnnotationBadge(badged));', 'const tr = el("tr", "d-annot");',
     "td.appendChild(annotationDetails(d));", "close(comment); editDraft(d, comment);", "deleteDraft(d); };",
     "annotEditing.forEach(([id, value]) => reopenDiffAnnotation(id, value));",
     "`${isDiffComment(d) ? diffAddressKey(d) + d.kind : d.id}\\n${d.comment}`",
     "if (annotation && anchor && !(trayEdit && trayEdit.id === d.id)) return anchoredTrayEntry(d, anchor);",
     "link.onclick = () => revealDiffAnnotation(d);", 'target.classList.add("d-flash");',
     "revealTrayEntry(drafts[0].id)"].each { |seam| assert_includes html, seam }
    refute_match(/function renderDiffAnnotationRow[^}]*putDiffDraft/, html, "an anchored annotation never becomes a diff comment")
  end

  def test_annotations_have_their_own_colour_in_both_themes
    html = page

    assert_equal 4, html.scan(/--annot: #/).size, "light, dark by preference, and both forced themes"
    [".act.drafts-chip", ".dt-entry.annot { border-left: 3px solid var(--annot); }", ".dt-details dl"].each do |seam|
      assert_includes html, seam
    end
  end
end
