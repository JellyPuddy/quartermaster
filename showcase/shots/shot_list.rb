# frozen_string_literal: true

require "yaml"

# The parsed, validated shots.yml: which screenshots to take of the demo world
# and how to get the page there. Pure Ruby, no Chrome, so the tests can load it alone.
module ShowcaseShots
  class Invalid < StandardError; end

  SHOT_KEYS = %w[id url viewport scale theme mobile steps clip note].freeze
  STEP_KINDS = %w[key click hover eval wait_for wait].freeze
  THEMES = %w[light dark].freeze
  DEFAULT_URL = "{gui}/"
  DEFAULT_VIEWPORT = [1920, 1080].freeze
  DEFAULT_SCALE = 2
  # Named keys a `key` step can press, with their virtual key code and typed text;
  # any single character also works.
  KEYS = {
    "Enter" => [13, "\r"], "Escape" => [27, nil], "Tab" => [9, nil], "Backspace" => [8, nil],
    "ArrowDown" => [40, nil], "ArrowUp" => [38, nil], "ArrowLeft" => [37, nil], "ArrowRight" => [39, nil]
  }.freeze

  # One step: `kind` is one of STEP_KINDS; `arg` a key name (or list of them),
  # a CSS selector, a JS expression or seconds.
  Step = Struct.new(:kind, :arg, keyword_init: true)

  # A close-up: either a CSS selector (its bounding box, grown by `pad` CSS px)
  # or a fixed rect [x, y, w, h] in CSS px.
  Clip = Struct.new(:selector, :rect, :pad, keyword_init: true)

  class Shot
    attr_reader :id, :viewport, :scale, :theme, :mobile, :steps, :clip, :note

    def initialize(fields)
      @fields = fields
      @id = fields["id"]
      @url = fields["url"] || DEFAULT_URL
      @viewport = parse_viewport(fields["viewport"])
      @scale = fields["scale"] || DEFAULT_SCALE
      @theme = fields["theme"]
      @mobile = fields.fetch("mobile", @viewport[0] < 600)
      @steps = Array(fields["steps"]).flatten.each_with_index.map { |s, i| parse_step(s, i) }
      @clip = parse_clip(fields["clip"])
      @note = fields["note"]
      validate
    end

    # The URL with {gui} (the demo GUI's base URL) and {world} (the demo
    # world's directory, as a file:// path) filled in.
    def url(gui:, world:)
      @url.gsub("{gui}", gui.chomp("/")).gsub("{world}", "file://#{File.expand_path(world)}")
    end

    def file_name = "#{id}.png"

    private

    def fail!(message) = raise(Invalid, "shot #{@id.inspect}: #{message}")

    def validate
      fail!("unknown keys #{(@fields.keys - SHOT_KEYS).join(', ')}") unless (@fields.keys - SHOT_KEYS).empty?
      fail!("id must be a lowercase slug") unless @id.is_a?(String) && @id.match?(/\A[a-z0-9][a-z0-9-]*\z/)
      fail!("url must be text") unless @url.is_a?(String)
      fail!("scale must be a number from 1 to 4") unless @scale.is_a?(Numeric) && @scale.between?(1, 4)
      fail!("theme must be one of #{THEMES.join(', ')}") if @theme && !THEMES.include?(@theme)
      fail!("mobile must be true or false") unless [true, false].include?(@mobile)
    end

    def parse_viewport(value)
      return DEFAULT_VIEWPORT if value.nil?

      dims = case value
             when /\A(\d+)x(\d+)\z/ then [Regexp.last_match(1).to_i, Regexp.last_match(2).to_i]
             when Array then value
             end
      fail!("viewport must be WxH or [w, h]") unless dims&.size == 2 && dims.all? { |d| d.is_a?(Integer) && d.positive? }
      dims
    end

    def parse_step(step, index)
      fail!("step #{index + 1} must be a mapping with one of #{STEP_KINDS.join(', ')}") unless step.is_a?(Hash) && step.size == 1

      kind, arg = step.first
      fail!("step #{index + 1}: unknown step #{kind.inspect}") unless STEP_KINDS.include?(kind)
      ok = case kind
           when "wait" then arg.is_a?(Numeric) && arg.positive?
           when "key" then !Array(arg).empty? && Array(arg).all? { |k| k.is_a?(String) && (k.size == 1 || KEYS.key?(k)) }
           else arg.is_a?(String) && !arg.strip.empty?
           end
      fail!("step #{index + 1}: bad #{kind} value #{arg.inspect}") unless ok
      Step.new(kind: kind, arg: arg)
    end

    def parse_clip(value)
      case value
      when nil then nil
      when String then Clip.new(selector: value, pad: 0)
      when Array
        fail!("clip rect must be [x, y, w, h]") unless value.size == 4 && value.all?(Numeric) && value[2].positive? && value[3].positive?
        Clip.new(rect: value)
      when Hash
        fail!("clip needs a selector") unless value["selector"].is_a?(String)
        fail!("clip takes selector and pad") unless (value.keys - %w[selector pad]).empty?
        Clip.new(selector: value["selector"], pad: value.fetch("pad", 0))
      else fail!("clip must be a selector, {selector, pad} or [x, y, w, h]")
      end
    end
  end

  class ShotList
    attr_reader :shots

    def self.load(path) = new(YAML.safe_load_file(path, aliases: true))

    def initialize(data)
      raise Invalid, "shots.yml must have a `shots` list" unless data.is_a?(Hash) && data["shots"].is_a?(Array)

      @shots = data["shots"].map do |fields|
        raise Invalid, "every shot must be a mapping" unless fields.is_a?(Hash)

        Shot.new(fields)
      end
      dupes = @shots.map(&:id).tally.select { |_, n| n > 1 }.keys
      raise Invalid, "duplicate shot ids: #{dupes.join(', ')}" unless dupes.empty?
    end

    def find(id) = @shots.find { |s| s.id == id } || raise(Invalid, "no shot #{id.inspect}; --list shows them")
  end
end
