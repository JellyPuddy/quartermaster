# frozen_string_literal: true

module Quartermaster
  # Every config.yml key, listed once: its dotted path (`*` for a map key: a
  # project name, a starter key, a model), type, help text, the Settings
  # section it sits in, whether it is rarely changed (collapsed), and what an
  # unset value falls back to (inherits: another key's path; default: a
  # value). Containers are the mappings keys live in; a container's shorthand
  # is the one key a plain string stands for (a project given as a path is
  # its root). ConfigFile validates and writes against this; the GUI draws
  # its form from #payload.
  module ConfigSchema
    Key = Struct.new(:path, :type, :help, :section, :collapsed, :inherits, :default, :options_from,
                     keyword_init: true) do
      def to_h = super.compact
    end

    # string/path/text: a String (path monospace, text multi-line); bool;
    # number; string_list: a list of names; argv: a command array holding
    # PATH; enum: one of the values options_from names (a sibling list, or
    # the keys of a map).
    TYPES = %w[string path text bool number string_list argv enum].freeze

    # kind :map (any key → child "<path>.*") or :object (only listed keys).
    CONTAINERS = {
      "projects" => { kind: :map },
      "projects.*" => { kind: :object, shorthand: "root" },
      "projects.*.dev_server" => { kind: :object, shorthand: "command" },
      "projects.*.benchmark" => { kind: :object },
      "loose_starters" => { kind: :map },
      "loose_starters.*" => { kind: :object },
      "prices" => { kind: :map },
      "prices.*" => { kind: :object }
    }.freeze

    # Top-level keys in the order a written file lists them.
    TOP_LEVEL = %w[projects default_project ide_command ide_label loose_starters overview_artifact prices].freeze

    def self.key(path, type, help, section, collapsed: false, **rest)
      Key.new(path: path, type: type, help: help, section: section, collapsed: collapsed, **rest).freeze
    end

    PRICE_HELP = {
      "input" => "USD per million input tokens",
      "cache_write_5m" => "USD per million tokens written to the 5-minute cache",
      "cache_write_1h" => "USD per million tokens written to the 1-hour cache",
      "cache_read" => "USD per million cache-read tokens",
      "output" => "USD per million output tokens"
    }.freeze

    KEYS = [
      key("projects.*.root", "path", "The project's main repo root; sessions in it or its worktrees get this project.",
          "basics"),
      key("projects.*.dev_server.command", "string",
          "The dev server command: qm runs `<command> switch PATH MODE`, `<command> stop`, `<command> status`.",
          "dev_server"),
      key("projects.*.dev_server.modes", "string_list", "The modes `switch` accepts (default: one mode, `default`).",
          "dev_server"),
      key("projects.*.dev_server.default_mode", "enum", "The mode Work on this starts in (default: the first mode).",
          "dev_server", options_from: "projects.*.dev_server.modes"),
      key("projects.*.dev_server.status_url", "string", "Answers JSON {mode, root, switching} while it serves.",
          "dev_server", collapsed: true),
      key("projects.*.dev_server.state_file", "path", "Holds `<mode> <root>` of what it serves.", "dev_server",
          collapsed: true),
      key("projects.*.test_db", "string",
          "Test-DB command: `<test_db> prepare` in each new worktree, `<test_db> drop PATH` on cleanup.", "worktrees"),
      key("projects.*.review_skill", "string", "The PRs view's Review skill.", "pull_requests",
          default: ProjectSettings::DEFAULT_REVIEW_SKILL),
      key("projects.*.pr_prerequisites", "bool", "PRs ship by release: sessions are told about `qm pr-requires`.",
          "pull_requests"),
      key("projects.*.benchmark.database", "string",
          "The Postgres database benchmark runs read (or clone as a template); letters, digits and _ only.",
          "benchmarks", collapsed: true),
      key("projects.*.benchmark.skill", "path", "The benchmark skill's folder (SKILL.md, bin/example_bench.rb).",
          "benchmarks", collapsed: true),
      key("projects.*.benchmark.notes", "text", "Extra lines for the benchmark planner's prompt.", "benchmarks",
          collapsed: true),
      key("projects.*.ide_command", "argv", "This project's own IDE command, overriding the global one.", "ide",
          collapsed: true, inherits: "ide_command"),
      key("projects.*.ide_label", "string", "This project's IDE name, overriding the global one.", "ide",
          collapsed: true, inherits: "ide_label"),
      key("default_project", "enum", "Where a bare issue number starts (default: the first project).", "general",
          options_from: "projects"),
      key("ide_command", "argv",
          "Open in …: an argv with PATH, the checkout (shell-escaped inside a longer element, e.g. a `sh -c` script).",
          "ide"),
      key("ide_label", "string", "The IDE buttons' name.", "ide", default: Ide::DEFAULT_LABEL),
      key("loose_starters.*.label", "string", "The preset's name in the loose-chat dialog (default: its key).",
          "starters", collapsed: true),
      key("loose_starters.*.prompt", "text",
          "The opening prompt; it ends mid-sentence (\"… Then give a one-line count of them and\").",
          "starters", collapsed: true),
      key("overview_artifact", "string", "The published phone page's URL.", "phone", collapsed: true),
      *PriceTable::FIELDS.map { |f| key("prices.*.#{f}", "number", PRICE_HELP.fetch(f), "prices", collapsed: true) }
    ].freeze

    BY_PATH = KEYS.to_h { |k| [k.path, k] }.freeze

    module_function

    def keys = KEYS

    def types = TYPES

    def segments(path) = path.to_s.split(".", -1)

    def match?(pattern, path)
      want = segments(pattern)
      have = segments(path)
      want.size == have.size && want.zip(have).all? { |w, h| w == "*" ? !h.empty? : w == h }
    end

    # The Key a concrete dotted path names ("projects.App.test_db"), or nil.
    def lookup(path) = KEYS.find { |k| match?(k.path, path) }

    # The container pattern a concrete path names ("projects.App" →
    # "projects.*"), or nil.
    def container(path) = CONTAINERS.keys.find { |pattern| match?(pattern, path) }

    def known?(path) = !lookup(path).nil? || !container(path).nil?

    # The pattern of a child key under a container pattern ("" the top
    # level), or nil when the schema doesn't list it.
    def child(pattern, key)
      candidate = if pattern.empty? then key.to_s
                  elsif CONTAINERS.dig(pattern, :kind) == :map then "#{pattern}.*"
                  else "#{pattern}.#{key}"
                  end
      candidate if BY_PATH.key?(candidate) || CONTAINERS.key?(candidate)
    end

    # The order keys under a container pattern are written in.
    def order(pattern)
      return TOP_LEVEL if pattern.empty?

      prefix = "#{pattern}."
      KEYS.filter_map { |k| k.path.delete_prefix(prefix).split(".").first if k.path.start_with?(prefix) }.uniq - ["*"]
    end

    # The projects × features grid's columns: each feature's id and the key
    # paths (under projects.<name>) whose issues mark its cell.
    FEATURES = {
      "dev_server" => %w[dev_server], "test_db" => %w[test_db], "review" => %w[review_skill],
      "ships_by_release" => %w[pr_prerequisites], "benchmarks" => %w[benchmark], "ide" => %w[ide_command ide_label]
    }.freeze

    # name → feature → {state, value, title} for every project in a config
    # mapping, as qm would read it: state on / off / inherit (unset, a
    # fallback applies) / error / warning (an issue under the feature's keys;
    # value and title still say what is set).
    def features(data, issues = [])
      data = {} unless data.is_a?(Hash)
      projects = data["projects"].is_a?(Hash) ? data["projects"] : {}
      global_ide = Ide.parse(data["ide_command"], data["ide_label"])
      projects.to_h do |name, value|
        [name.to_s, project_features(name.to_s, value, global_ide, issues)]
      end
    end

    def project_features(name, value, global_ide, issues)
      settings = ProjectSettings.new(name, value)
      cells = feature_cells(settings, value.is_a?(Hash) ? value : {}, global_ide)
      cells.to_h do |feature, cell|
        found = issues.select { |i| FEATURES[feature].any? { |k| under?(i[:path] || i["path"], "projects.#{name}.#{k}") } }
        level = found.map { |i| (i[:level] || i["level"]).to_s }
        cell = cell.merge(state: level.include?("error") ? "error" : "warning") unless level.empty?
        [feature, cell.transform_keys(&:to_s)]
      end
    end

    def feature_cells(settings, raw, global_ide)
      server = settings.dev_server
      bench = settings.benchmark
      {
        "dev_server" => cell(server && "#{server.command} · #{server.modes.size} mode#{"s" unless server.modes.size == 1}",
                             server && "#{server.command}: #{server.modes.join(", ")} (default #{server.default_mode})"),
        "test_db" => cell(settings.test_db),
        "review" => if raw["review_skill"].is_a?(String) && !raw["review_skill"].strip.empty?
                      cell(settings.review_skill)
                    else
                      { state: "inherit", value: "default", title: settings.review_skill }
                    end,
        "ships_by_release" => cell(settings.pr_prerequisites? ? "yes" : nil, "PRs ship by release"),
        "benchmarks" => cell(bench&.database, bench && "#{bench.database} · #{bench.skill}"),
        "ide" => if settings.ide
                   cell(settings.ide.label, settings.ide.command.join(" "))
                 elsif global_ide
                   { state: "inherit", value: "global", title: "#{global_ide.label}: #{global_ide.command.join(" ")}" }
                 else
                   cell(nil)
                 end
      }
    end

    def cell(value, title = value)
      value ? { state: "on", value: value, title: title } : { state: "off", value: nil, title: nil }
    end

    def under?(path, prefix) = path.to_s == prefix || path.to_s.start_with?("#{prefix}.")

    def payload
      { "types" => TYPES, "keys" => KEYS.map { |k| k.to_h.transform_keys(&:to_s) },
        "containers" => CONTAINERS.to_h { |path, c| [path, c.transform_keys(&:to_s).transform_values(&:to_s)] },
        "topLevel" => TOP_LEVEL, "features" => FEATURES.keys }
    end
  end
end
