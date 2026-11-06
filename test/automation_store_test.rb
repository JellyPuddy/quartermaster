# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/automation_store_test.rb`).
require_relative "test_helper"

class AutomationStoreTest < Minitest::Test
  include QmTestHelpers

  ROUTINES = JSON.parse(File.read(File.join(__dir__, "fixtures", "routines-list-response.json")))
  DIGEST = ROUTINES["data"].first

  def store = Quartermaster::AutomationStore.new

  def dir = File.join(Quartermaster::ROOT, "automations")

  def record
    {
      "routine" => "trig_1", "runner" => "cloud", "name" => "Digest", "cron" => "0 7 * * 1,4",
      "model" => "claude-sonnet-5-5", "sources" => [{ "git_repository" => { "url" => "https://github.com/o/r" } }],
      "connectors" => [{ "name" => "Slack", "url" => "https://mcp.slack.com/mcp" }], "allowed_tools" => %w[Bash Read],
      "environment_id" => "env_1", "enabled" => true, "remote_updated_at" => "2026-10-27T12:21:01.911143Z"
    }
  end

  def test_round_trips_the_record_and_prompt_through_two_files
    store.write("digest", record, "Do the digest.\n\nSecond paragraph.\n")

    entry = store.read("digest")
    assert_equal "digest", entry.slug
    assert_equal record.merge("v" => 1), entry.record
    assert_equal "Do the digest.\n\nSecond paragraph.\n", entry.prompt
    assert_equal "Do the digest.\n\nSecond paragraph.\n", File.read(File.join(dir, "digest.prompt.md"))
    assert File.read(File.join(dir, "digest.yml")).start_with?("---\nv: 1\nroutine: trig_1\n")
  end

  def test_a_missing_automation_reads_as_nil
    assert_nil store.read("nope")
    refute store.exists?("nope")
  end

  def test_unknown_keys_survive_a_rewrite_that_does_not_name_them
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "digest.yml"), "v: 1\nroutine: trig_1\nname: Old\nmy_note: keep me\n")
    File.write(File.join(dir, "digest.prompt.md"), "old prompt")

    store.write("digest", { "name" => "New" }, "new prompt")

    assert_equal({ "v" => 1, "routine" => "trig_1", "name" => "New", "my_note" => "keep me" }, store.read("digest").record)
  end

  def test_an_overwrite_keeps_the_previous_files_as_bak
    store.write("digest", record, "first")
    store.write("digest", record.merge("cron" => "0 8 * * *"), "second")

    assert_includes File.read(File.join(dir, "digest.yml.bak")), "cron: 0 7 * * 1,4"
    assert_equal "first", File.read(File.join(dir, "digest.prompt.md.bak"))
    assert_equal "0 8 * * *", store.read("digest").record["cron"]
  end

  def test_a_first_write_leaves_no_bak_and_no_temp_files
    store.write("digest", record, "first")

    assert_equal %w[digest.prompt.md digest.yml], Dir.children(dir).sort
  end

  def test_a_failed_write_leaves_the_previous_file_whole
    store.write("digest", record, "first")
    real = Quartermaster::AtomicFile.method(:write)
    Quartermaster::AtomicFile.define_singleton_method(:write) { |*| raise IOError, "disk full" }
    begin
      assert_raises(IOError) { store.write("digest", record.merge("name" => "Broken"), "second") }
    ensure
      Quartermaster::AtomicFile.define_singleton_method(:write, real)
    end

    assert_equal "Digest", store.read("digest").record["name"]
  end

  def test_lists_slugs_finds_by_routine_and_deletes_locally
    store.write("b-digest", record, "b")
    store.write("a-review", record.merge("routine" => "trig_2"), "a")

    assert_equal %w[a-review b-digest], store.list.map(&:slug)
    assert_equal "a-review", store.find_by_routine("trig_2").slug
    assert_nil store.find_by_routine("trig_missing")

    store.delete_local("b-digest")
    refute store.exists?("b-digest")
    assert_equal %w[a-review], store.list.map(&:slug)
  end

  def test_refuses_a_slug_that_is_not_a_plain_name
    assert_raises(ArgumentError) { store.write("../evil", record, "x") }
    assert_raises(ArgumentError) { store.read("a/b") }
  end

  def test_maps_a_routine_from_the_api_to_a_record_and_prompt
    record, prompt = Quartermaster::AutomationStore.from_routine(DIGEST)

    assert_equal "PROMPT", prompt
    assert_equal(
      {
        "routine" => "trig_01AAAAAAAAAAAAAAAAAAAAAAAA", "runner" => "cloud", "name" => "Shipped digest (DM)",
        "cron" => "0 7 * * 1,4", "model" => "claude-sonnet-5-5",
        "sources" => [{ "git_repository" => { "url" => "https://github.com/example-org/example-app" } }],
        "connectors" => [{ "clear_tool_policy_overrides" => false, "connector_uuid" => "00000000-0000-4000-8000-000000000002",
                           "name" => "Slack", "permitted_tools" => [], "tool_policy_overrides" => [], "url" => "https://mcp.slack.com/mcp" }],
        "allowed_tools" => %w[Bash Read Glob Grep], "environment_id" => "env_01BBBBBBBBBBBBBBBBBBBBBBBB", "enabled" => true,
        "remote_updated_at" => "2026-10-27T12:21:01.911143Z"
      },
      record
    )
  end

  def test_takes_the_prompt_from_derived_state_when_the_job_config_has_no_event
    routine = DIGEST.merge("job_config" => { "ccr" => {} }, "derived_state" => { "prompt" => "from derived" })

    assert_equal "from derived", Quartermaster::AutomationStore.from_routine(routine).last
  end

  def test_refuses_to_map_something_that_is_not_a_routine
    assert_raises(ArgumentError) { Quartermaster::AutomationStore.from_routine([]) }
    assert_raises(ArgumentError) { Quartermaster::AutomationStore.from_routine({ "name" => "no id" }) }
  end

  def test_builds_the_routine_body_from_a_record_and_prompt
    body = Quartermaster::AutomationStore.routine_body(record, "Do it.", uuid: "u-1")

    assert_equal(
      {
        "name" => "Digest", "cron_expression" => "0 7 * * 1,4", "enabled" => true,
        "job_config" => { "ccr" => {
          "environment_id" => "env_1",
          "events" => [{ "data" => { "message" => { "content" => "Do it.", "role" => "user" }, "parent_tool_use_id" => nil,
                                     "session_id" => "", "type" => "user", "uuid" => "u-1" } }],
          "session_context" => { "allowed_tools" => %w[Bash Read], "model" => "claude-sonnet-5-5",
                                 "sources" => [{ "git_repository" => { "url" => "https://github.com/o/r" } }] }
        } },
        "mcp_connections" => [{ "name" => "Slack", "url" => "https://mcp.slack.com/mcp" }]
      },
      body
    )
  end

  def test_a_fixture_routine_maps_back_to_its_own_job_config
    record, prompt = Quartermaster::AutomationStore.from_routine(DIGEST)
    uuid = DIGEST.dig("job_config", "ccr", "events", 0, "data", "uuid")
    body = Quartermaster::AutomationStore.routine_body(record, prompt, uuid: uuid)

    assert_equal DIGEST["job_config"], body["job_config"]
    assert_equal DIGEST["mcp_connections"], body["mcp_connections"]
  end
end
