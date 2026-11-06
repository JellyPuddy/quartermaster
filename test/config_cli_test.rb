# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/config_cli_test.rb`).
require_relative "test_helper"

# `qm config` through the real executable, on a QM_ROOT config.yml.
class ConfigCliTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    @root = Dir.mktmpdir("qm-config-root")
    FileUtils.mkdir_p(Quartermaster::ROOT)
    write_config(<<~YAML)
      projects:
        App:
          root: #{@root}
          dev_server: sh
    YAML
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def file = Quartermaster::CONFIG_FILE

  def write_config(text) = File.write(file, text)

  def qm(*argv)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_ITEM" => nil, "QM_ASIDE" => nil, "QM_LOOSE" => nil },
                   RbConfig.ruby, QM_BIN, "config", *argv)
  end

  def data = YAML.safe_load(File.read(file))

  def test_path_prints_the_file_location
    out, _err, status = qm("path")
    assert status.success?
    assert_equal "#{file}\n", out
  end

  def test_set_writes_a_list_a_bool_and_a_number
    _out, err, status = qm("set", "projects.App.dev_server.modes", "[dev, ngrok]")
    assert status.success?, err
    assert_equal %w[dev ngrok], data.dig("projects", "App", "dev_server", "modes")

    assert qm("set", "projects.App.pr_prerequisites", "true").last.success?
    assert_equal true, data.dig("projects", "App", "pr_prerequisites")

    assert qm("set", "prices.claude-opus-5-5.input", "4").last.success?
    assert_equal 4, data.dig("prices", "claude-opus-5-5", "input")
  end

  def test_set_echoes_what_it_wrote
    out, _err, status = qm("set", "projects.App.dev_server.modes", "[dev, ngrok]")
    assert status.success?
    assert_equal "projects.App.dev_server.modes: [dev, ngrok]\n", out
  end

  def test_set_of_an_unknown_path_fails_and_writes_nothing
    before = File.read(file)
    out, err, status = qm("set", "projects.App.typo", "x")
    assert_equal 1, status.exitstatus
    assert_empty out
    assert_match(/unknown config key: projects\.App\.typo/, err)
    assert_equal before, File.read(file)
  end

  def test_set_of_a_wrong_type_fails_on_stderr_and_writes_nothing
    before = File.read(file)
    _out, err, status = qm("set", "projects.App.pr_prerequisites", "maybe")
    assert_equal 1, status.exitstatus
    assert_match(/error: projects\.App\.pr_prerequisites: must be true or false/, err)
    assert_equal before, File.read(file)
    refute File.exist?("#{file}.bak")
  end

  def test_set_with_a_warning_writes_and_warns_on_stderr
    out, err, status = qm("set", "projects.App.test_db", "no-such-test-db-cmd-xyz")
    assert status.success?
    assert_match(/warning: projects\.App\.test_db: no-such-test-db-cmd-xyz is not on PATH/, err)
    assert_equal "projects.App.test_db: no-such-test-db-cmd-xyz\n", out
    assert_equal "no-such-test-db-cmd-xyz", data.dig("projects", "App", "test_db")
    assert File.exist?("#{file}.bak")
  end

  def test_set_without_a_value_prints_usage
    _out, err, status = qm("set", "projects.App.test_db")
    assert_equal 1, status.exitstatus
    assert_match(/usage: qm config/, err)
  end

  def test_get_prints_a_scalar_bare_and_a_subtree_as_yaml
    qm("set", "projects.App.dev_server.modes", "[dev, ngrok]")
    out, _err, status = qm("get", "projects.App.root")
    assert status.success?
    assert_equal "#{@root}\n", out

    out, = qm("get", "projects.App.dev_server")
    assert_equal({ "command" => "sh", "modes" => %w[dev ngrok] }, YAML.safe_load(out))
  end

  def test_get_without_a_path_prints_the_whole_file
    out, _err, status = qm("get")
    assert status.success?
    assert_equal({ "projects" => { "App" => { "root" => @root, "dev_server" => "sh" } } }, YAML.safe_load(out))
  end

  def test_get_of_an_unset_key_prints_nothing_and_exits_1
    out, err, status = qm("get", "projects.App.test_db")
    assert_equal 1, status.exitstatus
    assert_empty out
    assert_empty err
  end

  def test_get_of_an_unknown_path_fails
    _out, err, status = qm("get", "nope")
    assert_equal 1, status.exitstatus
    assert_match(/unknown config key: nope/, err)
  end

  def test_unset_removes_the_key
    qm("set", "projects.App.test_db", "x")
    _out, err, status = qm("unset", "projects.App.test_db")
    assert status.success?, err
    assert_nil data.dig("projects", "App", "test_db")
  end

  def test_unset_of_an_unknown_path_fails_even_when_absent
    _out, err, status = qm("unset", "foo.bar.baz")
    assert_equal 1, status.exitstatus
    assert_match(/unknown config key: foo\.bar\.baz/, err)
  end

  def test_unset_of_an_absent_known_key_says_so
    before = File.read(file)
    out, _err, status = qm("unset", "projects.App.test_db")
    assert status.success?
    assert_equal "projects.App.test_db is not set\n", out
    assert_equal before, File.read(file)
  end

  def test_unset_of_a_project_warns_with_its_work_item_count
    Quartermaster::WorkItem.create("One", project: "App")
    Quartermaster::WorkItem.create("Two", project: "App")
    Quartermaster::WorkItem.create("Elsewhere", project: "Other")
    _out, err, status = qm("unset", "projects.App")
    assert status.success?, err
    assert_match(/warning: 2 work items still have project App/, err)
    assert_equal({}, data["projects"])
  end

  def test_unset_refused_by_an_error_writes_nothing
    write_config(<<~YAML)
      projects:
        App:
          root: #{@root}
      default_project: App
    YAML
    before = File.read(file)
    _out, err, status = qm("unset", "projects.App")
    assert_equal 1, status.exitstatus
    assert_match(/error: default_project: default_project must name a project/, err)
    assert_equal before, File.read(file)
  end

  def test_an_unparsable_file_refuses_a_set
    write_config("projects: [unclosed\n")
    _out, err, status = qm("set", "default_project", "App")
    assert_equal 1, status.exitstatus
    assert_match(/error: .*not valid YAML/, err)
    assert_equal "projects: [unclosed\n", File.read(file)
  end

  def test_no_subcommand_prints_usage
    _out, err, status = qm
    assert_equal 1, status.exitstatus
    assert_match(/usage: qm config/, err)
  end

  def test_help_lists_qm_config
    out, = Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT }, RbConfig.ruby, QM_BIN, "help")
    assert_match(/qm config get \[PATH\]/, out)
    assert_match(/qm config set PATH VALUE/, out)
  end
end
