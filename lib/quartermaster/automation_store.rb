# frozen_string_literal: true

module Quartermaster
  # The local copy of each automation, the source of truth push sends from:
  # `automations/<slug>.yml` (the routine's settings, `v:` first) and
  # `automations/<slug>.prompt.md` (the prompt, nothing else). A write merges
  # onto the stored keys, so keys qm doesn't know survive, keeps each replaced
  # file as `<file>.bak` and replaces files through AtomicFile.
  #
  # `from_routine` and `routine_body` map between a claude.ai routine as the
  # routines API returns it and a record + prompt; `routine_body` is the one
  # place a create/update request body is built.
  class AutomationStore
    VERSION = 1
    FIELDS = %w[routine runner name cron model sources connectors allowed_tools environment_id enabled remote_updated_at].freeze
    SLUG = /\A[a-z0-9][a-z0-9-]*\z/

    Entry = Data.define(:slug, :record, :prompt)

    def initialize(dir = AUTOMATIONS_DIR)
      @dir = dir
    end

    def exists?(slug) = File.exist?(yml_path(slug))

    def read(slug)
      return nil unless exists?(slug)

      prompt = File.exist?(prompt_path(slug)) ? File.read(prompt_path(slug)) : ""
      Entry.new(slug: slug, record: load_record(slug), prompt: prompt)
    end

    # Every stored automation, by slug.
    def list
      return [] unless Dir.exist?(@dir)

      Dir.children(@dir).filter_map { |f| f.delete_suffix(".yml") if f.end_with?(".yml") }.grep(SLUG).sort.map { |slug| read(slug) }
    end

    def find_by_routine(id) = list.find { |entry| entry.record["routine"] == id }

    # Merges `record` onto the stored keys and writes it with `prompt`;
    # returns the entry as stored.
    def write(slug, record, prompt)
      merged = exists?(slug) ? load_record(slug) : {}
      merged = merged.merge(record.transform_keys(&:to_s)).merge("v" => VERSION)
      FileUtils.mkdir_p(@dir)
      replace(yml_path(slug), Psych.dump(ordered(merged)))
      replace(prompt_path(slug), prompt.to_s)
      Entry.new(slug: slug, record: merged, prompt: prompt.to_s)
    end

    # Removes the two files; their `.bak`s stay as the last copy.
    def delete_local(slug)
      FileUtils.rm_f([yml_path(slug), prompt_path(slug)])
    end

    def yml_path(slug) = File.join(@dir, "#{checked(slug)}.yml")

    def prompt_path(slug) = File.join(@dir, "#{checked(slug)}.prompt.md")

    # A routine from the API as `[record, prompt]`.
    def self.from_routine(routine)
      raise ArgumentError, "not a routine: #{routine.class}" unless routine.is_a?(Hash) && routine["id"].is_a?(String)

      ccr = routine.dig("job_config", "ccr") || {}
      context = ccr["session_context"] || {}
      record = {
        "routine" => routine["id"], "runner" => "cloud", "name" => routine["name"], "cron" => routine["cron_expression"],
        "model" => context["model"] || routine.dig("derived_state", "model"), "sources" => context["sources"] || [],
        "connectors" => routine["mcp_connections"] || [], "allowed_tools" => context["allowed_tools"] || [],
        "environment_id" => ccr["environment_id"], "enabled" => routine["enabled"], "remote_updated_at" => routine["updated_at"]
      }
      prompt = ccr.dig("events", 0, "data", "message", "content") || routine.dig("derived_state", "prompt") || ""
      [record, prompt]
    end

    # The create/update request body for a record + prompt: the whole
    # job_config, since updating the prompt means sending it again. Unset
    # values are left out.
    def self.routine_body(record, prompt, uuid: SecureRandom.uuid)
      message = { "content" => prompt, "role" => "user" }
      event = { "data" => { "message" => message, "parent_tool_use_id" => nil, "session_id" => "", "type" => "user", "uuid" => uuid } }
      context = { "allowed_tools" => record["allowed_tools"], "model" => record["model"], "sources" => record["sources"] }.compact
      ccr = { "environment_id" => record["environment_id"], "events" => [event], "session_context" => context }.compact
      {
        "name" => record["name"], "cron_expression" => record["cron"], "enabled" => record["enabled"],
        "job_config" => { "ccr" => ccr }, "mcp_connections" => record["connectors"]
      }.compact
    end

    private

    def checked(slug)
      raise ArgumentError, "not an automation slug: #{slug.inspect}" unless slug.is_a?(String) && slug.match?(SLUG)

      slug
    end

    def load_record(slug)
      data = YAML.safe_load(File.read(yml_path(slug)))
      data.is_a?(Hash) ? data : {}
    end

    def ordered(record) = (["v"] + FIELDS).filter_map { |k| [k, record[k]] if record.key?(k) }.to_h.merge(record)

    def replace(path, content)
      File.write("#{path}.bak", File.read(path)) if File.exist?(path)
      AtomicFile.write(path, content)
    end
  end
end
