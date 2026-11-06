# frozen_string_literal: true

module Quartermaster
  # config.yml as an editable document: the Settings view and `qm config` both
  # load it, change it by dotted path or as a whole, check it (ConfigCheck)
  # and write it back. qm owns the written layout (header, ConfigSchema's
  # key order, `|` blocks for multi-line text); comments are dropped, keys
  # the schema doesn't govern are kept as they are. A write is atomic, keeps
  # the previous file as config.yml.bak and is refused when the file changed
  # since it was loaded.
  class ConfigFile
    HEADER = "# Edited by qm (Settings view / qm config); key reference: docs/overview.md"

    class Stale < StandardError
      def initialize(msg = "config.yml changed since it was loaded; reload and redo the change") = super
    end

    class Invalid < StandardError
      attr_reader :issues

      def initialize(issues)
        @issues = issues
        super(issues.map { |i| "#{i[:path]}: #{i[:message]}" }.join("; "))
      end
    end

    attr_reader :file, :text, :digest, :data, :parse_error

    def self.load(file = CONFIG_FILE, probe: ConfigCheck::Probe.new)
      text = begin
        File.read(file)
      rescue Errno::ENOENT
        ""
      end
      new(file, text, probe: probe)
    end

    def self.digest(text) = Digest::SHA256.hexdigest(text)

    # A `qm config set` value: YAML (`[dev, ngrok]` a list, `true` a bool,
    # `4` a number); text YAML can't read stays a string.
    def self.parse_value(text)
      value = YAML.safe_load(text.to_s)
      value.nil? && !text.to_s.strip.match?(/\A(~|null|Null|NULL)?\z/) ? text.to_s : value
    rescue Psych::Exception
      text.to_s
    end

    def initialize(file, text, probe: ConfigCheck::Probe.new)
      @file = file
      @text = text
      @digest = self.class.digest(text)
      @probe = probe
      @data = parse(text)
    end

    # The value at a dotted path, nil when absent; the whole mapping for "".
    def get(path)
      return @data if path.to_s.empty?

      pattern = ""
      ConfigSchema.segments(path).reduce(@data) do |node, key|
        shorthand = ConfigSchema::CONTAINERS.dig(pattern, :shorthand)
        node = { shorthand => node } if shorthand && node.is_a?(String)
        pattern = ConfigSchema.child(pattern, key) || "-"
        node.is_a?(Hash) ? node[key] : nil
      end
    end

    # Sets a schema-known path, creating mappings on the way and opening a
    # shorthand (a project's plain path, a dev_server's plain command) into
    # its mapping.
    def set(path, value)
      parent, key = walk_to_parent(path, create: true)
      parent[key] = value
      self
    end

    def unset(path)
      parent, key = walk_to_parent(path, create: false)
      parent&.delete(key)
      self
    end

    def replace(data)
      @parse_error = nil
      @data = data
      self
    end

    def issues = ConfigCheck.new(@data, parse_error: @parse_error, probe: @probe).issues

    def errors = issues.select { |i| i[:level] == "error" }

    def warnings = issues.select { |i| i[:level] == "warning" }

    # Writes the document if it has no errors and the file still holds the
    # text loaded with `digest`; returns the new digest.
    def write!(digest: @digest)
      found = errors
      raise Invalid, found unless found.empty?

      current = File.exist?(@file) ? File.read(@file) : ""
      raise Stale unless self.class.digest(current) == digest

      text = self.class.emit(@data)
      FileUtils.mkdir_p(File.dirname(@file))
      tmp = "#{@file}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
      File.write(tmp, text)
      File.write("#{@file}.bak", current) if File.exist?(@file)
      File.rename(tmp, @file)
      @text = text
      @digest = self.class.digest(text)
    ensure
      File.unlink(tmp) if tmp && File.exist?(tmp)
    end

    # The file text qm writes for a config mapping.
    def self.emit(data)
      tree = Psych::Visitors::YAMLTree.create(line_width: -1)
      tree << fresh(ordered(ConfigCheck.tidy(data), ""))
      ast = tree.tree
      ast.each { |node| style(node) }
      ast.children.first.implicit = true
      "#{HEADER}\n#{ast.yaml(nil, line_width: -1)}"
    end

    # A copy sharing no object, so the emitter never writes YAML aliases.
    def self.fresh(value)
      case value
      when Hash then value.to_h { |k, v| [fresh(k), fresh(v)] }
      when Array then value.map { |v| fresh(v) }
      when String then value.dup
      else value
      end
    end

    def self.style(node)
      case node
      when Psych::Nodes::Sequence
        plain = node.children.all? { |c| c.is_a?(Psych::Nodes::Scalar) && !c.value.include?("\n") }
        node.style = Psych::Nodes::Sequence::FLOW if plain && !node.children.empty?
      when Psych::Nodes::Scalar
        if node.value.include?("\n")
          node.style = Psych::Nodes::Scalar::LITERAL
        elsif node.style == Psych::Nodes::Scalar::DOUBLE_QUOTED && plain_path?(node.value)
          node.style = Psych::Nodes::Scalar::PLAIN
        end
      end
    end

    # Psych quotes every string starting with a non-word character; paths
    # and flags (/code/app, ~/x, -a) read back the same without quotes.
    def self.plain_path?(value)
      value.match?(%r{\A[-/~.\w][\w/.~+@:-]*(?: [\w/.~+@:-]+)*\z}) && !value.include?(": ") &&
        Psych::ScalarScanner.new(Psych::ClassLoader.new).tokenize(value) == value
    end

    # A mapping's keys in schema order (then any others in their own order);
    # a map's keys as the user ordered them; a project holding only its root
    # in its plain-path shorthand.
    def self.ordered(value, pattern)
      return value unless value.is_a?(Hash) && (pattern.empty? || ConfigSchema::CONTAINERS.key?(pattern))

      kind = pattern.empty? ? :object : ConfigSchema::CONTAINERS[pattern][:kind]
      keys = kind == :map ? value.keys : (ConfigSchema.order(pattern) & value.keys) + (value.keys - ConfigSchema.order(pattern))
      out = keys.to_h do |k|
        child = ConfigSchema.child(pattern, k.to_s)
        [k, child ? ordered(value[k], child) : value[k]]
      end
      return out["root"] if pattern == "projects.*" && out.keys == ["root"] && out["root"].is_a?(String)

      out
    end

    private

    def parse(text)
      @parse_error = nil
      data = YAML.safe_load(text)
      return {} if data.nil?
      return data if data.is_a?(Hash)

      @parse_error = "is not a mapping of keys"
      {}
    rescue Psych::Exception => e
      @parse_error = "is not valid YAML: #{e.message}"
      {}
    end

    def walk_to_parent(path, create:)
      parent = ConfigSchema.segments(path)[0..-2].join(".")
      known = ConfigSchema.known?(path) || (!create && ConfigSchema.container(parent))
      raise ArgumentError, "unknown config key: #{path}" unless known

      keys = ConfigSchema.segments(path)
      node = @data
      pattern = ""
      keys[0..-2].each_with_index do |key, index|
        pattern = ConfigSchema.child(pattern, key)
        child = node[key]
        shorthand = ConfigSchema::CONTAINERS.dig(pattern, :shorthand)
        child = { shorthand => child } if shorthand && child.is_a?(String)
        return [nil, nil] if !create && !child.is_a?(Hash)

        child = {} unless child.is_a?(Hash)
        node[key] = child
        node = child
      end
      [node, keys.last]
    end
  end
end
