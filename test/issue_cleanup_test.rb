# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/issue_cleanup_test.rb`).
require_relative "test_helper"

# Cleanup and sweep entries for an item's issue drafts: created ones go
# freely, never-created ones need force, nothing is blocked.
class IssueCleanupTest < Minitest::Test
  include QmTestHelpers

  def issue(title, extra: "") = "---\ntitle: #{title}\nkind: feature\n#{extra}---\n\nBody of #{title}.\n"

  def write(slug, name, content)
    dir = File.join(Quartermaster::ROOT, "issues", slug)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), content)
  end

  def issues_dir(slug) = File.join(Quartermaster::ROOT, "issues", slug)

  def cleanup
    Quartermaster::Cleanup.new(project_map: Quartermaster::ProjectMap.new(roots: {}), runner: quiet_runner,
                               session_log: Quartermaster::SessionLog.new,
                               pr_status: Quartermaster::PrStatus.new(fetcher: ->(*) { "OPEN" }))
  end

  def comment(slug, file, block)
    Quartermaster::Drafts.new(slug).put_issue_comment("file" => file, "block" => block, "title" => "t", "comment" => "c")
  end

  def by_file(plan) = plan.issue_drafts.to_h { |e| [File.basename(e.path), e] }

  def test_an_items_issue_files_are_entries_created_ones_ticked_the_rest_need_force
    item = Quartermaster::WorkItem.create("Drafted", project: "Nowhere")
    write("drafted", "01-export.md", issue("Add export", extra: "number: 40\n"))
    write("drafted", "02-crash.md", issue("Crash on save"))
    write("drafted", "03-broken.md", "no frontmatter\n")
    comment("drafted", "02-crash.md", "")
    comment("drafted", "02-crash.md", "Body of Crash on save.")

    plan = cleanup.plan_item(item)
    entries = by_file(plan)

    created, open, broken = entries.values_at("01-export.md", "02-crash.md", "03-broken.md")
    assert_equal ["issue-draft", "ok", true, ["#40"], "Add export", "drafted"],
                 created.to_h.values_at("kind", "status", "ticked", "notes", "title", "item")
    assert_equal "issue:drafted/01-export.md", created.id
    assert_equal ["warn", false, ["never created on GitHub", "2 unsent comments"], "Crash on save"],
                 [open.status, open.ticked, open.reasons, open.title]
    assert_equal "warn", broken.status
    assert_match(/doesn't parse/, broken.reasons.join)
    refute plan.entries.any?(&:blocked?)
    assert_equal "3 issue drafts — 1 ready, 2 need a look", plan.summary
    assert_equal ["no repo root configured for 'Nowhere'"], plan.notes

    starts = []
    outcomes = cleanup.execute(plan, selected: [created.id], force: [open.id],
                                     on_start: ->(entry, index, total) { starts << [entry.id, index, total] })

    assert_equal [[created.id, 1, 2], [open.id, 2, 2]], starts
    assert_equal [%w[removed deleted], %w[removed deleted]], outcomes.map { |o| [o.result, o.message] }
    assert_equal ["03-broken.md"], Quartermaster::IssueDrafts.new("drafted").files
    assert_empty Quartermaster::Drafts.new("drafted").entries, "the deleted file's comments go with it"

    rest = by_file(cleanup.plan_item(item))
    assert_equal ["skipped"], cleanup.execute(Quartermaster::Cleanup::Plan.new(scope: "drafted", entries: rest.values, notes: []),
                                              selected: rest.values.map(&:id)).map(&:result)
    cleanup.execute(Quartermaster::Cleanup::Plan.new(scope: "drafted", entries: rest.values, notes: []),
                    selected: [], force: rest.values.map(&:id))
    refute File.exist?(issues_dir("drafted")), "the last file takes the directory and its .prev along"
  end

  def test_sweep_lists_sets_of_resolved_and_missing_items_and_never_preticks_an_open_items
    Quartermaster::WorkItem.create("Done", project: "Nowhere").update_state("resolved")
    Quartermaster::WorkItem.create("Busy", project: "Nowhere")
    write("done", "01-a.md", issue("A", extra: "number: 7\n"))
    write("gone", "01-b.md", issue("B", extra: "number: 8\n"))
    write("gone", "02-c.md", issue("C"))
    write("busy", "01-d.md", issue("D", extra: "number: 9\n"))
    FileUtils.mkdir_p(File.join(Quartermaster::ROOT, "issues", ".hidden"))

    plan = cleanup.plan_sweep
    entries = plan.issue_drafts.to_h { |e| ["#{e.item}/#{File.basename(e.path)}", e] }

    assert_equal %w[busy/01-d.md done/01-a.md gone/01-b.md gone/02-c.md], entries.keys.sort
    assert entries["done/01-a.md"].ticked
    assert entries["gone/01-b.md"].ticked
    assert_equal ["warn", false], [entries["gone/02-c.md"].status, entries["gone/02-c.md"].ticked]
    busy = entries["busy/01-d.md"]
    assert_equal ["ok", false], [busy.status, busy.ticked]
    assert_includes busy.notes, "belongs to unresolved item 'busy'"

    assert_equal [entries["gone/02-c.md"].id], Quartermaster::Cleanup.resolve_ids(plan, ["gone/02-c.md"])
    assert_equal [busy.id], Quartermaster::Cleanup.resolve_ids(plan, [busy.path])
  end

  def test_the_cli_and_the_checklist_render_the_kind
    item = Quartermaster::WorkItem.create("Shown", project: "Nowhere")
    write("shown", "01-export.md", issue("Add export"))

    stdout, = capture_io { Quartermaster::CLI.new.run(%w[cleanup shown]) }

    assert_includes stdout, "1 issue draft — 0 ready, 1 needs a look"
    assert_match(%r{\[ \] .*⚠ issue-draft.* shown/01-export\.md “Add export” — never created on GitHub}, stdout)

    stdout, = capture_io { Quartermaster::CLI.new.run(%w[cleanup shown --yes --force shown/01-export.md]) }
    assert_match(%r{removed.* issue:shown/01-export\.md: deleted|removed.* shown/01-export\.md: deleted}, stdout)
    assert_empty Quartermaster::IssueDrafts.new(item.slug).files

    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
    page = served_page(gui, { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" })
    assert_includes page, '"issue-draft": "issue draft"'
    assert_includes page, "Clean up its issue drafts?"
  end
end
