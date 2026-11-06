# frozen_string_literal: true

module Quartermaster
  # The one way code reads config values: a reader over a mapping at a
  # ConfigSchema pattern ("" the top level, "projects.*" a project) hands out
  # the raw value of a key the schema lists there, or a reader one level down.
  # A shorthand opens into its mapping (a project given as a path is its
  # root); anything that isn't a mapping reads as an empty one. Asking for a
  # key the schema doesn't list is a bug in the asker: it raises while
  # QM_CONFIG_STRICT=1 (the tests) and otherwise logs to qm.log and reads nil.
  class ConfigReader
    class UnknownKey < StandardError; end

    STRICT_ENV = "QM_CONFIG_STRICT"

    def self.strict? = ENV[STRICT_ENV] == "1"

    # The dotted path read from, for messages ("projects.App").
    attr_reader :path

    def initialize(data, pattern = "", path = "")
      shorthand = ConfigSchema::CONTAINERS.dig(pattern, :shorthand)
      data = { shorthand => data } if shorthand && data.is_a?(String)
      @mapping = data.is_a?(Hash)
      @data = @mapping ? data : {}
      @pattern = pattern
      @path = path
    end

    def mapping? = @mapping

    # The raw value under a key the schema lists here, nil when unset.
    def [](key)
      known(key) ? @data[key.to_s] : nil
    end

    # A reader for the mapping under a key.
    def section(key) = self.class.new(known(key) ? @data[key.to_s] : nil, known(key) || "-", child_path(key))

    # A map's entries (projects, starters, models), in config order: name and
    # its reader.
    def entries
      @data.map do |key, value|
        name = key.to_s
        [name, self.class.new(value, known(name) || "-", child_path(name))]
      end
    end

    private

    def child_path(key) = @path.empty? ? key.to_s : "#{@path}.#{key}"

    def known(key)
      ConfigSchema.child(@pattern, key.to_s) || unknown(key)
    end

    def unknown(key)
      error = UnknownKey.new("config key #{child_path(key)} is not in ConfigSchema")
      raise error if self.class.strict?

      Quartermaster.log_error("config-read", error)
      nil
    end
  end
end
