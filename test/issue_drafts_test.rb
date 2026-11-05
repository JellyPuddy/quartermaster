# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/issue_drafts_test.rb`).
require_relative "test_helper"

# The issue files the /draft-issues skill writes for an item, as qm reads them.
class IssueDraftsTest < Minitest::Test
  include QmTestHelpers

  def issue(title: "Add export", kind: "feature", extra: "", body: "Export the report.\n\n- csv\n- pdf\n")
    "---\ntitle: #{title}\nkind: #{kind}\n#{extra}---\n\n#{body}"
  end

  def write(slug, name, content)
    dir = File.join(Quartermaster::ROOT, "issues", slug)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), content)
  end

  def drafts(slug = "item") = Quartermaster::IssueDrafts.new(slug, clock: -> { @now ||= Time.now })

  def wait(seconds) = @now = (@now || Time.now) + seconds

  def test_frontmatter_and_body_are_read_in_filename_order_created_last
    write("item", "02-bug.md", issue(title: "Crash on save", kind: "bug",
                                     extra: "group: Saving\nparent: 12\ndeps: [\"#1 export\", \"—\"]\nchange: Split off the bug.\n"))
    write("item", "01-export.md", issue(extra: "group: Reports\ndeps: —\nnumber: \"#40\"\n"))
    write("item", "03-pdf.md", issue(title: "PDF layout", extra: "deps:\n  - 02-bug\n"))
    write("item", "notes.txt", "not an issue")

    data = drafts.read

    assert_empty data["errors"]
    assert_equal %w[02-bug.md 03-pdf.md 01-export.md], data["issues"].map { |i| i["file"] }
    bug, pdf, export = data["issues"]
    assert_equal ["Crash on save", "bug", "Saving", "12", ["#1 export"], "Split off the bug.", nil, false],
                 bug.values_at("title", "kind", "group", "parent", "deps", "change", "number", "created")
    assert_equal "Export the report.\n\n- csv\n- pdf", bug["body"]
    assert_equal [["02-bug"], "", ""], pdf.values_at("deps", "group", "change")
    assert_equal [40, true, []], export.values_at("number", "created", "deps")
    assert_match(/\A\h{12}\z/, export["version"])
    assert_nil export["previous"]
  end

  def test_a_malformed_file_is_an_error_entry_not_a_failure
    write("item", "01-ok.md", issue)
    write("item", "02-none.md", "just text\n")
    write("item", "03-yaml.md", "---\ntitle: [unclosed\n---\nbody\n")
    write("item", "04-kind.md", issue(kind: "chore"))
    write("item", "05-title.md", "---\nkind: bug\n---\nbody\n")
    write("item", "06-number.md", issue(extra: "number: soon\n"))
    write("item", "07-deps.md", issue(extra: "deps: {a: 1}\n"))
    write("item", "08-date.md", issue(title: "2026-10-26"))

    data = drafts.read

    assert_equal ["01-ok.md"], data["issues"].map { |i| i["file"] }
    errors = data["errors"].to_h { |e| [e["file"], e["error"]] }
    assert_equal %w[02-none.md 03-yaml.md 04-kind.md 05-title.md 06-number.md 07-deps.md 08-date.md], errors.keys
    assert_match(/no frontmatter/, errors["02-none.md"])
    assert_match(/kind must be feature or bug/, errors["04-kind.md"])
    assert_match(/title is missing/, errors["05-title.md"])
    assert_match(/number/, errors["06-number.md"])
    assert_match(/deps/, errors["07-deps.md"])
    refute File.exist?(File.join(drafts.dir, ".prev", "02-none.md.json")), "a broken file is never recorded as seen"
  end

  def test_a_revision_keeps_the_version_seen_before_across_restarts
    write("item", "01-export.md", issue(body: "Old text."))
    assert_nil drafts.read["issues"].first["previous"], "first sight has no previous version"
    assert_nil drafts.read["issues"].first["previous"], "an unchanged file still has none"

    wait(3600)
    write("item", "01-export.md", issue(title: "Export reports", body: "New text."))
    revised = drafts.read["issues"].first
    assert_equal({ "title" => "Add export", "body" => "Old text." }, revised["previous"])
    assert_equal({ "title" => "Add export", "body" => "Old text." }, Quartermaster::IssueDrafts.new("item").read["issues"].first["previous"],
                 "a fresh reader (a GUI restart) sees the same previous version")

    wait(3600)
    write("item", "01-export.md", "---\ntitle: half")
    assert_equal 1, drafts.read["errors"].size
    write("item", "01-export.md", issue(title: "Export reports", body: "Newer text."))
    assert_equal({ "title" => "Export reports", "body" => "New text." }, drafts.read["issues"].first["previous"],
                 "a half-written version in between is never the previous one")
  end

  def test_edits_in_quick_succession_are_one_revision
    write("item", "01-export.md", issue(body: "Old text."))
    drafts.read
    wait(3600)
    write("item", "01-export.md", issue(body: "New text."))
    drafts.read
    wait(30)
    write("item", "01-export.md", issue(extra: "change: Reworded.\n", body: "New text."))

    assert_equal "Old text.", drafts.read["issues"].first.dig("previous", "body"),
                 "the second Edit of the same revision doesn't make the first one the previous version"
  end

  def test_marking_a_revision_seen_clears_it_until_the_next_one
    write("item", "01-export.md", issue(body: "Old text."))
    drafts.read
    wait(3600)
    write("item", "01-export.md", issue(extra: "change: Reworded.\n", body: "New text."))
    assert_equal "Old text.", drafts.read["issues"].first.dig("previous", "body")

    assert drafts.acknowledge("01-export.md")
    seen = Quartermaster::IssueDrafts.new("item").read["issues"].first
    assert_equal [nil, true], seen.values_at("previous", "acknowledged"), "it stays seen across a GUI restart"

    wait(30)
    write("item", "01-export.md", issue(body: "Newer text."))
    settling = drafts.read["issues"].first
    assert_equal [false, "New text."], [settling["acknowledged"], settling.dig("previous", "body")],
                 "an Edit right after compares against what was acknowledged"

    refute drafts.acknowledge("02-none.md")
    write("item", "03-broken.md", "just text\n")
    refute drafts.acknowledge("03-broken.md")
    assert_raises(ArgumentError) { drafts.acknowledge("../x.md") }
  end

  def test_a_snapshot_whose_file_is_gone_is_dropped
    write("item", "01-a.md", issue(body: "one"))
    drafts.read
    File.delete(File.join(drafts.dir, "01-a.md"))
    write("item", "02-b.md", issue)
    drafts.read
    write("item", "01-a.md", issue(body: "two"))

    assert_nil drafts.read["issues"].first["previous"], "a recreated file doesn't inherit the old one's version"
  end

  def test_delete_removes_the_file_its_snapshot_and_finally_the_directory
    write("item", "01-a.md", issue(extra: "number: 7\n"))
    write("item", "02-b.md", issue)
    drafts.read

    assert_equal ["01-a.md"], drafts.delete_created
    refute File.exist?(File.join(drafts.dir, ".prev", "01-a.md.json"))
    assert_equal ["02-b.md"], drafts.files
    refute drafts.delete("01-a.md")
    assert drafts.delete("02-b.md")
    refute Dir.exist?(drafts.dir)

    write("item", "01-a.md", issue)
    write("item", "notes.txt", "Claude's own")
    drafts.read
    drafts.delete("01-a.md")
    assert_equal ["notes.txt"], Dir.children(drafts.dir), "a file qm doesn't know keeps the directory"
    ["../x.md", ".prev", "a/b.md", nil].each do |name|
      assert_raises(ArgumentError, name.inspect) { drafts.delete(name) }
    end
  end

  def test_a_slug_is_never_a_path
    ["../x", "a/b", "", nil, ".hidden"].each do |slug|
      assert_raises(ArgumentError, slug.inspect) { Quartermaster::IssueDrafts.new(slug) }
    end
  end

  def test_the_signature_moves_with_issue_files_but_not_snapshots
    assert_equal "0", Quartermaster::IssueDrafts.signature
    write("item", "01-a.md", issue)
    first = Quartermaster::IssueDrafts.signature
    refute_equal "0", first

    drafts.read
    assert_equal first, Quartermaster::IssueDrafts.signature, "qm's own snapshot is no news"
    write("item", "01-a.md", issue(body: "longer body text"))
    refute_equal first, Quartermaster::IssueDrafts.signature
  end

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)

  def test_state_pulse_and_the_issues_endpoint
    Quartermaster::WorkItem.create("Item", project: "Qm")
    Quartermaster::WorkItem.create("Other", project: "Qm")
    server = gui
    pulse = JSON.parse(server.respond("GET", "/api/pulse", ok_host, "")[2])
    write("item", "01-a.md", issue)
    write("item", "02-b.md", issue(extra: "number: 9\n"))
    write("item", "03-c.md", "broken")

    moved = JSON.parse(server.respond("GET", "/api/pulse", ok_host, "")[2])
    refute_equal pulse["pulse"], moved["pulse"]
    refute_equal pulse["events"], moved["events"]
    assert_equal ["0", Quartermaster::IssueDrafts.signature], [pulse["issues"], moved["issues"]],
                 "the Issues view refetches on this alone"

    items = JSON.parse(server.respond("GET", "/api/state", ok_host, "")[2])["items"].to_h { |i| [i["slug"], i] }
    assert_nil items["other"]["issues"]
    summary = items["item"]["issues"]
    assert_equal [3, 1, 1], summary.values_at("count", "open", "errors")
    assert_equal %w[01-a.md 02-b.md], summary["versions"].keys

    Dir.mktmpdir do |repo|
      system("git", "init", "-q", repo)
      system("git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/widget.git")
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Qm" => repo } }.to_yaml)

      payload = JSON.parse(server.respond("GET", "/api/issues/item", ok_host, "")[2])
      assert_equal [true, "item", "acme/widget"], payload.values_at("ok", "slug", "repo")
      assert_equal %w[01-a.md 02-b.md], payload["issues"].map { |i| i["file"] }
      assert_equal ["03-c.md"], payload["errors"].map { |e| e["file"] }
    end

    File.write(Quartermaster::CONFIG_FILE, { "projects" => {} }.to_yaml)
    assert_nil JSON.parse(server.respond("GET", "/api/issues/other", ok_host, "")[2])["repo"]
    missing = JSON.parse(server.respond("GET", "/api/issues/nope", ok_host, "")[2])
    assert_equal false, missing["ok"]
  end

  def touch(slug, name, at) = File.utime(at, at, File.join(Quartermaster::ROOT, "issues", slug, name))

  def test_the_cross_item_index_groups_drafts_by_item_in_state_then_recency_order
    Quartermaster::WorkItem.create("Resolved one", project: "Qm").update_state("resolved")
    Quartermaster::WorkItem.create("Fridged", project: "Other").update_state("fridge")
    Quartermaster::WorkItem.create("Fridged later", project: "Other").update_state("fridge")
    Quartermaster::WorkItem.create("Busy", project: "Qm")
    Quartermaster::WorkItem.create("Empty", project: "Qm")
    now = Time.now
    write("resolved-one", "01-a.md", issue(extra: "number: 7\n"))
    write("fridged", "01-a.md", issue(title: "Old"))
    touch("fridged", "01-a.md", now - 300)
    write("fridged-later", "01-a.md", issue(title: "Newer"))
    touch("fridged-later", "01-a.md", now - 60)
    write("busy", "02-crash.md", issue(title: "Crash", kind: "bug"))
    write("busy", "01-made.md", issue(title: "Made", extra: "number: \"#12\"\n"))
    write("busy", "03-broken.md", "broken")
    touch("busy", "03-broken.md", now - 3600)
    FileUtils.mkdir_p(File.join(Quartermaster::ROOT, "issues", "empty", ".prev"))
    write("orphan", "01-a.md", issue)
    server = gui

    Dir.mktmpdir do |repo|
      system("git", "init", "-q", repo)
      system("git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/widget.git")
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Qm" => repo } }.to_yaml)

      payload = JSON.parse(server.respond("GET", "/api/issues", ok_host, "")[2])
      assert payload["ok"]
      items = payload["items"]
      assert_equal %w[busy fridged-later fridged resolved-one], items.map { |i| i["slug"] },
                   "in progress, fridge, resolved; newest change first within a state; no empty dir or orphan"
      busy = items.first
      assert_equal ["Busy", "in_progress", "acme/widget"], busy.values_at("title", "state", "repo")
      assert_equal [{ "file" => "02-crash.md", "title" => "Crash", "kind" => "bug", "number" => nil, "created" => false },
                    { "file" => "01-made.md", "title" => "Made", "kind" => "feature", "number" => 12, "created" => true }],
                   busy["issues"], "uncreated first, no bodies"
      assert_equal ["03-broken.md"], busy["errors"].map { |e| e["file"] }
      assert_operator busy["changed_at"], :>=, Time.at(now.to_i).utc.iso8601, "the newest file decides"
      assert_equal Time.at(now - 300).utc.iso8601, items[2]["changed_at"]
      assert_nil items[1]["repo"], "no repo for a project without a root"
      assert_equal "resolved", items.last["state"]
    end

    item = JSON.parse(server.respond("GET", "/api/issues/busy", ok_host, "")[2])
    assert_equal "busy", item["slug"], "the per-item route is unchanged"
    assert_includes item["issues"].first, "body"
  end

  def test_the_cross_item_index_is_empty_without_drafts
    payload = JSON.parse(gui.respond("GET", "/api/issues", ok_host, "")[2])
    assert_equal({ "ok" => true, "items" => [] }, payload)
  end

  def test_the_acknowledge_action_marks_a_draft_seen
    Quartermaster::WorkItem.create("Item", project: "Qm")
    write("item", "01-a.md", issue)

    reply = gui.actions.dispatch("cmd" => "issue-acknowledge", "slug" => "item", "args" => { "file" => "01-a.md" })

    assert_equal({ "ok" => true, "acknowledged" => true }, reply)
    assert drafts.read["issues"].first["acknowledged"]
  end

  def test_clear_created_deletes_only_the_created_drafts
    Quartermaster::WorkItem.create("Item", project: "Qm")
    write("item", "01-a.md", issue)
    write("item", "02-b.md", issue(extra: "number: 9\n"))
    server = gui

    reply = server.actions.dispatch("cmd" => "issues-clear-created", "slug" => "item", "args" => {})

    assert_equal({ "ok" => true, "cleared" => ["02-b.md"] }, reply)
    assert_equal ["01-a.md"], drafts.files
    assert_equal false, server.actions.dispatch("cmd" => "issues-clear-created", "slug" => "nobody", "args" => {})["ok"]
  end

  def page = served_page(gui, ok_host)

  def test_the_pane_shares_the_diff_slot_and_opens_from_the_toolbar_and_detail_sheet
    html = page

    ['<section class="diff-pane issues-pane" id="issues-pane" hidden>', '<script src="/assets/js/issues.js"></script>',
     '<link rel="stylesheet" href="/assets/css/issues.css">',
     'src="https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"',
     "if (itemIssues(it)) bar.querySelector('.act[data-act=\"diff\"]').after(issuesButton(it));",
     'action("issues", "issues-toggle", `Issues · ${s.count}`, "")', 'case "issues": toggleIssues(); break;',
     "if (diffOpen && issuesOpen) setIssuesOpen(false);", "if (on) { issuesView.key = null; if (diffOpen) toggleDiff(); }",
     "syncIssuesPane();", "body.issues-open .chat-side { display: none; }",
     'body[data-mode="chat"].diff-max .issues-pane { display: none; }',
     'el("button", "issues-row", `<span class="t">Issues (${issues.count})</span>`', "row.onclick = () => openIssuesFor(it);",
     "fetch(`/api/issues/${encodeURIComponent(slug)}`)"].each { |seam| assert_includes html, seam }
  end

  def test_the_diff_or_issues_pane_is_remembered_per_chat
    html = page

    ['sidePanes = JSON.parse(sessionStorage.getItem("qm-side-panes") || "{}") || {};',
     'diffOpen = sidePanes[chatSlug] === "diff";', 'issuesOpen = sidePanes[chatSlug] === "issues";',
     "chatSlug = rows.length ? rows[0].slug : (looseChats.length ? looseChats[0].name : null);\n  }\n  adoptSidePane();"].each { |seam| assert_includes html, seam }
    refute_includes html, "qm-diff-open"
    refute_includes html, "qm-issues-open"
  end

  def test_the_issues_view_is_a_header_mode_beside_prs_toggled_by_shift_i
    html = page

    ['<button data-mode="prs"', '<button data-mode="issues" aria-pressed="false" title="Issue drafts across all items (⇧I)">' \
     'Issues <span id="issues-badge"></span></button>',
     '<link rel="stylesheet" href="/assets/css/issues-list.css">', '<div class="il-body" id="issue-list-body"></div>',
     '<span class="grp"><kbd>⇧I</kbd><span>issues</span></span>',
     '<span class="grp issues-only"><kbd>⏎</kbd><span>open in its chat</span></span>',
     'if (e.key === "I") { e.preventDefault(); setMode(mode === "issues" ? "board" : "issues"); return; }',
     'if (mode === "issues") return issueListKey(e);', 'if (["chat", "prs", "issues"].includes(savedMode)) setMode(savedMode);',
     'else if (m === "issues") { renderIssueList(); loadIssueIndex(); }',
     'body:not([data-mode="issues"]) .il-wrap { display: none; }',
     'body:not([data-mode="issues"]) .legend .issues-only { display: none; }',
     "renderIssuesBadge();\n  if (mode === \"chat\") renderChat();", 'if (mode === "issues") renderIssueList();',
     'case "i": if (it) openDetail(it); break;'].each { |seam| assert_includes html, seam }
    assert_operator html.index('data-mode="prs"'), :<, html.index('data-mode="issues"')
    assert_operator html.index("/assets/js/issues.js"), :<, html.index("/assets/js/issues-list.js"),
                    "it reuses the pane's kindPill and openIssuesFor"
    assert_operator html.index("/assets/js/issues-list.js"), :<, html.index("/assets/js/events.js")
  end

  def test_the_issues_view_badge_counts_drafts_not_yet_on_github
    html = page

    ['const open = items.reduce((n, it) => n + ((it.issues && it.issues.open) || 0), 0);',
     'badge.innerHTML = open ? `<span class="col-count">${open}</span>` : "";'].each { |seam| assert_includes html, seam }
  end

  def test_the_issues_view_fetches_the_index_on_open_and_when_an_issue_file_changes
    html = page

    ['res = await (await fetch("/api/issues")).json();',
     "const { pulse, events, issues } = await r.json();",
     "const issuesMoved = lastIssues !== null && issues !== lastIssues;",
     'if (issuesMoved && !onChat) await refresh();', 'if (issuesMoved && mode === "issues") loadIssueIndex();'].each { |seam| assert_includes html, seam }
  end

  def test_the_issues_view_groups_rows_by_item_and_opens_the_pane_on_that_issue
    html = page

    ['g.issues.map(issue => ({ group: g, file: issue.file, issue }))',
     '.concat(g.errors.map(error => ({ group: g, file: error.file, error }))));',
     'state.append(el("span", "col-dot dot-" + g.state), el("span", "", esc(stateLabel(g.state))));',
     'const n = (r.file.match(/^\d+/) || [""])[0];', "row.append(title, kindPill(r.issue.kind));",
     'row.appendChild(issueNumberLink(r.issue.number, r.group.repo));',
     'if (!repo) return el("span", "il-number", `#${number}`);',
     "a.href = `https://github.com/${repo}/issues/${number}`;",
     'row.appendChild(el("span", "il-name", `⚠ ${esc(r.file)}`));',
     ".il-row.created .il-n, .il-row.created .il-name, .il-row.created .iss-pill { opacity: .55; }",
     "openIssuesFor(it, r.error ? null : r.file);",
     "function openIssuesFor(it, file = null) {", "if (file) issuesPick[it.slug] = file;",
     "else if (file && issuesView.slug === it.slug && issuesView.data) renderIssuesPane();",
     'case "j": case "ArrowDown": e.preventDefault(); moveIssueList(1); break;',
     'case "Enter": if (r && !e.target.closest(".il-row a")) { e.preventDefault(); openIssueRow(r); } break;'
    ].each { |seam| assert_includes html, seam }
    view = html[/------- Issues view: every item's issue drafts \(GET.*?\nfunction issueListKey.*?\n\}\n/m]
    assert view
    refute_match(/act\(|method: "POST"/, view, "read-only: creating, deleting and commenting stay in the pane")
  end

  def test_the_pane_renders_tabs_blocks_revisions_and_created_issues
    html = page

    ['section("Created on GitHub")', 'section("Unreadable", "bad")', 'el("span", "iss-dot")',
     "<b>Changed in the last revision:</b> ${esc(i.change)}", 'act("issue-acknowledge", { slug, args: { file } })',
     "else if (i.change && !i.acknowledged)", 'copy.onclick = () => copyText(i.body + "\n", copy);',
     "<b>This file doesn't read as an issue draft:</b> ${esc(e.error)}",
     "a.href = `https://github.com/${repo}/issues/${i.number}`;", 'if (i.created) main.dataset.readonly = "1";',
     'act("issues-clear-created", { slug: d.slug })',
     "title.dataset.issueTarget = i.file;", 'node.classList.add("iss-block");', "node.dataset.src = src;",
     'if (seen && !seen.has(src)) node.classList.add("changed");',
     "renderIssueBody(i.body, prev ? issueBlockSources(prev.body) : null)",
     'issueMarked.use({ renderer: { html: (x) => esc(typeof x === "string" ? x : x.text) } });',
     '.iss-block.changed, .iss-title.changed {'].each { |seam| assert_includes html, seam }
  end

  def test_a_revision_toasts_once_the_files_are_still_without_switching_views
    html = page

    ["noticeIssuesInState(items);", "setTimeout(() => toastIssuesRevised(it.slug), ISSUES_QUIET_MS)",
     'toast(`${plural(n, "issue")} revised${here ? "" : ` for ${slug}`}`);'].each { |seam| assert_includes html, seam }
    revision = html[/function noticeIssuesInState.*?\n}\n/m] + html[/function toastIssuesRevised.*?\n}\n/m]
    refute_match(/setMode|openChat|selectChat/, revision, "a revision never switches the view")
  end

  def test_a_click_on_a_block_or_the_title_puts_an_issue_comment_except_on_a_created_issue
    html = page

    ['$("#issues-body").addEventListener("click", e => {', 'if (!main || main.dataset.readonly || !main.dataset.title) return;',
     'const target = e.target.closest(".iss-block, .iss-title[data-issue-target]");',
     'const block = target.classList.contains("iss-block") ? target.dataset.src : "";',
     'if (sel && !sel.isCollapsed && target.contains(sel.anchorNode)) return;',
     'draftAction("issue-comment-put", slug, { ...address, comment });',
     'const address = { file: main.dataset.file, block: block || "", title: main.dataset.title || "" };',
     'del.onclick = () => { putIssueComment(main, block, ""); removeIssueCommentRow(row); };'].each { |seam| assert_includes html, seam }
    assert_includes html[/function putIssueComment.*?\n}\n/m], "draftsChanged();", "a put or ✕ in the pane shows in the tray at once"
    assert_match(/if \(!i\.created\) acts\.appendChild\(createButton\("Create on GitHub", \[i\.file\]/, html,
                 "a created issue has no create button")
  end

  def test_comments_render_under_their_block_by_exact_text_and_stale_ones_at_the_top
    html = page

    ['return [...main.querySelectorAll(".iss-block")].find(b => b.dataset.src === block) || null;',
     'const row = issueCommentRow(main, block, { open, stale: !!block && !anchor });',
     'if (!block) main.querySelector(".iss-cmts").appendChild(row);',
     'else if (!anchor) main.querySelector(".iss-stale").appendChild(row);',
     '} else if (anchor.tagName === "LI") anchor.appendChild(row);',
     'main.append(el("div", "iss-cmts"), el("div", "iss-stale"));',
     '!block ? "on the whole issue" : stale ? "on a block that changed" : "comment"',
     'if (stale) row.appendChild(el("blockquote", "iss-cmt-quote", esc(block)));',
     "issueCommentsOn(d.slug, i.file).forEach(c => placeIssueComment(main, c.block, editing.get(issueKey(i.file, c.block))));",
     ".iss-cmt.stale { border-left-color: var(--warn); }"].each { |seam| assert_includes html, seam }
    refute_match(/function placeIssueComment.*?(indexOf|includes\(block\)|startsWith)/m, html[/function placeIssueComment.*?\n}\n/m],
                 "anchoring is exact, never fuzzy")
  end

  def test_open_editors_survive_rebuilds_which_follow_the_drafts
    html = page

    ["const editing = openIssueEditors(body);", "issuesView.drafts = issueDraftsShown();",
     "renderIssue(current, d, sameIssue ? editing : new Map())",
     'body.querySelectorAll(".iss-cmt textarea").forEach(box => {',
     "caret: focus ? [box.selectionStart, box.selectionEnd] : null",
     "if (issuesShown() && issuesView.data && issuesView.slug === chatSlug && issuesView.drafts !== issueDraftsShown()) renderIssuesPane();",
     "const diffDraftsShown = () => itemDrafts().filter(d => !isIssueComment(d))"].each { |seam| assert_includes html, seam }
  end

  def test_the_tray_lists_issue_comments_as_their_own_group_under_either_pane
    html = page

    ['const host = $(inIssues ? "#issues-pane" : "#diff-pane");', "if (tray.parentElement !== host) host.appendChild(tray);",
     "const drafts = (diffOpen || inIssues) && chatSlug ? trayOrder(itemDrafts()) : [];",
     'list.appendChild(el("div", "dt-group", "On the issue drafts"))',
     "list.appendChild(isIssueComment(d) ? issueTrayEntry(d) : isThreadReply(d) ? replyTrayEntry(d) : trayEntry(d, anchors.get(d.id)));",
     'const entry = el("div", "dt-entry issue");', "where.onclick = () => revealIssueComment(d);",
     'issueComments && plural(issueComments, "issue comment")',
     "return github.concat(comments, drafts.filter(isAnnotation), issueComments);",
     "else if (issuesOnly) setIssuesOpen(true);", "const now = drafts.filter(isAnnotation).map(d => d.id);",
     'if (row) flashDiffTarget(row, "center");'].each { |seam| assert_includes html, seam }
  end

  def test_create_on_github_is_disabled_like_send
    html = page

    ['act("issues-create", { slug, args: files ? { files } : {} })', "const blocker = diffSendBlocker();",
     "b.disabled = !!blocker;", "b.title = blocker || b.dataset.why;",
     "`Create all ${uncreated} on GitHub`", 'if (!panes.includes(chatSlug)) return "Open the chat in qm first'].each do |seam|
      assert_includes html, seam
    end
    sync = html[/function syncIssuesPane.*?\n}\n/m]
    assert_includes sync, "syncIssueCreateButtons();", "every chat render re-checks the turn"
  end

  def test_issues_dir_prints_and_creates_the_directory
    Quartermaster::WorkItem.create("Item", project: "Qm")
    out, = capture_io { Quartermaster::CLI.new.run(["issues-dir", "item"]) }

    assert_equal File.join(Quartermaster::ROOT, "issues", "item"), out.strip
    assert Dir.exist?(out.strip)
    _out, err = capture_subprocess_io do
      assert_raises(SystemExit) { Quartermaster::CLI.new.run(["issues-dir", "../item"]) }
    end
    assert_match(/not a work item slug/, err)
    _out, err = capture_subprocess_io do
      assert_raises(SystemExit) { Quartermaster::CLI.new.run(["issues-dir", "nope"]) }
    end
    assert_match(/no work item 'nope'/, err)
  end
end
