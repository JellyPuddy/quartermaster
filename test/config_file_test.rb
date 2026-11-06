# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/config_file_test.rb`).
require_relative "test_helper"

class ConfigFileTest < Minitest::Test
  include QmTestHelpers

  # Answers the warnings' folder and PATH checks from fixed lists.
  class Probe
    def initialize(dirs: [], commands: [])
      @dirs = dirs
      @commands = commands
    end

    def dir?(path) = @dirs.include?(path)

    def command?(name) = @commands.include?(name)
  end

  ALL_THERE = Probe.new(dirs: %w[/code/app /code/plain /skills/bench /run], commands: %w[pf app-test-db])

  def file = Quartermaster::CONFIG_FILE

  def load(text, probe: ALL_THERE)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, text)
    Quartermaster::ConfigFile.load(file, probe: probe)
  end

  def issues(text, probe: ALL_THERE) = load(text, probe: probe).issues

  FULL = <<~YAML
    # my own comment
    my_notes:
      keep: [1, 2]
    prices:
      claude-opus-5-5: { output: 30, input: 5 }
    overview_artifact: https://claude.ai/artifact/abc
    projects:
      Plain: /code/plain
      App:
        test_db: app-test-db
        root: /code/app
        dev_server:
          modes: [dev, tunnel]
          command: pf
          default_mode: tunnel
          state_file: /run/current
        review_skill: /review-app
        pr_prerequisites: true
        benchmark: { database: app_bench, skill: /skills/bench, notes: "Line one.\\nLine two.\\n" }
        ide_command: [code, PATH]
    loose_starters:
      backlog:
        label: Sprint backlog
        prompt: Load the open issues. Then give a one-line count of them and
    ide_label: MyIDE
    ide_command: [zsh, -ic, "myide PATH"]
    default_project: App
  YAML

  def test_writing_lays_the_file_out_in_qms_order_with_the_header
    config = load(FULL)
    assert_empty config.issues
    config.write!

    assert_equal <<~YAML, File.read(file)
      # Edited by qm (Settings view / qm config); key reference: docs/overview.md
      projects:
        Plain: /code/plain
        App:
          root: /code/app
          dev_server:
            command: pf
            modes: [dev, tunnel]
            default_mode: tunnel
            state_file: /run/current
          test_db: app-test-db
          review_skill: /review-app
          pr_prerequisites: true
          benchmark:
            database: app_bench
            skill: /skills/bench
            notes: |
              Line one.
              Line two.
          ide_command: [code, PATH]
      default_project: App
      ide_command: [zsh, -ic, myide PATH]
      ide_label: MyIDE
      loose_starters:
        backlog:
          label: Sprint backlog
          prompt: Load the open issues. Then give a one-line count of them and
      overview_artifact: https://claude.ai/artifact/abc
      prices:
        claude-opus-5-5:
          input: 5
          output: 30
      my_notes:
        keep: [1, 2]
    YAML
  end

  def test_a_round_trip_keeps_every_value_and_writes_the_same_text_again
    config = load(FULL)
    config.write!
    written = File.read(file)

    assert_equal YAML.safe_load(FULL), YAML.safe_load(written)
    again = Quartermaster::ConfigFile.load(file, probe: ALL_THERE)
    again.write!
    assert_equal written, File.read(file)
  end

  def test_unknown_top_level_keys_are_kept_but_unknown_keys_under_schema_mappings_are_errors
    config = load(<<~YAML)
      projects:
        App: { root: /code/app, typo: 1, dev_server: { command: pf, colour: red } }
      loose_starters: { a: { prompt: Go, emoji: x } }
      prices: { claude-x: { input: 1, discount: 2 } }
      someday: { anything: [goes] }
    YAML

    assert_equal [["error", "projects.App.typo"], ["error", "projects.App.dev_server.colour"],
                  ["error", "loose_starters.a.emoji"], ["error", "prices.claude-x.discount"]],
                 config.issues.map { |i| [i[:level], i[:path]] }
    config.unset("projects.App.typo").unset("projects.App.dev_server").unset("loose_starters.a.emoji")
          .unset("prices.claude-x.discount")
    config.write!
    assert_equal({ "anything" => ["goes"] }, YAML.safe_load(File.read(file))["someday"])
  end

  def test_every_error
    {
      "projects: [::" => ["", /not valid YAML/],
      "- a list" => ["", /not a mapping/],
      "projects: { App: { root: 5 } }" => ["projects.App.root", /must be a path/],
      "projects: { App: { dev_server: pf } }" => ["projects.App.root", /needs a root/],
      "projects: { App: [a] }" => ["projects.App", /must be a mapping or a root/],
      "projects: { App: { root: /code/app, pr_prerequisites: 'yes' } }" => ["projects.App.pr_prerequisites", /true or false/],
      "projects: { App: { root: /code/app, dev_server: { command: pf, modes: { a: 1 } } } }" =>
        ["projects.App.dev_server.modes", /list of names/],
      "projects: { App: { root: /code/app, dev_server: { modes: [dev] } } }" =>
        ["projects.App.dev_server.command", /needs a command/],
      "projects: { App: { root: /code/app, dev_server: { command: pf, modes: [dev], default_mode: prod } } }" =>
        ["projects.App.dev_server.default_mode", /one of the modes: dev/],
      "projects: { App: { root: /code/app, benchmark: { database: app_bench } } }" =>
        ["projects.App.benchmark", /both database and skill/],
      "projects: { App: { root: /code/app, benchmark: { database: app-bench, skill: /skills/bench } } }" =>
        ["projects.App.benchmark.database", /letters, digits and _/],
      "projects: { App: { root: /code/app, ide_command: [code, .] } }" => ["projects.App.ide_command", /needs a PATH/],
      "projects: {}\nide_command: code PATH" => ["ide_command", /command list/],
      "projects: {}\nide_command: ['', PATH]" => ["ide_command", /start with a program/],
      "projects: { App: /code/app }\ndefault_project: Web" => ["default_project", /must name a project \(App\)/],
      "projects: {}\nloose_starters: { a: { label: A } }" => ["loose_starters.a.prompt", /needs a prompt/],
      "projects: {}\nprices: { claude-x: { input: cheap } }" => ["prices.claude-x.input", /must be a number/],
      "projects: {}\noverview_artifact: [a]" => ["overview_artifact", /must be text/]
    }.each do |yaml, (path, message)|
      found = issues(yaml)
      assert_equal [["error", path]], found.map { |i| [i[:level], i[:path]] }, yaml
      assert_match message, found.first[:message], yaml
    end
  end

  def test_every_warning_and_warnings_never_block_a_write
    config = load(<<~YAML, probe: Probe.new)
      projects:
        App:
          root: /code/app
          dev_server: { command: pf --quiet, state_file: /run/current }
          test_db: app-test-db
          benchmark: { database: app_bench, skill: /skills/bench }
          ide_label: Code
      ide_label: MyIDE
    YAML

    assert_equal [["warning", "projects.App.root", "folder /code/app doesn't exist"],
                  ["warning", "projects.App.dev_server.command", "pf is not on PATH"],
                  ["warning", "projects.App.dev_server.state_file", "folder /run doesn't exist"],
                  ["warning", "projects.App.test_db", "app-test-db is not on PATH"],
                  ["warning", "projects.App.benchmark.skill", "folder /skills/bench doesn't exist"],
                  ["warning", "projects.App.ide_label", "ide_label does nothing without ide_command"],
                  ["warning", "ide_label", "ide_label does nothing without ide_command"]],
                 config.issues.map { |i| [i[:level], i[:path], i[:message]] }
    config.write!
    assert_equal "Code", YAML.safe_load(File.read(file)).dig("projects", "App", "ide_label")
  end

  def test_errors_refuse_the_write_and_leave_the_file_alone
    config = load("projects: { App: { dev_server: pf } }\n")

    error = assert_raises(Quartermaster::ConfigFile::Invalid) { config.write! }
    assert_equal ["projects.App.root"], error.issues.map { |i| i[:path] }
    assert_equal "projects: { App: { dev_server: pf } }\n", File.read(file)
    refute File.exist?("#{file}.bak")
  end

  def test_a_file_changed_since_loading_is_refused_as_stale
    config = load("projects: {}\n")
    File.write(file, "projects: { Other: /code/plain }\n")
    config.set("projects.App", "/code/app")

    assert_raises(Quartermaster::ConfigFile::Stale) { config.write! }
    assert_equal "projects: { Other: /code/plain }\n", File.read(file)

    fresh = Quartermaster::ConfigFile.load(file, probe: ALL_THERE)
    assert_raises(Quartermaster::ConfigFile::Stale) { fresh.write!(digest: config.digest) }
    fresh.write!(digest: Quartermaster::ConfigFile.digest("projects: { Other: /code/plain }\n"))
  end

  def test_a_write_keeps_the_previous_file_as_bak_and_replaces_by_rename
    config = load("# hand-written\nprojects: { App: /code/app }\n")
    before = File.stat(file).ino
    config.set("projects.App.test_db", "app-test-db")
    new_digest = config.write!

    assert_equal "# hand-written\nprojects: { App: /code/app }\n", File.read("#{file}.bak")
    refute_equal before, File.stat(file).ino
    assert_equal [file, "#{file}.bak"].sort, Dir[File.join(File.dirname(file), "config.yml*")].sort
    assert_equal Quartermaster::ConfigFile.digest(File.read(file)), new_digest
    assert_equal new_digest, config.digest
  end

  def test_a_missing_file_is_written_fresh
    FileUtils.rm_f(file)
    config = Quartermaster::ConfigFile.load(file, probe: ALL_THERE)
    config.set("projects.App.root", "/code/app")
    config.write!

    assert_equal "# Edited by qm (Settings view / qm config); key reference: docs/overview.md\n" \
                 "projects:\n  App: /code/app\n", File.read(file)
    refute File.exist?("#{file}.bak")
  end

  def test_set_and_get_open_shorthands_and_unset_removes
    config = load("projects: { App: /code/app }\n")
    assert_equal "/code/app", config.get("projects.App.root")

    config.set("projects.App.dev_server", "pf")
    assert_equal "pf", config.get("projects.App.dev_server.command")
    config.set("projects.App.dev_server.modes", Quartermaster::ConfigFile.parse_value("[dev, ngrok]"))
    assert_equal({ "root" => "/code/app", "dev_server" => { "command" => "pf", "modes" => %w[dev ngrok] } },
                 config.get("projects.App"))

    config.unset("projects.App.dev_server").unset("projects.Nope.test_db")
    assert_equal({ "root" => "/code/app" }, config.get("projects.App"))
    assert_nil config.get("projects.Nope.root")
  end

  def test_set_refuses_paths_the_schema_does_not_list
    config = load("projects: {}\n")

    %w[projects.App.typo colour prices.claude-x.discount projects.App.dev_server.command.x].each do |path|
      assert_raises(ArgumentError, path) { config.set(path, "x") }
    end
  end

  def test_values_parse_as_yaml
    parse = Quartermaster::ConfigFile.method(:parse_value)

    assert_equal [%w[dev ngrok], true, 4, 0.25, "~/code/app", "pf", nil, "[unclosed"],
                 [parse["[dev, ngrok]"], parse["true"], parse["4"], parse["0.25"], parse["~/code/app"], parse["pf"],
                  parse["null"], parse["[unclosed"]]
  end

  def test_the_earlier_seeds_empty_projects_key_reads_as_no_projects
    config = load("# qm configuration\nprojects:\n#   my-app: ~/code/my-app\n")
    assert_empty config.issues

    config.set("ide_command", %w[code PATH])
    config.write!
    assert_equal "# Edited by qm (Settings view / qm config); key reference: docs/overview.md\n" \
                 "projects: {}\nide_command: [code, PATH]\n", File.read(file)
  end

  def test_unset_values_and_emptied_mappings_are_dropped_on_write
    config = load("projects: { App: /code/app }\n")
    config.replace({ "projects" => { "App" => { "root" => "/code/app", "test_db" => "", "review_skill" => nil,
                                                "benchmark" => { "notes" => " " } } },
                     "ide_label" => "", "loose_starters" => {} })
    config.write!

    assert_equal "# Edited by qm (Settings view / qm config); key reference: docs/overview.md\n" \
                 "projects:\n  App: /code/app\n", File.read(file)
  end

  def test_the_schema_finds_keys_and_containers_by_concrete_path
    schema = Quartermaster::ConfigSchema
    mode = schema.lookup("projects.App.dev_server.default_mode")
    price = schema.lookup("prices.claude-x.output")

    assert_equal ["enum", "projects.*.dev_server.modes"], [mode.type, mode.options_from]
    assert_equal %w[number prices], [price.type, price.section]
    assert_equal "ide_command", schema.lookup("projects.App.ide_command").inherits
    assert_equal "/code-review", schema.lookup("projects.App.review_skill").default
    assert_nil schema.lookup("projects.App.dev_server")
    assert_equal "projects.*.dev_server", schema.container("projects.App.dev_server")
    assert_nil schema.lookup("projects..root")
    refute schema.known?("projects.App.typo")
    assert_equal %w[string path text bool number string_list argv enum], schema.types
    assert_equal schema.keys.size, schema.keys.map(&:path).uniq.size
    schema.keys.each { |k| assert_includes schema.types, k.type, k.path }
  end

  def test_features_say_on_off_inherit_and_mark_issues
    data = YAML.safe_load(<<~YAML)
      projects:
        App:
          root: /code/app
          dev_server: { command: pf, modes: [dev, ngrok, tunnel, prod] }
          test_db: app-test-db
          pr_prerequisites: true
          benchmark: { database: app_bench, skill: /skills/bench }
          ide_command: [code, PATH]
        Plain: /code/plain
      ide_command: [zsh, -ic, "myide PATH"]
      ide_label: MyIDE
    YAML
    issues = [{ level: "warning", path: "projects.App.test_db", message: "x" },
              { level: "error", path: "projects.Plain.benchmark", message: "y" }]
    grid = Quartermaster::ConfigSchema.features(data, issues).transform_values do |cells|
      cells.transform_values { |c| [c["state"], c["value"]] }
    end

    assert_equal({ "App" => { "dev_server" => ["on", "pf · 4 modes"], "test_db" => %w[warning app-test-db],
                              "review" => %w[inherit default], "ships_by_release" => %w[on yes],
                              "benchmarks" => %w[on app_bench], "ide" => %w[on IDE] },
                   "Plain" => { "dev_server" => ["off", nil], "test_db" => ["off", nil], "review" => %w[inherit default],
                                "ships_by_release" => ["off", nil], "benchmarks" => ["error", nil],
                                "ide" => %w[inherit global] } }, grid)
    assert_equal "MyIDE: zsh -ic myide PATH", Quartermaster::ConfigSchema.features(data)["Plain"]["ide"]["title"]
  end
end

class ConfigDocsTest < Minitest::Test
  OVERVIEW = File.expand_path("../docs/overview.md", __dir__)

  # Every dotted path the section spells out in backticks: `{a, b}` expands
  # to each alternative, and a `<name>` placeholder stands for a map key.
  def documented_paths
    section = File.read(OVERVIEW)[/^## config\.yml$(.*?)^## /m, 1]
    section.scan(/`([^`]+)`/).flatten.flat_map { |span| expand(span.gsub(/<\w+>/, "*")) }
  end

  def expand(span)
    return [span] unless (group = span.match(/\{([^{}]*)\}/))

    group[1].split(",").flat_map { |alt| expand(group.pre_match + alt.strip + group.post_match) }
  end

  def test_overview_names_every_config_key_path
    missing = Quartermaster::ConfigSchema.keys.map(&:path) - documented_paths
    assert_empty missing, "docs/overview.md §config.yml must name these keys"
  end
end
