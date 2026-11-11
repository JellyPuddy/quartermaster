# frozen_string_literal: true

module Quartermaster
  # One project's entry under config.yml's `projects:` — either a plain repo
  # root path, or a mapping with `root:` and the optional feature keys
  # (docs/overview.md lists them), read through ConfigReader. A key that is
  # absent or malformed leaves its feature off; nothing here raises on a bad
  # config.
  class ProjectSettings
    # The dev server qm switches between checkouts: `command switch PATH MODE`,
    # `command stop`, `command status` (exit 0 while it serves). status_url
    # (JSON {mode, root, switching}) and state_file ("<mode> <root>") are
    # optional ways to see what it serves.
    DevServer = Struct.new(:command, :modes, :default_mode, :status_url, :state_file, keyword_init: true) do
      def check_mode!(mode)
        return mode if modes.include?(mode)

        raise ArgumentError, "#{command} mode must be one of: #{modes.join(", ")}"
      end
    end

    # Benchmark runs (docs/areas/benchmarks.md): database is the Postgres
    # template a run reads (or clones), skill the folder whose SKILL.md and
    # bin/example_bench.rb the planner follows, notes extra prompt lines.
    Benchmark = Struct.new(:database, :skill, :notes, keyword_init: true) do
      def read_only_url = "postgres:///#{database}?options=-c%20default_transaction_read_only%3Don"
    end

    # Which of the project's GitHub issues start as epics (docs/areas/issues.md):
    # issue_types the issue type names that make an issue an epic.
    Epics = Struct.new(:issue_types, keyword_init: true) do
      def epic_type?(name) = !name.to_s.empty? && issue_types.any? { |type| type.casecmp?(name.to_s) }
    end

    # The links an item started from one of the project's GitHub issues gets
    # (IssueLinks): tracker_url the Tracker link's template, notion_author
    # the login whose comment carries the Notion link, notion_label that
    # link's label, headings [[heading word, label]] for links from the
    # issue body's sections.
    IssueLinkSettings = Struct.new(:tracker_url, :notion_author, :notion_label, :headings, keyword_init: true)

    DEFAULT_REVIEW_SKILL = "/code-review"
    DEFAULT_NOTION_LABEL = "Notion"

    # ide is this project's own override of the global IDE (ProjectConfig#ide).
    attr_reader :name, :root, :dev_server, :test_db, :benchmark, :ide, :epics, :issue_links

    # value: the project's raw entry, or its ConfigReader.
    def initialize(name, value)
      @name = name
      @config = value.is_a?(ConfigReader) ? value : ConfigReader.new(value, "projects.*", "projects.#{name}")
      @root = expand(@config["root"])
      @dev_server = parse_dev_server(@config.section("dev_server"))
      @ide = Ide.parse(@config["ide_command"], @config["ide_label"])
      @test_db = string(@config["test_db"])
      @benchmark = parse_benchmark(@config.section("benchmark"))
      epics = @config.section("epics")
      @epics = Epics.new(issue_types: Array(epics["issue_types"]).map { |type| type.to_s.strip }.reject(&:empty?))
      @issue_links = parse_issue_links(@config.section("issue_links"), epics)
    end

    # A feature key's raw value, for features that read their own keys; the
    # key must be one ConfigSchema lists under a project.
    def [](key) = @config[key]

    # The command that sets one of this project's keys, for "not configured"
    # messages: `qm config set projects.App.test_db <command>`.
    def config_command(key, value) = "qm config set #{@config.path}.#{key} #{value}"

    def dev_server!
      dev_server || raise(ArgumentError, "#{name} has no dev server: run `#{config_command("dev_server.command", "<command>")}`")
    end

    def review_skill = string(@config["review_skill"]) || DEFAULT_REVIEW_SKILL

    # PRs here ship by release, so sessions learn about `qm pr-requires`.
    def pr_prerequisites? = @config["pr_prerequisites"] == true

    private

    def parse_dev_server(server)
      return nil unless (command = string(server["command"]))

      modes = Array(server["modes"]).map(&:to_s).reject(&:empty?)
      default = string(server["default_mode"])
      modes = [default || "default"] if modes.empty?
      DevServer.new(command: command, modes: modes, default_mode: modes.include?(default) ? default : modes.first,
                    status_url: string(server["status_url"]), state_file: expand(server["state_file"]))
    end

    # Both database and skill, or no benchmarks: a run needs the one to
    # measure on and the other to plan by.
    def parse_benchmark(bench)
      return nil unless (database = string(bench["database"])) && (skill = expand(bench["skill"]))
      return nil unless database.match?(/\A\w+\z/)

      Benchmark.new(database: database, skill: skill, notes: string(bench["notes"]))
    end

    # Each link key falls back to its old place under epics: (where qm read
    # it before every issue item got links), so a value set there still works.
    def parse_issue_links(links, epics)
      read = ->(key) { string(links[key]) || string(epics[key]) }
      headings = Array(links["heading_links"]).filter_map do |rule|
        heading, label = rule.to_s.split("=", 2).map(&:strip)
        [heading, label.to_s.empty? ? heading : label] unless heading.to_s.empty?
      end
      IssueLinkSettings.new(tracker_url: read["tracker_url"], notion_author: read["notion_author"],
                            notion_label: read["notion_label"] || DEFAULT_NOTION_LABEL, headings: headings)
    end

    def string(value) = value.is_a?(String) && !value.strip.empty? ? value.strip : nil

    def expand(path)
      path = string(path)
      path && File.expand_path(path)
    rescue ArgumentError
      path
    end
  end
end
