# frozen_string_literal: true

module Quartermaster
  # The one validator of a config mapping, shared by the Settings view and
  # `qm config`: issues {level, path, message}. An error blocks a write (a
  # value of the wrong type, a key the schema doesn't list under a mapping
  # it governs, a setting that can't work); a warning never does (a folder or
  # command that isn't there on this machine right now).
  class ConfigCheck
    # What the warnings look at on this machine; tests pass a stub.
    class Probe
      def dir?(path) = File.directory?(path)

      def command?(name)
        return File.executable?(File.expand_path(name)) if name.include?("/")

        dirs = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR) + [CommandRunner::PERSONAL_BIN]
        dirs.any? { |dir| File.executable?(File.join(dir, name)) && !File.directory?(File.join(dir, name)) }
      end
    end

    TYPE_MESSAGES = {
      "string" => "must be text", "path" => "must be a path", "text" => "must be text",
      "bool" => "must be true or false", "number" => "must be a number",
      "string_list" => "must be a list of names, e.g. [dev, tunnel]",
      "argv" => "must be a command list, e.g. [open, -a, MyIDE, PATH]", "enum" => "must be text"
    }.freeze

    # The mapping as qm keeps it: under the keys the schema governs, unset
    # values (nil, blank text, empty lists) and emptied sub-mappings are
    # dropped, and a bare `projects:` is no projects; everything else is
    # untouched.
    def self.tidy(data, pattern = "")
      return data unless data.is_a?(Hash)

      data.each_with_object({}) do |(key, value), out|
        child = ConfigSchema.child(pattern, key.to_s)
        next out[key] = value unless child

        value = {} if value.nil? && child == "projects"
        value = tidy(value, child) if ConfigSchema::CONTAINERS.key?(child)
        kept = pattern.empty? ? key.to_s == "projects" : ConfigSchema::CONTAINERS.dig(pattern, :kind) == :map
        next if blank?(value) && !kept

        out[key] = value
      end
    end

    def self.blank?(value)
      value.nil? || (value.is_a?(String) && value.strip.empty?) || (value.respond_to?(:empty?) && value.empty?)
    end

    def initialize(data, parse_error: nil, probe: Probe.new)
      @data = data
      @parse_error = parse_error
      @probe = probe
    end

    def issues
      return [issue("error", "", "config.yml #{@parse_error}")] if @parse_error
      return [issue("error", "", "config must be a mapping of keys")] unless @data.is_a?(Hash)

      @issues = []
      data = self.class.tidy(@data)
      data.each do |key, value|
        child = ConfigSchema.child("", key.to_s)
        check_node(value, child, key.to_s) if child
      end
      check_projects(data["projects"]) if data["projects"].is_a?(Hash)
      check_globals(data)
      check_starters(data["loose_starters"]) if data["loose_starters"].is_a?(Hash)
      @issues
    end

    private

    def issue(level, path, message) = { level: level, path: path, message: message }

    def error(path, message) = @issues << issue("error", path, message)

    def warning(path, message) = @issues << issue("warning", path, message)

    def check_node(value, pattern, path)
      container = ConfigSchema::CONTAINERS[pattern]
      return check_type(ConfigSchema::BY_PATH.fetch(pattern), value, path) unless container

      value = { container[:shorthand] => value } if container[:shorthand] && value.is_a?(String)
      return error(path, container[:shorthand] ? "must be a mapping or a #{container[:shorthand]}" : "must be a mapping") unless value.is_a?(Hash)

      value.each do |key, child_value|
        child = ConfigSchema.child(pattern, key.to_s)
        next error("#{path}.#{key}", "unknown key #{key}") unless child

        check_node(child_value, child, "#{path}.#{key}")
      end
    end

    def check_type(key, value, path)
      ok = case key.type
           when "string", "path", "text", "enum" then value.is_a?(String)
           when "bool" then [true, false].include?(value)
           when "number" then value.is_a?(Numeric)
           when "string_list" then value.is_a?(String) || (value.is_a?(Array) && value.all? { |v| scalar?(v) })
           when "argv" then value.is_a?(Array) && value.all? { |v| scalar?(v) }
           end
      return error(path, TYPE_MESSAGES.fetch(key.type)) unless ok

      error(path, "must be one of: #{key.options.join(", ")}") if key.options && !key.options.include?(value.strip)
    end

    def scalar?(value) = value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(Symbol)

    def text?(value) = value.is_a?(String) && !value.strip.empty?

    def check_projects(projects)
      projects.each do |name, value|
        path = "projects.#{name}"
        value = { "root" => value } if value.is_a?(String)
        next unless value.is_a?(Hash)

        check_root(path, value["root"])
        check_dev_server("#{path}.dev_server", value["dev_server"])
        check_command("#{path}.test_db", value["test_db"])
        check_benchmark("#{path}.benchmark", value["benchmark"])
        check_ide(path, value)
        check_moved_links(path, value["epics"])
      end
    end

    # The link keys that moved from epics: to issue_links: still read there.
    def check_moved_links(path, epics)
      return unless epics.is_a?(Hash)

      %w[tracker_url notion_author notion_label].each do |key|
        warning("#{path}.epics.#{key}", "moved: set issue_links.#{key} instead") if text?(epics[key])
      end
    end

    def check_root(path, root)
      return if !root.nil? && !root.is_a?(String)
      return error("#{path}.root", "a project needs a root: its main repo's folder") unless text?(root)

      check_dir("#{path}.root", root)
    end

    def check_dev_server(path, server)
      server = { "command" => server } if server.is_a?(String)
      return unless server.is_a?(Hash)
      return error("#{path}.command", "dev_server needs a command") unless text?(server["command"])

      check_command("#{path}.command", server["command"])
      modes = server["modes"]
      modes = Array(modes).map(&:to_s).reject(&:empty?) if modes.is_a?(String) || modes.is_a?(Array)
      default = server["default_mode"]
      if text?(default) && modes.is_a?(Array) && !modes.empty? && !modes.include?(default.strip)
        error("#{path}.default_mode", "default_mode must be one of the modes: #{modes.join(", ")}")
      end
      check_dir("#{path}.state_file", File.dirname(server["state_file"].strip)) if text?(server["state_file"])
    end

    def check_benchmark(path, bench)
      return unless bench.is_a?(Hash)

      database = bench["database"]
      skill = bench["skill"]
      return error(path, "benchmark needs both database and skill") unless text?(database) && text?(skill)
      return error("#{path}.database", "database must be letters, digits and _ only") unless database.strip.match?(/\A\w+\z/)

      check_dir("#{path}.skill", skill)
    end

    def check_ide(path, value)
      prefix = path.empty? ? "" : "#{path}."
      command = value["ide_command"]
      if command.is_a?(Array) && command.all? { |v| scalar?(v) }
        if command.empty? || command.first.to_s.strip.empty?
          error("#{prefix}ide_command", "ide_command must start with a program")
        elsif command.none? { |arg| arg.to_s.include?(Ide::PLACEHOLDER) }
          error("#{prefix}ide_command", "ide_command needs a PATH element where the checkout's path goes")
        end
      end
      return unless text?(value["ide_label"]) && command.nil?

      warning("#{prefix}ide_label", "ide_label does nothing without ide_command")
    end

    def check_globals(data)
      check_ide("", data)
      default = data["default_project"]
      return unless text?(default)

      names = data["projects"].is_a?(Hash) ? data["projects"].keys.map(&:to_s) : []
      error("default_project", "default_project must name a project (#{names.join(", ")})") unless names.include?(default.strip)
    end

    def check_starters(starters)
      starters.each do |key, starter|
        next unless starter.is_a?(Hash)

        error("loose_starters.#{key}.prompt", "a loose-chat starter needs a prompt") unless text?(starter["prompt"])
      end
    end

    def check_command(path, command)
      return unless text?(command)

      name = command.strip.split(/\s+/).first
      warning(path, "#{name} is not on PATH") unless @probe.command?(name)
    end

    def check_dir(path, dir)
      expanded = File.expand_path(dir.strip)
      warning(path, "folder #{Quartermaster.shorten_home(expanded)} doesn't exist") unless @probe.dir?(expanded)
    rescue ArgumentError
      warning(path, "folder #{dir} doesn't exist")
    end
  end
end
