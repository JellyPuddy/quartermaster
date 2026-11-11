# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/project_config_test.rb`).
require_relative "test_helper"

class ProjectConfigTest < Minitest::Test
  include QmTestHelpers

  def config(yaml) = Quartermaster::ProjectConfig.new(YAML.safe_load(yaml))

  def test_a_plain_path_and_a_mapping_both_name_a_root
    c = config(<<~YAML)
      projects:
        Plain: /code/plain
        Mapped:
          root: ~/code/mapped
        Rootless:
          dev_server: pf
    YAML

    assert_equal({ "Plain" => "/code/plain", "Mapped" => File.expand_path("~/code/mapped") }, c.roots)
    assert_nil c.settings("Plain").dev_server
    assert_nil c.settings("Plain").test_db
    assert_equal "/code-review", c.settings("Plain").review_skill
    refute c.settings("Plain").pr_prerequisites?
  end

  def test_feature_keys_read_with_their_defaults
    c = config(<<~YAML)
      projects:
        App:
          root: /code/app
          dev_server:
            command: devserver
            modes: [dev, tunnel]
            default_mode: tunnel
            status_url: http://localhost:3000/status
            state_file: /tmp/devserver-current
          test_db: app-test-db
          review_skill: /review-app-pr
          pr_prerequisites: true
          benchmark: { database: app_bench }
        Short:
          root: /code/short
          dev_server: other-server
    YAML

    server = c.settings("App").dev_server
    assert_equal ["devserver", %w[dev tunnel], "tunnel", "http://localhost:3000/status", "/tmp/devserver-current"],
                 [server.command, server.modes, server.default_mode, server.status_url, server.state_file]
    assert_equal "app-test-db", c.settings("App").test_db
    assert_equal "/review-app-pr", c.settings("App").review_skill
    assert c.settings("App").pr_prerequisites?
    assert_equal({ "database" => "app_bench" }, c.settings("App")["benchmark"])

    short = c.settings("Short").dev_server
    assert_equal ["other-server", ["default"], "default", nil, nil],
                 [short.command, short.modes, short.default_mode, short.status_url, short.state_file]
    assert_equal "devserver", c.dev_server.command
    assert_equal %w[devserver other-server], c.dev_server_commands
  end

  def test_epic_and_issue_link_settings_read_with_their_defaults
    c = config(<<~YAML)
      projects:
        App:
          root: /code/app
          epics:
            issue_types: [Project, " Epic ", ""]
          issue_links:
            tracker_url: "https://tracker.example/ws/{repo}/{number}"
            notion_author: notes-bot
            heading_links: [Design, " Test plan = QA ", "=Nothing", ""]
        Plain: /code/plain
    YAML

    epics = c.settings("App").epics
    assert_equal %w[Project Epic], epics.issue_types
    assert epics.epic_type?("epic")
    refute epics.epic_type?(nil)
    links = c.settings("App").issue_links
    assert_equal ["https://tracker.example/ws/{repo}/{number}", "notes-bot", "Notion"],
                 [links.tracker_url, links.notion_author, links.notion_label]
    assert_equal [%w[Design Design], ["Test plan", "QA"]], links.headings, "a bare heading is its own label"
    plain = c.settings("Plain")
    assert_equal [[], nil, nil, []],
                 [plain.epics.issue_types, plain.issue_links.tracker_url, plain.issue_links.notion_author,
                  plain.issue_links.headings]
    refute plain.epics.epic_type?("Project")
  end

  def test_malformed_values_leave_the_feature_off
    c = config(<<~YAML)
      projects:
        App:
          root: /code/app
          dev_server: { modes: [dev] }
          test_db: ["not", "a", "string"]
          review_skill: ""
          pr_prerequisites: "yes"
      default_project: Nope
      loose_starters: [backlog]
    YAML

    settings = c.settings("App")
    assert_nil settings.dev_server
    assert_nil settings.test_db
    assert_equal "/code-review", settings.review_skill
    refute settings.pr_prerequisites?
    assert_nil c.dev_server
    assert_equal "App", c.default_project
    assert_empty c.loose_starters
    assert_nil Quartermaster::ProjectConfig.new(nil).default_project
  end

  def test_default_project_and_loose_starters
    c = config(<<~YAML)
      projects:
        First: /code/first
        Second: /code/second
      default_project: Second
      loose_starters:
        backlog:
          label: Sprint backlog
          prompt: "  Load the sprint backlog. Then give a count and  "
        unlabelled:
          prompt: Load something
        promptless:
          label: Nothing
    YAML

    assert_equal "Second", c.default_project
    assert_equal %w[backlog unlabelled], c.loose_starters.keys
    assert_equal({ "key" => "backlog", "label" => "Sprint backlog" }, c.loose_starters["backlog"].to_h)
    assert_equal "Load the sprint backlog. Then give a count and", c.loose_starters["backlog"].prompt
    assert_equal "unlabelled", c.loose_starters["unlabelled"].label
  end

  def test_current_follows_the_files_text_and_survives_a_broken_file
    configure_projects({ "App" => featured_project("/code/app") })
    first = Quartermaster::ProjectConfig.current
    assert_same first, Quartermaster::ProjectConfig.current
    assert_equal "pf", first.settings("App").dev_server.command

    configure_projects({ "App" => "/code/app" })
    assert_nil Quartermaster::ProjectConfig.current.settings("App").dev_server

    File.write(Quartermaster::CONFIG_FILE, "projects: [::")
    assert_empty Quartermaster::ProjectConfig.current.roots
  end

  def test_the_seed_parses_with_no_projects
    Quartermaster.ensure_setup

    assert_empty Quartermaster::ProjectMap.new.known_projects
    assert_nil Quartermaster::ProjectConfig.current.default_project
  end

  def test_the_seed_is_what_qm_writes_for_no_projects
    assert_equal "# Edited by qm (Settings view / qm config); key reference: docs/overview.md\nprojects: {}\n",
                 Quartermaster::CONFIG_SEED
    assert_equal Quartermaster::CONFIG_SEED, Quartermaster::ConfigFile.emit({ "projects" => {} })
  end

  def test_project_map_takes_injected_settings_mappings
    map = Quartermaster::ProjectMap.new(roots: { "App" => featured_project("/code/app"), "Plain" => "/code/plain" })

    assert_equal "/code/app", map.root_for("App")
    assert_equal "app-test-db", map.settings_for("App").test_db
    assert_nil map.settings_for("Plain").test_db
    assert_nil map.settings_for("Unknown").dev_server
  end

  def test_asking_for_a_key_the_schema_does_not_list_raises_in_tests
    settings = config("projects:\n  App:\n    root: /code/app\n    tset_db: typo\n").settings("App")

    error = assert_raises(Quartermaster::ConfigReader::UnknownKey) { settings["tset_db"] }
    assert_match "projects.App.tset_db", error.message
    assert_raises(Quartermaster::ConfigReader::UnknownKey) { Quartermaster::ConfigReader.new({}).section("project") }
  end

  def test_outside_tests_an_unknown_key_reads_nil_and_is_logged
    Quartermaster.ensure_setup
    ENV.delete(Quartermaster::ConfigReader::STRICT_ENV)
    reader = Quartermaster::ConfigReader.new({ "projects" => {}, "colour" => "red" })

    assert_nil reader["colour"]
    refute reader.section("colour").mapping?
    assert_match "config key colour is not in ConfigSchema", File.read(Quartermaster::LOG_FILE)
  ensure
    ENV[Quartermaster::ConfigReader::STRICT_ENV] = "1"
  end

  def test_the_overview_url_and_price_overrides_come_from_the_current_config
    Quartermaster.ensure_setup
    File.write(Quartermaster::CONFIG_FILE, <<~YAML)
      overview_artifact: " https://claude.ai/artifact/abc "
      prices:
        claude-opus-5-5: { output: 30 }
        broken: 7
    YAML

    assert_equal "https://claude.ai/artifact/abc", Quartermaster::Overview.artifact_url
    assert_equal({ "claude-opus-5-5" => { "output" => 30 } }, Quartermaster::ProjectConfig.current.prices)

    File.write(Quartermaster::CONFIG_FILE, "overview_artifact: [::")
    assert_nil Quartermaster::Overview.artifact_url
  end
end
