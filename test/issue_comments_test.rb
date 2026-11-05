# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/issue_comments_test.rb`).
require_relative "test_helper"

# Comments on an item's issue drafts: the third Drafts kind, its section of
# the sent message, and asking the chat to create the drafts on GitHub.
class IssueCommentsTest < Minitest::Test
  include QmTestHelpers
  include ChatAttentionHelpers

  BODY = "Export the report.\n\n- csv\n- pdf\n"
  ON_CSV = { "file" => "01-export.md", "block" => "- csv", "title" => "Add export", "comment" => "and xlsx?" }.freeze

  def issue(title: "Add export", extra: "", body: BODY) = "---\ntitle: #{title}\nkind: feature\n#{extra}---\n\n#{body}"

  def write(name, content, slug = "drafted")
    dir = File.join(Quartermaster::ROOT, "issues", slug)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), content)
  end

  def act(gui, cmd, args = {}, slug = "drafted") = gui.actions.dispatch("cmd" => cmd, "slug" => slug, "args" => args)

  def chat_gui(tmux = FakeTmux.new(["drafted"])) = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)

  def test_one_comment_per_block_and_a_blank_one_removes_it
    drafts = Quartermaster::Drafts.new("item")
    first = drafts.put_issue_comment(ON_CSV.merge("block" => "  - csv\n"))
    again = drafts.put_issue_comment(ON_CSV.merge("comment" => "and json?", "title" => "Add exports"))
    whole = drafts.put_issue_comment(ON_CSV.merge("block" => "", "comment" => "split this"))

    assert_equal first["id"], again["id"], "the same block keeps its draft"
    assert_equal [2, "Add exports"], again.values_at("rev", "title")
    assert_equal({ "kind" => "issue-comment", "file" => "01-export.md", "block" => "", "title" => "Add export" },
                 whole.slice("kind", *Quartermaster::Drafts::ISSUE_FIELDS))
    assert_equal 2, drafts.entries.size

    assert_nil drafts.put_issue_comment(ON_CSV.merge("comment" => " "))
    assert_equal [whole["id"]], drafts.entries.map { |entry| entry["id"] }
    ["../x.md", ".hidden.md", "a/b.md", "notes.txt", nil].each do |file|
      assert_raises(ArgumentError, file.inspect) { drafts.put_issue_comment(ON_CSV.merge("file" => file)) }
    end
  end

  def test_a_put_without_a_title_keeps_the_stored_one
    drafts = Quartermaster::Drafts.new("item")
    drafts.put_issue_comment(ON_CSV)

    assert_equal "Add export", drafts.put_issue_comment(ON_CSV.merge("title" => " ", "comment" => "or json"))["title"]
  end

  def test_a_comment_on_a_file_that_does_not_parse_says_so_not_that_it_is_gone
    text = Quartermaster::IssueComments.message([ON_CSV], broken: ["01-export.md"])

    assert_includes text, "## 01-export.md — Add export (doesn't parse right now)\n\n> - csv\nand xlsx?"
  end

  def test_counts_per_file_and_deleting_a_draft_file_forgets_its_comments
    write("01-export.md", issue)
    write("02-bug.md", issue(title: "Crash"))
    drafts = Quartermaster::Drafts.new("drafted")
    drafts.put_issue_comment(ON_CSV)
    drafts.put_issue_comment(ON_CSV.merge("block" => ""))
    drafts.put_issue_comment(ON_CSV.merge("file" => "02-bug.md"))
    drafts.put_diff_comment(DRAFT_COMMENT)
    issue_drafts = Quartermaster::IssueDrafts.new("drafted")

    assert_equal({ "01-export.md" => 2, "02-bug.md" => 1 }, issue_drafts.unsent_comments)

    assert issue_drafts.delete("01-export.md")
    assert_equal({ "02-bug.md" => 1 }, issue_drafts.unsent_comments)
    assert_equal %w[issue-comment diff-comment], drafts.entries.map { |entry| entry["kind"] }

    Quartermaster::Drafts.new("drafted").remove
    Quartermaster::IssueDrafts.new("drafted").delete("02-bug.md")
    refute File.exist?(Quartermaster::Drafts.new("drafted").path), "forgetting on an item without drafts writes nothing"
  end

  def test_the_message_groups_by_issue_in_body_order_and_quotes_a_changed_block
    issues = { "01-export.md" => { "title" => "Add export", "body" => "Export the report.\n\n- csv\n- pdf" } }
    entries = [
      ON_CSV.merge("block" => "- pdf", "comment" => "landscape"),
      ON_CSV.merge("file" => "02-gone.md", "title" => "Old one", "block" => "", "comment" => "drop it"),
      ON_CSV.merge("block" => "- csv\n- tsv", "comment" => "was two lines"),
      ON_CSV,
      ON_CSV.merge("block" => "", "comment" => "split this")
    ]

    text = Quartermaster::IssueComments.message(entries, issues: issues, dir: "~/qm/issues/drafted")

    assert_equal <<~MESSAGE.chomp, text
      Comments on the issue drafts in ~/qm/issues/drafted — 5 comments:

      ## 01-export.md — Add export

      On the whole issue:
      split this

      > - csv
      and xlsx?

      > - pdf
      landscape

      > - csv
      > - tsv
      (this block has changed since; the text above is what the comment was made on)
      was two lines

      ## 02-gone.md — Old one (no longer in the issue drafts)

      On the whole issue:
      drop it
    MESSAGE
    assert_raises(ArgumentError) { Quartermaster::IssueComments.message([ON_CSV.merge("comment" => " ")]) }
  end

  def test_put_through_the_action_and_send_with_the_other_kinds
    live_item("Drafted", "s-drafted")
    write("01-export.md", issue(body: "Export the report.\n\n- tsv\n- pdf\n"))
    tmux = FakeTmux.new(["drafted"])
    gui = chat_gui(tmux)

    put = act(gui, "issue-comment-put", ON_CSV)
    assert_equal true, put["ok"], put["error"]
    assert_equal "issue-comment", put["draft"]["kind"]
    assert_equal false, act(gui, "issue-comment-put", ON_CSV.merge("file" => "../x.md"))["ok"]
    drafts = Quartermaster::Drafts.new("drafted")
    drafts.put_diff_comment(DRAFT_COMMENT)
    drafts.add_annotations([{ "comment" => "bigger" }], url: "http://localhost:3000/", title: "Home")

    assert_equal({ "ok" => true, "sent" => 3 }, act(gui, "drafts-send", "branch" => "feature", "base" => "main"))

    text = tmux.typed.first[2]
    comments = Quartermaster::DiffComments.message([DRAFT_COMMENT], branch: "feature", base: "main")
    annotations = Quartermaster::PageAnnotations.message([{ "comment" => "bigger", "page" => "http://localhost:3000/" }],
                                                         url: "http://localhost:3000/", title: "Home")
    issue_section = "Comments on the issue drafts in #{Quartermaster.shorten_home(File.join(Quartermaster::ROOT, "issues", "drafted"))} — 1 comment:\n\n" \
                    "## 01-export.md — Add export\n\n> - csv\n" \
                    "(this block has changed since; the text above is what the comment was made on)\nand xlsx?"
    assert_equal "#{comments}\n\n#{annotations}\n\n#{issue_section}", text
    assert_empty drafts.entries
  end

  def test_create_asks_the_chat_for_the_open_drafts
    live_item("Drafted", "s-drafted")
    write("01-export.md", issue)
    write("02-bug.md", issue(title: "Crash on save"))
    write("03-done.md", issue(title: "Done", extra: "number: 40\n"))
    write("04-broken.md", "no frontmatter")
    tmux = FakeTmux.new(["drafted"])
    gui = chat_gui(tmux)

    assert_equal({ "ok" => true, "requested" => %w[01-export.md 02-bug.md] }, act(gui, "issues-create"))
    dir = Quartermaster.shorten_home(File.join(Quartermaster::ROOT, "issues", "drafted"))
    assert_equal [["drafted", :paste, <<~MESSAGE.chomp], ["drafted", :enter]], tmux.typed
      Create 2 drafted issues on GitHub, per the /draft-issues skill's create step. The files are in #{dir}:

      - 01-export.md — Add export
      - 02-bug.md — Crash on save

      Then add `number: <n>` to each created file's frontmatter.
    MESSAGE

    tmux.typed.clear
    assert_equal({ "ok" => true, "requested" => ["02-bug.md"] }, act(gui, "issues-create", "files" => ["02-bug.md"]))
    assert_includes tmux.typed.first[2], "Create 1 drafted issue on GitHub"

    { "03-done.md" => "03-done.md is already created on GitHub", "04-broken.md" => "04-broken.md doesn't parse — fix it first",
      "09-none.md" => "no issue draft 09-none.md" }.each do |file, error|
      assert_equal({ "ok" => false, "error" => error }, act(gui, "issues-create", "files" => [file]))
    end
    assert_equal({ "ok" => false, "error" => "no issue drafts chosen" }, act(gui, "issues-create", "files" => []))
  end

  def test_create_is_refused_like_send
    live_item("Drafted", "s-drafted")
    write("01-export.md", issue)

    closed = act(chat_gui(FakeTmux.new), "issues-create")
    assert_match(/no chat open in the GUI/, closed["error"])

    tmux = FakeTmux.new(["drafted"])
    log_events("s-drafted", [5, "UserPromptSubmit"])
    busy = act(chat_gui(tmux), "issues-create")
    assert_match(/mid-turn \(working\)/, busy["error"])
    assert_empty tmux.typed

    log_events("s-drafted", [1, "Stop"])
    write("01-export.md", issue(extra: "number: 7\n"))
    assert_equal({ "ok" => false, "error" => "no issue drafts left to create" }, act(chat_gui(tmux), "issues-create"))
  end
end
