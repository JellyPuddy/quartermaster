# frozen_string_literal: true

# Loaded by the launcher before the rest of lib/, so this file must parse and
# run on the old Ruby it reports: Ruby 2.x syntax only, no stdlib requires.
module Quartermaster
  module RubyFloor
    FLOOR = "3.3"
    CONTEXT = "ruby-floor"

    # Below the floor: one qm.log line, stderr too for a command the user typed,
    # stdout never (SessionStart's stdout is Claude's context). A hook exits 0
    # so the session carries on uncaptured; any other command exits 1.
    def self.enforce(command, version: RUBY_VERSION, ruby: current_ruby)
      return if met?(version)

      message = "qm needs Ruby >= #{FLOOR}, got #{version} (#{ruby}); pin one with qm pin-ruby"
      log(message)
      hook = command.to_s.start_with?("hook-")
      warn("[#{CONTEXT}] #{message}") unless hook
      exit(hook ? 0 : 1)
    end

    def self.met?(version)
      (segments(version) <=> segments(FLOOR)) >= 0
    end

    def self.segments(version)
      version.to_s.split(".").map(&:to_i)
    end

    def self.current_ruby
      require "rbconfig"
      RbConfig.ruby
    rescue StandardError, LoadError
      "ruby"
    end

    def self.log(message)
      root = File.expand_path(ENV["QM_ROOT"] || "~/.claude/quartermaster")
      Dir.mkdir(root) unless File.directory?(root)
      stamp = Time.now.strftime("%Y-%m-%dT%H:%M:%S%:z")
      File.open(File.join(root, "qm.log"), "a") { |f| f.puts("#{stamp} [#{CONTEXT}] #{message}") }
    rescue StandardError
      nil
    end
  end
end
