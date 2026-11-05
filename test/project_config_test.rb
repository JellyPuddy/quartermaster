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

  def test_uncommenting_the_seeds_example_project_configures_it
    seed = Quartermaster::CONFIG_SEED.sub("#   my-app: ~/code/my-app", "  my-app: ~/code/my-app")

    assert_equal({ "my-app" => File.expand_path("~/code/my-app") }, config(seed).roots)
  end

  def test_project_map_takes_injected_settings_mappings
    map = Quartermaster::ProjectMap.new(roots: { "App" => featured_project("/code/app"), "Plain" => "/code/plain" })

    assert_equal "/code/app", map.root_for("App")
    assert_equal "app-test-db", map.settings_for("App").test_db
    assert_nil map.settings_for("Plain").test_db
    assert_nil map.settings_for("Unknown").dev_server
  end
end
