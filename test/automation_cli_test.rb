# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/automation_cli_test.rb`).
require_relative "test_helper"

# `qm automation …` through the Automations service, with a stub routines
# client in place of RoutinesClient: no keychain, no network.
class AutomationCliTest < Minitest::Test
  include QmTestHelpers

  DIGEST = JSON.parse(File.read(File.join(__dir__, "fixtures", "routines-list-response.json")))["data"].first
  ID = DIGEST["id"]
  SYNCED = DIGEST["updated_at"]
  SLACK = DIGEST["mcp_connections"]
  DEFAULT_MODEL = "claude-default-model"

  # The routines API as a hash of routines: records every call, applies
  # creates and updates the way the API would (via the real request body)
  # and stamps a new updated_at on each write.
  class StubClient
    attr_reader :calls, :routines
    attr_accessor :fail_with, :delete_answer

    def initialize(*routines)
      @routines = routines.to_h { |r| [r["id"], JSON.parse(JSON.generate(r))] }
      @calls = []
      @stamp = 0
      @delete_answer = :unsupported
    end

    def list
      record(:list)
      @routines.values.map { |r| copy(r) }
    end

    def get(id)
      record(:get, id)
      copy(routine!(id))
    end

    # Like the API, a created routine is enabled and gets a model unless the
    # body names them.
    def create(fields)
      record(:create, fields)
      body = Quartermaster::RoutinesClient.request_body(fields)
      context = body.dig("job_config", "ccr", "session_context")
      context["model"] ||= DEFAULT_MODEL if context
      apply({ "id" => "trig_NEW", "enabled" => true }, body)
    end

    def update(id, fields)
      record(:update, id, fields)
      apply(routine!(id), Quartermaster::RoutinesClient.request_body(fields))
    end

    def run(id)
      record(:run, id)
      { "session_id" => "cse_RUN" }
    end

    def runs(id, limit:)
      record(:runs, id, limit)
      [{ "id" => "cse_1", "title" => "Digest run", "status" => "completed", "created_at" => "2026-11-05T07:10:10Z",
         "updated_at" => nil, "url" => "https://claude.ai/code/cse_1" }]
    end

    def delete(id)
      record(:delete, id)
      @routines.delete(id) if @delete_answer == :deleted
      @delete_answer
    end

    def touch(id) = @routines[id]["updated_at"] = "2026-11-06T10:00:00Z"

    private

    def routine!(id) = @routines.fetch(id) { raise Quartermaster::RoutinesClient::RoutineMissing, id }

    def record(*call)
      raise fail_with if fail_with

      @calls << call
    end

    def apply(routine, body)
      routine = routine.merge(body.except("clear_mcp_connections")).merge("updated_at" => "2026-11-06T09:00:0#{@stamp += 1}Z")
      @routines[routine["id"]] = routine
      copy(routine)
    end

    def copy(routine) = JSON.parse(JSON.generate(routine))
  end

  def setup
    super
    Quartermaster.ensure_setup
    @client = StubClient.new(DIGEST)
  end

  # Runs `qm automation ARGV` with the stub client in place of RoutinesClient.
  def invoke(*argv, stdin: "")
    client = @client
    klass = Quartermaster::RoutinesClient
    original = klass.method(:new)
    klass.define_singleton_method(:new) { |**| client }
    with_stdin(stdin) { Quartermaster::CLI.new(runner: FakeRunner.new).run(["automation", *argv]) }
  ensure
    klass.define_singleton_method(:new, original)
  end

  # [stdout, stderr] of a command that succeeds.
  def qm(*argv, stdin: "") = capture_io { invoke(*argv, stdin: stdin) }

  # [stdout, stderr] of a command that must exit non-zero.
  def qm_fails(*argv, stdin: "")
    capture_io do
      error = assert_raises(SystemExit) { invoke(*argv, stdin: stdin) }
      refute error.success?
    end
  end

  def store = Quartermaster::AutomationStore.new

  def item(slug = "digest") = Quartermaster::WorkItem.find(slug)

  def adopt
    qm("adopt", ID, "--project", "MyApp", "--slug", "digest")
    @client.calls.clear
  end

  def history(slug = "digest") = item(slug).notes.select { |n| n.kind == "history" }.map(&:text)

  def edit(changes, prompt: nil)
    entry = store.read("digest")
    store.write("digest", changes, prompt || entry.prompt)
  end

  def test_adopt_stores_the_routine_and_makes_an_automation_item
    @client.routines[ID]["job_config"]["ccr"]["events"][0]["data"]["message"]["content"] = "Post the digest.\nTo Slack.\n\nDetails here."
    out, = qm("adopt", ID, "--project", "MyApp")

    assert_equal "adopted #{ID} as shipped-digest-dm\n", out
    entry = store.read("shipped-digest-dm")
    assert_equal [ID, "cloud", "0 7 * * 1,4", true, SYNCED],
                 entry.record.values_at("routine", "runner", "cron", "enabled", "remote_updated_at")
    item = item("shipped-digest-dm")
    assert_equal ["automation", ID, "cloud", "MyApp", "active", "Shipped digest (DM)"],
                 [item.kind, item.routine, item.runner, item.project, item.state, item.title]
    assert_equal "Shipped digest (DM)\n\nPost the digest.\nTo Slack.", item.description
  end

  def test_adopting_a_managed_routine_again_is_refused
    adopt
    qm_fails("adopt", ID, "--project", "MyApp")
  end

  def test_push_sends_only_what_changed_and_notes_it
    adopt
    edit({ "cron" => "0 6 * * 1" })
    out, = qm("push", "digest")

    update = @client.calls.find { |c| c.first == :update }
    assert_equal [:update, ID, { "cron" => "0 6 * * 1", "connectors" => SLACK }], update
    assert_equal "2026-11-06T09:00:01Z", store.read("digest").record["remote_updated_at"]
    assert_equal ["pushed: schedule → Mon 07:00 (0 6 * * 1 UTC)"], history
    assert_includes out, "schedule → Mon 07:00"
  end

  def test_a_prompt_change_sends_the_whole_job_config
    adopt
    edit({}, prompt: "New prompt")
    qm("push", "digest")

    _, id, fields = @client.calls.find { |c| c.first == :update }
    assert_equal ID, id
    assert_equal %w[allowed_tools connectors environment_id model prompt sources], fields.keys.sort
    assert_equal "New prompt", @client.routines[ID].dig("job_config", "ccr", "events", 0, "data", "message", "content")
    assert_equal DIGEST.dig("job_config", "ccr", "session_context"), @client.routines[ID].dig("job_config", "ccr", "session_context")
    assert_equal ["pushed: prompt changed"], history
  end

  def test_push_with_nothing_changed_writes_nothing
    adopt
    out, = qm("push", "digest")

    assert_equal "digest: nothing to push\n", out
    refute(@client.calls.any? { |c| c.first == :update })
    assert_empty history
  end

  def test_push_refuses_a_routine_changed_outside_qm_unless_forced
    adopt
    @client.touch(ID)
    edit({ "cron" => "0 6 * * 1" })

    _, err = qm_fails("push", "digest")
    assert_includes err, "qm: digest changed outside qm"
    refute(@client.calls.any? { |c| c.first == :update })
    assert_equal SYNCED, store.read("digest").record["remote_updated_at"]

    qm("push", "digest", "--force")
    assert(@client.calls.any? { |c| c.first == :update })
    assert_equal "2026-11-06T09:00:01Z", store.read("digest").record["remote_updated_at"]
  end

  def test_the_stale_refusal_names_pull_and_force
    adopt
    @client.touch(ID)
    message = assert_raises(Quartermaster::Automations::Stale) do
      Quartermaster::Automations.new(client: @client).push("digest")
    end.message
    assert_includes message, "changed outside qm"
    assert_includes message, "qm automation pull digest"
    assert_includes message, "qm automation push digest --force"
  end

  def test_first_push_creates_the_routine_and_links_it
    service = Quartermaster::Automations.new(client: @client)
    service.create_item("new-digest", "New digest", project: "MyApp")
    store.write("new-digest", { "runner" => "cloud", "name" => "New digest", "cron" => "0 8 * * *", "enabled" => true,
                                "environment_id" => "env_1", "model" => "claude-sonnet-5-5" }, "Do it.")
    assert_equal "in_progress", item("new-digest").state

    qm("push", "new-digest")

    _, fields = @client.calls.find { |c| c.first == :create }
    assert_equal ["New digest", "0 8 * * *", true, "Do it."], fields.values_at("name", "cron", "enabled", "prompt")
    assert_equal ["trig_NEW", "2026-11-06T09:00:01Z"], store.read("new-digest").record.values_at("routine", "remote_updated_at")
    assert_equal ["trig_NEW", "active", "automation"], [item("new-digest").routine, item("new-digest").state, item("new-digest").kind]
    assert_equal ["pushed: created routine trig_NEW"], history("new-digest")
  end

  def test_a_created_routine_without_repos_tools_or_connectors_is_in_sync_after_its_first_push
    service = Quartermaster::Automations.new(client: @client)
    service.create_item("bare", "Bare", project: "MyApp")
    store.write("bare", { "runner" => "cloud", "name" => "Bare", "cron" => "0 8 * * *", "enabled" => true }, "Do it.")
    qm("push", "bare")

    _, fields = @client.calls.find { |c| c.first == :create }
    refute(fields.any? { |_, v| v.nil? }, "a create sends no nulls")
    assert_equal [], fields["connectors"]
    assert_equal true, Quartermaster::RoutinesClient.request_body(fields)["clear_mcp_connections"]
    assert_equal [], @client.routines["trig_NEW"]["mcp_connections"]
    refute @client.routines["trig_NEW"].key?("clear_mcp_connections")
    out, = qm("push", "bare")
    assert_equal "bare: nothing to push\n", out
  end

  def test_the_first_push_takes_the_routines_defaults_so_a_second_push_has_nothing_to_send
    service = Quartermaster::Automations.new(client: @client)
    service.create_item("fresh", "Fresh", project: "MyApp")
    store.write("fresh", { "runner" => "cloud", "name" => "Fresh", "cron" => "0 8 * * *" }, "Do it.")
    qm("push", "fresh")

    record = store.read("fresh").record
    assert_equal [true, DEFAULT_MODEL, "trig_NEW", "2026-11-06T09:00:01Z"],
                 record.values_at("enabled", "model", "routine", "remote_updated_at")
    assert_equal "Do it.", store.read("fresh").prompt
    @client.calls.clear
    out, = qm("push", "fresh")

    assert_equal "fresh: nothing to push\n", out
    assert_equal [[:get, "trig_NEW"]], @client.calls
    assert_equal ["pushed: created routine trig_NEW"], history("fresh")
  end

  def test_a_push_never_sends_a_field_left_unset_locally
    adopt
    edit({ "enabled" => nil, "name" => "Renamed" })
    qm("push", "digest")

    _, _, fields = @client.calls.find { |c| c.first == :update }
    refute fields.key?("enabled"), "an unset enabled is no change"
    assert_equal ["pushed: name → Renamed"], history("digest").last(1)
    assert_equal true, @client.routines[ID]["enabled"]
  end

  def test_pause_and_resume_push_enabled_and_move_the_state
    adopt
    out, = qm("pause", "digest")

    assert_equal "digest: paused\n", out
    assert_equal [:update, ID, { "enabled" => false, "connectors" => SLACK }], @client.calls.find { |c| c.first == :update }
    assert_equal [false, "fridge"], [store.read("digest").record["enabled"], item.state]

    qm("resume", "digest")
    assert_equal [true, "active"], [@client.routines[ID]["enabled"], item.state]
    assert_equal ["pushed: resumed", "pushed: paused"], history, "newest first"
  end

  def test_pull_overwrites_local_and_keeps_a_bak
    adopt
    edit({ "cron" => "0 6 * * 1" })
    @client.routines[ID]["enabled"] = false
    @client.touch(ID)

    out, = qm("pull", "digest")

    record = store.read("digest").record
    assert_equal ["0 7 * * 1,4", false, "2026-11-06T10:00:00Z"], record.values_at("cron", "enabled", "remote_updated_at")
    assert_includes File.read("#{store.yml_path("digest")}.bak"), "0 6 * * 1"
    assert_equal "fridge", item.state
    assert_includes out, "pulled schedule, enabled"
    assert_equal ["pulled from claude.ai: schedule, enabled"], history
  end

  def test_run_runs_the_routine_now
    adopt
    out, = qm("run", "digest")

    assert_equal [[:run, ID]], @client.calls
    assert_includes out, "https://claude.ai/code/routines/#{ID}"
  end

  def test_delete_asks_first_and_a_no_changes_nothing
    adopt
    qm_fails("delete", "digest", stdin: "n\n")

    assert_empty @client.calls
    assert_equal "active", item.state
  end

  def test_delete_without_an_api_delete_pauses_and_links_to_claude_ai
    adopt
    out, = qm("delete", "digest", stdin: "y\n")

    assert_equal [[:delete, ID], [:update, ID, { "enabled" => false, "connectors" => SLACK }]], @client.calls
    assert_equal "digest: paused; delete it on claude.ai: https://claude.ai/code/routines/#{ID}\n", out
    assert_equal "resolved", item.state
    assert_equal false, store.read("digest").record["enabled"]
  end

  def test_delete_yes_deletes_and_resolves_keeping_the_item
    adopt
    @client.delete_answer = :deleted
    out, = qm("delete", "digest", "--yes")

    assert_equal "digest: deleted\n", out
    assert_nil store.read("digest")
    assert_equal "resolved", item.state
    assert_equal ["deleted"], history
  end

  def test_list_shows_local_then_status_drift_and_unmanaged
    adopt
    other = DIGEST.merge("id" => "trig_OTHER", "name" => "Other routine", "cron_expression" => "*/5 * * * *")
    @client.routines["trig_OTHER"] = other
    @client.touch(ID)
    out, = qm("list")

    lines = out.lines.map(&:chomp)
    assert_match(/\Adigest  MyApp  active  Mon, Thu (08|09):00  enabled\z/, lines[0])
    assert_equal "digest: last run succeeded 2026-11-05 07:10 UTC, next 2026-11-09 07:06 UTC, " \
                 "changed outside qm (pull or push --force)", lines[1]
    assert_includes out, "Not managed by qm"
    assert_includes out, "trig_OTHER  Other routine  */5 * * * * UTC"
    assert_equal [[:list]], @client.calls
  end

  def test_list_prints_the_local_files_before_a_client_error
    adopt
    @client.fail_with = Quartermaster::RoutinesClient::TokenExpired.new
    out, err = qm_fails("list")
    assert_match(/\Adigest  MyApp  active/, out)
    assert_includes err, "Claude Code's login token expired"
  end

  def test_show_lists_the_automation_and_its_runs
    adopt
    out, = qm("show", "digest")

    assert_includes out, "Shipped digest (DM)"
    assert_includes out, "schedule: Mon, Thu"
    assert_includes out, "(0 7 * * 1,4 UTC)"
    assert_includes out, "repos: https://github.com/example-org/example-app"
    assert_includes out, "connectors: Slack"
    assert_includes out, "routine: https://claude.ai/code/routines/#{ID}"
    assert_includes out, "completed  2026-11-05 07:10 UTC  Digest run  https://claude.ai/code/cse_1"
    assert_includes @client.calls, [:runs, ID, 10]
  end

  def test_push_of_a_routine_deleted_on_claude_ai_says_it_is_gone
    adopt
    @client.routines.delete(ID)
    _, err = qm_fails("push", "digest")

    assert_includes err, "digest: routine #{ID} isn't on claude.ai any more — delete the automation in qm " \
                         "(`qm automation delete digest`) or re-create it (`qm automation push digest --recreate`)"
    refute_includes err, "API changed"
    assert_equal [[:get, ID]], @client.calls
    assert_equal ID, store.read("digest").record["routine"]
  end

  def test_recreate_makes_a_new_routine_for_one_deleted_on_claude_ai
    adopt
    @client.routines.delete(ID)
    edit({ "name" => "Digest again" })
    out, = qm("push", "digest", "--recreate")

    assert_equal "digest: re-created routine trig_NEW (was #{ID})\n", out
    _, fields = @client.calls.find { |c| c.first == :create }
    assert_equal ["Digest again", SLACK.map { |c| c["name"] }], [fields["name"], fields["connectors"].map { |c| c["name"] }]
    assert_equal ["trig_NEW", "2026-11-06T09:00:01Z"], store.read("digest").record.values_at("routine", "remote_updated_at")
    assert_equal "trig_NEW", item.routine
    assert_equal "active", item.state
    assert_equal "pushed: re-created routine trig_NEW (was #{ID})", history.last
    assert_equal "digest: nothing to push\n", qm("push", "digest").first
  end

  def test_recreate_without_connectors_clears_the_api_default_set
    adopt
    @client.routines.delete(ID)
    edit({ "connectors" => [], "enabled" => false })
    qm("push", "digest", "--recreate")

    _, fields = @client.calls.find { |c| c.first == :create }
    assert_equal true, Quartermaster::RoutinesClient.request_body(fields)["clear_mcp_connections"]
    assert_equal "fridge", item.state
  end

  def test_recreate_refuses_a_routine_that_still_exists
    adopt
    before = File.read(store.yml_path("digest"))
    _, err = qm_fails("push", "digest", "--recreate")

    assert_includes err, "digest: routine #{ID} is still on claude.ai — `qm automation push digest` updates it"
    assert_equal [[:get, ID]], @client.calls
    assert_equal before, File.read(store.yml_path("digest"))
    assert_equal ID, item.routine
  end

  def test_recreate_of_an_automation_never_pushed_says_push_creates_it
    service = Quartermaster::Automations.new(client: @client)
    service.create_item("fresh", "Fresh", project: "MyApp")
    store.write("fresh", { "runner" => "cloud", "name" => "Fresh", "cron" => "0 8 * * *" }, "Do it.")
    _, err = qm_fails("push", "fresh", "--recreate")

    assert_includes err, "fresh has no routine yet: `qm automation push fresh` creates it"
    assert_empty @client.calls
  end

  def test_delete_of_a_routine_already_gone_from_claude_ai_removes_it_from_qm
    adopt
    @client.routines.delete(ID)
    out, = qm("delete", "digest", "--yes")

    assert_equal "digest: deleted\n", out
    assert_nil store.read("digest")
    assert_equal "resolved", item.state
  end

  def test_client_errors_print_their_message_and_exit_non_zero
    adopt
    @client.fail_with = Quartermaster::RoutinesClient::NotEnabled.new
    _, err = qm_fails("push", "digest")
    assert_includes err, "qm config set automations.token_source claude_code"
  end

  def test_unknown_subcommand_prints_usage
    _, err = qm_fails("frobnicate")
    assert_includes err, "usage: qm automation"
  end

  def test_a_slug_command_with_a_stray_word_prints_usage_and_does_nothing
    adopt
    _, err = qm_fails("delete", "digest", "extra", "--yes")
    assert_includes err, "usage: qm automation"
    assert_equal "active", item.state
    assert_empty @client.calls
  end
end
