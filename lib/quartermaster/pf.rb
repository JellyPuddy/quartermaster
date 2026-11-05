# frozen_string_literal: true

module Quartermaster
  # A project's dev server (config.yml `dev_server:`, ProjectSettings::DevServer),
  # driven through its command: what it serves right now, and switching or
  # stopping it. It serves one checkout at a time, so this is a single shared
  # resource, not per item. Without a configured server there is no status.
  class Pf
    STATUS_TIMEOUT_SECONDS = "0.5"

    Status = Struct.new(:mode, :root, :running, :switching, keyword_init: true) do
      def to_h = { "mode" => mode, "root" => root, "running" => running, "switching" => switching }
    end

    def initialize(runner: CommandRunner.new, server: ProjectConfig.current.dev_server)
      @runner = runner
      @server = server
    end

    def status
      return nil unless @server

      from_endpoint || from_files
    end

    # Whether the dev server is serving this checkout right now — the cleanup
    # guard: a served worktree must never be removed.
    def serves?(path)
      current = status
      current&.running && current.root && same_path?(current.root, path) ? true : false
    end

    def switch(path, mode)
      run!([command, "switch", path, mode], "#{command} switch")
    end

    def stop
      run!([command, "stop"], "#{command} stop")
    end

    private

    def command = (@server || raise(ArgumentError, "no dev server configured in config.yml")).command

    # The status URL answers from inside the running server — authoritative,
    # but only while it is up (not mid-boot).
    def from_endpoint
      return nil unless @server.status_url

      result = @runner.call(["curl", "-s", "--max-time", STATUS_TIMEOUT_SECONDS, @server.status_url])
      return nil unless result.success?

      data = JSON.parse(result.out)
      return nil unless data.is_a?(Hash) && data["mode"]

      Status.new(mode: data["mode"], root: data["root"], running: true, switching: data["switching"] == true)
    rescue JSON::ParserError
      nil
    end

    # `<command> status` exits non-zero when nothing runs; the state file,
    # written on every switch and never cleared on stop, names what it was
    # (or still is) serving.
    def from_files
      mode, root = begin
        @server.state_file && File.read(@server.state_file).strip.split(" ", 2)
      rescue SystemCallError
        nil
      end
      running = @runner.call([command, "status"]).success?
      Status.new(mode: mode, root: root, running: running, switching: false)
    end

    def run!(argv, label)
      result = @runner.call(argv)
      return result.out if result.success?

      message = [result.err, result.out].map(&:strip).find { |text| !text.empty? } || "exit status non-zero"
      raise ArgumentError, "#{label} failed: #{message}"
    end

    def same_path?(left, right)
      normalize(left) == normalize(right)
    end

    def normalize(path)
      File.realpath(File.expand_path(path))
    rescue SystemCallError
      File.expand_path(path)
    end
  end
end
