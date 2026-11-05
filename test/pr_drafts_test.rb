# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/pr_drafts_test.rb`).
require_relative "test_helper"

# GitHub drafts (PR review plan D5-D8): the store's github-comment kind,
# its PR fields and ranges, moving a draft between the review and the chat.
class PrDraftsStoreTest < Minitest::Test
  include QmTestHelpers

  LINE = DRAFT_COMMENT
  PR = { "repo" => "acme/widgets", "number" => 7, "base" => "a" * 40, "commit" => "b" * 40 }.freeze

  def drafts = Quartermaster::Drafts.new("item")

  def test_a_github_draft_keeps_its_pr_anchor_commit_range_and_author
    entry = drafts.put_diff_comment(LINE.merge(PR, "kind" => "github-comment", "number" => "7", "start_line" => 1,
                                               "start_side" => "new", "code" => "y = 0\nx = 1", "noGh" => true))

    assert_equal({ "kind" => "github-comment", "path" => "lib/a.rb", "side" => "new", "line" => 2, "code" => "y = 0\nx = 1",
                   "start_line" => 1, "start_side" => "new", "repo" => "acme/widgets", "number" => 7, "base" => "a" * 40,
                   "commit" => "b" * 40, "subject" => "line", "author" => "user" },
                 entry.except("id", "comment", "rev", "createdAt", "updatedAt"))
  end

  def test_a_line_holds_one_draft_per_pr_and_saving_it_the_other_way_turns_it
    chat = drafts.put_diff_comment(LINE.merge(PR))
    branch = drafts.put_diff_comment(LINE)
    review = drafts.put_diff_comment(LINE.merge(PR, "kind" => "github-comment"))
    same = drafts.put_diff_comment(LINE.merge(PR, "kind" => "github-comment"))

    assert_equal ["diff-comment", nil, nil], chat.values_at("kind", "subject", "author"), "a chat draft keeps its PR, no more"
    assert_equal [7, "b" * 40], chat.values_at("number", "commit")
    refute_equal chat["id"], branch["id"], "the PR scope's line is not the branch's"
    assert_equal [chat["id"], "github-comment", 2], review.values_at("id", "kind", "rev")
    assert_equal 2, same["rev"], "nothing changed"
    assert_equal 2, drafts.entries.size
  end

  def test_a_github_draft_needs_its_pr_and_commit_and_a_known_subject_and_author
    github = LINE.merge(PR, "kind" => "github-comment")

    [LINE.merge("kind" => "github-comment"), github.merge("commit" => "HEAD"), github.merge("repo" => "widgets"),
     github.merge("subject" => "commit"), github.merge("author" => "someone"), github.merge("base" => "main"),
     LINE.merge("kind" => "annotation")].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { drafts.put_diff_comment(bad) }
    end
    assert_empty drafts.entries
  end

  def test_the_chip_moves_a_pr_draft_between_the_review_and_the_chat
    store = drafts
    pr_draft = store.put_diff_comment(LINE.merge(PR))
    plain = store.put_diff_comment(LINE)

    moved = store.move(pr_draft["id"], "github")
    assert_equal %w[github-comment line user], moved.values_at("kind", "subject", "author")
    back = store.move(pr_draft["id"], "chat")
    assert_equal ["diff-comment", 3], [back["kind"], back["rev"]]
    assert_equal 3, store.move(pr_draft["id"], "chat")["rev"], "already there"
    file = store.put_diff_comment(LINE.merge(PR, "line" => 9, "kind" => "github-comment", "subject" => "file"))
    store.move(file["id"], "chat")
    assert_equal "file", store.move(file["id"], "github")["subject"], "a file comment comes back one"
    assert_raises(ArgumentError) { store.move(plain["id"], "github") }
    assert_raises(ArgumentError) { store.move(pr_draft["id"], "slack") }
    annotation, = store.add_annotations([{ "comment" => "c" }])
    assert_raises(ArgumentError) { store.move(annotation["id"], "chat") }
  end

  def test_a_draft_claude_wrote_is_the_users_once_they_edit_it
    store = drafts
    entry = store.put_diff_comment(LINE.merge(PR, "kind" => "github-comment", "author" => "claude"))

    assert_equal "claude", store.edit(entry["id"], LINE["comment"])["author"], "saving it unchanged isn't an edit"
    assert_equal "user", store.edit(entry["id"], "better")["author"]
  end

  def test_a_put_keeps_claudes_authorship_until_the_text_changes
    store = drafts
    github = LINE.merge(PR, "kind" => "github-comment")
    entry = store.put_diff_comment(github.merge("author" => "claude"))

    same = store.put_diff_comment(github)
    assert_equal ["claude", entry["rev"]], same.values_at("author", "rev"), "an unchanged save from the page"
    assert_equal "user", store.put_diff_comment(github.merge("comment" => "better"))["author"]
  end
end

# What GitHub drafts say: in the chat (path:line on repo#n @sha7, ranges)
# and, posted, as a review comment's body.
class PrDraftMessagesTest < Minitest::Test
  def test_a_pr_scope_chat_draft_names_the_pr_and_commit_and_a_range_its_lines
    text = Quartermaster::DiffComments.message(
      [{ "path" => "a.rb", "line" => 4, "side" => "new", "code" => "x", "comment" => "one", "repo" => "acme/widgets",
         "number" => 7, "commit" => "abcdef1234567890" },
       { "path" => "b.rb", "line" => 6, "start_line" => 4, "side" => "new", "start_side" => "new",
         "code" => "a\nb\nc", "comment" => "two" },
       { "path" => "c.rb", "line" => 3, "start_line" => 2, "side" => "new", "start_side" => "old",
         "code" => "gone\nnew", "comment" => "three" },
       { "path" => "d.rb", "line" => 9, "start_line" => 8, "side" => "old", "start_side" => "old",
         "code" => "p\nq", "comment" => "four" }]
    )

    assert_includes text, "a.rb:4 on widgets#7 @abcdef1\n> x\none"
    assert_includes text, "b.rb:4-6\n> a\n> b\n> c\ntwo"
    assert_includes text, "c.rb:old 2-new 3\n> gone\n> new\nthree"
    assert_includes text, "d.rb:8-9 (removed lines)\n> p\n> q\nfour"
  end

  def test_the_github_body_is_the_comment_and_a_file_comment_quotes_its_lines
    line = { "path" => "a.rb", "line" => 4, "side" => "new", "code" => "x = 1", "comment" => "```suggestion\nx = 2\n```" }

    assert_equal "```suggestion\nx = 2\n```", Quartermaster::DiffComments.github_body(line)
    assert_equal "Line 4:\n> x = 1\n\nwhy?", Quartermaster::DiffComments.github_body(line.merge("subject" => "file", "comment" => "why?"))
    range = line.merge("subject" => "file", "start_line" => 3, "start_side" => "new", "code" => "y\nx = 1", "comment" => "hm")
    assert_equal "Lines 3-4:\n> y\n> x = 1\n\nhm", Quartermaster::DiffComments.github_body(range)
  end
end

# The PR scope marks the lines GitHub won't take for a selected run's
# anchor, and the actions check a GitHub draft's line before storing it.
class PrDraftAnchoringTest < Minitest::Test
  include QmTestHelpers
  include PrRepoHelpers
  include ChatAttentionHelpers

  LINES = ANCHOR_LINES

  # main: a.txt of 20 lines. The PR: c1 changes line 5 and adds one.txt, c2
  # changes line 5 back — so base..c2 doesn't touch a.txt at all.
  def with_reverting_pr
    with_pr_repo do |repo|
      commit(repo, "a.txt", LINES)
      push(repo, "main")
      wt = add_worktree(repo, "feature", "wt-feature")
      File.write(File.join(wt, "one.txt"), "1\n")
      system("git", "-C", wt, "add", "one.txt")
      commit(wt, "a.txt", LINES.sub("line 5\n", "line five\n"), message: "c1")
      c1 = sha_of(wt, "HEAD")
      commit(wt, "a.txt", LINES, message: "c2")
      push(wt, "feature:refs/pull/7/head")
      cache_prs(pr_entry)
      yield repo, c1, sha_of(wt, "HEAD"), sha_of(repo, "main")
    end
  end

  def pr_diff(item, **options)
    Quartermaster::BranchDiff.new(tmux: FakeTmux.new, runner: GitPassThroughRunner.new).call(item, scope: "pr", **options)
  end

  def gh_flags(result, path) = result["files"].find { |f| f["path"] == path }["hunks"].flat_map { |h| h["lines"] }.map { |l| l["gh"] }

  def test_a_selected_run_marks_the_lines_github_wont_take_at_its_last_commit
    with_reverting_pr do |_repo, c1, c2, _base|
      item = Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")

      whole = pr_diff(item)
      first = pr_diff(item, from: c1)
      second = pr_diff(item, from: c2)

      assert_equal ["one.txt"], whole["files"].map { |f| f["path"] }
      assert(whole["files"].all? { |f| f["hunks"].flat_map { |h| h["lines"] }.none? { |l| l.key?("gh") } }, "base..head is GitHub's own diff")
      assert_equal [nil], gh_flags(first, "a.txt").uniq, "c1's view is base..c1"
      assert_equal [false], gh_flags(second, "a.txt").uniq, "base..c2 has no a.txt to comment on"
    end
  end

  def act(gui, cmd, args, slug = "feat") = gui.actions.dispatch("cmd" => cmd, "slug" => slug, "args" => args)

  def test_a_github_draft_is_stored_only_on_a_line_github_takes_else_as_a_file_comment
    with_reverting_pr do |_repo, c1, _c2, base|
      Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
      draft = { "kind" => "github-comment", "repo" => "acme/widgets", "number" => 7, "base" => base, "commit" => c1,
                "path" => "a.txt", "side" => "new", "comment" => "hm" }

      taken = act(gui, "draft-put", draft.merge("line" => 5, "code" => "line five"))
      far = act(gui, "draft-put", draft.merge("line" => 15, "code" => "line 15"))
      stale = act(gui, "draft-put", draft.merge("line" => 5, "code" => "line 5"))
      file = act(gui, "draft-put", draft.merge("line" => 15, "code" => "line 15", "subject" => "file"))
      ranged = act(gui, "draft-put", draft.merge("line" => 6, "start_line" => 1, "start_side" => "new", "code" => "line 1\nline 6"))

      assert taken["ok"], taken["error"]
      assert_match(/GitHub can't take a comment on a\.txt:15 at widgets#7 @#{c1[0, 7]}/, far["error"])
      refute stale["ok"], "the line's text must still be the one GitHub has"
      assert_equal "file", file.dig("draft", "subject")
      assert_match(/a\.txt:1 /, ranged["error"], "both ends of a range")
      assert_equal 2, Quartermaster::Drafts.new("feat").entries.size
    end
  end

  def test_the_chip_moves_a_chat_draft_to_the_review_only_where_github_takes_it
    with_reverting_pr do |_repo, c1, _c2, base|
      Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
      chat = { "repo" => "acme/widgets", "number" => 7, "base" => base, "commit" => c1, "path" => "a.txt", "side" => "new",
               "comment" => "hm" }
      near = act(gui, "draft-put", chat.merge("line" => 5, "code" => "line five"))["draft"]
      far = act(gui, "draft-put", chat.merge("line" => 15, "code" => "line 15"))["draft"]

      assert_equal "github-comment", act(gui, "draft-move", "id" => near["id"], "to" => "github").dig("draft", "kind")
      assert_match(/can't take a comment/, act(gui, "draft-move", "id" => far["id"], "to" => "github")["error"])
      assert_equal "diff-comment", act(gui, "draft-move", "id" => near["id"], "to" => "chat").dig("draft", "kind")
    end
  end

  def test_send_leaves_github_drafts_for_the_review
    live_item("Drafted", "s-drafted")
    tmux = FakeTmux.new(["drafted"])
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: tmux)
    store = Quartermaster::Drafts.new("drafted")
    chat = store.put_diff_comment(DRAFT_COMMENT.merge(PrDraftsStoreTest::PR))
    review = store.put_diff_comment(DRAFT_COMMENT.merge(PrDraftsStoreTest::PR, "line" => 3, "kind" => "github-comment"))

    assert_equal({ "ok" => true, "sent" => 1 }, act(gui, "drafts-send", { "ids" => [chat["id"], review["id"]] }, "drafted"))
    assert_includes tmux.typed.first[2], "lib/a.rb:2 on widgets#7 @bbbbbbb\n> x = 1\nrename x"
    assert_equal [review["id"]], store.entries.map { |entry| entry["id"] }
    assert_equal({ "ok" => false, "error" => "no drafts to send" }, act(gui, "drafts-send", {}, "drafted"))
    assert_equal 1, store.entries.size
  end
end

# The page: the PR scope's editor saves to the review or the chat, the
# tray groups GitHub drafts per PR, ranges and suggestions in every scope.
class PrDraftsPageTest < Minitest::Test
  include QmTestHelpers

  def page
    host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
    served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)
  end

  def test_the_pr_scope_editor_adds_to_the_review_or_asks_the_chat
    html = page

    ['el("button", "primary gh", "Add to review")', 'el("button", "", "Ask chat")',
     'if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); pr ? addToReview() : askChat(); }',
     'else if (e.key === "Enter" && e.altKey) { e.preventDefault(); askChat(); }',
     'return pr ? { repo: pr.repo, number: pr.number, base: pr.baseSha, commit: diffView.data.anchor } : {};',
     "if (pr) address.number = pr.number;", 'const diffAddressKey = a => `${a.number ? `#${a.number}/` : ""}'].each do |seam|
      assert_includes html, seam
    end
  end

  def test_a_line_github_wont_take_offers_ask_chat_or_a_file_comment
    html = page

    ['if (line.gh === false) tr.dataset.gh = "0";', "if (!address.noGh) { save(\"github-comment\"); return; }",
     'el("button", "primary gh", "Save as file comment")', 'save("github-comment", "file")',
     "GitHub can't take a comment on this line at"].each { |seam| assert_includes html, seam }
  end

  def test_editing_a_saved_draft_keeps_its_line_check_subject_and_a_refused_text
    html = page

    ["if (drafted && !isOutdatedDraft(drafted)) tbody.appendChild(renderDiffCommentRow(address));",
     'let refused = !!(draft && isGithubDraft(draft) && draft.subject === "file");',
     "if (!res.ok && text.trim()) reopenDiffComment(diffAddressKey(address), text, address);",
     "? diffRangeAddress(start, end) : null;",
     'if (typed && typed.value.trim()) editor.querySelector("textarea").value = typed.value;'].each do |seam|
      assert_includes html, seam
    end
  end

  def test_ranges_by_shift_click_and_suggestions_in_every_scope
    html = page

    ["if (e.shiftKey && diffRangeFrom && diffRangeFrom !== tr && diffRangeFrom.isConnected &&",
     "start_line: first.line, start_side: first.side, code: lines.map(r => r.dataset.code).join(\"\\n\")",
     'if (span.some(r => r.classList.contains("d-hunk") || r.classList.contains("d-expand"))) return null;', "markDiffDraftRanges(tbody, f.path);",
     'el("button", "", "Suggest change")', "`${before && !before.endsWith(\"\\n\") ? \"\\n\" : \"\"}\\`\\`\\`suggestion\\n${text}\\n\\`\\`\\`\\n`",
     'if (address.side !== "new" || (address.start_side && address.start_side !== "new")) return null;'].each do |seam|
      assert_includes html, seam
    end
  end

  def test_the_tray_groups_github_drafts_per_pr_with_post_and_move_chips
    html = page

    ['const isDiffComment = d => d.kind === "diff-comment" || d.kind === "github-comment";',
     'el("button", "primary gh", "Post as pending review")', 'postPendingReview(d.repo, d.number, drafts.map(x => x.id))',
     'draftAction("draft-move", slug, { id: d.id, to })', 'github ? "→ chat" : "→ review"',
     'if (String(d.id).startsWith("pending:")) d = itemDrafts(slug).find(',
     "const drafts = itemDrafts(slug).filter(isChatDraft);", 'el("div", "dt-group", "For the chat")',
     'd.author === "claude" ? "🤖 " : ""'].each { |seam| assert_includes html, seam }
  end
end
