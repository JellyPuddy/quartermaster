# frozen_string_literal: true

module Quartermaster
  # A new tab in Warp's active window, in a directory and optionally running
  # a command. Tab configs (not launch configurations — those always open a
  # whole new window): TOML under ~/.warp/tab_configs/, opened by file stem
  # (matched case-insensitively; an absolute path is silently ignored).
  # QM_WARP_TAB_CONFIGS moves the directory (tests do).
  class WarpTab
    STEM = "qm-launch"

    def initialize(runner: CommandRunner.new)
      @runner = runner
    end

    def open(cwd, title, command: nil)
      dir = File.expand_path(ENV.fetch("QM_WARP_TAB_CONFIGS", "~/.warp/tab_configs"))
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "#{STEM}.toml"), <<~TOML)
        name = #{toml_string(title)}

        [[panes]]
        id = "main"
        type = "terminal"
        directory = #{toml_string(cwd)}
        #{command ? "commands = [#{toml_string(command)}]" : ""}
      TOML
      result = @runner.call(["open", "warp://tab_config/#{STEM}"])
      raise ArgumentError, "could not open a Warp tab (is Warp installed?)" unless result.success?

      "Opened Warp tab: #{title}"
    end

    private

    def toml_string(text)
      %("#{text.gsub("\\") { "\\\\" }.gsub('"') { '\"' }}")
    end
  end
end
