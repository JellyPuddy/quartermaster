# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "yaml"

# The fake, self-contained world the showcase runs `qm gui` in: its own HOME,
# QM_ROOT, transcripts dir, tmux socket and a PATH whose stub programs come
# first, plus the "Bakery webshop" git repos. Built by DemoWorld.seed into one
# directory that is wiped first, so every build is the same.
#
# Seeding data on top (work items, sessions, gh answers, chat screens) is a
# step: a file in showcase/demo-world/seeds/ calls DemoWorld.step, and seed
# runs the steps in file-name order after the core world exists.
module DemoWorld
  SHOWCASE_DIR = File.expand_path("../..", __dir__)
  QM_EXECUTABLE = File.expand_path("../quartermaster", SHOWCASE_DIR)
  DEFAULT_ROOT = File.join(SHOWCASE_DIR, "out", "demo-world")
  STUBS_DIR = File.expand_path("../stubs", __dir__)
  SEEDS_DIR = File.expand_path("../seeds", __dir__)
  # A world's default port and tmux socket, derived from its root (see World).
  TMUX_SOCKET_PREFIX = "qm-demo"
  PORT_RANGE = (7700...8700)
  # Real tools the world may use (git, tmux, rg); stubs shadow everything else.
  SYSTEM_PATH = %w[/opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin].freeze
  # Every external program qm may run on its own, stubbed so nothing reaches
  # the user's apps, dev server, notifications or GitHub (README: "Stubs").
  HARMLESS_STUBS = %w[open osascript terminal-notifier curl devserver bakery-test-db bakery-ide caffeinate pbcopy].freeze
  STUBS = (%w[gh claude] + HARMLESS_STUBS).freeze
  PROJECTS = { "Bakery webshop" => "bakery-shop", "Bakery design system" => "bakery-design-system" }.freeze
  # The bakery-shop worktree the stub dev server serves when the world is built.
  SERVED_WORKTREE = "gift-cards"
  GITHUB_OWNER = "bakery-co"
  LOGIN = "mara-dev"

  STEPS = []

  # Registers a seeding step: the block gets the World once the core (home,
  # stubs, repos, config.yml) is built. Steps run in registration order.
  def self.step(name, &block)
    STEPS.reject! { |existing| existing[:name] == name }
    STEPS << { name: name, run: block }
  end

  def self.load_steps(dir = SEEDS_DIR)
    Dir[File.join(dir, "*.rb")].sort.each { |file| load file }
  end

  # Wipes root and builds the world in it; returns the World.
  def self.seed(root = DEFAULT_ROOT, steps: nil, now: Time.now, tmux_socket: nil)
    world = World.new(root, tmux_socket: tmux_socket)
    world.build(now: now)
    load_steps if steps.nil?
    (steps || STEPS).each { |step| step[:run].call(world) }
    world
  end

  # The paths and environment of one built (or to-be-built) world.
  class World
    attr_reader :root, :tmux_socket, :port, :now

    # tmux_socket: the server the world's chats run on, and port: where its
    # GUI serves — both its own per root unless given or overridden, so two
    # worlds never share (or kill) each other's chats or GUI.
    def initialize(root, tmux_socket: nil, port: nil)
      @root = File.expand_path(root)
      @tmux_socket = tmux_socket || ENV["QM_DEMO_TMUX_SOCKET"] || World.socket_for(@root)
      @port = Integer(port || ENV["QM_DEMO_PORT"] || World.port_for(@root))
      @now = Time.now
    end

    def self.socket_for(root)
      "#{TMUX_SOCKET_PREFIX}-#{Digest::MD5.hexdigest(root)[0, 8]}"
    end

    def self.port_for(root)
      PORT_RANGE.first + (Digest::MD5.hexdigest(root).to_i(16) % PORT_RANGE.size)
    end

    def home = File.join(root, "home")
    def qm_root = File.join(home, ".claude", "quartermaster")
    def transcripts_dir = File.join(home, ".claude", "projects")
    def bin_dir = File.join(root, "bin")
    def repos_dir = File.join(home, "code")
    def fixtures_dir = File.join(root, "fixtures")
    # gh answers: every *.json here is an array of routes (stubs/gh says how they match).
    def gh_fixtures_dir = File.join(fixtures_dir, "gh")
    # Chat screens: <slug>.txt for an item's chat, default.txt otherwise, print.txt for `claude -p`.
    def claude_fixtures_dir = File.join(fixtures_dir, "claude")
    def log_dir = File.join(root, "log")
    def tmp_dir = File.join(root, "tmp")
    def pid_file = File.join(root, "gui.pid")
    def work_items_dir = File.join(qm_root, "work-items")
    def config_file = File.join(qm_root, "config.yml")
    # The stub devserver's state: "<mode> <root>" of its last switch, and a marker while it "serves".
    def dev_server_state_file = File.join(home, ".devserver", "state")
    def dev_server_running_file = File.join(home, ".devserver", "running")
    def repo(name) = File.join(repos_dir, name)
    def project_root(project) = repo(PROJECTS.fetch(project))
    def url = "http://127.0.0.1:#{port}"

    # The whole environment qm and its children run with: nothing inherited
    # from the user's shell (spawn with unsetenv_others: true).
    def env
      {
        "HOME" => home, "USER" => "mara", "LOGNAME" => "mara", "SHELL" => "/bin/zsh",
        "PATH" => ([bin_dir] + SYSTEM_PATH).join(":"), "LANG" => "en_US.UTF-8", "TERM" => "xterm-256color",
        "TMPDIR" => tmp_dir, "XDG_CONFIG_HOME" => File.join(home, ".config"), "GIT_CONFIG_NOSYSTEM" => "1",
        "QM_ROOT" => qm_root, "QM_TRANSCRIPTS_DIR" => transcripts_dir,
        "QM_WARP_TAB_CONFIGS" => File.join(home, ".warp", "tab_configs"),
        "QM_TMUX_SOCKET" => tmux_socket, "QM_GUI_PORT" => port.to_s, "QM_GUI_NO_OPEN" => "1",
        "QM_DEMO_WORLD" => root
      }
    end

    def build(now: Time.now)
      @now = now
      FileUtils.rm_rf(root)
      [home, qm_root, work_items_dir, transcripts_dir, bin_dir, repos_dir, gh_fixtures_dir,
       claude_fixtures_dir, log_dir, tmp_dir, env["QM_WARP_TAB_CONFIGS"], env["XDG_CONFIG_HOME"]].each { |d| FileUtils.mkdir_p(d) }
      write_home
      install_stubs
      write_base_fixtures
      Repos.new(self, now: now).build
      write_config
      write_dev_server
      self
    end

    # Runs a command inside the world (its env only), raising on failure.
    def run!(*argv, chdir: root, extra_env: {})
      out, err, status = Open3.capture3(env.merge(extra_env), *argv, chdir: chdir, unsetenv_others: true)
      raise "#{argv.join(" ")} failed in #{chdir}: #{err}#{out}" unless status.success?

      out
    end

    def write_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(data)}\n")
    end

    private

    def write_home
      File.write(File.join(home, ".gitconfig"), <<~INI)
        [user]
        \tname = Mara de Vries
        \temail = mara@bakery.example
        [commit]
        \tgpgsign = false
        [tag]
        \tgpgsign = false
        [init]
        \tdefaultBranch = main
        [protocol "https"]
        \tallow = never
        [protocol "ssh"]
        \tallow = never
      INI
      # CommandRunner looks in ~/bin before PATH.
      File.symlink(bin_dir, File.join(home, "bin"))
      write_json(File.join(home, ".claude", "settings.json"), { "cleanupPeriodDays" => 30 })
    end

    def install_stubs
      STUBS.each do |name|
        source = File.join(STUBS_DIR, HARMLESS_STUBS.include?(name) ? "harmless" : name)
        target = File.join(bin_dir, name)
        File.write(target, File.read(source).sub(%r{\A#!.*\n}, "#!#{RbConfig.ruby}\n"))
        File.chmod(0o755, target)
      end
    end

    def write_base_fixtures
      write_json(File.join(gh_fixtures_dir, "00-defaults.json"), [
        { "match" => ["--web"], "stdout" => "" },
        { "match" => ["^auth status"], "stdout" => "github.com\n  ✓ Logged in to github.com account #{LOGIN}\n" },
        { "match" => ["^api user\\b"], "stdout" => { "login" => LOGIN, "name" => "Mara de Vries" } },
        { "match" => ["^stack\\b"], "stdout" => "" }
      ])
      File.write(File.join(claude_fixtures_dir, "default.txt"), <<~SCREEN)
        \e[38;5;174m╭───────────────────────────────────────────────────╮\e[0m
        \e[38;5;174m│\e[0m \e[38;5;174m✻\e[0m Welcome to \e[1mClaude Code\e[0m!                         \e[38;5;174m│\e[0m
        \e[38;5;174m│\e[0m                                                   \e[38;5;174m│\e[0m
        \e[38;5;174m│\e[0m   \e[2m/help for help, /status for your current setup\e[0m  \e[38;5;174m│\e[0m
        \e[38;5;174m╰───────────────────────────────────────────────────╯\e[0m

        \e[2m╭───────────────────────────────────────────────────╮\e[0m
        \e[2m│\e[0m >                                                 \e[2m│\e[0m
        \e[2m╰───────────────────────────────────────────────────╯\e[0m
          \e[2m? for shortcuts\e[0m
      SCREEN
      File.write(File.join(claude_fixtures_dir, "print.txt"), "Done — nothing to report in the demo world.\n")
    end

    def write_config
      projects = PROJECTS.to_h { |project, dir| [project, repo(dir)] }
      projects["Bakery webshop"] = {
        "root" => repo(PROJECTS.fetch("Bakery webshop")),
        "dev_server" => { "command" => "devserver", "modes" => %w[dev tunnel], "default_mode" => "dev",
                          "state_file" => dev_server_state_file },
        "test_db" => "bakery-test-db"
      }
      config = { "projects" => projects, "ide_command" => %w[bakery-ide PATH], "ide_label" => "Bakery IDE" }
      File.write(config_file, "# qm configuration (demo world).\n#{YAML.dump(config).delete_prefix("---\n")}")
    end

    # As if `devserver switch <gift-cards worktree> dev` had run (stubs/harmless keeps the same files).
    def write_dev_server
      FileUtils.mkdir_p(File.dirname(dev_server_state_file))
      File.write(dev_server_state_file, "dev #{worktree("bakery-shop", SERVED_WORKTREE)}\n")
      FileUtils.touch(dev_server_running_file)
    end
  end
end

require_relative "demo_world/repos"
require_relative "demo_world/qm_side"
require_relative "demo_world/cast"
require_relative "demo_world/transcript"
