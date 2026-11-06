# frozen_string_literal: true

module Quartermaster
  # The Settings view's server side, over ConfigFile: GET /api/settings is
  # the form's payload, POST /api/settings/check validates a draft (the page
  # never validates in JS), POST /api/settings/save writes one. A save is
  # refused as stale (409) when config.yml changed since the page loaded it,
  # and with its issues (422) while the draft has errors; a written save
  # answers a fresh state build so the page's buttons follow at once. Off the
  # action mutex: the write is quick and serialised by its own lock, and the
  # digest check is what keeps two editors apart.
  class GuiSettings
    JSON_TYPE = "application/json; charset=utf-8"

    # probe: what the warnings look at (ConfigCheck::Probe); tests pass a stub.
    def initialize(state:, probe: ConfigCheck::Probe.new)
      @state = state
      @probe = probe
      @lock = Mutex.new
    end

    # [status, content type, body] for a /api/settings route, nil for any other.
    def respond(method, route, request)
      case [method, route]
      when ["GET", "/api/settings"] then ok(payload)
      when ["POST", "/api/settings/check"] then ok(check(request["config"]))
      when ["POST", "/api/settings/save"] then save(request["config"], request["digest"])
      end
    end

    def payload
      file = ConfigFile.load(CONFIG_FILE, probe: @probe)
      issues = file.issues
      { "schema" => ConfigSchema.payload, "config" => self.class.normalize(file.data), "digest" => file.digest,
        "issues" => issues, "features" => ConfigSchema.features(file.data, issues),
        "items" => WorkItem.all.map(&:project).compact.tally, "priceDefaults" => PriceTable::DEFAULTS,
        "path" => CONFIG_FILE }
    end

    def check(config)
      issues = ConfigCheck.new(config, probe: @probe).issues
      { "issues" => issues, "features" => ConfigSchema.features(config, issues) }
    end

    # A mapping as the form edits it: unset values dropped (ConfigCheck.tidy)
    # and every shorthand opened into its mapping (a project's plain path is
    # {root}, a plain dev_server {command}); keys the schema doesn't govern
    # are left as they are.
    def self.normalize(value, pattern = "")
      shorthand = ConfigSchema::CONTAINERS.dig(pattern, :shorthand)
      value = { shorthand => value } if shorthand && value.is_a?(String)
      return value unless value.is_a?(Hash)

      (pattern.empty? ? ConfigCheck.tidy(value) : value).to_h do |key, child_value|
        child = ConfigSchema.child(pattern, key.to_s)
        [key, child && ConfigSchema::CONTAINERS.key?(child) ? normalize(child_value, child) : child_value]
      end
    end

    private

    def save(config, digest)
      file = ConfigFile.load(CONFIG_FILE, probe: @probe).replace(config)
      @lock.synchronize { file.write!(digest: digest.to_s) }
      @state.forget_pf_status
      ok("ok" => true, "settings" => payload, "state" => @state.build)
    rescue ConfigFile::Stale => e
      answer("409 Conflict", "ok" => false, "stale" => true, "error" => e.message, "settings" => payload)
    rescue ConfigFile::Invalid => e
      answer("422 Unprocessable Content", "ok" => false, "error" => e.message, "issues" => e.issues,
                                          "features" => ConfigSchema.features(config, e.issues))
    end

    def ok(object) = answer("200 OK", object)

    def answer(status, object) = [status, JSON_TYPE, JSON.generate(object)]
  end
end
