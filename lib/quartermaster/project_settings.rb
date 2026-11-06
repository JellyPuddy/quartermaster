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

    DEFAULT_REVIEW_SKILL = "/code-review"

    # ide is this project's own override of the global IDE (ProjectConfig#ide).
    attr_reader :name, :root, :dev_server, :test_db, :benchmark, :ide

    # value: the project's raw entry, or its ConfigReader.
    def initialize(name, value)
      @name = name
      @config = value.is_a?(ConfigReader) ? value : ConfigReader.new(value, "projects.*", "projects.#{name}")
      @root = expand(@config["root"])
      @dev_server = parse_dev_server(@config.section("dev_server"))
      @ide = Ide.parse(@config["ide_command"], @config["ide_label"])
      @test_db = string(@config["test_db"])
      @benchmark = parse_benchmark(@config.section("benchmark"))
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

    def string(value) = value.is_a?(String) && !value.strip.empty? ? value.strip : nil

    def expand(path)
      path = string(path)
      path && File.expand_path(path)
    rescue ArgumentError
      path
    end
  end
end
