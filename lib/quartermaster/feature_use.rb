# frozen_string_literal: true

module Quartermaster
  # Which features the user actually uses, so the dead ones can be found and
  # deleted: one line per GUI action, GUI read and CLI command in
  # feature-use.jsonl. Only the kind and the feature's name are kept — no
  # slugs, arguments or session ids. Append-only and best-effort: a failed
  # write is logged to qm.log and never reaches the request or command.
  class FeatureUse
    FILE = File.join(ROOT, "feature-use.jsonl")
    # The page polls these every second or so; a poll is not a use.
    POLLS = %w[/api/state /api/pulse].freeze
    KINDS = %w[action get cli].freeze

    def initialize(path: FILE, clock: -> { Time.now })
      @path = path
      @clock = clock
    end

    def record(kind, name)
      line = JSON.generate("v" => 1, "at" => @clock.call.utc.iso8601, "kind" => kind, "name" => name.to_s)
      begin
        File.open(@path, "a") { |f| f.write("#{line}\n") }
      rescue Errno::ENOENT
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") { |f| f.write("#{line}\n") }
      end
    rescue StandardError => e
      Quartermaster.log_error("feature-use", e)
    end

    # A GUI request that got past the loopback guard. /api/action is named
    # by its cmd, every other POST by its route; a GET by its route cut to
    # `/api/<word>`, so the slug, sha or session id after it never lands
    # in the log. Assets, the page itself and the polls are not uses.
    def request(method, route, body)
      return unless route.start_with?("/api/")

      if method == "POST"
        record("action", route == "/api/action" ? action_name(body) : route)
      elsif method == "GET" && !POLLS.include?(route)
        record("get", route[%r{\A/api/[^/]+}])
      end
    end

    # A `qm` run, by its command word. Hook commands and QM_SKIP runs (qm's
    # own headless subprocesses) are capture plumbing, not uses.
    def command(word)
      return if word.nil? || word.start_with?("hook-") || ENV["QM_SKIP"]

      record("cli", word)
    end

    # `qm feature-use [--days N]`: per kind, the names used in the window
    # (most-used first, with their last use), then the known names nobody
    # used in it. The log's first line dates how much history there is.
    def report(argv = [], days: 30)
      begin
        extra = OptionParser.new { |o| o.on("--days N", Integer) { |v| days = v } }.parse(argv)
        raise ArgumentError, "unexpected argument: #{extra.first} (did you mean --days #{extra.first}?)" if extra.any?
      rescue OptionParser::ParseError => e
        raise ArgumentError, e.message
      end
      raise ArgumentError, "--days must be positive" unless days.positive?

      all = uses
      since = @clock.call - (days * 86_400)
      window = all.select { |use| use[:at] >= since }
      lines = ["Feature use, last #{days} days (log starts #{all.empty? ? "— nothing logged yet" : date(all.first[:at])})"]
      KINDS.each do |kind|
        counted = tally(window.select { |use| use[:kind] == kind })
        total = counted.sum { |_, n, _| n }
        lines << "" << "#{kind} (#{total} use#{"s" unless total == 1})"
        counted.each { |name, n, last| lines << format("  %5d  %-24s last %s", n, name, date(last)) }
      end
      lines << "" << "Never used in the last #{days} days"
      KINDS.each do |kind|
        unused = self.class.known_names(kind) - window.select { |use| use[:kind] == kind }.map { |use| use[:name] }
        lines << "  #{kind}: #{unused.empty? ? "—" : unused.join(", ")}"
      end
      lines.join("\n")
    end

    # The names a kind can have, read from the code that dispatches them so
    # no second list can drift: GuiActions#dispatch's cmds plus Gui#respond's
    # other POST routes, Gui#respond's /api/ GET routes (polls left out), and
    # CLI.commands plus CLI#run's explicit branches (hooks and flag aliases left out).
    def self.known_names(kind)
      case kind
      when "action" then (branches(source("gui_actions.rb", /def dispatch\(.*?\n      else /m)) + gui_routes("POST")).uniq.sort
      when "get" then (gui_routes("GET") - POLLS).uniq.sort
      when "cli" then (CLI.commands.keys + cli_branches).reject { |w| w.start_with?("hook-", "-") }.uniq.sort
      else []
      end
    end

    def self.source(file, slice) = File.read(File.join(__dir__, file))[slice].to_s

    def self.branches(code) = code.scan(/^\s*when ((?:"[^"]+"(?:, )?)+) then/).flat_map { |(words)| words.scan(/"([^"]+)"/).flatten }

    # The command words CLI#run dispatches itself rather than through CLI.commands.
    def self.cli_branches = branches(source("cli.rb", /def run\(.*?\n      else\n/m))

    def self.gui_routes(method)
      code = source("gui.rb", /def respond\(.*?\n    end\n/m)
      code.scan(/method == "#{method}" && route(?: == "([^"]+)"|\.start_with\?\("([^"]+)"\))/)
          .map { |exact, prefix| (exact || prefix).delete_suffix("/") }
          .select { |route| route.start_with?("/api/") } - ["/api/action"]
    end

    private

    def uses
      return [] unless File.exist?(@path)

      File.foreach(@path).filter_map do |line|
        use = JSON.parse(line)
        { kind: use["kind"], name: use["name"], at: Time.iso8601(use["at"]) }
      rescue JSON::ParserError, ArgumentError, TypeError
        nil
      end
    end

    # [[name, count, last used]], most-used first, then by name.
    def tally(uses)
      uses.group_by { |use| use[:name] }
          .map { |name, group| [name, group.size, group.map { |use| use[:at] }.max] }
          .sort_by { |name, n, _| [-n, name] }
    end

    def date(time) = time.localtime.strftime("%Y-%m-%d")

    def action_name(body)
      payload = JSON.parse(body.to_s)
      payload.is_a?(Hash) ? payload["cmd"].to_s : ""
    rescue JSON::ParserError
      ""
    end
  end
end
