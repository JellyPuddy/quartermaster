# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/showcase_demo_world_test.rb`).
require_relative "test_helper"
require "etc"
require_relative "../showcase/demo-world/lib/demo_world"

class ShowcaseDemoWorldTest < Minitest::Test
  # One seed for the whole class: it runs a few dozen git commands.
  def self.world
    @world ||= begin
      root = File.join(Dir.mktmpdir("qm-demo-world"), "world")
      Minitest.after_run { FileUtils.rm_rf(File.dirname(root)) }
      DemoWorld.seed(root, steps: [])
    end
  end

  def world = self.class.world

  def test_env_points_only_inside_the_world_and_never_at_live_state
    env = world.env
    %w[HOME QM_ROOT QM_TRANSCRIPTS_DIR QM_WARP_TAB_CONFIGS TMPDIR XDG_CONFIG_HOME QM_DEMO_WORLD].each do |key|
      assert inside?(env.fetch(key)), "#{key}=#{env[key]} is outside the world"
    end
    assert_equal world.bin_dir, env["PATH"].split(":").first
    real_home = Etc.getpwuid.dir
    env["PATH"].split(":").drop(1).each { |dir| refute dir.start_with?(real_home), "PATH reaches into #{dir}" }
    refute_equal Quartermaster::Tmux::DEFAULT_SOCKET, env["QM_TMUX_SOCKET"]
    refute_equal Quartermaster::Gui::DEFAULT_PORT.to_s, env["QM_GUI_PORT"]
    assert env["QM_GUI_NO_OPEN"]
    refute env.keys.any? { |key| key.start_with?("CLAUDE") }
  end

  def test_every_stub_is_installed_and_shadows_the_real_program
    DemoWorld::STUBS.each do |name|
      path = File.join(world.bin_dir, name)
      assert File.executable?(path), "#{name} stub missing"
      assert_equal "#!#{RbConfig.ruby}", File.foreach(path).first.chomp
    end
    assert_equal File.realpath(world.bin_dir), File.realpath(File.join(world.home, "bin")), "CommandRunner's ~/bin must be the stubs"
    assert_equal File.join(world.bin_dir, "gh"), world.run!("sh", "-c", "command -v gh").strip
  end

  def test_config_maps_the_bakery_projects_to_the_world_repos
    projects = YAML.safe_load(File.read(world.config_file))["projects"]
    assert_equal DemoWorld::PROJECTS.keys, projects.keys
    assert_equal world.repo("bakery-shop"), projects["Bakery webshop"]["root"]
    assert_equal world.repo("bakery-design-system"), projects["Bakery design system"]
    roots = projects.values.map { |value| value.is_a?(Hash) ? value["root"] : value }
    roots.each { |root| assert inside?(root) && File.directory?(File.join(root, ".git")), root }
  end

  def test_the_webshop_has_a_stub_dev_server_and_test_db
    shop = demo_config.settings("Bakery webshop")
    assert_equal "devserver", shop.dev_server.command
    assert_equal %w[dev tunnel], shop.dev_server.modes
    assert_equal "dev", shop.dev_server.default_mode
    assert_equal "bakery-test-db", shop.test_db
    assert inside?(shop.dev_server.state_file), shop.dev_server.state_file
    assert_nil demo_config.settings("Bakery design system").dev_server
    [shop.dev_server.command, shop.test_db].each { |name| assert_includes DemoWorld::HARMLESS_STUBS, name }
  end

  def test_the_stub_dev_server_serves_the_gift_cards_worktree_and_follows_switch_and_stop
    server = demo_config.settings("Bakery webshop").dev_server
    pf = Quartermaster::Pf.new(runner: world_runner, server: server)
    gift_cards = world.worktree("bakery-shop", "gift-cards")
    slots = world.worktree("bakery-shop", "delivery-slots-v2")
    assert pf.serves?(gift_cards), "the built world must show gift-cards served"
    assert_equal "dev", pf.status.mode

    pf.switch(slots, "tunnel")
    assert pf.serves?(slots)
    assert_equal "tunnel", pf.status.mode
    pf.stop
    refute pf.status.running, "a stopped dev server reports nothing served"
    assert_equal slots, pf.status.root, "the state file keeps the last switch after a stop"
  ensure
    world.run!("devserver", "switch", gift_cards, "dev") if gift_cards
  end

  def test_the_stub_test_db_names_one_database_per_worktree
    worktree = world.worktree("bakery-shop", "croissant-spike")
    assert_equal "bakery_test_croissant_spike\n", world.run!("bakery-test-db", "drop", worktree, "--dry-run")
    assert_equal "", world.run!("bakery-test-db", "prepare", worktree)
  end

  def test_the_ide_is_a_harmless_stub_so_screenshots_keep_its_buttons
    config = Quartermaster::ProjectConfig.new(YAML.safe_load(File.read(world.config_file)))
    assert_equal "Bakery IDE", config.ide.label
    assert_equal File.join(world.bin_dir, config.ide.command.first), world.run!("sh", "-c", "command -v #{config.ide.command.first}").strip
  end

  def test_repos_have_branches_worktrees_and_a_three_layer_stack
    shop = world.repo("bakery-shop")
    branches = world.run!("git", "for-each-ref", "--format=%(refname:short)", "refs/heads", chdir: shop).split("\n")
    assert_empty DemoWorld::Repos::PULLS["bakery-shop"].keys - branches
    assert_operator world.run!("git", "rev-list", "--count", "main", chdir: shop).to_i, :>=, 6
    worktrees = Quartermaster.branch_worktrees(shop)
    DemoWorld::Repos::WORKTREES["bakery-shop"].each_value { |branch| assert worktrees[branch], "no worktree for #{branch}" }
    assert_equal "bakery-co/bakery-shop", Quartermaster.github_repo(shop)
    stack = Quartermaster::GhStack.for_root(shop)
    assert_equal [DemoWorld::Repos::STACK], stack.stacks.map { |s| s.map(&:branch) }
    unsigned = world.run!("git", "log", "--all", "--format=%G?", chdir: shop).split("\n").uniq
    assert_equal ["N"], unsigned
  end

  def test_origin_is_never_reached
    _out, err, status = Open3.capture3(world.env, "git", "fetch", "origin", chdir: world.repo("bakery-shop"), unsetenv_others: true)
    refute status.success?
    assert_match(/not allowed/, err)
  end

  def test_gh_stub_answers_from_the_most_specific_fixture_and_logs_misses
    world.write_json(File.join(world.gh_fixtures_dir, "50-test.json"), [
      { "match" => ["^pr view"], "stdout" => { "state" => "OPEN" } },
      { "match" => ["^pr view", "feature/gift-cards"], "stdout" => { "state" => "MERGED", "number" => 38 } }
    ])
    shop = world.repo("bakery-shop")
    assert_equal({ "state" => "MERGED", "number" => 38 },
                 JSON.parse(world.run!("gh", "pr", "view", "feature/gift-cards", "--json", "state,number", chdir: shop)))
    assert_equal({ "state" => "OPEN" }, JSON.parse(world.run!("gh", "pr", "view", "fix/cart-rounding", chdir: shop)))
    _out, err, status = Open3.capture3(world.env, "gh", "issue", "list", chdir: shop, unsetenv_others: true)
    refute status.success?
    assert_match(/no fixture for: issue list/, err)
    logged = File.readlines(File.join(world.log_dir, "gh.jsonl")).map { |line| JSON.parse(line) }
    assert_includes logged.map { |entry| entry["argv"] }, %w[issue list]
  ensure
    FileUtils.rm_f(File.join(world.gh_fixtures_dir, "50-test.json"))
  end

  def test_claude_stub_prints_without_a_model_and_harmless_stubs_do_nothing
    assert_match(/demo world/, world.run!("claude", "-p", "summarise this"))
    world.run!("open", "http://example.com")
    world.run!("osascript", "-e", "display notification \"x\"")
    world.run!("devserver", "status")
    _out, _err, status = Open3.capture3(world.env, "curl", "-s", "http://localhost:3000/__pf/status", unsetenv_others: true)
    refute status.success?, "curl must never reach a dev server"
    programs = File.readlines(File.join(world.log_dir, "stubs.jsonl")).map { |line| JSON.parse(line)["program"] }
    assert_empty %w[open osascript devserver curl] - programs
  end

  def test_seed_runs_registered_steps_after_the_core
    seen = nil
    root = File.join(Dir.mktmpdir("qm-demo-steps"), "world")
    DemoWorld.seed(root, steps: [{ name: "probe", run: ->(w) { seen = File.exist?(w.config_file) } }])
    assert seen, "a step must see the built core"
  ensure
    FileUtils.rm_rf(File.dirname(root)) if root
  end

  def test_port_and_socket_derive_from_the_checkout_path
    with_demo_env do
      world = DemoWorld::World.new("/Users/mara/code/qm/showcase/out/demo-world")
      # md5 -s /Users/mara/code/qm/showcase/out/demo-world → 5fad73ec…; 7700 + its value mod 1000.
      assert_equal 8268, world.port
      assert_equal "qm-demo-5fad73ec", world.tmux_socket
      assert_equal "http://127.0.0.1:8268", world.url
      assert_equal "8268", world.env["QM_GUI_PORT"]
      assert_equal "qm-demo-5fad73ec", world.env["QM_TMUX_SOCKET"]
    end
  end

  def test_two_checkouts_get_different_ports_and_sockets_and_one_checkout_always_the_same
    with_demo_env do
      main = DemoWorld::World.new("/Users/mara/code/qm/showcase/out/demo-world")
      other = DemoWorld::World.new("/Users/mara/code/qm/.claude/worktrees/wf-1/showcase/out/demo-world")
      refute_equal main.port, other.port
      refute_equal main.tmux_socket, other.tmux_socket
      again = DemoWorld::World.new("/Users/mara/code/qm/showcase/out/demo-world")
      assert_equal [main.port, main.tmux_socket], [again.port, again.tmux_socket]
      [main, other].each do |w|
        assert_includes DemoWorld::PORT_RANGE, w.port
        refute_equal Quartermaster::Gui::DEFAULT_PORT, w.port
        refute_equal Quartermaster::Tmux::DEFAULT_SOCKET, w.tmux_socket
      end
    end
  end

  def test_the_default_world_lives_in_this_checkout
    with_demo_env do
      world = DemoWorld::World.new(DemoWorld::DEFAULT_ROOT)
      assert_equal File.expand_path("../showcase/out/demo-world", __dir__), world.root
      assert_equal DemoWorld::World.port_for(world.root), world.port
    end
  end

  def test_env_overrides_win_over_the_derived_values
    with_demo_env("QM_DEMO_PORT" => "7788", "QM_DEMO_TMUX_SOCKET" => "qm-demo") do
      world = DemoWorld::World.new("/Users/mara/code/qm/showcase/out/demo-world")
      assert_equal 7788, world.port
      assert_equal "qm-demo", world.tmux_socket
      assert_equal "7788", world.env["QM_GUI_PORT"]
    end
  end

  def test_arguments_win_over_env_overrides
    with_demo_env("QM_DEMO_PORT" => "7788", "QM_DEMO_TMUX_SOCKET" => "qm-demo") do
      world = DemoWorld::World.new("/Users/mara/code/qm/showcase/out/demo-world", port: 7799, tmux_socket: "qm-test-x")
      assert_equal 7799, world.port
      assert_equal "qm-test-x", world.tmux_socket
    end
  end

  private

  def demo_config = Quartermaster::ProjectConfig.new(YAML.safe_load(File.read(world.config_file)))

  # Runs qm's dev-server commands as the GUI would: inside the world, so they hit its stubs.
  def world_runner
    lambda do |argv, **|
      out, err, status = Open3.capture3(world.env, *argv, unsetenv_others: true)
      Quartermaster::CommandRunner::Result.new(out: out, err: err, success: status.success?)
    end
  end

  def with_demo_env(values = {})
    keys = %w[QM_DEMO_PORT QM_DEMO_TMUX_SOCKET]
    saved = ENV.to_h.slice(*keys)
    keys.each { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    keys.each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def inside?(path)
    File.expand_path(path) == world.root || File.expand_path(path).start_with?("#{world.root}/")
  end
end
