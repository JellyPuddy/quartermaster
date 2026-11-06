# frozen_string_literal: true

module Quartermaster
  # `qm config`: config.yml by dotted path, through ConfigFile, so it refuses
  # exactly what the Settings view refuses. Errors go to stderr, exit 1 and
  # write nothing; warnings go to stderr and the write happens.
  module CliConfig
    COMMANDS = { "config" => :cmd_config }.freeze

    CONFIG_USAGE = "usage: qm config get [PATH] | set PATH VALUE | unset PATH | path  " \
                   "(PATH dotted, e.g. projects.App.test_db; VALUE is YAML: [dev, ngrok], true, 4)"

    private

    def cmd_config(argv)
      sub, path, *rest = argv
      case sub
      when "path" then puts CONFIG_FILE
      when "get" then config_get(path)
      when "set"
        abort(CONFIG_USAGE) if path.nil? || rest.empty?
        config_set(path, ConfigFile.parse_value(rest.join(" ")))
      when "unset"
        abort(CONFIG_USAGE) unless path
        config_unset(path)
      else abort(CONFIG_USAGE)
      end
    end

    # A scalar prints bare (a shell can use it); a subtree as YAML; an unset
    # key prints nothing and exits 1.
    def config_get(path)
      config = ConfigFile.load
      return print(config.text) if path.nil? || path.empty?
      raise ArgumentError, "unknown config key: #{path}" unless ConfigSchema.known?(path)

      config_refuse(config.errors) if config.parse_error
      value = config.get(path)
      exit(1) if value.nil?
      value.is_a?(Hash) || value.is_a?(Array) ? print(ConfigFile.dump(value)) : puts(value)
    end

    def config_set(path, value)
      config = ConfigFile.load.set(path, value)
      config_write(config, path)
      print ConfigFile.dump({ path => value })
    end

    def config_unset(path)
      config = ConfigFile.load
      present = config.parse_error || !config.get(path).nil?
      config.unset(path)
      return puts("#{path} is not set") unless present

      config_write(config, path)
      return unless ConfigSchema.container(path) == "projects.*"

      name = ConfigSchema.segments(path).last
      count = WorkItem.all.count { |item| item.project == name }
      return if count.zero?

      warn "qm: warning: #{count == 1 ? "1 work item still has" : "#{count} work items still have"} project #{name} " \
           "(qm move SLUG PROJECT reassigns one)"
    end

    # Writes, or prints every error and exits 1; warnings about the changed
    # path go to stderr either way.
    def config_write(config, path)
      config_refuse(config.errors)
      config.write!
      config.warnings.select { |i| config_related?(i[:path], path) }.each { |i| warn "qm: warning: #{config_issue(i)}" }
    rescue ConfigFile::Stale => e
      abort("qm: #{e.message}")
    end

    def config_refuse(errors)
      return if errors.empty?

      errors.each { |i| warn "qm: error: #{config_issue(i)}" }
      exit 1
    end

    def config_issue(issue) = issue[:path].empty? ? issue[:message] : "#{issue[:path]}: #{issue[:message]}"

    def config_related?(issue_path, path)
      [[issue_path, path], [path, issue_path]].any? { |a, b| a == b || a.start_with?("#{b}.") }
    end
  end
end
