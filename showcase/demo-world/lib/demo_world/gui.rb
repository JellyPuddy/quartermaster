# frozen_string_literal: true

require "net/http"

module DemoWorld
  # Starting and stopping `qm gui` against a world: a detached process with
  # only the world's env, its pid in the world's gui.pid, output in log/gui.log.
  class Gui
    def initialize(world)
      @world = world
    end

    def start(timeout: 15)
      raise "port #{@world.port} is taken: stop whatever serves #{@world.url} first (or set QM_DEMO_PORT)" if answering?

      log = File.join(@world.log_dir, "gui.log")
      pid = Process.spawn(@world.env, RbConfig.ruby, QM_EXECUTABLE, "gui",
                          chdir: @world.home, unsetenv_others: true, pgroup: true,
                          in: File::NULL, out: [log, "a"], err: [log, "a"])
      Process.detach(pid)
      File.write(@world.pid_file, "#{pid}\n")
      deadline = Time.now + timeout
      sleep 0.2 until answering? || Time.now > deadline
      raise "qm gui did not answer on #{@world.url} within #{timeout}s; see #{log}" unless answering?

      pid
    end

    # Stops the GUI this world started (its whole process group) and the
    # demo tmux server. Safe when nothing runs.
    def stop
      pid = File.read(@world.pid_file).to_i if File.exist?(@world.pid_file)
      if pid&.positive?
        begin
          Process.kill("TERM", -pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
      FileUtils.rm_f(@world.pid_file)
      system("tmux", "-L", @world.tmux_socket, "kill-server", out: File::NULL, err: File::NULL)
      pid
    end

    def answering?
      Net::HTTP.start("127.0.0.1", @world.port, open_timeout: 0.5, read_timeout: 2) do |http|
        http.get("/api/pulse", "Host" => "127.0.0.1:#{@world.port}").is_a?(Net::HTTPResponse)
      end
    rescue StandardError
      false
    end
  end
end
