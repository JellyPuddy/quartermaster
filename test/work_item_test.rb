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
