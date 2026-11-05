#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders showcase/video/storyboard.yml into showcase/out/video/qm-overview.mp4.
#   ruby showcase/video/render.rb               render every scene (cached) and stitch
#   ruby showcase/video/render.rb --scene <id>  render one scene, print its mp4 path
#   ruby showcase/video/render.rb --list        scenes, cache status and durations
require "open3"
require "fileutils"
require "optparse"
require "tmpdir"
require_relative "storyboard"

module ShowcaseVideo
  SHOWCASE = File.expand_path("..", __dir__)
  TOOLS = %w[ffmpeg ffprobe magick say].freeze

  # Draws scenes into a hash-keyed cache and stitches them with crossfades.
  class Renderer
    CLOSEUP_FADE = 0.5
    CLOSEUP_MIN = 2.5 # seconds a frame needs before it gets a close-up

    def initialize(storyboard, video_dir:, log: $stderr)
      @board = storyboard
      @s = storyboard.settings
      @cap = @s["caption"]
      @video_dir = video_dir
      @cache = File.join(video_dir, "cache")
      @log = log
    end

    def output_path = File.join(@video_dir, "qm-overview.mp4")
    def cached_path(scene) = File.join(@cache, "#{scene.id}-#{scene.cache_key}.mp4")
    def cached?(scene) = File.file?(cached_path(scene))

    def duration_of(scene)
      meta = "#{cached_path(scene).delete_suffix('.mp4')}.json"
      return JSON.parse(File.read(meta))["duration"] if File.file?(meta)

      scene.voiceover ? nil : planned_duration(scene, 0)
    end

    def render_all
      scenes = @board.scenes.map { |sc| [render_scene(sc), duration_of(sc)] }
      stitch(scenes)
      output_path
    end

    def render_scene(scene)
      path = cached_path(scene)
      if File.file?(path)
        @log.puts "  #{scene.id}: cached"
        return path
      end
      @log.puts "  #{scene.id}: rendering#{" (placeholder for #{scene.missing_visuals.join(', ')})" unless scene.missing_visuals.empty?}"
      FileUtils.mkdir_p(@cache)
      Dir.mktmpdir("qm-scene-") do |work|
        audio = scene.voiceover && speak(scene.voiceover, work)
        audio_len = audio ? probe_duration(audio) : 0
        total = planned_duration(scene, audio_len)
        tmp = File.join(work, "scene.mp4")
        draw_scene(scene, work, audio, total, tmp)
        actual = probe_duration(tmp)
        File.write("#{path.delete_suffix('.mp4')}.json", JSON.generate("id" => scene.id, "duration" => actual))
        FileUtils.mv(tmp, path)
      end
      path
    end

    private

    # With a voiceover the speech (plus lead-in and padding) sets the length,
    # never shorter than an explicit duration or the frames' own durations.
    def planned_duration(scene, audio_len)
      base = scene.voiceover ? @s["lead_in"] + audio_len + @s["padding"] : (scene.duration || @s["default_duration"])
      base = [base, scene.duration].max if scene.duration
      fixed = scene.frames.sum { |f| f.duration || 0 }
      [base, fixed + scene.frames.count { |f| f.duration.nil? } * 1.0].max
    end

    def frame_durations(scene, total)
      fixed = scene.frames.sum { |f| f.duration || 0 }
      open = scene.frames.count { |f| f.duration.nil? }
      share = open.zero? ? 0 : (total - fixed) / open
      durations = scene.frames.map { |f| f.duration || share }
      durations[-1] += total - durations.sum # the last frame absorbs any rest
      durations
    end

    def speak(text, work)
      out = File.join(work, "voice.aiff")
      run("say", "-v", @s["voice"], "-r", @s["rate"].to_s, "-o", out, text)
      out
    end

    def draw_scene(scene, work, audio, total, out)
      w, h, fps = @s.values_at("width", "height", "fps")
      inputs = []
      filters = []
      still = ->(png, len) { inputs += ["-loop", "1", "-framerate", fps.to_s, "-t", format("%.3f", len), "-i", png] }
      prep = ->(idx) { "[#{idx}:v]scale=#{w}:#{h},format=yuv444p,setsar=1" }
      frame_durations(scene, total).each_with_index do |dur, i|
        full, closeup = stills_for(scene, scene.frames[i], work, i)
        a = inputs.count("-i")
        if closeup && dur >= CLOSEUP_MIN
          held = (dur * 0.4).clamp(1.0, 3.0)
          still.(full, held + CLOSEUP_FADE)
          still.(closeup, dur - held)
          filters << "#{prep.(a)}[a#{i}];#{prep.(a + 1)}[b#{i}];" \
                     "[a#{i}][b#{i}]xfade=transition=fade:duration=#{CLOSEUP_FADE}:offset=#{format('%.3f', held)}[f#{i}]"
        else
          still.(full, dur)
          filters << "#{prep.(a)}[f#{i}]"
        end
      end
      count = scene.frames.size
      cap_in = inputs.count("-i")
      bg = count == 1 ? "[f0]" : "[bg]"
      filters << "#{(0...count).map { |i| "[f#{i}]" }.join}concat=n=#{count}:v=1:a=0[bg]" if count > 1
      caption = caption_png(scene, work)
      inputs += ["-loop", "1", "-t", format("%.3f", total), "-i", caption]
      fade_at = scene.style == "title" ? 0.15 : 0.35
      filters << "[#{cap_in}:v]format=rgba,fade=t=in:st=#{fade_at}:d=0.45:alpha=1[cap]"
      filters << "#{bg}[cap]overlay=0:0:shortest=1,format=yuv420p[v]"
      if audio
        inputs += ["-i", audio]
        filters << "[#{cap_in + 1}:a]aresample=48000,aformat=channel_layouts=stereo," \
                   "adelay=#{(@s['lead_in'] * 1000).round}:all=1,apad,atrim=0:#{format('%.3f', total)}[a]"
      else
        inputs += ["-f", "lavfi", "-t", format("%.3f", total), "-i", "anullsrc=r=48000:cl=stereo"]
        filters << "[#{cap_in + 1}:a]anull[a]"
      end
      run("ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", filters.join(";"),
          "-map", "[v]", "-map", "[a]", "-t", format("%.3f", total), "-r", fps.to_s,
          *encode_args, out)
    end

    def encode_args
      %w[-c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k -ar 48000 -movflags +faststart]
    end

    # The frame as a still at output size, and with a focus rect also a still
    # close-up of it (cut from the 2x canvas, so it stays sharp).
    def stills_for(scene, frame, work, index)
      w, h = @s.values_at("width", "height")
      canvas, focus = canvas_for(scene, frame, work, index)
      full = File.join(work, "full-#{index}.png")
      run("magick", canvas, "-resize", "#{w}x#{h}!", full)
      return [full, nil] unless focus

      closeup = File.join(work, "closeup-#{index}.png")
      x, y, cw, ch = closeup_rect(focus, w * 2, h * 2)
      run("magick", canvas, "-crop", "#{cw}x#{ch}+#{x}+#{y}", "+repage", "-resize", "#{w}x#{h}!", closeup)
      [full, closeup]
    end

    # The focus rect padded a little and widened to the output's aspect ratio,
    # kept inside the canvas.
    def closeup_rect(focus, canvas_w, canvas_h)
      fx, fy, fw, fh = focus
      aspect = canvas_w.to_f / canvas_h
      cw = [fw * 1.08, fh * 1.08 * aspect].max.clamp(canvas_w / 2.4, canvas_w)
      ch = cw / aspect
      x = (fx + fw / 2 - cw / 2).clamp(0, canvas_w - cw)
      y = (fy + fh / 2 - ch / 2).clamp(0, canvas_h - ch)
      [x, y, cw, ch].map(&:round)
    end

    # The frame fitted onto a canvas twice the output size, and its focus rect
    # mapped into canvas pixels.
    def canvas_for(scene, frame, work, index)
      cw = @s["width"] * 2
      ch = @s["height"] * 2
      out = File.join(work, "canvas-#{index}.png")
      src = scene.visual_path(frame)
      unless File.file?(src)
        placeholder(scene, frame, out, cw, ch)
        return [out, nil]
      end
      iw, ih = run("magick", "identify", "-format", "%w %h", "#{src}[0]").split.map(&:to_i)
      scale = [cw.to_f / iw, ch.to_f / ih].min
      sw = (iw * scale).round
      sh = (ih * scale).round
      ox = (cw - sw) / 2
      oy = (ch - sh) / 2
      run("magick", "#{src}[0]", "-resize", "#{sw}x#{sh}!", "-background", @cap["backdrop"],
          "-gravity", "center", "-extent", "#{cw}x#{ch}", out)
      focus = frame.focus && [ox + frame.focus[0] * scale, oy + frame.focus[1] * scale,
                              frame.focus[2] * scale, frame.focus[3] * scale]
      [out, focus]
    end


    def placeholder(scene, frame, out, cw, ch)
      text = File.join(File.dirname(out), "placeholder-#{File.basename(out, '.png')}.txt")
      File.write(text, scene.caption)
      run("magick", "-size", "#{cw}x#{ch}", "gradient:#1e293b-#0b1020",
          "-fill", "none", "-stroke", "#475569", "-strokewidth", "6",
          "-draw", "roundrectangle 120,120 #{cw - 120},#{ch - 120} 40,40", "-stroke", "none",
          "-font", @cap["font"], "-fill", @cap["accent"], "-pointsize", "64",
          "-gravity", "north", "-annotate", "+0+260", "MISSING SHOT  #{frame.file.gsub('%', '%%')}",
          "-font", @cap["title_font"], "-fill", "#e2e8f0", "-pointsize", "200",
          "-annotate", "+0+520", scene.id.gsub("%", "%%"),
          "(", "-size", "#{cw - 600}x", "-background", "none", "-fill", "#94a3b8",
          "-font", @cap["font"], "-pointsize", "80", "-gravity", "center", "caption:@#{text}", ")",
          "-gravity", "center", "-geometry", "+0+160", "-composite", out)
    end

    # The caption as a full-frame transparent PNG: a lower-third bar with an
    # accent edge, or a title card over a darkened frame.
    def caption_png(scene, work)
      w, h = @s.values_at("width", "height")
      text = File.join(work, "caption.txt")
      File.write(text, scene.caption)
      out = File.join(work, "caption.png")
      if scene.style == "title"
        run("magick", "-size", "#{w}x#{h}", "xc:#{@cap['backdrop']}c8",
            "(", "-size", "#{(w * 0.75).round}x", "-background", "none", "-fill", @cap["color"],
            "-font", @cap["title_font"], "-pointsize", @cap["title_size"].to_s, "-gravity", "center",
            "caption:@#{text}", ")", "-gravity", "center", "-composite",
            "-fill", @cap["accent"], "-draw", "rectangle #{w / 2 - 60},#{h - 300} #{w / 2 + 60},#{h - 292}", out)
      else
        run("magick", "-size", "#{w}x#{h}", "xc:none",
            "(", "-size", "#{(w * 0.72).round}x", "-background", "none", "-fill", @cap["color"],
            "-font", @cap["font"], "-pointsize", @cap["size"].to_s, "caption:@#{text}", "-trim", "+repage",
            "-background", @cap["bar"], "-flatten", "-bordercolor", @cap["bar"], "-border", "44x30",
            "-background", @cap["accent"], "-gravity", "west", "-splice", "10x0", ")",
            "-gravity", "southwest", "-geometry", "+96+84", "-composite", out)
      end
      out
    end

    def stitch(scenes)
      xf = @s["crossfade"].to_f
      inputs = scenes.flat_map { |path, _| ["-i", path] }
      filters = []
      v = "[0:v]"
      a = "[0:a]"
      offset = 0.0
      (1...scenes.size).each do |i|
        offset += scenes[i - 1][1] - xf
        filters << "#{v}[#{i}:v]xfade=transition=fade:duration=#{xf}:offset=#{format('%.3f', offset)}[v#{i}]"
        filters << "#{a}[#{i}:a]acrossfade=d=#{xf}[a#{i}]"
        v = "[v#{i}]"
        a = "[a#{i}]"
      end
      stamp = JSON.generate("v" => RENDER_VERSION, "scenes" => scenes, "crossfade" => xf, "fps" => @s["fps"])
      stamp_file = File.join(@video_dir, ".qm-overview.stamp")
      if File.file?(output_path) && File.file?(stamp_file) && File.read(stamp_file) == stamp
        @log.puts "  #{File.basename(output_path)} is up to date"
        return
      end
      total = scenes.sum { |_, d| d } - xf * (scenes.size - 1)
      out_at = format("%.3f", [total - 0.8, 0].max)
      filters << "#{v}fade=t=in:st=0:d=0.6,fade=t=out:st=#{out_at}:d=0.8,format=yuv420p[v]"
      filters << "#{a}afade=t=in:st=0:d=0.4,afade=t=out:st=#{out_at}:d=0.8[a]"
      FileUtils.mkdir_p(@video_dir)
      @log.puts "  stitching #{scenes.size} scenes (#{total.round(1)}s)"
      tmp = File.join(@video_dir, ".qm-overview.tmp.mp4")
      run("ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", filters.join(";"),
          "-map", "[v]", "-map", "[a]", "-r", @s["fps"].to_s, *encode_args, tmp)
      FileUtils.mv(tmp, output_path)
      File.write(stamp_file, stamp)
    end

    def probe_duration(path)
      run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path).to_f
    end

    def run(*cmd)
      out, err, status = Open3.capture3(*cmd)
      raise "#{cmd.first} failed (#{status.exitstatus}): #{err.lines.last(8).join}" unless status.success?

      out
    end
  end

  def self.cli(argv)
    storyboard = File.join(__dir__, "storyboard.yml")
    out_dir = File.join(SHOWCASE, "out")
    mode = :all
    scene_id = nil
    OptionParser.new do |o|
      o.banner = "usage: render.rb [--list | --scene ID] [--storyboard PATH]"
      o.on("--list", "list scenes with cache status and durations") { mode = :list }
      o.on("--scene ID", "render one scene and print its mp4 path") { |id| mode = :scene; scene_id = id }
      o.on("--storyboard PATH") { |p| storyboard = File.expand_path(p) }
    end.parse!(argv)
    board = Storyboard.load(storyboard, out_dir: out_dir)
    renderer = Renderer.new(board, video_dir: File.join(out_dir, "video"))
    case mode
    when :list
      board.scenes.each do |sc|
        dur = renderer.duration_of(sc)
        state = renderer.cached?(sc) ? "cached" : "stale "
        shots = sc.missing_visuals.empty? ? "" : "  (missing: #{sc.missing_visuals.join(', ')})"
        puts format("%-22s %s  %8s%s", sc.id, state, dur ? format("%.1fs", dur) : "TTS?", shots)
      end
    else
      missing = TOOLS.reject { |t| system("command -v #{t} >/dev/null 2>&1") }
      abort "render.rb needs #{missing.join(', ')} on PATH" unless missing.empty?
      if mode == :scene
        sc = board.scene(scene_id) or abort "no scene #{scene_id}; try --list"
        puts renderer.render_scene(sc)
      else
        puts renderer.render_all
      end
    end
  rescue Invalid => e
    abort e.message
  end
end

ShowcaseVideo.cli(ARGV) if $PROGRAM_NAME == __FILE__
