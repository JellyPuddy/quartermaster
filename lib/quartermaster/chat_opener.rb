# frozen_string_literal: true

module Quartermaster
  # Brings the qm GUI up on one item's chat (`qm open-chat`, a macOS
  # notification's click): Arc's open GUI tab gets a `#chat=` hash — a
  # hash-only change, so no reload — and comes to the front; without such a
  # tab the URL opens in the default browser. Through the runner, so tests
  # never touch a real browser.
  class ChatOpener
    ARC = "company.thebrowser.Browser"

    # Prints "found" when it moved a GUI tab, "none" otherwise. Never
    # launches Arc. The URLs come in as argv, never spliced into the script.
    ARC_SCRIPT = <<~APPLESCRIPT
      on run argv
        set target to item 1 of argv
        set prefixes to items 2 thru -1 of argv
        if application id "#{ARC}" is not running then return "none"
        tell application id "#{ARC}"
          repeat with w in windows
            repeat with t in tabs of w
              set u to URL of t
              repeat with prefix in prefixes
                if u starts with (prefix as text) then
                  set URL of t to target
                  select t
                  activate
                  return "found"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "none"
      end run
    APPLESCRIPT

    def initialize(runner: CommandRunner.new, port: Gui.port)
      @runner = runner
      @port = port
    end

    # benchmark: a branch whose benchmark modal opens over the chat (a
    # finished benchmark run's click), as `&benchmark=<branch>` in the hash.
    def url(slug, benchmark: nil)
      hash = "chat=#{URI.encode_www_form_component(slug)}"
      hash += "&benchmark=#{URI.encode_www_form_component(benchmark)}" if benchmark
      "http://127.0.0.1:#{@port}/##{hash}"
    end

    # :arc when an open GUI tab took it, :browser when it opened afresh.
    def open(slug, benchmark: nil)
      target = url(slug, benchmark: benchmark)
      prefixes = ["http://127.0.0.1:#{@port}/", "http://localhost:#{@port}/"]
      result = @runner.call(["osascript", "-e", ARC_SCRIPT, target, *prefixes])
      return :arc if result.success? && result.out.strip == "found"

      @runner.call(["open", target])
      :browser
    end
  end
end
