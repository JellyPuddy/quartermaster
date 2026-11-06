# frozen_string_literal: true

module Quartermaster
  # The IDE "Open in <label>" launches: config.yml's `ide_command:` (an argv
  # array with a literal PATH placeholder) and `ide_label:`, globally or per
  # project. An argv element that is exactly PATH becomes the checkout's path;
  # PATH inside a longer element (a `sh -c` script) becomes the shell-escaped
  # path. Unset or malformed — no PATH anywhere — means no IDE.
  class Ide
    PLACEHOLDER = "PATH"
    DEFAULT_LABEL = "IDE"
    # What "no IDE" messages tell the user to run.
    CONFIG_COMMAND = "qm config set ide_command '[open, -a, <IDE>, PATH]'"

    attr_reader :command, :label

    def self.parse(command, label)
      return nil unless command.is_a?(Array) && !command.empty?
      return nil unless command.all? { |arg| arg.is_a?(String) || arg.is_a?(Symbol) || arg.is_a?(Numeric) }

      command = command.map(&:to_s)
      return nil if command.first.strip.empty? || command.none? { |arg| arg.include?(PLACEHOLDER) }

      label = label.is_a?(String) && !label.strip.empty? ? label.strip : DEFAULT_LABEL
      new(command, label)
    end

    def initialize(command, label)
      @command = command
      @label = label
    end

    def argv(path)
      command.map { |arg| arg == PLACEHOLDER ? path : arg.gsub(PLACEHOLDER) { Shellwords.escape(path) } }
    end

    def to_h = { "label" => label, "command" => command }
  end
end
