# frozen_string_literal: true

module Quartermaster
  # The local copy of each automation, the source of truth push sends from:
  # `automations/<slug>.yml` (the routine's settings, `v:` first) and
  # `automations/<slug>.prompt.md` (the prompt, nothing else). A write merges
  # onto the stored keys, so keys qm doesn't know survive, keeps each replaced
  # file as `<file>.bak` and replaces files through AtomicFile.
  #
  # `from_routine` turns a claude.ai routine as the routines API returns it
  # into a record + prompt; request bodies are RoutinesClient's to build.
  class AutomationStore
    VERSION = 1
    FIELDS = %w[routine runner name cron when flow repos cwd model sources connectors allowed_tools permission_mode
                environment_id enabled timeout_minutes notify remote_updated_at].freeze
    SLUG = /\A[a-z0-9][a-z0-9-]*\z/
    REPO = %r{\A[\w.-]+/[\w.-]+\z}
    LOCAL_DEFAULTS = { "flow" => "chat", "timeout_minutes" => 30, "notify" => "attention" }.freeze
    NOTIFY = %w[attention quiet].freeze

    Entry = Data.define(:slug, :record, :prompt)

    attr_reader :dir

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
      self.class.validate_local(merged) if merged["runner"] == "local"
      FileUtils.mkdir_p(@dir)
      replace(yml_path(slug), Psych.dump(ordered(merged)))
      replace(prompt_path(slug), prompt.to_s)
      Entry.new(slug: slug, record: merged, prompt: prompt.to_s)
    end

    # Removes the two files and the run log; the `.bak`s stay as the last copy.
    def delete_local(slug)
      FileUtils.rm_f([yml_path(slug), prompt_path(slug), RunLog.new(slug, dir: @dir).path])
    end

    # A local automation's record with the defaults of the fields it leaves unset.
    def self.local_settings(record) = LOCAL_DEFAULTS.merge(record.compact)

    # Raises ArgumentError naming every field a local automation can't run with.
    def self.validate_local(record)
      settings = local_settings(record)
      problems = []
      problems << "permission_mode bypassPermissions is refused for local automations" if settings["permission_mode"] == "bypassPermissions"
      problems << "notify must be attention or quiet, got #{settings['notify'].inspect}" unless NOTIFY.include?(settings["notify"])
      problems << "flow must be a flow name, got #{settings['flow'].inspect}" unless settings["flow"].is_a?(String) && !settings["flow"].empty?
      timeout = settings["timeout_minutes"]
      problems << "timeout_minutes must be a positive whole number, got #{timeout.inspect}" unless timeout.is_a?(Integer) && timeout.positive?
      tools = settings["allowed_tools"]
      problems << "allowed_tools must be a list of tool names" unless tools.nil? || (tools.is_a?(Array) && tools.all?(String))
      repos = settings["repos"]
      problems << "repos must be a list of owner/name strings" unless repos.nil? || (repos.is_a?(Array) && repos.all? { |r| r.is_a?(String) && r.match?(REPO) })
      raise ArgumentError, problems.join("; ") unless problems.empty?
    end

    def yml_path(slug) = File.join(@dir, "#{checked(slug)}.yml")

    def prompt_path(slug) = File.join(@dir, "#{checked(slug)}.prompt.md")

    # A routine from the API as `[record, prompt]`, read through
    # RoutinesClient.fields.
    def self.from_routine(routine)
      fields = RoutinesClient.fields(routine)
      record = { "routine" => fields["id"], "runner" => "cloud" }
               .merge(fields.slice(*%w[name cron model sources connectors allowed_tools environment_id enabled]))
               .merge("remote_updated_at" => fields["updated_at"])
      [record, fields["prompt"].to_s]
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
