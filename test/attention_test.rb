# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/attention_test.rb`).
require_relative "test_helper"

class AttentionTest < Minitest::Test
  include QmTestHelpers

  def build_attention(retention_days: 30, pr_states: {}, project_map: Quartermaster::ProjectMap.new(roots: {}))
    Quartermaster::Attention.new(
      retention_days: retention_days,
      pr_status: Quartermaster::PrStatus.new(fetcher: ->(_item, branch) { pr_states[branch] }),
      project_map: project_map
    )
  end

  def item_with_transcript(title: "My item", session_id: "sess-1", age_days:)
    transcript = File.join(Quartermaster::ROOT, "transcript-#{session_id}.jsonl")
    Quartermaster.ensure_setup
    File.write(transcript, "")
    mtime = Time.now - (age_days * 86_400)
    File.utime(mtime, mtime, transcript)
    Quartermaster::SessionLog.new.append(
      "event" => "start", "session_id" => session_id, "cwd" => "/",
      "transcript_path" => transcript, "ts" => Time.now.iso8601
    )
    Quartermaster::SessionLog.new.append("event" => "end", "session_id" => session_id, "ts" => Time.now.iso8601)
    Quartermaster::WorkItem.create(title, project: "No project", session_id: session_id)
  end

  def test_warns_when_a_transcript_expires_within_the_window
    item = item_with_transcript(age_days: 25)

    entries = build_attention.entries_for(item)
    assert_equal 1, entries.size
    assert_equal "degrade", entries.first.kind
    assert_match(/transcript expires in [45]d/, entries.first.message)

    assert_empty build_attention(retention_days: 90).degradations(item)
  end

  def test_ack_and_snapshot_both_silence_the_degradation_warning
    acked = item_with_transcript(age_days: 25)
    acked.ack_degrade("sess-1")
    assert_empty build_attention.degradations(Quartermaster::WorkItem.find("my-item"))

    snapshotted = item_with_transcript(title: "Other item", session_id: "sess-2", age_days: 25)
    snapshotted.add_snapshot("sess-2", "the distilled context")
    assert_empty build_attention.degradations(Quartermaster::WorkItem.find("other-item"))
  end

  def test_every_attention_kind_has_a_badge
    %w[degrade stale pr_merged].each do |kind|
      entry = Quartermaster::Attention::Entry.new(slug: "x", kind: kind, message: "m")
      refute_nil entry.badge
    end
  end

  def test_acknowledge_all_silences_every_current_degradation
    item_with_transcript(age_days: 25)

    acked = build_attention.acknowledge_all(Quartermaster::WorkItem.find("my-item"))

    assert_equal ["sess-1"], acked
    assert_empty build_attention.degradations(Quartermaster::WorkItem.find("my-item"))
  end

  def test_acknowledge_all_with_an_explicit_session_acks_only_that_one
    item = item_with_transcript(age_days: 25)

    acked = build_attention.acknowledge_all(item, session_id: "sess-1")

    assert_equal ["sess-1"], acked
    assert_empty build_attention.degradations(Quartermaster::WorkItem.find("my-item"))
  end

  def test_nudges_stale_in_progress_items_unless_snoozed
    item = Quartermaster::WorkItem.create("Quiet item", project: "No project")
    old = Time.now - (12 * 86_400)
    File.utime(old, old, Quartermaster::WorkItem.path_for(item.slug))

    entries = build_attention.entries_for(Quartermaster::WorkItem.find("quiet-item"))
    assert_equal ["stale"], entries.map { |e| e.kind }

    Quartermaster::WorkItem.find("quiet-item").snooze("7d")
    File.utime(old, old, Quartermaster::WorkItem.path_for(item.slug))
    assert_empty build_attention.entries_for(Quartermaster::WorkItem.find("quiet-item"))

    expired = Quartermaster::WorkItem.find("quiet-item")
    expired.front["snooze_until"] = (Date.today - 1).to_s
    expired.save
    File.utime(old, old, Quartermaster::WorkItem.path_for(item.slug))
    refute_empty build_attention.entries_for(Quartermaster::WorkItem.find("quiet-item"))
  end

  def test_fridge_items_do_not_get_staleness_nudges
    item = Quartermaster::WorkItem.create("Frozen", project: "No project")
    item.update_state("fridge")
    old = Time.now - (30 * 86_400)
    File.utime(old, old, Quartermaster::WorkItem.path_for(item.slug))

    assert_nil build_attention.staleness(Quartermaster::WorkItem.find("frozen"))
  end

  def test_signals_merged_prs_on_unresolved_items
    merged = Quartermaster::WorkItem.create("Shipped", project: "No project", branch: "issue/1-shipped")
    open_pr = Quartermaster::WorkItem.create("In review", project: "No project", branch: "issue/2-review")

    entries = build_attention(pr_states: { "issue/1-shipped" => "MERGED" }).entries_for(merged)
    assert_equal ["pr_merged"], entries.map { |e| e.kind }

    assert_empty build_attention(pr_states: { "issue/2-review" => "OPEN" })
      .entries_for(open_pr).select { |e| e.kind == "pr_merged" }
  end

  def test_stacks_nudge_only_when_every_branch_pr_is_merged
    stack = Quartermaster::WorkItem.create("Stacked", project: "No project", branch: "issue/3-part-1")
    stack.link_branch("issue/3-part-2")

    half = build_attention(pr_states: { "issue/3-part-1" => "MERGED", "issue/3-part-2" => "OPEN" })
    assert_empty half.entries_for(Quartermaster::WorkItem.find("stacked"))

    Quartermaster::PrStatus.new.send(:write_cache, {})
    done = build_attention(pr_states: { "issue/3-part-1" => "MERGED", "issue/3-part-2" => "MERGED" })
    entries = done.entries_for(Quartermaster::WorkItem.find("stacked"))
    assert_equal ["pr_merged"], entries.map { |e| e.kind }
    assert_match(/all 2 PRs merged/, entries.first.message)
  end

  def test_ignores_pr_less_branches_that_no_longer_exist
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "main", dir)
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      map = Quartermaster::ProjectMap.new(roots: { "Repo" => dir })

      renamed = Quartermaster::WorkItem.create("Renamed", project: "Repo", branch: "chore/old-name")
      renamed.link_branch("refactor/new-name")
      entries = build_attention(pr_states: { "refactor/new-name" => "MERGED" }, project_map: map)
        .entries_for(Quartermaster::WorkItem.find("renamed"))
      assert_equal ["pr_merged"], entries.map { |e| e.kind }
      assert_match(/PR merged — resolve\?/, entries.first.message)
    end
  end

  def test_pr_less_branches_that_still_exist_keep_blocking_the_nudge
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "main", dir)
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      system("git", "-C", dir, "branch", "-q", "chore/in-flight")
      map = Quartermaster::ProjectMap.new(roots: { "Repo" => dir })

      stack = Quartermaster::WorkItem.create("Half shipped", project: "Repo", branch: "chore/shipped")
      stack.link_branch("chore/in-flight")
      attention = build_attention(pr_states: { "chore/shipped" => "MERGED" }, project_map: map)
      assert_empty attention.entries_for(Quartermaster::WorkItem.find("half-shipped"))
    end
  end

  def test_no_nudge_when_every_branch_is_gone_without_a_pr
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "main", dir)
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      map = Quartermaster::ProjectMap.new(roots: { "Repo" => dir })

      ghost = Quartermaster::WorkItem.create("Ghost", project: "Repo", branch: "chore/vanished")
      assert_empty build_attention(project_map: map).entries_for(Quartermaster::WorkItem.find("ghost"))
    end
  end

  def test_unknown_project_roots_treat_branches_as_still_existing
    orphan = Quartermaster::WorkItem.create("Orphan", project: "No project", branch: "chore/somewhere")
    assert_empty build_attention.entries_for(Quartermaster::WorkItem.find("orphan"))
  end

  def test_a_branch_only_on_origin_still_exists
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "main", dir)
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      system("git", "-C", dir, "update-ref", "refs/remotes/origin/chore/pushed", "HEAD")
      map = Quartermaster::ProjectMap.new(roots: { "Repo" => dir })

      item = Quartermaster::WorkItem.create("Pushed", project: "Repo", branch: "chore/pushed")
      attention = build_attention(project_map: map)
      refute attention.branch_gone?(item, "chore/pushed")
      assert attention.branch_gone?(item, "chore/elsewhere")
    end
  end

  def test_branch_refs_are_listed_once_per_repo_per_instance
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "main", dir)
      system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
             "commit", "-q", "--allow-empty", "-m", "init")
      map = Quartermaster::ProjectMap.new(roots: { "Repo" => dir })
      item = Quartermaster::WorkItem.create("Later", project: "Repo", branch: "chore/later")

      attention = build_attention(project_map: map)
      assert attention.branch_gone?(item, "chore/later")
      system("git", "-C", dir, "branch", "-q", "chore/later")
      assert attention.branch_gone?(item, "chore/later"), "the listing is taken once per instance"
      refute build_attention(project_map: map).branch_gone?(item, "chore/later")
    end
  end

  def test_resolved_items_get_no_merged_pr_nudge
    item = Quartermaster::WorkItem.create("Done", project: "No project", branch: "issue/9-done")
    item.update_state("resolved")
    resolved = Quartermaster::WorkItem.find("done")
    assert_empty build_attention(pr_states: { "issue/9-done" => "MERGED" }).entries_for(resolved)
  end

  def test_pr_states_are_cached_across_instances
    item = Quartermaster::WorkItem.create("Shipped", project: "No project", branch: "issue/1-shipped")

    calls = 0
    counting = Quartermaster::PrStatus.new(fetcher: ->(_i, _b) { calls += 1; "MERGED" })
    counting.state_for(item, "issue/1-shipped")
    counting.state_for(item, "issue/1-shipped")
    assert_equal 1, calls

    exploding = Quartermaster::PrStatus.new(fetcher: ->(_i, _b) { raise "network down" })
    assert_equal "MERGED", exploding.state_for(item, "issue/1-shipped")
  end

  def test_a_branch_without_a_pr_is_asked_again_sooner_than_one_with_a_pr
    item = Quartermaster::WorkItem.create("Fresh", project: "No project", branch: "issue/3-fresh")
    Quartermaster::PrStatus.new(fetcher: ->(_i, b) { b == "issue/3-fresh" ? nil : "MERGED" }).tap do |pr|
      pr.state_for(item, "issue/3-fresh")
      pr.state_for(item, "issue/3-merged")
    end

    later = Time.now + Quartermaster::PrStatus::NO_PR_TTL_SECONDS + 60
    asked = []
    pr = Quartermaster::PrStatus.new(fetcher: ->(_i, b) { asked << b; "OPEN" }, now: later)
    assert_equal "OPEN", pr.state_for(item, "issue/3-fresh")
    assert_equal "MERGED", pr.state_for(item, "issue/3-merged")
    assert_equal %w[issue/3-fresh], asked
  end

  # An open PR is the one about to merge: a stack layer landed this morning
  # must not show open until the afternoon. Merged and closed hold.
  def test_an_open_pr_is_asked_again_sooner_than_a_merged_or_closed_one
    item = Quartermaster::WorkItem.create("Stack", project: "No project", branch: "issue/4-open")
    states = { "issue/4-open" => "OPEN", "issue/4-merged" => "MERGED", "issue/4-closed" => "CLOSED" }
    Quartermaster::PrStatus.new(fetcher: ->(_i, b) { states[b] }).tap do |pr|
      states.each_key { |b| pr.state_for(item, b) }
    end

    later = Time.now + Quartermaster::PrStatus::OPEN_TTL_SECONDS + 60
    asked = []
    pr = Quartermaster::PrStatus.new(fetcher: ->(_i, b) { asked << b; "MERGED" }, now: later)
    assert_equal %w[MERGED MERGED CLOSED], states.keys.map { |b| pr.state_for(item, b) }
    assert_equal %w[issue/4-open], asked
  end

  # background mode is the GUI's contract: an expired entry never blocks the
  # caller on the fetcher — it's served stale and refetched on a thread, with
  # #refreshing? true until the fresh state has landed in the cache.
  def test_background_mode_serves_the_stale_state_and_refreshes_off_thread
    item = Quartermaster::WorkItem.create("Shipped", project: "No project", branch: "issue/1-shipped")
    Quartermaster::PrStatus.new(fetcher: ->(_i, _b) { "OPEN" }).state_for(item, "issue/1-shipped")

    gate = Queue.new
    fetches = 0
    later = Time.now + Quartermaster::PrStatus::CACHE_TTL_SECONDS + 60
    stale = Quartermaster::PrStatus.new(fetcher: ->(_i, _b) { fetches += 1; gate.pop; "MERGED" },
                                        now: later, background: true)

    # Served instantly from the expired entry — the fetcher is still gated.
    assert_equal "OPEN", stale.state_for(item, "issue/1-shipped")
    assert_equal "OPEN", stale.state_for(item, "issue/1-shipped")
    assert_predicate stale, :refreshing?

    2.times { gate << true } # only one pop is consumed: the refetch is deduped
    Thread.pass until Quartermaster::PrStatus::IN_FLIGHT_MUTEX.synchronize { Quartermaster::PrStatus::IN_FLIGHT.empty? }
    assert_equal 1, fetches

    fresh = Quartermaster::PrStatus.new(fetcher: ->(_i, _b) { raise "should hit the cache" },
                                        now: later, background: true)
    assert_equal "MERGED", fresh.state_for(item, "issue/1-shipped")
    refute_predicate fresh, :refreshing?
  end

  def test_background_mode_returns_nil_for_a_never_fetched_branch_but_still_refreshes
    item = Quartermaster::WorkItem.create("New", project: "No project", branch: "issue/2-new")

    pr = Quartermaster::PrStatus.new(fetcher: ->(_i, _b) { "OPEN" }, background: true)
    assert_nil pr.state_for(item, "issue/2-new")
    assert_predicate pr, :refreshing?

    Thread.pass until Quartermaster::PrStatus::IN_FLIGHT_MUTEX.synchronize { Quartermaster::PrStatus::IN_FLIGHT.empty? }
    assert_equal "OPEN", Quartermaster::PrStatus.new(background: true).state_for(item, "issue/2-new")
  end

  def test_a_stale_copy_mutation_does_not_clobber_a_concurrent_write
    Quartermaster::WorkItem.create("Race", project: "No project")
    stale = Quartermaster::WorkItem.find("race")
    Quartermaster::WorkItem.find("race").add_note("written in between")

    stale.add_snapshot("sess-1", "snapshot from a stale copy")

    fresh = Quartermaster::WorkItem.find("race")
    assert_equal ["written in between"], fresh.notes.map(&:text)
    assert fresh.snapshot_for?("sess-1")
  end

  def test_concurrent_processes_do_not_lose_writes
    Quartermaster::WorkItem.create("Contended", project: "No project")
    pids = %w[a b].map do |tag|
      spawn(
        { "QM_ROOT" => Quartermaster::ROOT, "QM_TRANSCRIPTS_DIR" => Quartermaster::TRANSCRIPTS_DIR },
        RbConfig.ruby, "-e",
        "load #{QM_BIN.inspect}; 15.times { |i| Quartermaster::WorkItem.find('contended').add_note(\"#{tag}-\#{i}\") }"
      )
    end
    statuses = pids.map { |pid| Process.wait2(pid).last }

    assert statuses.all?(&:success?)
    assert_equal 30, Quartermaster::WorkItem.find("contended").notes.size
  end

  def test_snapshots_append_into_their_section_and_are_findable
    item = Quartermaster::WorkItem.create("My item", project: "No project", description: "Desc")
    item.add_note("a note")
    item.add_snapshot("sess-abc", "What happened, distilled.")

    reloaded = Quartermaster::WorkItem.find("my-item")
    assert reloaded.snapshot_for?("sess-abc")
    refute reloaded.snapshot_for?("sess-other")
    assert_match(/## Snapshots\n\n### \d{4}-\d{2}-\d{2} — session sess-abc\n\nWhat happened, distilled\./, reloaded.body)
    assert_operator reloaded.body.index("a note"), :<, reloaded.body.index("## Snapshots")
  end

  def test_snooze_command_parses_durations
    Quartermaster::WorkItem.create("My item", project: "No project")

    _out, _err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT }, RbConfig.ruby, QM_BIN, "snooze", "my-item", "7d")
    assert_equal 0, status.exitstatus
    assert_equal (Date.today + 7).to_s, Quartermaster::WorkItem.find("my-item").front["snooze_until"]

    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT }, RbConfig.ruby, QM_BIN, "snooze", "my-item", "clear")
    assert_nil Quartermaster::WorkItem.find("my-item").front["snooze_until"]

    _out, _err, status = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT }, RbConfig.ruby, QM_BIN, "snooze", "my-item", "soon")
    assert_equal 1, status.exitstatus
  end
end
