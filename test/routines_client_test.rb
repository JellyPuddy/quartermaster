# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/routines_client_test.rb`).
require_relative "test_helper"

# RoutinesClient against a stub keychain (FakeRunner answering `security`)
# and a stub HTTP transport: no test reaches the network or the real keychain.
class RoutinesClientTest < Minitest::Test
  include QmTestHelpers

  FIXTURE = File.read(File.expand_path("fixtures/routines-list-response.json", __dir__))
  TOKEN = "sk-ant-oat01-SECRET-TOKEN"
  ORG = "0f1e2d3c-org-uuid"
  ID = "trig_01AAAAAAAAAAAAAAAAAAAAAAAA"
  KEYCHAIN = ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"].freeze

  # Answers each request from a script (status, body) and records it.
  class StubTransport
    attr_reader :requests

    def initialize(*answers)
      @answers = answers
      @requests = []
    end

    def call(method, url, headers, body)
      @requests << { method: method, url: url, headers: headers, body: body && JSON.parse(body) }
      answer = @answers.size > 1 ? @answers.shift : @answers.first
      raise answer if answer.is_a?(Exception)

      answer
    end

    def last = @requests.last
  end

  def setup
    super
    Quartermaster.ensure_setup
    @claude_json = File.join(Quartermaster::ROOT, "claude.json")
    File.write(@claude_json, JSON.generate("oauthAccount" => { "organizationUuid" => ORG }))
    @credentials = JSON.generate("claudeAiOauth" => { "accessToken" => TOKEN, "refreshToken" => "sk-ant-ort01-REFRESH",
                                                      "expiresAt" => ((Time.now.to_f + 3600) * 1000).to_i })
  end

  def runner(out = @credentials, success: true) = FakeRunner.new(KEYCHAIN => [out, "", success])

  def client(transport, runner: self.runner, token_source: "claude_code")
    Quartermaster::RoutinesClient.new(runner: runner, transport: transport, claude_json: @claude_json,
                                      token_source: -> { token_source })
  end

  def test_list_sends_the_verified_headers_and_returns_the_routines
    transport = StubTransport.new([200, FIXTURE])
    routines = client(transport).list

    assert_equal [ID], routines.map { |r| r["id"] }
    request = transport.last
    assert_equal ["GET", "https://api.anthropic.com/v1/code/triggers", nil], request.values_at(:method, :url, :body)
    assert_equal({ "Authorization" => "Bearer #{TOKEN}", "anthropic-version" => "2023-06-01",
                   "anthropic-beta" => "ccr-triggers-2026-01-30", "x-organization-uuid" => ORG,
                   "content-type" => "application/json" }, request[:headers])
  end

  def test_the_token_is_read_from_the_keychain_on_every_call
    keychain = runner
    api = client(StubTransport.new([200, FIXTURE]), runner: keychain)
    api.list
    api.list

    assert_equal [KEYCHAIN, KEYCHAIN], keychain.argvs
  end

  def test_fields_read_a_routine_into_the_local_shape
    routine = JSON.parse(FIXTURE)["data"].first
    fields = Quartermaster::RoutinesClient.fields(routine)

    assert_equal({ "id" => ID, "name" => "Shipped digest (DM)", "cron" => "0 7 * * 1,4", "enabled" => true,
                   "prompt" => "PROMPT", "model" => "claude-sonnet-5-5",
                   "sources" => [{ "git_repository" => { "url" => "https://github.com/example-org/example-app" } }],
                   "allowed_tools" => %w[Bash Read Glob Grep], "environment_id" => "env_01BBBBBBBBBBBBBBBBBBBBBBBB",
                   "connectors" => routine["mcp_connections"], "updated_at" => "2026-10-27T12:21:01.911143Z" },
                 fields)
  end

  def test_get_run_and_partial_update_hit_their_endpoints
    routine = JSON.generate(JSON.parse(FIXTURE)["data"].first)
    transport = StubTransport.new([200, routine])
    api = client(transport)

    assert_equal ID, api.get(ID)["id"]
    assert_equal ["GET", "https://api.anthropic.com/v1/code/triggers/#{ID}"], transport.last.values_at(:method, :url)

    api.update(ID, "enabled" => false)
    assert_equal ["POST", "https://api.anthropic.com/v1/code/triggers/#{ID}", { "enabled" => false }],
                 transport.last.values_at(:method, :url, :body)

    api.update(ID, "cron" => "0 6 * * 1")
    assert_equal({ "cron_expression" => "0 6 * * 1" }, transport.last[:body])

    api.run(ID)
    assert_equal ["POST", "https://api.anthropic.com/v1/code/triggers/#{ID}/run"], transport.last.values_at(:method, :url)
  end

  def test_create_mirrors_the_fixtures_job_config
    routine = JSON.parse(FIXTURE)["data"].first
    transport = StubTransport.new([200, JSON.generate(routine)])
    fields = Quartermaster::RoutinesClient.fields(routine).except("id", "updated_at")
    client(transport).create(fields)

    body = transport.last[:body]
    assert_equal ["POST", "https://api.anthropic.com/v1/code/triggers"], transport.last.values_at(:method, :url)
    assert_equal ["Shipped digest (DM)", "0 7 * * 1,4", true, routine["mcp_connections"]],
                 body.values_at("name", "cron_expression", "enabled", "mcp_connections")
    ccr = body.dig("job_config", "ccr")
    expected = routine.dig("job_config", "ccr")
    assert_equal expected["environment_id"], ccr["environment_id"]
    assert_equal expected["session_context"], ccr["session_context"]
    event = ccr["events"].first["data"]
    assert_equal({ "content" => "PROMPT", "role" => "user" }, event["message"])
    assert_equal "user", event["type"]
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, event["uuid"])
  end

  def test_updating_the_prompt_sends_the_whole_job_config
    routine = JSON.parse(FIXTURE)["data"].first
    transport = StubTransport.new([200, JSON.generate(routine)])
    fields = Quartermaster::RoutinesClient.fields(routine)
    client(transport).update(ID, fields.slice("prompt", "model", "sources", "allowed_tools", "environment_id")
                                       .merge("prompt" => "New prompt"))

    body = transport.last[:body]
    assert_equal ["job_config"], body.keys
    assert_equal "New prompt", body.dig("job_config", "ccr", "events", 0, "data", "message", "content")
    assert_equal routine.dig("job_config", "ccr", "session_context"), body.dig("job_config", "ccr", "session_context")
  end

  def test_runs_tolerate_missing_fields_and_link_to_claude_ai
    sessions = { "data" => [{ "id" => "cse_1", "title" => "Digest", "status" => "completed",
                              "created_at" => "2026-11-05T07:10:10Z", "updated_at" => "2026-11-05T07:10:47Z" },
                            { "id" => "cse_2" }] }
    transport = StubTransport.new([200, JSON.generate(sessions)])
    runs = client(transport).runs(ID, limit: 1)

    assert_equal "https://api.anthropic.com/v1/code/sessions?trigger_id=#{ID}&limit=1", transport.last[:url]
    assert_equal [{ "id" => "cse_1", "title" => "Digest", "status" => "completed", "created_at" => "2026-11-05T07:10:10Z",
                    "updated_at" => "2026-11-05T07:10:47Z", "url" => "https://claude.ai/code/cse_1" }], runs
    assert_equal "https://claude.ai/code/routines/#{ID}", Quartermaster::RoutinesClient.routine_url(ID)
  end

  def test_delete_reports_unsupported_on_404_or_405
    assert_equal :deleted, client(StubTransport.new([200, "{}"])).delete(ID)
    transport = StubTransport.new([404, "{}"])
    assert_equal :unsupported, client(transport).delete(ID)
    assert_equal ["DELETE", "https://api.anthropic.com/v1/code/triggers/#{ID}"], transport.last.values_at(:method, :url)
    assert_equal :unsupported, client(StubTransport.new([405, ""])).delete(ID)
  end

  def test_errors_are_typed_with_user_facing_messages
    expired = assert_raises(Quartermaster::RoutinesClient::TokenExpired) { client(StubTransport.new([401, "{}"])).list }
    assert_equal "Claude Code's login token expired — open any Claude Code session, then refresh", expired.message

    changed = assert_raises(Quartermaster::RoutinesClient::ApiChanged) { client(StubTransport.new([404, "{}"])).list }
    assert_equal "routines API changed — check the `ccr-triggers-*` beta in the claude binary", changed.message

    assert_raises(Quartermaster::RoutinesClient::BadShape) { client(StubTransport.new([200, "<html>"])).list }
    assert_raises(Quartermaster::RoutinesClient::BadShape) { client(StubTransport.new([200, '{"items":[]}'])).list }
    assert_raises(Quartermaster::RoutinesClient::BadShape) { client(StubTransport.new([200, '{"data":[1]}'])).list }

    down = assert_raises(Quartermaster::RoutinesClient::Network) { client(StubTransport.new(SocketError.new("getaddrinfo"))).list }
    assert_match(/api\.anthropic\.com/, down.message)

    other = assert_raises(Quartermaster::RoutinesClient::Error) { client(StubTransport.new([500, '{"error":{"message":"boom"}}'])).list }
    assert_match(/500.*boom/, other.message)
  end

  def test_off_by_default_and_then_the_keychain_is_never_read
    keychain = runner
    api = Quartermaster::RoutinesClient.new(runner: keychain, transport: StubTransport.new([200, FIXTURE]),
                                            claude_json: @claude_json)
    error = assert_raises(Quartermaster::RoutinesClient::NotEnabled) { api.list }

    assert_equal "automations are off: run `qm config set automations.token_source claude_code`", error.message
    assert_empty keychain.calls

    configure_projects({}, automations: { "token_source" => "claude_code" })
    assert_equal [ID], api.list.map { |r| r["id"] }
  end

  def test_a_missing_or_expired_login_fails_before_any_request
    transport = StubTransport.new([200, FIXTURE])
    assert_raises(Quartermaster::RoutinesClient::TokenExpired) { client(transport, runner: runner("", success: false)).list }
    assert_raises(Quartermaster::RoutinesClient::TokenExpired) { client(transport, runner: runner("not json")).list }
    stale = JSON.generate("claudeAiOauth" => { "accessToken" => TOKEN, "expiresAt" => 1000 })
    assert_raises(Quartermaster::RoutinesClient::TokenExpired) { client(transport, runner: runner(stale)).list }
    File.write(@claude_json, "{}")
    assert_raises(Quartermaster::RoutinesClient::TokenExpired) { client(transport).list }
    assert_empty transport.requests
  end

  def test_the_token_never_reaches_an_error_message_or_the_log
    [[401, "{}"], [404, "{}"], [500, %({"error":{"message":"bad Bearer #{TOKEN}"}})], [200, "nope"],
     Errno::ECONNREFUSED.new("Bearer #{TOKEN}")].each do |answer|
      error = assert_raises(Quartermaster::RoutinesClient::Error) { client(StubTransport.new(answer)).list }
      refute_includes error.message, TOKEN
      Quartermaster.log_error("routines", error)
    end
    refute_includes File.read(Quartermaster::LOG_FILE), TOKEN
    refute_includes File.read(Quartermaster::LOG_FILE), "REFRESH"
  end
end
