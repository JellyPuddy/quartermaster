# frozen_string_literal: true

module Quartermaster
  # config.yml's project side: each project's root and settings
  # (ProjectSettings), the default project, the IDE and the loose-chat starters.
  # `current` parses the file once per change of its text — hooks, every GUI
  # state build and each item's dev-server check ask it — and an unreadable
  # or malformed file reads as no projects, never an error.
  class ProjectConfig
    Starter = Struct.new(:key, :label, :prompt, keyword_init: true) do
      def to_h = { "key" => key, "label" => label }
    end

    def self.current
      text = begin
        File.read(CONFIG_FILE)
      rescue SystemCallError
        ""
      end
      cached = @cached
      return cached.last if cached && cached.first == text

      new(parse(text)).tap { |config| @cached = [text, config] }
    end

    def self.parse(text)
      YAML.safe_load(text)
    rescue StandardError
      nil
    end

    def initialize(data)
      data = {} unless data.is_a?(Hash)
      projects = data["projects"].is_a?(Hash) ? data["projects"] : {}
      @projects = projects.to_h { |name, value| [name.to_s, ProjectSettings.new(name.to_s, value)] }.select { |_, s| s.root }
      @default_project = data["default_project"].to_s
      @starters = parse_starters(data["loose_starters"])
      @ide = Ide.parse(data["ide_command"], data["ide_label"])
    end

    # The IDE a project's "Open in …" launches: its own ide_command, else the
    # global one; nil (the feature off) when neither is set.
    def ide(project = nil) = @projects[project.to_s]&.ide || @ide

    def ide!(project = nil)
      ide(project) || raise(ArgumentError, "no IDE configured: set ide_command (and ide_label) in config.yml")
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

    def parse_starters(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, starter), out|
        next unless starter.is_a?(Hash) && starter["prompt"].is_a?(String) && !starter["prompt"].strip.empty?

        label = starter["label"].is_a?(String) && !starter["label"].empty? ? starter["label"] : key.to_s
        out[key.to_s] = Starter.new(key: key.to_s, label: label, prompt: starter["prompt"].strip)
      end
    end
  end
end
