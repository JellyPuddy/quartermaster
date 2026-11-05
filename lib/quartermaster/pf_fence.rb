# frozen_string_literal: true

module Quartermaster
  # The runner a GUI on a throwaway data root uses: the configured dev server
  # is the user's one real server whatever QM_ROOT says, so every dev-server
  # command that changes what it serves is refused here and never reaches the
  # wrapped runner. Reads (`<command> status`, the status URL) pass through.
  class PfFence
    def self.reason(root = ROOT) = "the dev server is off in this GUI: #{Quartermaster.shorten_home(root)} is not the live qm data root"

    # commands: the dev-server command names to fence; default every one
    # config.yml configures, read per call since the config can change.
    def initialize(runner, reason: PfFence.reason, commands: nil)
      @runner = runner
      @reason = reason
      @commands = commands
    end

    attr_reader :reason

    def call(argv, **options)
      return CommandRunner::Result.new(out: "", err: @reason, success: false) if changes_server?(argv)

      @runner.call(argv, **options)
    end

    private

    def changes_server?(argv)
      commands = @commands || ProjectConfig.current.dev_server_commands
      commands.map { |c| File.basename(c) }.include?(File.basename(argv.first.to_s)) && argv[1] != "status"
    end
  end
end
