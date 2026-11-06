# frozen_string_literal: true

module Quartermaster
  # The ⚙ area's Automations tab, server side (/api/automations…), over the
  # Automations service. GET answers the local files at once, merged with the
  # routines the last list call saw; every network call (the list, a detail's
  # runs, push, pull, pause, resume, run, delete, adopt) runs as a GuiJobs job,
  # never under the action mutex, and each action ends with one list call so
  # the tab shows where it landed. Automations being off or Claude Code's
  # token having expired is a state of the tab (`remote.state`), not an error.
  class GuiAutomations
    JSON_TYPE = "application/json; charset=utf-8"
    ACTIONS = %w[apply pause resume run pull push delete].freeze
    UNREACHABLE = [RoutinesClient::NotEnabled, RoutinesClient::TokenExpired].freeze

    def initialize(jobs:, client:, store: AutomationStore.new)
      @jobs = jobs
      @client = client
      @service = Automations.new(client: client, store: store)
      @store = store
      @lock = Mutex.new
      @remote = { "state" => "idle" }
      @runs = {}
    end

    # [status, content type, body] for a /api/automations route, nil for any other.
    def respond(method, route, request)
      return unless route == "/api/automations" || route.start_with?("/api/automations/")

      verb = route.delete_prefix("/api/automations").delete_prefix("/")
      return ok(verb.empty? ? list : detail(verb)) if method == "GET"
      return unless method == "POST"

      case verb
      when "refresh" then ok(refresh)
      when "runs" then ok(load_runs(request["slug"].to_s))
      when "adopt" then ok(adopt(request))
      when "new" then ok(create(request))
      when *ACTIONS then ok(act(verb, request["slug"].to_s, request))
      end
    rescue ArgumentError => e
      answer("422 Unprocessable Content", "ok" => false, "error" => e.message)
    end

    def list
      remote = remote_state
      rows = @service.local.map { |row| row_payload(row["entry"], row["item"], remote["routines"]) }
      managed = rows.filter_map { |r| r["routine"] }
      unmanaged = (remote["routines"] || {}).values.reject { |r| managed.include?(r["id"]) }.map do |r|
        { "id" => r["id"], "name" => r["name"], "cron" => r["cron_expression"], "enabled" => r["enabled"] != false,
          "schedule" => schedule(r["cron_expression"]), "routineUrl" => Automations.routine_url(r["id"]) }
      end
      { "remote" => remote.except("routines"), "rows" => rows, "unmanaged" => unmanaged }
    end

    def detail(slug)
      entry = @store.read(slug) or raise ArgumentError, "no automation '#{slug}'"
      item = @service.local.find { |row| row["slug"] == slug }&.dig("item")
      record = entry.record
      runs = @lock.synchronize { @runs[slug] } || { "state" => "idle" }
      row_payload(entry, item, remote_state["routines"]).merge(
        "prompt" => entry.prompt, "model" => record["model"], "promptPath" => @store.prompt_path(slug),
        "ymlPath" => @store.yml_path(slug),
        "repos" => Array(record["sources"]).filter_map { |s| s.dig("git_repository", "url") || s["url"] if s.is_a?(Hash) },
        "connectors" => Array(record["connectors"]).filter_map { |c| c["name"] if c.is_a?(Hash) },
        "item" => item && { "title" => item.title, "project" => item.project, "state" => item.state,
                            "description" => item.description, "notes" => item.notes.map(&:to_h) },
        "runs" => runs["runs"], "runsState" => runs["state"], "runsError" => runs["error"]
      )
    end

    private

    def enabled? = RoutinesClient::TOKEN_SOURCES.include?(ProjectConfig.current.automations_token_source)

    def remote_state
      return { "state" => "off", "message" => RoutinesClient::NotEnabled.new.message, "command" => RoutinesClient::CONFIG_COMMAND } unless enabled?

      @lock.synchronize { @remote.dup }
    end

    def row_payload(entry, item, routines)
      record = entry.record
      remote = routines&.[](record["routine"])
      run = remote && remote["last_run"].is_a?(Hash) ? remote["last_run"] : nil
      { "slug" => entry.slug, "name" => record["name"] || item&.title || entry.slug, "project" => item&.project,
        "state" => item&.state, "cron" => record["cron"], "schedule" => schedule(record["cron"]),
        "enabled" => record["enabled"] != false, "runner" => record["runner"] || "cloud", "routine" => record["routine"],
        "routineUrl" => record["routine"] && Automations.routine_url(record["routine"]),
        "drift" => @service.drift?(entry, remote), "missing" => !record["routine"].nil? && !routines.nil? && remote.nil?,
        "nextRunAt" => remote&.dig("next_run_at"),
        "lastRun" => run && { "status" => run["status"], "at" => run["finished_at"] || run["fired_at"],
                              "url" => run["session_id"] && RoutinesClient.run_url(run["session_id"]) } }
    end

    def schedule(cron)
      return nil if cron.nil?

      s = LocalSchedule.from_cron(cron)
      { "label" => s.label, "days" => s.days, "time" => s.time, "raw" => s.raw? }
    end

    def refresh
      return { "ok" => true, "remote" => remote_state } unless enabled?

      loaded = @lock.synchronize { @runs.reject { |_, runs| runs["state"] == "idle" }.keys }
      @jobs.background("automations", "listing routines") do
        fetch_routines
        @lock.synchronize { loaded.each { |slug| @runs[slug] = stale(@runs[slug]) } }
        { "ok" => true, "quiet" => true, "automation" => nil }
      end
    end

    # The one list call; an unreachable API becomes the tab's state.
    def fetch_routines
      routines = @client.list
      @lock.synchronize do
        @remote = { "state" => "ok", "fetchedAt" => Time.now.utc.iso8601, "routines" => routines.to_h { |r| [r["id"], r] } }
      end
    rescue *UNREACHABLE => e
      unreachable(e)
    rescue RoutinesClient::Error => e
      @lock.synchronize { @remote = @remote.merge("state" => "error", "message" => e.message) }
    end

    def unreachable(error)
      state = error.is_a?(RoutinesClient::NotEnabled) ? "off" : "expired"
      @lock.synchronize { @remote = { "state" => state, "message" => error.message } }
    end

    # Runs shown until the page asks again: still listed, but idle, so the
    # open detail reloads them.
    def stale(runs) = { "state" => "idle", "runs" => runs && runs["runs"] }

    def load_runs(slug)
      entry = @store.read(slug) or raise ArgumentError, "no automation '#{slug}'"
      id = entry.record["routine"]
      @jobs.background("automation-runs-#{slug}", "loading runs") do
        runs = id ? @client.runs(id, limit: 10) : []
        @lock.synchronize { @runs[slug] = { "state" => "ok", "runs" => runs } }
        { "ok" => true, "quiet" => true, "automation" => slug }
      rescue *UNREACHABLE => e
        unreachable(e)
        @lock.synchronize { @runs[slug] = { "state" => "idle" } }
        { "ok" => false, "quiet" => true, "error" => e.message, "automation" => slug }
      rescue RoutinesClient::Error => e
        @lock.synchronize { @runs[slug] = { "state" => "error", "error" => e.message } }
        { "ok" => false, "quiet" => true, "error" => e.message, "automation" => slug }
      end
    end

    def adopt(request)
      id = request["id"].to_s
      project = request["project"].to_s
      raise ArgumentError, "pick a project for #{id}" if project.empty?

      slug = request["slug"].to_s.empty? ? nil : request["slug"].to_s
      job("automation-adopt-#{id}", "adopting") do
        entry = @service.adopt(id, project: project, slug: slug)
        ["adopted as #{entry.slug}", entry.slug]
      end
    end

    # A kind: automation item and its empty files; the page then opens its
    # chat through the automation-chat action.
    def create(request)
      title = request["title"].to_s.strip
      project = request["project"].to_s
      raise ArgumentError, "an automation needs a title and a project" if title.empty? || project.empty?

      description = request["description"].to_s.strip
      item = AutomationChat.create(title, project: project, description: description.empty? ? nil : description, store: @store)
      { "ok" => true, "slug" => item.slug }
    end

    def act(verb, slug, request)
      entry = @store.read(slug) or raise ArgumentError, "no automation '#{slug}'"
      save_edits(entry, request) if verb == "apply"
      job("automation-#{slug}", verb == "apply" ? "pushing" : verb) do
        [run_action(verb, slug, request), slug]
      ensure
        @lock.synchronize { @runs[slug] = stale(@runs[slug]) if @runs.key?(slug) }
      end
    end

    def run_action(verb, slug, request)
      case verb
      when "apply", "push"
        changes = @service.push(slug, force: verb == "push" && request["force"] == true)["changes"]
        changes.empty? ? "#{slug}: nothing to push" : "#{slug}: #{changes.join("; ")}"
      when "pull"
        changes = @service.pull(slug)
        changes.empty? ? "#{slug}: already in sync" : "#{slug}: pulled #{changes.join(", ")}"
      when "pause", "resume"
        @service.public_send(verb, slug)
        "#{slug}: #{verb == "pause" ? "paused" : "resumed"}"
      when "run"
        @service.run(slug)
        "#{slug}: running"
      when "delete" then deleted_message(slug, @store.read(slug).record["routine"], @service.delete(slug))
      end
    end

    def deleted_message(slug, routine, outcome)
      case outcome
      when :paused then "#{slug}: paused; delete it on claude.ai: #{Automations.routine_url(routine)}"
      when :deleted then "#{slug}: deleted"
      else "#{slug}: removed (it was never pushed)"
      end
    end

    # Apply's schedule and prompt land in the local files before the push.
    def save_edits(entry, request)
      changes = {}
      if request.key?("cron")
        cron = request["cron"].to_s.strip
        raise ArgumentError, "a cron has five fields (minute hour day month weekday), got #{cron.inspect}" unless cron.split.size == 5

        changes["cron"] = cron
      elsif request.key?("days")
        changes["cron"] = LocalSchedule.to_cron(days: Array(request["days"]), time: request["time"])
      end
      prompt = request.key?("prompt") ? request["prompt"].to_s : entry.prompt
      @store.write(entry.slug, changes, prompt)
    end

    # A network action as a job: its message for the toast, then one list
    # call, also after a refusal (a stale push then shows its drift); an
    # unreachable API answers quietly (the tab shows why).
    def job(key, label)
      @jobs.background(key, label) do
        message, slug = yield
        fetch_routines
        { "ok" => true, "message" => message, "automation" => slug }
      rescue *UNREACHABLE => e
        unreachable(e)
        { "ok" => false, "quiet" => true, "error" => e.message }
      rescue ArgumentError => e
        fetch_routines
        { "ok" => false, "error" => e.message }
      end
    end

    def ok(object) = answer("200 OK", object)

    def answer(status, object) = [status, JSON_TYPE, JSON.generate(object)]
  end
end
