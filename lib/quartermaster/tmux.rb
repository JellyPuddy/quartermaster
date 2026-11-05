# frozen_string_literal: true

module Quartermaster
  # The tmux server the GUI's chats live in, so a chat outlives the GUI that
  # started it. A dedicated socket (`tmux -L qm`, QM_TMUX_SOCKET for tests)
  # keeps it apart from any tmux the user runs themselves. Each chat is its own tmux
  # session holding one window, both named after the item's slug: a pane then
  # attaches with `attach -t =slug` and can never be switched onto another
  # item's window when its chat ends — the session ends with it and the
  # attached client exits.
  class Tmux
    DEFAULT_SOCKET = "qm"
    # tmux reserves these in target names; slugs never carry them.
    NAME = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

    # Strips Claude Code's own variables before exec: a child that inherits
    # the nested-session marker stops saving its transcript, which is fatal
    # for qm. The GUI may itself run inside a claude session, and the tmux
    # server keeps the environment it was started with.
    SCRUB = 'for v in $(env | sed -n "s/^\(CLAUDE[A-Za-z0-9_]*\)=.*/\1/p"); do unset "$v"; done; exec "$@"'

    # Server-wide, re-applied on every open (cheap, and the server may predate
    # a change here): no status bar, the wheel scrolls into copy-mode, Esc
    # reaches claude without tmux's escape delay, and no prefix key — Ctrl-b
    # belongs to claude. Closing the tab is how a Warp attach detaches.
    # OSC 8 hyperlinks pass through only to a client tmux knows supports them;
    # a fixed array index keeps re-applying idempotent.
    OPTIONS = [%w[status off], %w[mouse on], %w[escape-time 10], %w[prefix None],
               %w[history-limit 50000], %w[window-size latest], ["terminal-features[90]", "xterm*:hyperlinks"]].freeze

    attr_reader :socket

    def initialize(socket: ENV.fetch("QM_TMUX_SOCKET", DEFAULT_SOCKET))
      @socket = socket
    end

    def command(*args) = ["tmux", "-L", @socket, *args]

    # Live session names. No server yet means none.
    def sessions
      out, _err, status = run("list-sessions", "-F", '#{session_name}')
      status.success? ? out.split("\n") : []
    end

    def live?(name) = valid_name?(name) && run("has-session", "-t", "=#{name}")[2].success?

    # Starts `argv` in a new detached session `name` at `cwd`. Returns false
    # when that session already runs — one live chat per item.
    def open(name, cwd:, argv:, env: {})
      raise ArgumentError, "not a usable tmux name: #{name.inspect}" unless valid_name?(name)
      return false if live?(name)

      options = OPTIONS.flat_map { |name_value| [";", "set-option", "-g", *name_value] }
      _out, err, status = run("new-session", "-d", "-s", name, "-n", name, "-c", usable_cwd(cwd), "-x", "160", "-y", "48",
                              *program(argv, env), *options)
      raise ArgumentError, "tmux could not start #{name}: #{err.strip}" unless status.success?

      true
    end

    # Types text into the session as if from the keyboard (-l: no key-name
    # lookup, so "Enter" in the text stays a word). Submitting is a separate
    # send_enter: claude reads a burst of typed text as a paste, and an Enter
    # inside that burst would land in the paste instead of submitting it.
    def send_text(name, text) = target_run(name, "send-keys", "-l", text)

    def send_enter(name) = target_run(name, "send-keys", "Enter")

    # Multi-line text as one paste: every newline typed with send_text would
    # submit. -p wraps it in bracketed-paste markers when the program asked
    # for them (claude does), so it lands in the prompt whole; -d drops the
    # buffer afterwards. Submitting stays a separate send_enter.
    def paste(name, text)
      return false unless valid_name?(name)

      buffer = "qm-paste-#{name}"
      run_with_input(text, "load-buffer", "-b", buffer, "-")[2].success? &&
        target_run(name, "paste-buffer", "-p", "-d", "-b", buffer)
    end

    # remain-on-exit keeps the window (and every client attached to it) when
    # its program ends, so a context rotation can start the next chat in the
    # same window instead of the pane closing under the user.
    def keep_on_exit(name, keep) = target_run(name, "set-option", "-w", "remain-on-exit", keep ? "on" : "off")

    def pane_dead?(name)
      return false unless valid_name?(name)

      out, _err, status = run("display-message", "-p", "-t", "=#{name}:", '#{pane_dead}')
      status.success? && out.strip == "1"
    end

    # The process the session's pane runs (the chat, once its launcher
    # exec'd), or nil when tmux can't say.
    def pane_pid(name)
      return nil unless valid_name?(name)

      out, _err, status = run("display-message", "-p", "-t", "=#{name}:", '#{pane_pid}')
      pid = out.strip.to_i
      status.success? && pid.positive? ? pid : nil
    end

    # The directory the session's pane runs in, or nil when tmux can't say.
    def pane_path(name)
      return nil unless valid_name?(name)

      out, _err, status = run("display-message", "-p", "-t", "=#{name}:", '#{pane_current_path}')
      path = out.strip
      status.success? && !path.empty? ? path : nil
    end

    # Starts `argv` afresh in the session's pane, killing whatever still runs.
    def respawn(name, cwd:, argv:, env: {})
      target_run(name, "respawn-pane", "-k", "-c", usable_cwd(cwd), *program(argv, env)) ||
        raise(ArgumentError, "tmux could not restart #{name}")
    end

    # Renames session `old` and its window to `new`, so the attach target
    # (`=slug`) follows the chat. False when either name is unusable, `old`
    # isn't running, or `new` already is — never two chats under one name.
    def rename(old, new)
      return false unless valid_name?(old) && valid_name?(new) && !live?(new)

      run("rename-session", "-t", "=#{old}", new)[2].success? &&
        run("rename-window", "-t", "=#{new}:", new)[2].success?
    end

    def kill(name)
      valid_name?(name) && run("kill-session", "-t", "=#{name}")[2].success?
    end

    # What a pane's PTY runs to show a session: a fresh client per pane, so a
    # reload or a second tab is just another client.
    def attach_command(name) = command("attach-session", "-t", "=#{name}")

    # Tests' cleanup: tmux leaves the socket file behind on kill-server.
    def kill_server
      run("kill-server")
      FileUtils.rm_f(File.join(ENV.fetch("TMUX_TMPDIR", "/tmp"), "tmux-#{Process.uid}", @socket))
    end

    def valid_name?(name) = name.is_a?(String) && NAME.match?(name)

    private

    def usable_cwd(cwd) = (cwd && File.directory?(cwd) ? cwd : Dir.home)

    def program(argv, env)
      ["sh", "-c", SCRUB, "qm-chat", "env", *env.map { |k, v| "#{k}=#{v}" }, *argv]
    end

    # A command aimed at the session's (only) pane; true when tmux took it.
    def target_run(name, command, *args)
      valid_name?(name) && run(command, "-t", "=#{name}:", *args)[2].success?
    end

    # TMUX unset: a GUI started inside tmux must still talk to our server.
    # [output, error, status]; tmux's stderr is folded into the output, which
    # only failures read.
    def run(*args)
      out = IO.popen({ "TMUX" => nil }, command(*args), err: %i[child out], &:read)
      [out, out, $?]
    rescue SystemCallError => e
      ["", e.message, FAILED]
    end

    def run_with_input(input, *args)
      out = IO.popen({ "TMUX" => nil }, command(*args), "r+", err: %i[child out]) do |io|
        io.write(input)
        io.close_write
        io.read
      end
      [out, out, $?]
    rescue SystemCallError => e
      ["", e.message, FAILED]
    end

    FAILED = Struct.new(:success?).new(false)
  end
end
