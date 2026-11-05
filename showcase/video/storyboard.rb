# frozen_string_literal: true

require "yaml"
require "json"
require "digest"

# The parsed, validated storyboard.yml: global settings plus scenes, and each
# scene's cache key. Pure Ruby, no ffmpeg, so the tests can load it alone.
module ShowcaseVideo
  # Bumped when render.rb changes how a scene is drawn, so cached scenes rebuild.
  RENDER_VERSION = 2

  DEFAULT_SETTINGS = {
    "voice" => "Daniel",
    "rate" => 180,
    "width" => 1920,
    "height" => 1080,
    "fps" => 30,
    "crossfade" => 0.6,
    "lead_in" => 0.4,
    "padding" => 0.9,
    "default_duration" => 4.0,
    "caption" => {
      "style" => "lower_third",
      "font" => "/System/Library/Fonts/HelveticaNeue.ttc",
      "title_font" => "/System/Library/Fonts/Avenir Next.ttc",
      "size" => 46,
      "title_size" => 96,
      "color" => "#ffffff",
      "bar" => "#0f172ae0",
      "accent" => "#f59e0b",
      "backdrop" => "#0b1020"
    }
  }.freeze

  # Settings that only the final stitch reads; changing them re-renders no scene.
  STITCH_ONLY_SETTINGS = %w[crossfade].freeze
  CAPTION_STYLES = %w[lower_third title].freeze
  SCENE_KEYS = %w[id visual focus caption voiceover duration style].freeze
  FRAME_KEYS = %w[file duration focus].freeze

  class Invalid < StandardError; end

  # One frame of a scene's visual: a PNG (relative to the out dir) shown for
  # `duration` seconds (nil: share what the scene has left), panning to `focus`.
  Frame = Struct.new(:file, :duration, :focus, keyword_init: true)

  class Scene
    attr_reader :id, :frames, :focus, :caption, :voiceover, :duration, :style, :fields

    def initialize(fields, settings, out_dir)
      @fields = fields
      @settings = settings
      @out_dir = out_dir
      @id = fields["id"]
      @focus = fields["focus"]
      @caption = fields["caption"]
      @voiceover = fields["voiceover"]
      @duration = fields["duration"]&.to_f
      @style = fields["style"] || settings.dig("caption", "style")
      @frames = Array(fields["visual"]).map do |v|
        v.is_a?(Hash) ? Frame.new(file: v["file"], duration: v["duration"]&.to_f, focus: v["focus"] || @focus) : Frame.new(file: v, focus: @focus)
      end
    end

    def visual_path(frame) = frame.file && File.join(@out_dir, frame.file)
    def missing_visuals = frames.reject { |f| File.file?(visual_path(f)) }.map(&:file)

    # Every input that changes this scene's pixels or sound, and nothing else:
    # its own fields, the scene-affecting settings and the visuals' bytes.
    def cache_key
      @cache_key ||= begin
        scene_settings = @settings.reject { |k, _| STITCH_ONLY_SETTINGS.include?(k) }
        visuals = frames.map do |f|
          path = visual_path(f)
          [f.file, File.file?(path) ? Digest::SHA256.file(path).hexdigest : "missing"]
        end
        payload = { "v" => RENDER_VERSION, "scene" => fields, "settings" => scene_settings, "visuals" => visuals }
        Digest::SHA256.hexdigest(JSON.generate(canonical(payload)))[0, 16]
      end
    end

    private

    def canonical(obj)
      case obj
      when Hash then obj.keys.sort.to_h { |k| [k, canonical(obj[k])] }
      when Array then obj.map { |o| canonical(o) }
      else obj
      end
    end
  end

  class Storyboard
    attr_reader :settings, :scenes, :out_dir

    def self.load(path, out_dir:)
      new(YAML.safe_load(File.read(path), aliases: false) || {}, out_dir: out_dir, source: path)
    rescue Psych::SyntaxError => e
      raise Invalid, "#{path}: #{e.message}"
    end

    def initialize(data, out_dir:, source: "storyboard")
      @out_dir = out_dir
      @errors = []
      raise Invalid, "#{source}: top level must be a mapping with settings and scenes" unless data.is_a?(Hash)

      @settings = merge_settings(data["settings"] || {})
      raw = data["scenes"]
      @errors << "scenes must be a non-empty list" unless raw.is_a?(Array) && !raw.empty?
      Array(raw).each_with_index { |s, i| validate_scene(s, i) }
      raise Invalid, "#{source} is invalid:\n  #{@errors.join("\n  ")}" unless @errors.empty?

      @scenes = raw.map { |s| Scene.new(s, @settings, out_dir) }
    end

    def scene(id) = scenes.find { |s| s.id == id }

    private

    def merge_settings(given)
      unless given.is_a?(Hash)
        @errors << "settings must be a mapping"
        return DEFAULT_SETTINGS
      end
      (given.keys - DEFAULT_SETTINGS.keys).each { |k| @errors << "settings: unknown key #{k}" }
      caption = given["caption"] || {}
      unless caption.is_a?(Hash)
        @errors << "settings.caption must be a mapping"
        caption = {}
      end
      @errors << "settings.voice must be a voice name" if given.key?("voice") && !given["voice"].is_a?(String)
      (caption.keys - DEFAULT_SETTINGS["caption"].keys).each { |k| @errors << "settings.caption: unknown key #{k}" }
      unless CAPTION_STYLES.include?(caption.fetch("style", "lower_third"))
        @errors << "settings.caption.style must be one of #{CAPTION_STYLES.join(', ')}"
      end
      %w[rate width height fps crossfade lead_in padding default_duration].each do |k|
        next unless given.key?(k)
        @errors << "settings.#{k} must be a non-negative number" unless given[k].is_a?(Numeric) && given[k] >= 0
      end
      DEFAULT_SETTINGS.merge(given).merge("caption" => DEFAULT_SETTINGS["caption"].merge(caption))
    end

    def validate_scene(scene, index)
      unless scene.is_a?(Hash)
        @errors << "scene ##{index + 1} must be a mapping"
        return
      end
      where = "scene #{scene['id'] || "##{index + 1}"}"
      (scene.keys - SCENE_KEYS).each { |k| @errors << "#{where}: unknown key #{k}" }
      id = scene["id"]
      if !id.is_a?(String) || !id.match?(/\A[a-z0-9][a-z0-9-]*\z/)
        @errors << "#{where}: id must be a lowercase slug (a-z, 0-9, -)"
      elsif (@seen ||= []).include?(id)
        @errors << "#{where}: duplicate id"
      else
        @seen << id
      end
      @errors << "#{where}: caption must be text" unless scene["caption"].is_a?(String) && !scene["caption"].strip.empty?
      @errors << "#{where}: voiceover must be text" if scene.key?("voiceover") && !scene["voiceover"].is_a?(String)
      @errors << "#{where}: duration must be a positive number" if scene.key?("duration") && !positive?(scene["duration"])
      if scene.key?("style") && !CAPTION_STYLES.include?(scene["style"])
        @errors << "#{where}: style must be one of #{CAPTION_STYLES.join(', ')}"
      end
      validate_focus(scene["focus"], where) if scene.key?("focus")
      validate_visual(scene["visual"], where)
    end

    def validate_visual(visual, where)
      case visual
      when String then validate_file(visual, where)
      when Array
        @errors << "#{where}: visual list is empty" if visual.empty?
        visual.each do |frame|
          if frame.is_a?(String) then validate_file(frame, where)
          elsif frame.is_a?(Hash)
            (frame.keys - FRAME_KEYS).each { |k| @errors << "#{where}: unknown visual key #{k}" }
            validate_file(frame["file"], where)
            @errors << "#{where}: frame duration must be a positive number" if frame.key?("duration") && !positive?(frame["duration"])
            validate_focus(frame["focus"], where) if frame.key?("focus")
          else @errors << "#{where}: each visual must be a path or {file, duration, focus}"
          end
        end
      else @errors << "#{where}: visual must be a PNG path or a list of them"
      end
    end

    def validate_file(file, where)
      return @errors << "#{where}: visual file missing" unless file.is_a?(String) && !file.empty?

      @errors << "#{where}: visual #{file} must be a .png relative to showcase/out" if file.start_with?("/") || file.include?("..") || !file.end_with?(".png")
    end

    def validate_focus(focus, where)
      ok = focus.is_a?(Array) && focus.size == 4 && focus.all?(Numeric) && focus[0] >= 0 && focus[1] >= 0 && focus[2].positive? && focus[3].positive?
      @errors << "#{where}: focus must be [x, y, w, h] in source pixels" unless ok
    end

    def positive?(value) = value.is_a?(Numeric) && value.positive?
  end
end
