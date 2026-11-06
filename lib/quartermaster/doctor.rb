# frozen_string_literal: true

module Quartermaster
  # `qm doctor`: is qm wired up and capturing? Each check is one line marked
  # ✓ (fine), ! (works, but worth knowing) or ✗ (broken, with how to fix it).
  # Reads only; it writes nothing.
  class Doctor
    SETTINGS_FILE = File.expand_path(ENV.fetch("QM_CLAUDE_SETTINGS", "~/.claude/settings.json"))
    # The events `qm install-hooks` hands to hooks/record-event.sh.
    RECORD_EVENTS = %w[UserPromptSubmit PermissionRequest Stop StopFailure PostToolUseFailure PostToolUse].freeze
    QUIET_AFTER = 24 * 3600
    OK = "✓"
    WARN = "!"
    FAIL = "✗"
    INSTALL_HINT = "merge the snippet `qm install-hooks` prints"

    Check = Struct.new(:mark, :name, :detail, :hint) do
      def line = "#{mark} #{name}: #{detail}#{" — #{hint}" if hint && mark != OK}"
    end

    def initialize(settings_path: SETTINGS_FILE, pin: RubyPin.new, ruby_version: RUBY_VERSION, now: Time.now)
      @settings_path = settings_path
      @pin = pin
      @ruby_version = ruby_version
      @now = now
    end

    def checks
      @checks ||= [*hook_checks, pin_check, floor_check, root_check, errors_check, capture_check]
    end

    def failed? = checks.any? { |check| check.mark == FAIL }

    private

    def hook_checks
      hooks = JSON.parse(File.read(@settings_path)).fetch("hooks", {})
      [session_hook(hooks, "SessionStart", "hook-session-start"),
       session_hook(hooks, "SessionEnd", "hook-session-end"),
       record_event_hook(hooks)]
    rescue StandardError => e
      ["SessionStart hook", "SessionEnd hook", "record-event.sh hook"].map do |name|
        Check.new(FAIL, name, "can't read #{@settings_path} (#{e.class})", INSTALL_HINT)
      end
    end

    def session_hook(hooks, event, word)
      name = "#{event} hook"
      words = commands(hooks, event).map(&:split).find { |argv| argv.include?(word) }
      return Check.new(FAIL, name, "not registered in #{@settings_path}", INSTALL_HINT) unless words

      file_check(name, File.expand_path(words.first))
    end

    def record_event_hook(hooks)
      name = "record-event.sh hook"
      found = RECORD_EVENTS.to_h do |event|
        [event, commands(hooks, event).map { |cmd| cmd.split.first.to_s }.find { |file| File.basename(file) == "record-event.sh" }]
      end
      missing = found.select { |_, file| file.nil? }.keys
      return Check.new(FAIL, name, "not registered on #{missing.join(", ")}", INSTALL_HINT) if missing.any?

      found.values.map { |file| File.expand_path(file) }.uniq
           .map { |file| file_check(name, file) }
           .find { |check| check.mark == FAIL } || Check.new(OK, name, "on all #{RECORD_EVENTS.size} events")
    end

    def commands(hooks, event)
      Array(hooks[event]).flat_map { |group| Array(group.is_a?(Hash) ? group["hooks"] : nil) }
                         .filter_map { |hook| hook["command"] if hook.is_a?(Hash) }
    end

    def file_check(name, file)
      return Check.new(OK, name, file) if File.exist?(file)

      Check.new(FAIL, name, "points at #{file}, which does not exist", INSTALL_HINT)
    end

    def pin_check
      version = @pin.version
      unless version
        return Check.new(WARN, "Ruby pin", "none, so hooks run on whatever Ruby each project pins",
                         "`qm pin-ruby` pins the one running now")
      end
      unless RubyFloor.met?(version)
        return Check.new(FAIL, "Ruby pin", "#{version} is below the #{RubyFloor::FLOOR} floor", "`qm pin-ruby` a newer one")
      end
      unless @pin.installed?(version)
        return Check.new(FAIL, "Ruby pin", "#{version} is not installed",
                         "`asdf install ruby #{version}`, or `qm pin-ruby --clear`")
      end

      Check.new(OK, "Ruby pin", version)
    end

    def floor_check
      detail = "#{@ruby_version} (floor #{RubyFloor::FLOOR})"
      return Check.new(OK, "Ruby floor", detail) if RubyFloor.met?(@ruby_version)

      Check.new(FAIL, "Ruby floor", detail, "`qm pin-ruby` one at or above the floor")
    end

    def root_check
      return Check.new(OK, "Data root", ROOT) if File.directory?(ROOT) && File.writable?(ROOT)

      Check.new(FAIL, "Data root", "#{ROOT} is missing or not writable", "create it and make it writable for you")
    end

    def errors_check
      errors = ErrorLog.new(now: @now)
      since = errors.since.localtime.strftime("%Y-%m-%d %H:%M")
      return Check.new(OK, "qm.log errors", "none since #{since}") if errors.count.zero?

      Check.new(WARN, "qm.log errors",
                "#{errors.count} error#{"s" unless errors.count == 1} since #{since}, last: #{errors.entries.last["lines"].first}",
                "details in #{LOG_FILE}")
    end

    def capture_check
      last = [last_session_event, EventLog.new.last_ts].filter_map { |ts| parse_time(ts) }.max
      hint = "capture may have stopped: check the asdf global Ruby (~/.tool-versions), then #{LOG_FILE}"
      return Check.new(WARN, "Capture", "nothing captured yet", hint) unless last

      detail = "last event #{last.localtime.strftime("%Y-%m-%d %H:%M")}"
      Check.new(@now - last > QUIET_AFTER ? WARN : OK, "Capture", detail, hint)
    end

    def last_session_event
      SessionLog.new.events.reverse.find { |event| event["event"] != "dismissed" }&.dig("ts")
    end

    def parse_time(ts)
      Time.iso8601(ts.to_s)
    rescue ArgumentError
      nil
    end
  end
end
