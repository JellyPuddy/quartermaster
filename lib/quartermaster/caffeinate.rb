# frozen_string_literal: true

module Quartermaster
  # The GUI header's ☕ toggle: keeps the Mac from idle-sleeping while
  # chats and agents run (the display may still sleep and lock). On spawns
  # `caffeinate -i -w <gui pid>` as a
  # child of the GUI; off kills that one child, by its pid. `-w` makes
  # caffeinate exit on its own when the GUI does, so nothing outlives the
  # server and a restarted GUI starts off — there is never a stray process to
  # adopt, which is why the pid lives only in memory.
  #
  # Auto mode holds the child only while some session is busy: the GUI's
  # watcher calls #sync with that verdict, and #sync does nothing in the
  # other modes, so a manual on or off always wins.
  #
  # spawn / alive / kill are the seams: tests pass lambdas and never start a
  # real caffeinate.
  class Caffeinate
    BINARY = "/usr/bin/caffeinate"

    def initialize(owner_pid: Process.pid, spawn: nil, alive: nil, kill: nil)
      @owner_pid = owner_pid
      @spawn = spawn || method(:spawn_process)
      @alive = alive || method(:process_alive?)
      @kill = kill || method(:kill_process)
      @lock = Mutex.new
      @pid = nil
      @mode = "off"
    end

    MODES = %w[off on auto].freeze

    def mode = @lock.synchronize { @mode }

    def argv = [BINARY, "-i", "-w", @owner_pid.to_s]

    # Idempotent: a second "on" keeps the running child.
    def on
      @lock.synchronize do
        @mode = "on"
        hold
      end
    end

    def off
      @lock.synchronize do
        @mode = "off"
        release
      end
    end

    # Switches to auto and applies the current verdict straight away.
    def auto(busy)
      @lock.synchronize { @mode = "auto" }
      sync(busy)
    end

    def sync(busy)
      @lock.synchronize do
        next status_unlocked unless @mode == "auto"

        busy ? hold : release
      end
    end

    def status
      @lock.synchronize { status_unlocked }
    end

    private

    # A child that died on its own (killed from outside) reads as off.
    def running?
      @pid && @alive.call(@pid)
    end

    def hold
      @pid = @spawn.call(argv) unless running?
      status_unlocked
    end

    def release
      @kill.call(@pid) if running?
      @pid = nil
      status_unlocked
    end

    def status_unlocked
      @pid = nil unless running?
      { "on" => @pid ? true : false, "pid" => @pid, "mode" => @mode }
    end

    def spawn_process(argv)
      Process.spawn(*argv, in: File::NULL, out: File::NULL, err: File::NULL)
    end

    # WNOHANG also reaps a child that exited, so no zombie is left behind.
    def process_alive?(pid)
      Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      false
    end

    def kill_process(pid)
      Process.kill("TERM", pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
