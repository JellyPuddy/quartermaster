#!/usr/bin/env ruby
# frozen_string_literal: true

# Takes the showcase screenshots listed in shots.yml from the demo world's
# qm gui with a headless Chrome. See showcase/README.md.
#
#   ruby showcase/shots/capture.rb               # every shot
#   ruby showcase/shots/capture.rb --shot diff   # one (repeatable)
#   ruby showcase/shots/capture.rb --list
require "optparse"
require_relative "shot_list"
require_relative "cdp"
require_relative "../demo-world/lib/demo_world"
require_relative "../demo-world/lib/demo_world/gui"

module ShowcaseShots
  SHOTS_FILE = File.join(__dir__, "shots.yml")
  OUT_DIR = File.expand_path("../out", __dir__)

  # Hides what only a screenshot would catch: the text caret.
  SCREENSHOT_CSS = "*, *::before, *::after { caret-color: transparent !important; }"

  # Drives one Chrome through every requested shot, each in a fresh browser
  # context (no storage carried over from the shot before).
  class Capturer
    def initialize(cdp, gui:, world:, out_dir:)
      @cdp = cdp
      @gui = gui
      @world = world
      @out_dir = out_dir
    end

    def capture(shot)
      context = @cdp.call("Target.createBrowserContext")["browserContextId"]
      target = @cdp.call("Target.createTarget", { url: "about:blank", browserContextId: context })["targetId"]
      @session = @cdp.call("Target.attachToTarget", { targetId: target, flatten: true })["sessionId"]
      open(shot)
      shot.steps.each_with_index do |step, i|
        run(step)
      rescue ProtocolError => e
        raise ProtocolError, "step #{i + 1} (#{step.kind}: #{step.arg.to_s[0, 60]}): #{e.message}"
      end
      settle
      path = File.join(@out_dir, shot.file_name)
      File.binwrite(path, screenshot(shot))
      path
    ensure
      @cdp.drop_events(@session) if @session
      @cdp.call("Target.closeTarget", { targetId: target }) if target
      @cdp.call("Target.disposeBrowserContext", { browserContextId: context }) if context
      @session = nil
    end

    private

    def page(method, params = {}, timeout: 30) = @cdp.call(method, params, session: @session, timeout: timeout)

    def open(shot)
      width, height = shot.viewport
      page("Page.enable")
      page("Runtime.enable")
      page("Emulation.setFocusEmulationEnabled", { enabled: true })
      page("Emulation.setDeviceMetricsOverride", { width: width, height: height,
                                                 deviceScaleFactor: shot.scale, mobile: shot.mobile })
      page("Emulation.setTouchEmulationEnabled", { enabled: true }) if shot.mobile
      page("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: shot.theme }] }) if shot.theme
      page("Page.addScriptToEvaluateOnNewDocument", { source: <<~JS })
        document.addEventListener("DOMContentLoaded", () => {
          const s = document.createElement("style"); s.textContent = #{SCREENSHOT_CSS.to_json};
          document.head.appendChild(s);
        });
      JS
      page("Page.navigate", { url: shot.url(gui: @gui, world: @world) })
      @cdp.wait_event("Page.loadEventFired", session: @session, timeout: 30)
    end

    def run(step)
      case step.kind
      when "key" then Array(step.arg).each { |k| key(k) }
      when "click" then evaluate("(() => { const el = #{element(step.arg)}; el.scrollIntoView({block: 'nearest'}); el.click(); })()")
      when "hover" then hover(step.arg)
      when "eval" then evaluate(step.arg)
      when "wait_for" then wait_for(step.arg)
      when "wait" then sleep(step.arg)
      end
    end

    # A selector's element, or a thrown error naming the selector.
    def element(selector)
      "(document.querySelector(#{selector.to_json}) || (() => { throw new Error(#{"nothing matches #{selector}".to_json}) })())"
    end

    def key(name)
      code, text = KEYS.fetch(name) { [name.upcase.ord, name] }
      modifiers = name.size == 1 && name =~ /[A-Z]/ ? 8 : 0 # shift
      down = { type: text ? "keyDown" : "rawKeyDown", key: name, windowsVirtualKeyCode: code, modifiers: modifiers }
      down[:text] = text if text
      page("Input.dispatchKeyEvent", down)
      page("Input.dispatchKeyEvent", { type: "keyUp", key: name, windowsVirtualKeyCode: code, modifiers: modifiers })
      sleep 0.15
    end

    def hover(selector)
      x, y = evaluate("(() => { const r = #{element(selector)}.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()")
      page("Input.dispatchMouseEvent", { type: "mouseMoved", x: x, y: y })
    end

    def wait_for(selector, timeout: 15)
      deadline = Time.now + timeout
      until evaluate("!!document.querySelector(#{selector.to_json})")
        raise ProtocolError, "#{selector} never appeared within #{timeout}s" if Time.now > deadline

        sleep 0.1
      end
    end

    def evaluate(expression)
      result = page("Runtime.evaluate", { expression: expression, awaitPromise: true, returnByValue: true })
      if (error = result["exceptionDetails"])
        raise ProtocolError, "eval failed: #{error.dig('exception', 'description') || error['text']}"
      end

      result.dig("result", "value")
    end

    # Fonts loaded, nothing focused (no focus rings), two frames painted.
    def settle
      evaluate("document.fonts.ready.then(() => { document.activeElement?.blur?.(); })")
      evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
      sleep 0.3
    end

    def screenshot(shot)
      params = { format: "png" }
      params[:clip] = clip_rect(shot.clip).merge(scale: 1) if shot.clip
      Base64.decode64(page("Page.captureScreenshot", params, timeout: 60)["data"])
    end

    def clip_rect(clip)
      if clip.rect
        x, y, w, h = clip.rect
      else
        x, y, w, h = evaluate("(() => { const r = #{element(clip.selector)}.getBoundingClientRect(); " \
                              "return [r.x + scrollX, r.y + scrollY, r.width, r.height]; })()")
        x -= clip.pad
        y -= clip.pad
        w += 2 * clip.pad
        h += 2 * clip.pad
      end
      { x: [x, 0].max, y: [y, 0].max, width: w + [x, 0].min, height: h + [y, 0].min }
    end
  end

  module CLI
    module_function

    def run(argv)
      wanted = []
      list = false
      OptionParser.new do |o|
        o.banner = "usage: ruby showcase/shots/capture.rb [--shot ID]... [--list]"
        o.on("--shot ID", "capture only this shot (repeatable)") { |id| wanted << id }
        o.on("--list", "list the shots") { list = true }
      end.parse!(argv)
      shots = ShotList.load(SHOTS_FILE)
      return print_list(shots) if list

      chosen = wanted.empty? ? shots.shots : wanted.map { |id| shots.find(id) }
      capture(chosen)
    end

    def print_list(shots)
      shots.shots.each do |s|
        taken = File.exist?(File.join(OUT_DIR, "shots", s.file_name)) ? "taken" : "missing"
        puts format("%-20s %-8s %4dx%-5d %s", s.id, taken, *s.viewport, s.note)
      end
    end

    def capture(chosen)
      world = DemoWorld::World.new(ENV["QM_DEMO_WORLD"] || DemoWorld::DEFAULT_ROOT)
      ensure_gui(world)
      out = File.join(OUT_DIR, "shots")
      FileUtils.mkdir_p(out)
      chrome = Chrome.new(File.join(OUT_DIR, "chrome-profile"), log: File.join(OUT_DIR, "chrome.log"))
      cdp = chrome.start
      capturer = Capturer.new(cdp, gui: world.url, world: world.root, out_dir: out)
      failed = chosen.reject do |shot|
        started = Time.now
        path = capturer.capture(shot)
        puts format("%-20s %s (%.1fs)", shot.id, path, Time.now - started)
        true
      rescue ProtocolError, Invalid => e
        warn "#{shot.id}: #{e.message}"
        false
      end
      cdp.close
      abort "#{failed.size} shot(s) failed: #{failed.map(&:id).join(', ')}" unless failed.empty?
    ensure
      chrome&.stop
    end

    # Starts the demo world's GUI when nothing answers on the demo port.
    def ensure_gui(world)
      return if DemoWorld::Gui.new(world).answering?

      puts "no demo qm gui on #{world.url}: running showcase/demo-world/run"
      system(RbConfig.ruby, File.expand_path("../demo-world/run", __dir__), exception: true)
    end
  end
end

ShowcaseShots::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
