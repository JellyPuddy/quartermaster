# frozen_string_literal: true

module Quartermaster
  # One project's entry under config.yml's `projects:` — either a plain repo
  # root path, or a mapping with `root:` and the optional feature keys
  # (docs/overview.md lists them). A key that is absent or malformed leaves
  # its feature off; nothing here raises on a bad config.
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

    def initialize(name, value)
      @name = name
      @raw = value.is_a?(Hash) ? value : { "root" => value }
      @root = expand(@raw["root"])
      @dev_server = parse_dev_server(@raw["dev_server"])
      @ide = Ide.parse(@raw["ide_command"], @raw["ide_label"])
      @test_db = string(@raw["test_db"])
      @benchmark = parse_benchmark(@raw["benchmark"])
    end

    # A feature key's raw value, for features that read their own keys.
    def [](key) = @raw[key]

    def dev_server!
      dev_server || raise(ArgumentError, "#{name} has no dev server: set projects.#{name}.dev_server in config.yml")
    end

    def review_skill = string(@raw["review_skill"]) || DEFAULT_REVIEW_SKILL

    # PRs here ship by release, so sessions learn about `qm pr-requires`.
    def pr_prerequisites? = @raw["pr_prerequisites"] == true

    private

    def parse_dev_server(value)
      value = { "command" => value } if value.is_a?(String)
      return nil unless value.is_a?(Hash) && (command = string(value["command"]))

      modes = Array(value["modes"]).map(&:to_s).reject(&:empty?)
      default = string(value["default_mode"])
      modes = [default || "default"] if modes.empty?
      DevServer.new(command: command, modes: modes, default_mode: modes.include?(default) ? default : modes.first,
                    status_url: string(value["status_url"]), state_file: expand(value["state_file"]))
    end

    # Both database and skill, or no benchmarks: a run needs the one to
    # measure on and the other to plan by.
    def parse_benchmark(value)
      return nil unless value.is_a?(Hash) && (database = string(value["database"])) && (skill = expand(value["skill"]))
      return nil unless database.match?(/\A\w+\z/)

      Benchmark.new(database: database, skill: skill, notes: string(value["notes"]))
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
