# frozen_string_literal: true

module Quartermaster
  # A local automation's `when:` guard: a shell command run through the
  # runner in the automation's cwd, given 60 s. Each non-empty stdout line is
  # one item: a JSON object with a string `key` as it is, any other line as
  # { key: line, line: line }. A JSON object without a string key is refused
  # on its own; a non-zero exit or a timeout fails the whole guard.
  class AutomationGuard
    TIMEOUT = 60

    class Failed < ArgumentError; end

    def initialize(runner:)
      @runner = runner
    end

    # [items, problems]: problems are { "error", "item" } for refused lines.
    def run(command, cwd:)
      result = @runner.call(["sh", "-c", command], chdir: cwd, timeout: TIMEOUT)
      raise Failed, failure(result) unless result.success?

      self.class.parse(result.out)
    end

    def self.parse(out)
      out.to_s.each_line.map(&:strip).reject(&:empty?).each_with_object([[], []]) do |line, (items, problems)|
        object = line.start_with?("{") ? Quartermaster.json_object(line) : nil
        if object.nil?
          items << { "key" => line, "line" => line }
        elsif object["key"].is_a?(String) && !object["key"].strip.empty?
          items << object
        else
          problems << { "error" => "a guard's JSON item needs a string key", "item" => line }
        end
      end
    end

    private

    def failure(result)
      detail = result.err.to_s.strip.lines.last(3).join.strip
      detail = "exited non-zero with nothing on stderr" if detail.empty?
      "guard failed: #{detail[0, 300]}"
    end
  end
end
