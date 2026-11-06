# frozen_string_literal: true

module Quartermaster
  # What the CLI and the GUI do with automations: each one is a local store
  # entry plus a `kind: automation` work item of the same slug. The local
  # files are the source of truth and push is the one path that changes a
  # routine: it refuses when the routine moved since the last sync (unless
  # forced), records the routine's new updated_at, appends a history note
  # naming what changed and moves the item's state with the routine
  # (enabled → active, paused → fridge). Every network call goes through the
  # RoutinesClient, whose errors are user-facing ArgumentErrors.
  class Automations
    class Stale < ArgumentError; end

    STATE_FOR_ENABLED = { true => "active", false => "fridge" }.freeze
    # Local field → how a history note names a change to it.
    CHANGE_LABELS = { "name" => "name", "cron" => "schedule", "enabled" => "enabled", "prompt" => "prompt",
                      "model" => "model", "sources" => "repos", "allowed_tools" => "tools",
                      "environment_id" => "environment", "connectors" => "connectors" }.freeze
    TOP_FIELDS = %w[name cron enabled connectors].freeze
    LIST_FIELDS = %w[sources allowed_tools connectors].freeze

    attr_reader :store, :local_automations

    # `local` handles the `runner: local` ones (LocalAutomations); the
    # claude.ai verbs refuse them.
    def initialize(client: RoutinesClient.new, store: AutomationStore.new, local: nil)
      @client = client
      @store = store
      @local_automations = local || LocalAutomations.new(store: store)
    end

    def self.routine_url(id) = RoutinesClient.routine_url(id)

    # Every local automation, without touching the network: slug, the store
    # entry and its work item (nil when the item is gone).
    def local
      @store.list.map { |entry| { "slug" => entry.slug, "entry" => entry, "item" => item_or_nil(entry.slug) } }
    end

    # The local rows merged with one list call: each row gains "remote" (the
    # routine, or nil when it isn't on claude.ai) and "drift" (the routine
    # changed since the last sync); "unmanaged" are routines with no local
    # files. `runner: local` rows have no routine and are left out.
    def overview(rows = local)
      routines = @client.list
      by_id = routines.to_h { |r| [r["id"], r] }
      rows = rows.reject { |row| LocalAutomations.local?(row["entry"]) }.map do |row|
        remote = by_id[row["entry"].record["routine"]]
        row.merge("remote" => remote, "drift" => drift?(row["entry"], remote))
      end
      managed = rows.filter_map { |row| row["entry"].record["routine"] }
      { "rows" => rows, "unmanaged" => routines.reject { |r| managed.include?(r["id"]) } }
    end

    # One automation with its routine and its last `limit` runs.
    def detail(slug, limit: 10)
      entry = entry!(slug)
      return @local_automations.detail(slug) if LocalAutomations.local?(entry)

      id = entry.record["routine"]
      remote = id && @client.get(id)
      { "slug" => slug, "entry" => entry, "item" => item_or_nil(slug), "remote" => remote,
        "drift" => drift?(entry, remote), "runs" => id ? @client.runs(id, limit: limit) : [] }
    end

    # Takes a routine with no local files under qm: the store entry and a
    # `kind: automation` item whose description is the routine's name and its
    # prompt's first paragraph.
    def adopt(id, project:, slug: nil)
      refuse_local!(slug && @store.read(slug))
      raise ArgumentError, "#{id} is already managed by qm as '#{@store.find_by_routine(id).slug}'" if @store.find_by_routine(id)

      routine = @client.get(id)
      record, prompt = AutomationStore.from_routine(routine)
      slug ||= WorkItem.slugify(record["name"].to_s)
      raise ArgumentError, "automation '#{slug}' already exists" if @store.exists?(slug)

      item = create_item(slug, record["name"] || id, project: project, description: draft_description(record["name"], prompt),
                                                     routine: id)
      entry = @store.write(slug, record, prompt)
      item.update_state(STATE_FOR_ENABLED.fetch(record["enabled"] == true))
      entry
    end

    # A `kind: automation` work item under `slug` (which needn't be the
    # title's slug); `routine` is written once the routine exists.
    def create_item(slug, title, project:, description: nil, routine: nil)
      WorkItem.create(title, project: project, description: description, slug: slug,
                             front: { "kind" => "automation", "routine" => routine, "runner" => "cloud" }.compact)
    end

    # Sends the local files: creates the routine on the first push, else
    # updates what differs. `recreate` makes a new routine for one deleted on
    # claude.ai, and only then. Answers {"created" => bool, "changes" => [...]}.
    def push(slug, force: false, recreate: false)
      entry = entry!(slug)
      refuse_local!(entry)
      id = entry.record["routine"]
      raise ArgumentError, "#{slug} has no routine yet: `qm automation push #{slug}` creates it" if recreate && !id
      return create(entry) unless id

      remote = begin
        @client.get(id)
      rescue RoutinesClient::RoutineMissing => e
        return create(entry, was: id) if recreate

        raise ArgumentError, "#{slug}: #{e.message} (`qm automation delete #{slug}`) or re-create it " \
                             "(`qm automation push #{slug} --recreate`)"
      end
      raise ArgumentError, "#{slug}: routine #{id} is still on claude.ai — `qm automation push #{slug}` updates it" if recreate

      check_fresh!(entry, remote) unless force
      changes = pushable_changes(fields_of(entry), RoutinesClient.fields(remote))
      updated = changes.empty? ? remote : @client.update(id, update_fields(entry, changes))
      @store.write(slug, { "remote_updated_at" => updated["updated_at"] }, entry.prompt)
      finish_push(slug, entry.record["enabled"], changes.map { |f| describe_change(f, entry) }, created: false)
    end

    # The routine overwrites the local files (each kept as .bak).
    def pull(slug)
      entry = entry!(slug)
      refuse_local!(entry)
      id = entry.record["routine"] or raise ArgumentError, "#{slug} has no routine yet: `qm automation push #{slug}` creates it"

      record, prompt = AutomationStore.from_routine(@client.get(id))
      pulled = AutomationStore::Entry.new(slug: slug, record: record, prompt: prompt)
      changes = changed_fields(fields_of(entry), fields_of(pulled)).map { |f| CHANGE_LABELS[f] }
      @store.write(slug, record, prompt)
      item = WorkItem.find(slug)
      item.add_note("pulled from claude.ai: #{changes.empty? ? "no changes" : changes.join(", ")}", kind: "history")
      sync_state(item, record["enabled"])
      changes
    end

    def pause(slug) = local?(slug) ? @local_automations.pause(slug) : set_enabled(slug, false)

    # `skip_existing` (local only): the guard's current items are marked seen.
    def resume(slug, skip_existing: false)
      return @local_automations.resume(slug, skip_existing: skip_existing) if local?(slug)
      raise ArgumentError, "#{slug}: --skip-existing is for local automations (they have a guard)" if skip_existing

      set_enabled(slug, true)
    end

    # Runs the routine now; answers the API's reply. A local automation
    # queues a manual run instead and answers the queued run ids.
    def run(slug)
      return @local_automations.run(slug) if local?(slug)

      id = entry!(slug).record["routine"] or raise ArgumentError, "#{slug} has no routine yet: `qm automation push #{slug}` creates it"

      @client.run(id)
    end

    # Deletes the routine, or pauses it when the API has no delete; the item
    # is resolved either way. Answers :deleted (also when the routine was
    # already gone), :paused or :local (never pushed). A local automation is
    # LocalAutomations#delete: refused while a run is live.
    def delete(slug)
      entry = entry!(slug)
      return @local_automations.delete(slug) if LocalAutomations.local?(entry)

      id = entry.record["routine"]
      outcome = if id.nil? then :local
                elsif @client.delete(id) == :deleted then :deleted
                else pause_for_delete(entry, id)
                end
      @store.delete_local(slug) unless outcome == :paused
      item = item_or_nil(slug)
      item&.add_note(outcome == :paused ? "paused on claude.ai (no delete in the API)" : "deleted", kind: "history")
      item&.update_state("resolved")
      outcome
    end

    def drift?(entry, remote) = !remote.nil? && remote["updated_at"] != entry.record["remote_updated_at"]

    private

    def entry!(slug) = @store.read(slug) || raise(ArgumentError, "no automation '#{slug}'")

    def local?(slug) = LocalAutomations.local?(entry!(slug))

    def refuse_local!(entry)
      raise ArgumentError, "#{entry.slug} runs locally — nothing on claude.ai" if LocalAutomations.local?(entry)
    end

    def pause_for_delete(entry, id)
      updated = @client.update(id, { "enabled" => false }.merge(connectors_of(entry)))
      @store.write(entry.slug, { "enabled" => false, "remote_updated_at" => updated["updated_at"] }, entry.prompt)
      :paused
    rescue RoutinesClient::RoutineMissing
      :deleted
    end

    def item_or_nil(slug)
      File.exist?(WorkItem.path_for(slug)) ? WorkItem.find(slug) : nil
    end

    # The first push, or a re-create (`was` the deleted routine's id): the
    # new routine's id and updated_at replace the stored ones.
    def create(entry, was: nil)
      routine = @client.create(fields_of(entry).compact.merge(connectors_of(entry)))
      @store.write(entry.slug, AutomationStore.from_routine(routine).first, entry.prompt)
      item = WorkItem.with_lock do
        WorkItem.find(entry.slug).tap do |fresh|
          fresh.front["routine"] = routine["id"]
          fresh.save
        end
      end
      change = was ? "re-created routine #{routine["id"]} (was #{was})" : "created routine #{routine["id"]}"
      finish_push(entry.slug, entry.record["enabled"], [change], created: true, item: item)
    end

    def finish_push(slug, enabled, changes, created:, item: WorkItem.find(slug))
      item.add_note("pushed: #{changes.join("; ")}", kind: "history") unless changes.empty?
      sync_state(item, enabled)
      { "created" => created, "changes" => changes }
    end

    def sync_state(item, enabled)
      state = STATE_FOR_ENABLED.fetch(enabled != false)
      item.update_state(state) unless item.state == state
    end

    def set_enabled(slug, enabled)
      entry = entry!(slug)
      @store.write(slug, { "enabled" => enabled }, entry.prompt)
      push(slug)
    end

    def check_fresh!(entry, remote)
      return unless drift?(entry, remote)

      raise Stale, "#{entry.slug} changed outside qm (claude.ai: #{remote["updated_at"]}, last sync: " \
                   "#{entry.record["remote_updated_at"] || "never"}): `qm automation pull #{entry.slug}` takes the " \
                   "routine, `qm automation push #{entry.slug} --force` overwrites it"
    end

    # The entry in RoutinesClient's field shape.
    def fields_of(entry) = CHANGE_LABELS.keys.to_h { |k| [k, entry.record[k]] }.merge("prompt" => entry.prompt)

    # A list field unset on one side and empty on the other is no change.
    def changed_fields(local, remote)
      CHANGE_LABELS.keys.reject { |f| LIST_FIELDS.include?(f) ? (local[f] || []) == (remote[f] || []) : local[f] == remote[f] }
    end

    # What a push can change: a field unset locally can't be sent, so the
    # routine keeps its value and it is no change.
    def pushable_changes(local, remote)
      changed_fields(local, remote).reject { |f| local[f].nil? && !LIST_FIELDS.include?(f) }
    end

    # Changed top-level fields as they are; any changed job field sends all of
    # them, since the API takes job_config whole. Connectors always go along.
    def update_fields(entry, changes)
      fields = fields_of(entry)
      job = RoutinesClient::JOB_FIELDS
      keys = (changes & TOP_FIELDS) + (changes.intersect?(job) ? job : [])
      fields.slice(*keys).merge(connectors_of(entry))
    end

    # Every create and update carries the stored connectors (none → []), so
    # a pushed routine has exactly those and never the API's default set.
    def connectors_of(entry) = { "connectors" => entry.record["connectors"] || [] }

    def describe_change(field, entry)
      record = entry.record
      case field
      when "cron"
        schedule = LocalSchedule.from_cron(record["cron"])
        "schedule → #{schedule.raw? ? schedule.label : "#{schedule.label} (#{record["cron"]} UTC)"}"
      when "enabled" then record["enabled"] == false ? "paused" : "resumed"
      when "name" then "name → #{record["name"]}"
      else "#{CHANGE_LABELS[field]} changed"
      end
    end

    def draft_description(name, prompt)
      paragraph = prompt.to_s.strip.split(/\n\s*\n/).first.to_s.strip
      [name, paragraph].reject { |s| s.nil? || s.empty? }.join("\n\n")
    end
  end
end
