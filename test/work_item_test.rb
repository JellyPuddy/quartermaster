# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/work_item_test.rb`).
require_relative "test_helper"

class WorkItemTest < Minitest::Test
  include QmTestHelpers

  def test_slugify_reduces_titles_to_filename_safe_slugs
    assert_equal "fix-sso-login-my-app", Quartermaster::WorkItem.slugify("Fix: SSO login (My App)!")
  end

  def test_slugify_transliterates_accented_letters
    assert_equal "uni", Quartermaster::WorkItem.slugify("ünï")
    assert_equal "cafe-creme", Quartermaster::WorkItem.slugify("Café Crème")
  end

  def test_a_title_without_letters_or_digits_creates_nothing
    error = assert_raises(ArgumentError) { Quartermaster::WorkItem.create("日本語 タイトル", project: "MyApp") }

    assert_equal "title needs at least one letter or digit (a-z, 0-9) for its slug", error.message
    assert_empty Dir.glob(File.join(Quartermaster::WORK_ITEMS_DIR, "*.md"), File::FNM_DOTMATCH)
  end

  def test_create_and_find_round_trip_preserves_frontmatter
    Quartermaster::WorkItem.create("My item", project: "MyApp", branch: "issue/123-foo",
                        session_id: "sess-1", description: "Something")
    item = Quartermaster::WorkItem.find("my-item")

    assert_equal Quartermaster::WORK_ITEM_VERSION, item.front["v"]
    assert_equal "My item", item.title
    assert_equal "in_progress", item.state
    assert_equal "MyApp", item.project
    assert_equal ["issue/123-foo"], item.branches
    assert_equal "123", item.issue_number
    assert_equal [{ "id" => "sess-1" }], item.sessions
    assert_includes item.body, "## Description"
    assert_includes item.body, "Something"
  end

  def test_create_rejects_duplicate_slugs
    Quartermaster::WorkItem.create("My item", project: "MyApp")
    assert_raises(ArgumentError) { Quartermaster::WorkItem.create("My item!", project: "MyApp") }
  end

  def test_attach_session_dedupes
    item = Quartermaster::WorkItem.create("My item", project: "MyApp", session_id: "sess-1")

    refute item.attach_session("sess-1")
    assert item.attach_session("sess-2")
    assert_equal %w[sess-1 sess-2], Quartermaster::WorkItem.find("my-item").sessions.map { |s| s["id"] }
  end

  def test_detach_session_elsewhere_leaves_only_the_kept_item_attached
    Quartermaster::WorkItem.create("Alpha", project: "MyApp", session_id: "sess-m")
    Quartermaster::WorkItem.create("Beta", project: "MyApp", session_id: "sess-m")

    detached = Quartermaster::WorkItem.detach_session_elsewhere("sess-m", keep: "beta")

    assert_equal ["alpha"], detached
    assert_empty Quartermaster::WorkItem.find("alpha").sessions
    assert_equal [{ "id" => "sess-m" }], Quartermaster::WorkItem.find("beta").sessions
  end

  def test_for_session_finds_the_linked_item_and_nil_otherwise
    Quartermaster::WorkItem.create("Alpha", project: "MyApp", session_id: "sess-a")
    Quartermaster::WorkItem.create("Beta", project: "MyApp", session_id: "sess-b")

    assert_equal "Alpha", Quartermaster::WorkItem.for_session("sess-a").title
    assert_equal "Beta", Quartermaster::WorkItem.for_session("sess-b").title
    assert_nil Quartermaster::WorkItem.for_session("sess-unknown")
    assert_nil Quartermaster::WorkItem.for_session(nil)
  end

  def test_notes_pack_together_inside_the_notes_section
    item = Quartermaster::WorkItem.create("My item", project: "MyApp")
    item.add_note("first")
    Quartermaster::WorkItem.find("my-item").add_note("second")

    body = Quartermaster::WorkItem.find("my-item").body
    assert_match(/## Notes\n- \d{4}-\d{2}-\d{2}: first\n- \d{4}-\d{2}-\d{2}: second\n/, body)
    assert_operator body.index("second"), :<, body.index("## Snapshots")
  end

  def test_update_state_validates_against_known_states
    item = Quartermaster::WorkItem.create("My item", project: "MyApp")
    item.update_state("fridge")

    assert_equal "fridge", Quartermaster::WorkItem.find("my-item").state
    assert_raises(ArgumentError) { item.update_state("done") }
  end

  def test_branches_accumulate_for_stacks_and_renames_are_unlink_plus_link
    Quartermaster::WorkItem.create("My item", project: "MyApp", branch: "worktree-foo")
    Quartermaster::WorkItem.find("my-item").link_branch("issue/55-part-2")
    Quartermaster::WorkItem.find("my-item").link_branch("issue/55-part-2")

    assert_equal %w[worktree-foo issue/55-part-2], Quartermaster::WorkItem.find("my-item").branches

    Quartermaster::WorkItem.find("my-item").unlink_branch("worktree-foo")
    Quartermaster::WorkItem.find("my-item").link_branch("issue/55-part-1")
    assert_equal %w[issue/55-part-2 issue/55-part-1], Quartermaster::WorkItem.find("my-item").branches
  end

  def test_a_status_board_is_absent_until_linked_and_goes_away_when_unlinked
    Quartermaster::WorkItem.create("My item", project: "MyApp")
    assert_nil Quartermaster::WorkItem.find("my-item").board

    Quartermaster::WorkItem.find("my-item").link_board("https://claude.ai/code/artifact/abc")
    assert_equal "https://claude.ai/code/artifact/abc", Quartermaster::WorkItem.find("my-item").board

    Quartermaster::WorkItem.find("my-item").link_board("https://claude.ai/code/artifact/def")
    assert_equal "https://claude.ai/code/artifact/def", Quartermaster::WorkItem.find("my-item").board

    Quartermaster::WorkItem.find("my-item").unlink_board
    assert_nil Quartermaster::WorkItem.find("my-item").board
    refute_includes Quartermaster::WorkItem.find("my-item").front, "board"
  end

  def test_legacy_singular_branch_frontmatter_still_reads
    Quartermaster.ensure_setup
    File.write(Quartermaster::WorkItem.path_for("legacy"),
               "---\nv: 1\ntitle: Legacy\nstate: in_progress\nproject: P\nbranch: issue/9-old\n---\n\n## Description\n")

    assert_equal ["issue/9-old"], Quartermaster::WorkItem.find("legacy").branches
  end

  def test_retitle_changes_the_title_but_never_the_slug
    Quartermaster::WorkItem.create("Vague idea", project: "MyApp")
    Quartermaster::WorkItem.find("vague-idea").retitle("Sharp, specific title")

    item = Quartermaster::WorkItem.find("vague-idea")
    assert_equal "Sharp, specific title", item.title
    assert_equal "vague-idea", item.slug
  end

  def test_describe_replaces_the_description_and_leaves_other_sections_alone
    item = Quartermaster::WorkItem.create("My item", project: "MyApp", description: "Old text")
    item.add_note("keep me")
    item.add_snapshot("sess-1", "keep me too")

    Quartermaster::WorkItem.find("my-item").describe("New multi-line\ndescription.")

    body = Quartermaster::WorkItem.find("my-item").body
    assert_includes body, "New multi-line\ndescription."
    refute_includes body, "Old text"
    assert_includes body, "keep me"
    assert_includes body, "keep me too"
    assert_operator body.index("description."), :<, body.index("## Notes")
  end

  def test_describe_reads_stdin_when_no_text_given
    Quartermaster::WorkItem.create("My item", project: "MyApp")

    _out, _err, status = Open3.capture3(
      { "QM_ROOT" => Quartermaster::ROOT }, RbConfig.ruby, QM_BIN, "describe", "my-item",
      stdin_data: "Piped in.\nSecond line."
    )

    assert_equal 0, status.exitstatus
    assert_includes Quartermaster::WorkItem.find("my-item").body, "Piped in.\nSecond line."
  end

  # martijnpieters/quartermaster#2: a reader racing a save once saw a truncated
  # file and failed with "malformed work item file", dropping that note.
  def test_concurrent_qm_note_processes_all_land
    Quartermaster::WorkItem.create("Shared", project: "MyApp", description: "long history\n" * 20_000)
    env = { "QM_ROOT" => Quartermaster::ROOT, "QM_SKIP" => nil }
    writers = (1..12).map do |i|
      err_r, err_w = IO.pipe
      pid = Process.spawn(env, RbConfig.ruby, QM_BIN, "note", "shared", "n#{i}", out: File::NULL, err: err_w)
      err_w.close
      [pid, err_r]
    end

    failures = writers.filter_map do |pid, err|
      _, status = Process.wait2(pid)
      message = err.read
      err.close
      message unless status.success?
    end

    assert_empty failures
    texts = Quartermaster::WorkItem.find("shared").notes.map(&:text)
    assert_equal (1..12).map { |i| "n#{i}" }.sort, texts.sort
  end

  # The lock-free readers (GUI, viewer, qm list, a mutator's first find) must
  # never catch a save half-way.
  def test_a_reader_racing_saves_never_sees_a_partial_file
    item = Quartermaster::WorkItem.create("Busy", project: "MyApp", description: "long history\n" * 20_000)
    reader = <<~RUBY
      load #{QM_BIN.dump}
      $stdout.puts("ready"); $stdout.flush
      torn = 0
      begin
        torn += 1 if Quartermaster::WorkItem.find("busy").description.empty? while IO.select([$stdin], nil, nil, 0).nil?
      rescue ArgumentError => e
        abort(e.message)
      end
      abort("\#{torn} reads saw no description") unless torn.zero?
    RUBY
    Open3.popen3({ "QM_ROOT" => Quartermaster::ROOT }, RbConfig.ruby, "-e", reader) do |stdin, stdout, stderr, wait|
      assert_equal "ready\n", stdout.gets
      150.times { |i| item.add_note("n#{i}") }
      stdin.close

      assert wait.value.success?, "reader saw a partial work item: #{stderr.read}"
    end
  end

  def test_save_never_leaves_a_temp_file_and_keeps_the_items_permissions
    item = Quartermaster::WorkItem.create("Private", project: "MyApp")
    path = Quartermaster::WorkItem.path_for("private")
    File.chmod(0o600, path)

    item.add_note("still private")

    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal ["private.md"], Dir.children(Quartermaster::WORK_ITEMS_DIR) - [".lock"]
    assert_equal ["still private"], Quartermaster::WorkItem.find("private").notes.map(&:text)
  end

  # A handle found before another process deleted the item must not write its
  # stale copy back: the mutation re-reads under the lock and finds nothing.
  def test_a_stale_handle_never_resurrects_a_deleted_item
    Quartermaster::WorkItem.create("Gone", project: "MyApp")
    handle = Quartermaster::WorkItem.find("gone")
    File.delete(Quartermaster::WorkItem.path_for("gone"))

    error = assert_raises(ArgumentError) { handle.add_note("too late") }
    assert_equal "no work item 'gone'", error.message
    refute File.exist?(Quartermaster::WorkItem.path_for("gone"))
  end
end

class AtomicFileTest < Minitest::Test
  include QmTestHelpers

  def test_writes_a_new_file_with_the_default_permissions
    path = File.join(Dir.mktmpdir("qm-atomic"), "fresh.txt")

    Quartermaster::AtomicFile.write(path, "hello\n")

    assert_equal "hello\n", File.read(path)
    assert_equal 0o666 & ~File.umask, File.stat(path).mode & 0o777
    assert_equal ["fresh.txt"], Dir.children(File.dirname(path))
  end

  def test_replaces_an_existing_file_keeping_its_mode
    path = File.join(Dir.mktmpdir("qm-atomic"), "kept.txt")
    File.write(path, "old")
    File.chmod(0o640, path)

    Quartermaster::AtomicFile.write(path, "new")

    assert_equal "new", File.read(path)
    assert_equal 0o640, File.stat(path).mode & 0o777
  end

  def test_a_failed_write_leaves_the_original_and_no_temp_file
    dir = Dir.mktmpdir("qm-atomic")
    path = File.join(dir, "kept.txt")
    File.write(path, "old")
    content = Object.new
    def content.to_s = raise(IOError, "disk full")

    assert_raises(IOError) { Quartermaster::AtomicFile.write(path, content) }
    assert_equal "old", File.read(path)
    assert_equal ["kept.txt"], Dir.children(dir)
  end
end

class ProjectMapTest < Minitest::Test
  include QmTestHelpers

  def test_maps_a_repo_root_and_its_subdirectories_to_the_project
    map = Quartermaster::ProjectMap.new(roots: { "MyApp" => "/repos/my-app" })

    assert_equal "MyApp", map.project_for("/repos/my-app")
    assert_equal "MyApp", map.project_for("/repos/my-app/app/models")
    assert_equal "No project", map.project_for("/repos/my-app-other")
    assert_equal "No project", map.project_for("/somewhere/else")
    assert_equal "No project", map.project_for(nil)
  end

  def test_resolves_worktrees_to_their_main_repo_project
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      worktree = File.join(dir, "elsewhere", "repo-wt")
      system("git", "init", "-q", "-b", "main", repo)
      system("git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      system("git", "-C", repo, "worktree", "add", "-q", "-b", "feature", worktree)

      map = Quartermaster::ProjectMap.new(roots: { "Repo" => repo })
      assert_equal "Repo", map.project_for(worktree)
    end
  end

  def test_reads_roots_from_the_config_file
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Foo" => "/repos/foo" } }.to_yaml)

    assert_equal "Foo", Quartermaster::ProjectMap.new.project_for("/repos/foo/sub")
  end
end

class NoteTest < Minitest::Test
  include QmTestHelpers

  def test_stored_form_round_trips_through_parse
    original = Quartermaster::Note.new(stamp: "2026-08-10", kind: "open", text: "blocked on X", position: 3)
    reparsed = Quartermaster::Note.parse(original.to_s, position: 3)

    assert_equal original.to_h, reparsed.to_h
  end

  def test_default_kind_is_unmarked_in_the_file_and_survives_reparse
    note = Quartermaster::Note.new(stamp: "2026-08-10", kind: "decision", text: "chose Y")

    refute_includes note.to_s, "["
    assert_equal "decision", Quartermaster::Note.parse(note.to_s).kind
  end

  def test_headline_note_prefers_open_over_newer_notes
    item = Quartermaster::WorkItem.create("Headlined", project: "No project")
    item.add_note("old blocker", kind: "open")
    item.add_note("newer decision")
    item.add_note("newest mechanics", kind: "history")

    assert_equal "old blocker", Quartermaster::WorkItem.find("headlined").headline_note.text
  end
end

class WorkItemToHTest < Minitest::Test
  include QmTestHelpers

  def test_to_h_exposes_the_static_shape_from_the_file_alone
    item = Quartermaster::WorkItem.create("My thing", project: "MyApp", branch: "issue/77-thing",
                              session_id: "sess-1", description: "The description")
    item.add_note("first note")
    item.attach_session("sess-2")

    hash = Quartermaster::WorkItem.find("my-thing").to_h

    assert_equal "my-thing", hash["slug"]
    assert_equal "My thing", hash["title"]
    assert_equal "in_progress", hash["state"]
    assert_equal "MyApp", hash["project"]
    assert_equal ["issue/77-thing"], hash["branches"]
    assert_equal "77", hash["issue_number"]
    assert_equal %w[sess-1 sess-2], hash["session_ids"]
    assert_equal 2, hash["sessions"]
    assert_equal "The description", hash["description"]
    assert_equal [{ "stamp" => Date.today.to_s, "kind" => "decision", "text" => "first note", "position" => 1 }],
                 hash["notes"]
  end

  def test_notes_come_back_newest_first
    item = Quartermaster::WorkItem.create("Noted", project: "Nowhere")
    item.add_note("older")
    Quartermaster::WorkItem.find("noted").add_note("newer")

    texts = Quartermaster::WorkItem.find("noted").notes.map(&:text)
    assert_equal %w[newer older], texts
  end

  def test_snapshots_parse_newest_first_with_session_ids
    item = Quartermaster::WorkItem.create("Snapped", project: "Nowhere")
    item.add_snapshot("sess-old", "first snapshot")
    Quartermaster::WorkItem.find("snapped").add_snapshot("sess-new", "second snapshot")

    snaps = Quartermaster::WorkItem.find("snapped").snapshots
    assert_equal %w[sess-new sess-old], snaps.map { |s| s["session"] }
    assert_equal "second snapshot", snaps.first["text"]
  end
end

# Epics (docs/areas/work-items.md): a `kind: epic` item groups children one level
# deep; a child names it in `epic:`, and links hang on any item.
class EpicTest < Minitest::Test
  include QmTestHelpers

  def qm(*argv) = capture_io { Quartermaster::CLI.new.run(argv) }

  def qm_fails(*argv)
    capture_io do
      error = assert_raises(SystemExit) { Quartermaster::CLI.new.run(argv) }
      refute error.success?
    end
  end

  def find(slug) = Quartermaster::WorkItem.find(slug)

  def epic(title = "Epic Alpha") = Quartermaster::WorkItem.create(title, project: "MyApp", front: { "kind" => "epic" })

  def test_qm_new_kind_epic_makes_an_epic_with_no_session
    out, = qm("new", "--kind", "epic", "--project", "MyApp", "Epic Alpha")

    item = find("epic-alpha")
    assert_equal "epic-alpha\n", out
    assert item.epic?
    assert_equal "epic", item.front["kind"]
    assert_empty item.sessions
    _, err = qm_fails("new", "--kind", "automation", "Sneaky")
    assert_includes err, "--kind takes only 'epic'"
  end

  def test_qm_new_epic_puts_the_new_item_inside_the_epic
    epic
    out, = qm("new", "--epic", "epic-alpha", "Child one")

    assert_equal "child-one\n", out
    assert_equal "epic-alpha", find("child-one").epic
    assert_equal ["child-one"], find("epic-alpha").children.map(&:slug)
  end

  def test_qm_new_into_a_missing_or_non_epic_target_creates_nothing
    Quartermaster::WorkItem.create("Plain", project: "MyApp")

    _, err = qm_fails("new", "--epic", "plain", "Child one")
    assert_includes err, "'plain' is not an epic"
    _, err = qm_fails("new", "--epic", "nope", "Child two")
    assert_includes err, "no work item 'nope'"
    _, err = qm_fails("new", "--kind", "epic", "--epic", "plain", "Nested")
    assert_includes err, "an epic can't be inside another epic"
    assert_equal ["plain"], Quartermaster::WorkItem.all.map(&:slug)
  end

  def test_qm_epic_sets_and_clears_an_items_epic_keeping_unknown_fields
    epic
    item = Quartermaster::WorkItem.create("Child", project: "MyApp")
    item.front["future_field"] = "kept"
    item.save

    out, = qm("epic", "child", "epic-alpha")
    assert_equal "child → epic epic-alpha\n", out
    assert_equal "epic-alpha", find("child").epic
    assert_equal "kept", find("child").front["future_field"]

    out, = qm("epic", "child", "--clear")
    assert_equal "child → (no epic)\n", out
    assert_nil find("child").epic
    refute find("child").front.key?("epic")
    assert_equal "kept", find("child").front["future_field"]
  end

  def test_qm_epic_refuses_nesting_automations_self_and_non_epics
    epic
    epic("Epic Beta")
    auto = Quartermaster::WorkItem.create("Digest", project: "MyApp", front: { "kind" => "automation" })
    Quartermaster::WorkItem.create("Plain", project: "MyApp")
    Quartermaster::WorkItem.create("Other", project: "MyApp")

    assert_includes qm_fails("epic", "epic-beta", "epic-alpha")[1], "an epic can't be inside another epic"
    assert_includes qm_fails("epic", auto.slug, "epic-alpha")[1], "an automation can't join an epic"
    assert_includes qm_fails("epic", "plain", "other")[1], "'other' is not an epic"
    assert_includes qm_fails("epic", "plain", "plain")[1], "'plain' is not an epic"
    assert_includes qm_fails("epic", "plain")[1], "usage: qm epic"
    assert_nil find("plain").epic
  end

  def test_qm_link_adds_replaces_by_label_and_removes
    epic

    qm("link", "epic-alpha", "Tracker", "https://example.com/t/1")
    qm("link", "epic-alpha", "Doc", "https://example.com/doc")
    out, = qm("link", "epic-alpha", "Tracker", "https://example.com/t/2")
    assert_equal "epic-alpha → Tracker, Doc\n", out
    assert_equal [{ "label" => "Tracker", "url" => "https://example.com/t/2" },
                  { "label" => "Doc", "url" => "https://example.com/doc" }], find("epic-alpha").links

    out, = qm("link", "epic-alpha", "Tracker", "--remove")
    assert_equal "epic-alpha → Doc\n", out
    assert_includes qm_fails("link", "epic-alpha", "Tracker", "--remove")[1], "no link 'Tracker'"
    assert_includes qm_fails("link", "epic-alpha", "Bad", "javascript:alert(1)")[1], "http(s)"
    assert_includes qm_fails("link", "epic-alpha", "Doc")[1], "usage: qm link"
    assert_equal ["Doc"], find("epic-alpha").links.map { |l| l["label"] }
  end

  def test_qm_list_marks_epics_and_names_a_childs_epic
    epic
    qm("new", "--project", "MyApp", "--epic", "epic-alpha", "Child one")
    Quartermaster::WorkItem.create("Loner", project: "MyApp")

    out, = qm("list")
    rows = out.lines.to_h { |l| [l.split[2], l] }
    assert_includes rows["epic-alpha"], "◆ epic"
    assert_includes rows["child-one"], "◆ epic-alpha"
    refute_includes rows["loner"], "◆"
    epics_only, = qm("list", "--kind", "epic")
    assert_equal ["epic-alpha"], epics_only.lines.map { |l| l.split[2] }
  end

  def test_qm_show_lists_an_epics_children_and_links_and_a_childs_epic
    epic.update_state("active")
    qm("new", "--epic", "epic-alpha", "Child one")
    qm("new", "--epic", "epic-alpha", "Child two")
    find("child-two").update_state("resolved")
    qm("link", "epic-alpha", "Tracker", "https://example.com/t/1")

    out, = qm("show", "epic-alpha")
    assert_includes out.lines[1], "epic"
    refute_includes out.lines[1], "routine"
    assert_includes out, "Children\e[0m\nchild-one  in_progress  Child one\nchild-two  resolved     Child two\n"
    assert_includes out, "Links\e[0m\nTracker  https://example.com/t/1\n"

    child, = qm("show", "child-one")
    assert_includes child, "Epic: Epic Alpha (epic-alpha)"
  end

  def test_a_dangling_epic_reads_as_none_and_children_keep_their_field
    epic
    qm("new", "--epic", "epic-alpha", "Child one")
    File.delete(Quartermaster::WorkItem.path_for("epic-alpha"))

    assert_equal "epic-alpha", find("child-one").epic
    assert_nil find("child-one").epic_item
    child, = qm("show", "child-one")
    assert_includes child, "Epic: epic-alpha (missing)"
  end

  def test_to_h_carries_kind_epic_and_links_for_the_gui
    epic
    qm("new", "--epic", "epic-alpha", "Child one")
    qm("link", "epic-alpha", "Doc", "https://example.com/doc")

    assert_equal({ "kind" => "epic", "epic" => nil, "links" => [{ "label" => "Doc", "url" => "https://example.com/doc" }] },
                 find("epic-alpha").to_h.slice("kind", "epic", "links"))
    assert_equal({ "kind" => nil, "epic" => "epic-alpha", "links" => [] },
                 find("child-one").to_h.slice("kind", "epic", "links"))
  end
end
