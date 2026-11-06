# frozen_string_literal: true

module Quartermaster
  # The LaunchAgent that runs `qm automation tick` every five minutes: its plist
  # text, and installing or removing it in the user's launchd GUI domain. Only an
  # explicit install or uninstall changes anything; every launchctl call goes
  # through the runner.
  class TickInstaller
    LABEL = "com.quartermaster.automation-tick"
    INTERVAL = 300
    AGENTS_DIR = File.expand_path("~/Library/LaunchAgents")

    def initialize(runner:, agents_dir: AGENTS_DIR, env: ENV, root: ROOT, uid: Process.uid,
                   program: File.realpath(EXECUTABLE))
      @runner = runner
      @agents_dir = agents_dir
      @env = env
      @root = root
      @uid = uid
      @program = program
    end

    def plist_path = File.join(@agents_dir, "#{LABEL}.plist")

    def log_path = File.join(@root, "automations", "tick.log")

    def installed? = File.exist?(plist_path)

    def plist
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          #{string(LABEL)}
          <key>ProgramArguments</key>
          <array>
            #{string(@program)}
            #{string("automation")}
            #{string("tick")}
          </array>
          <key>StartInterval</key>
          <integer>#{INTERVAL}</integer>
          <key>RunAtLoad</key>
          <false/>
          <key>StandardOutPath</key>
          #{string(log_path)}
          <key>StandardErrorPath</key>
          #{string(log_path)}
          <key>EnvironmentVariables</key>
          <dict>
        #{environment.map { |key, value| "    <key>#{key}</key>\n    #{string(value)}\n" }.join}  </dict>
        </dict>
        </plist>
      XML
    end

    # A label launchd already holds is booted out first, so a reinstall picks up
    # a changed plist; a failed bootstrap leaves no plist behind.
    def install
      FileUtils.mkdir_p(@agents_dir)
      FileUtils.mkdir_p(File.dirname(log_path))
      AtomicFile.write(plist_path, plist)
      launchctl("bootout", target)
      result = launchctl("bootstrap", domain, plist_path)
      return if result.success?

      FileUtils.rm_f(plist_path)
      raise ArgumentError, "launchctl bootstrap failed: #{result.err.strip}"
    end

    # launchd may no longer hold the label; the plist goes either way.
    def uninstall
      launchctl("bootout", target)
      FileUtils.rm_f(plist_path)
    end

    private

    def domain = "gui/#{@uid}"

    def target = "#{domain}/#{LABEL}"

    def launchctl(*args) = @runner.call(["launchctl", *args])

    def environment
      { "PATH" => @env["PATH"], "QM_ROOT" => (@root if @env.key?("QM_ROOT")) }.compact
    end

    def string(value) = "<string>#{value.to_s.encode(xml: :text)}</string>"
  end
end
