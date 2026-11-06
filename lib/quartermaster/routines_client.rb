# frozen_string_literal: true

module Quartermaster
  # The claude.ai routines API (scheduled cloud Claude Code agents), called
  # straight at api.anthropic.com with Claude Code's own login. Off until
  # `automations.token_source` is set; then each call reads the token from
  # the keychain through the runner and drops it afterwards: never stored,
  # logged, put in a message or refreshed (a refresh would rotate Claude
  # Code's refresh token and could log it out). Every failure is a typed
  # Error whose message is for the user. Request bodies are built in
  # .request_body only, the one place to fix when the API's shape moves.
  class RoutinesClient
    API = "https://api.anthropic.com"
    HEADERS = { "anthropic-version" => "2023-06-01", "anthropic-beta" => "ccr-triggers-2026-01-30",
                "content-type" => "application/json" }.freeze
    KEYCHAIN = ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"].freeze
    TOKEN_SOURCES = %w[claude_code].freeze
    CONFIG_COMMAND = "qm config set automations.token_source claude_code"
    # Local field → its top-level API key; the JOB_FIELDS go in job_config.
    BODY_KEYS = { "name" => "name", "cron" => "cron_expression", "enabled" => "enabled",
                  "connectors" => "mcp_connections" }.freeze
    JOB_FIELDS = %w[prompt model sources allowed_tools environment_id].freeze

    # ArgumentError is qm's user-facing channel: the CLI aborts with the
    # message and GUI jobs answer it without logging.
    class Error < ArgumentError; end

    class NotEnabled < Error
      def initialize(msg = "automations are off: run `#{CONFIG_COMMAND}`") = super
    end

    class TokenExpired < Error
      def initialize(msg = "Claude Code's login token expired — open any Claude Code session, then refresh") = super
    end

    class ApiChanged < Error
      def initialize(msg = "routines API changed — check the `ccr-triggers-*` beta in the claude binary") = super
    end

    class BadShape < Error; end

    class Network < Error; end

    # One HTTPS request: [status, body]. Tests pass a stub with the same call.
    class Transport
      def call(method, url, headers, body)
        uri = URI(url)
        request = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri, headers)
        request.body = body if body
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
          http.request(request)
        end
        [response.code.to_i, response.body.to_s]
      end
    end

    def self.routine_url(id) = "https://claude.ai/code/routines/#{id}"

    def self.run_url(session_id) = "https://claude.ai/code/#{session_id}"

    # A remote routine in the local shape: name, cron (UTC), enabled, prompt,
    # model, sources, allowed_tools, environment_id, connectors (its
    # mcp_connections as given) and updated_at. The one remote-to-local
    # mapping: prompt and model fall back to derived_state.
    def self.fields(routine)
      raise BadShape, "routines API answered a routine without an id" unless routine.is_a?(Hash) && routine["id"].is_a?(String)

      ccr = routine.dig("job_config", "ccr")
      ccr = {} unless ccr.is_a?(Hash)
      context = ccr["session_context"].is_a?(Hash) ? ccr["session_context"] : {}
      event = Array(ccr["events"]).first
      prompt = event.dig("data", "message", "content") if event.is_a?(Hash)
      prompt = routine.dig("derived_state", "prompt") unless prompt.is_a?(String)
      { "id" => routine["id"], "name" => routine["name"], "cron" => routine["cron_expression"],
        "enabled" => routine["enabled"], "prompt" => prompt, "model" => context["model"] || routine.dig("derived_state", "model"),
        "sources" => context["sources"], "allowed_tools" => context["allowed_tools"],
        "environment_id" => ccr["environment_id"], "connectors" => routine["mcp_connections"],
        "updated_at" => routine["updated_at"] }
    end

    # The create/update body for local fields; only the fields given, so a
    # partial update stays partial. Any job field sends the whole job_config.
    # Given connectors (nil counts as none) are sent as the routine's exact
    # set: an empty list also sends clear_mcp_connections, since the API
    # reads an empty or missing mcp_connections as "leave them" (on create:
    # "attach all"). Callers that omit connectors leave them untouched.
    def self.request_body(fields, uuid: SecureRandom.uuid)
      body = BODY_KEYS.filter_map { |local, api| [api, fields[local]] if fields.key?(local) }.to_h
      if fields.key?("connectors")
        body["mcp_connections"] = fields["connectors"] || []
        body["clear_mcp_connections"] = true if body["mcp_connections"].empty?
      end
      body["job_config"] = job_config(fields, uuid) if JOB_FIELDS.any? { |f| fields.key?(f) }
      body
    end

    def self.job_config(fields, uuid)
      message = { "content" => fields["prompt"].to_s, "role" => "user" }
      event = { "data" => { "message" => message, "parent_tool_use_id" => nil, "session_id" => "", "type" => "user",
                            "uuid" => uuid } }
      context = { "allowed_tools" => fields["allowed_tools"] || [], "model" => fields["model"],
                  "sources" => fields["sources"] || [] }.compact
      { "ccr" => { "environment_id" => fields["environment_id"], "events" => [event], "session_context" => context } }
    end

    # token_source: asked on every call (config.yml's
    # automations.token_source by default); claude_json: where Claude Code
    # keeps the organization.
    def initialize(runner: CommandRunner.new, transport: Transport.new, claude_json: File.expand_path("~/.claude.json"),
                   token_source: -> { ProjectConfig.current.automations_token_source })
      @runner = runner
      @transport = transport
      @claude_json = claude_json
      @token_source = token_source
    end

    def list = routines(request("GET", "/v1/code/triggers"))

    def get(id) = routine(request("GET", "/v1/code/triggers/#{id}"))

    def create(fields) = routine(request("POST", "/v1/code/triggers", self.class.request_body(fields)))

    def update(id, fields) = routine(request("POST", "/v1/code/triggers/#{id}", self.class.request_body(fields)))

    def run(id) = request("POST", "/v1/code/triggers/#{id}/run", {})

    # The routine's sessions, most recent first: id, title, status, the
    # timestamps given and the claude.ai link; missing fields stay nil.
    def runs(id, limit: 10)
      answer = request("GET", "/v1/code/sessions?#{URI.encode_www_form(trigger_id: id, limit: limit)}")
      list = answer.is_a?(Hash) ? answer["data"] : answer
      raise BadShape, "routines API answered runs that aren't a list" unless list.is_a?(Array)

      list.select { |s| s.is_a?(Hash) && s["id"].is_a?(String) }.first(limit).map do |s|
        { "id" => s["id"], "title" => s["title"], "status" => s["status"], "created_at" => s["created_at"],
          "updated_at" => s["updated_at"], "url" => self.class.run_url(s["id"]) }
      end
    end

    # :deleted, or :unsupported when the API has no delete (404/405); what
    # to do then is the caller's call.
    def delete(id)
      request("DELETE", "/v1/code/triggers/#{id}", nil, unsupported: [404, 405]) == :unsupported ? :unsupported : :deleted
    end

    private

    def routines(answer)
      list = answer["data"] if answer.is_a?(Hash)
      raise BadShape, "routines API answered a list without data" unless list.is_a?(Array)

      list.each { |r| self.class.fields(r) }
    end

    def routine(answer) = answer.tap { self.class.fields(answer) }

    def request(method, path, body = nil, unsupported: [])
      token = token!
      headers = HEADERS.merge("Authorization" => "Bearer #{token}", "x-organization-uuid" => organization!)
      status, text = send_request(method, path, headers, body, token)
      return :unsupported if unsupported.include?(status)

      check_status(status, text, token)
      parse(text)
    end

    def send_request(method, path, headers, body, token)
      @transport.call(method, "#{API}#{path}", headers, body && JSON.generate(body))
    rescue StandardError => e
      raise Network, scrub("can't reach api.anthropic.com: #{e.class.name.split("::").last}: #{e.message}", token)
    end

    def check_status(status, text, token)
      raise TokenExpired if status == 401
      raise ApiChanged if status == 404
      return if (200..299).cover?(status)

      detail = Quartermaster.json_object(text)&.dig("error", "message")
      raise Error, scrub("routines API answered #{status}#{": #{detail}" if detail.is_a?(String)}", token)
    end

    def parse(text)
      return {} if text.strip.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      raise BadShape, "routines API answered something that isn't JSON"
    end

    def token!
      raise NotEnabled unless TOKEN_SOURCES.include?(@token_source.call)

      result = @runner.call(KEYCHAIN)
      raise TokenExpired, "Claude Code's login wasn't found in the keychain — log in to Claude Code, then refresh" unless result.success?

      oauth = Quartermaster.json_object(result.out)&.dig("claudeAiOauth")
      token = oauth["accessToken"] if oauth.is_a?(Hash)
      raise TokenExpired, "Claude Code's keychain login has no access token — log in to Claude Code, then refresh" unless token.is_a?(String) && !token.empty?
      raise TokenExpired if oauth["expiresAt"].is_a?(Numeric) && oauth["expiresAt"] / 1000.0 <= Time.now.to_f

      token
    end

    def organization!
      data = Quartermaster.json_object(File.read(@claude_json))
      uuid = data&.dig("oauthAccount", "organizationUuid")
      return uuid if uuid.is_a?(String) && !uuid.empty?

      raise TokenExpired, "no claude.ai organization in #{Quartermaster.shorten_home(@claude_json)} — log in to Claude Code, then refresh"
    rescue SystemCallError
      raise TokenExpired, "can't read #{Quartermaster.shorten_home(@claude_json)} — log in to Claude Code, then refresh"
    end

    def scrub(message, token) = message.gsub(token, "[token]")
  end
end
