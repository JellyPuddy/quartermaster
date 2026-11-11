# frozen_string_literal: true

module Quartermaster
  # What config.yml says, read through ConfigReader: each project's root and
  # settings (ProjectSettings), the default project, the IDE, the loose-chat
  # starters, the price overrides and the phone page's URL. `current` reads
  # the file only when its stat (mtime, size, inode) changed and parses it
  # once per change of its text — hooks, every GUI state build and each
  # item's dev-server check ask it — and an unreadable or malformed file
  # reads as an empty config, never an error.
  class ProjectConfig
    Starter = Struct.new(:key, :label, :prompt, keyword_init: true) do
      def to_h = { "key" => key, "label" => label }
    end

    def self.current
      stat = file_stat
      cached = @cached
      return cached.last if stat && cached && cached[1] == stat

      text = begin
        File.read(CONFIG_FILE)
      rescue SystemCallError
        stat = nil # unreadable: ask again next time, a chmod leaves the stat as it was
        ""
      end
      return (@cached = [text, stat, cached.last]).last if cached && cached.first == text

      new(parse(text)).tap { |config| @cached = [text, stat, config] }
    end

    def self.file_stat
      stat = File.stat(CONFIG_FILE)
      [stat.mtime, stat.size, stat.ino]
    rescue SystemCallError
      nil
    end

    def self.parse(text)
      YAML.safe_load(text)
    rescue StandardError
      nil
    end

    # model → {field → number} from `prices:`, only the numeric fields of
    # models given as a mapping (PriceTable merges them over its defaults).
    attr_reader :prices

    # The published phone page's claude.ai URL, nil while unset.
    attr_reader :overview_artifact

    # Where RoutinesClient gets a claude.ai login (`claude_code`); nil while
    # automations are off.
    attr_reader :automations_token_source

    def initialize(data)
      config = ConfigReader.new(data)
      @projects = config.section("projects").entries.to_h { |name, project| [name, ProjectSettings.new(name, project)] }
                        .select { |_, s| s.root }
      @default_project = config["default_project"].to_s
      @starters = parse_starters(config.section("loose_starters"))
      @ide = Ide.parse(config["ide_command"], config["ide_label"])
      @prices = parse_prices(config.section("prices"))
      @overview_artifact = string(config["overview_artifact"])
      automations = config.section("automations")
      @automations_token_source = string(automations["token_source"])
      numbers = %w[max_running hold_five_hour hold_seven_day].to_h do |name|
        value = automations["local_#{name}"]
        [name.to_sym, value.is_a?(Numeric) ? value : ConfigSchema::BY_PATH.fetch("automations.local_#{name}").default]
      end
      @local_automations = LocalAutomations.new(paused: automations["local_paused"] == true, **numbers)
    end

    # The local automations' tick settings, unset ones at their defaults.
    LocalAutomations = Struct.new(:paused, :max_running, :hold_five_hour, :hold_seven_day, keyword_init: true)

    def local_automations = @local_automations

    # The IDE a project's "Open in …" launches: its own ide_command, else the
    # global one; nil (the feature off) when neither is set.
    def ide(project = nil) = @projects[project.to_s]&.ide || @ide

    def ide!(project = nil)
      ide(project) || raise(ArgumentError, "no IDE configured: run `#{Ide::CONFIG_COMMAND}`")
    end

    # name → repo root, the map ProjectMap matches cwds against.
    def roots = @projects.transform_values(&:root)

    # An unconfigured project gets settings with every feature off.
    def settings(project) = @projects[project] || ProjectSettings.new(project.to_s, nil)

    # Where an issue number with no project goes: `default_project:` when it
    # names a configured project, else the first one.
    def default_project = @projects.key?(@default_project) ? @default_project : @projects.keys.first

    # One dev server serves one checkout at a time across projects: its
    # status is read through the first project that configures one.
    def dev_server = @projects.each_value.lazy.filter_map(&:dev_server).first

    def dev_server_commands = @projects.values.filter_map { |s| s.dev_server&.command }.uniq

    # key → Starter, in config order.
    def loose_starters = @starters

    private

    def parse_starters(starters)
      starters.entries.each_with_object({}) do |(key, starter), out|
        next unless (prompt = string(starter["prompt"]))

        label = starter["label"].is_a?(String) && !starter["label"].empty? ? starter["label"] : key
        out[key] = Starter.new(key: key, label: label, prompt: prompt)
      end
    end

    def parse_prices(prices)
      prices.entries.each_with_object({}) do |(model, fields), out|
        next unless fields.mapping?

        out[model] = PriceTable::FIELDS.to_h { |f| [f, fields[f]] }.select { |_, v| v.is_a?(Numeric) }
      end
    end

    def string(value) = value.is_a?(String) && !value.strip.empty? ? value.strip : nil
  end
end
