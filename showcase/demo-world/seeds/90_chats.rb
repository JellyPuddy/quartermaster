# frozen_string_literal: true

# The live chats: one tmux session per live cast session on the world's
# socket, named as qm names them (the item's slug, <slug>--aside for an
# aside), each running the stub claude resumed on that session, which draws a
# screen made from the session's own transcript tail and then waits. Their
# start events go into sessions.jsonl with the pane's pid, so qm sees them
# live — and the hook events already logged say whose turn it is.
module DemoWorld
  # A Claude Code-looking screen for a live session, from its transcript.
  module Screen
    DIM = "\e[2m"
    OFF = "\e[0m"
    BOLD = "\e[1m"
    ACCENT = "\e[38;5;174m"
    GREEN = "\e[32m"

    def self.for(session, state)
      out = ["#{ACCENT}✻#{OFF} #{BOLD}Claude Code#{OFF} #{DIM}· resumed #{session.id[0, 8]} · #{session.cwd.sub(%r{.*/code/}, "~/code/")}#{OFF}", ""]
      lines = session.transcript.lines.last(14)
      lines = lines[0...-1] if state == :blocked # the pending call shows as the permission prompt
      lines.each { |line| out.concat(entry(line)) }
      out.concat(footer(session, state))
      "#{out.join("\n")}\n"
    end

    def self.entry(line)
      content = line.dig("message", "content")
      if line["type"] == "user"
        return [] unless content.is_a?(String)

        return ["#{DIM}> #{wrap(content, 2).join("\n  ")}#{OFF}", ""]
      end
      Array(content).flat_map do |block|
        case block["type"]
        when "text" then [*wrap(block["text"], 2).each_with_index.map { |l, i| i.zero? ? "#{GREEN}⏺#{OFF} #{l}" : "  #{l}" }, ""]
        when "tool_use"
          subject = block["input"].values.find { |v| v.is_a?(String) }.to_s.sub(%r{.*/(app|src|test|db)/}, '\1/')
          ["#{GREEN}⏺#{OFF} #{BOLD}#{block["name"]}#{OFF}(#{subject[0, 90]})", "  #{DIM}⎿  done#{OFF}"]
        else []
        end
      end
    end

    def self.footer(session, state)
      box = ["#{DIM}╭#{"─" * 96}╮#{OFF}", "#{DIM}│#{OFF} > #{" " * 93}#{DIM}│#{OFF}", "#{DIM}╰#{"─" * 96}╯#{OFF}"]
      case state
      when :blocked
        cmd = session.transcript.lines.last.dig("message", "content", 0, "input")
        ["#{ACCENT}╭#{"─" * 96}╮#{OFF}", " #{BOLD}Bash command#{OFF}", "", "   #{cmd["command"]}", "   #{DIM}#{cmd["description"]}#{OFF}", "",
         " Do you want to proceed?", " #{ACCENT}❯ 1. Yes#{OFF}", "   2. Yes, and don't ask again for gh stack push commands", "   3. No, and tell Claude what to do differently (esc)",
         "#{ACCENT}╰#{"─" * 96}╯#{OFF}"]
      when :working then ["#{ACCENT}✻ Running the system test…#{OFF} #{DIM}(2m 14s · ↓ 3.1k tokens · esc to interrupt)#{OFF}", "", *box]
      when :waiting then [*box, "  #{DIM}1 background task · ↓ to manage#{OFF}"]
      else [*box, "  #{DIM}? for shortcuts#{OFF}"]
      end
    end

    def self.wrap(text, indent)
      text.split("\n").flat_map { |para| para.scan(/\S.{0,#{94 - indent}}(?=\s|\z)/) }.then { |l| l.empty? ? [""] : l }
    end
  end

  module Chats
    STATES = { "gc2" => :your_turn, "co2" => :blocked, "ds3" => :working, "bv1" => :waiting }.freeze

    OPENER = <<~'RUBY'
      tmux = Quartermaster::Tmux.new
      pids = DATA_IN["chats"].to_h do |chat|
        tmux.open(chat["pane"], cwd: chat["cwd"], argv: chat["argv"], env: chat["env"])
        [chat["pane"], tmux.pane_pid(chat["pane"])]
      end
      puts JSON.generate(pids)
    RUBY

    def self.open(world)
      live = world.cast.sessions.select(&:live?)
      sessions_dir = File.join(world.claude_fixtures_dir, "sessions")
      FileUtils.mkdir_p(sessions_dir)
      live.each { |s| File.write(File.join(sessions_dir, "#{s.id}.txt"), Screen.for(s, STATES.fetch(s.name, :your_turn))) }
      chats = live.map do |s|
        argv = ["claude", "--resume", s.id]
        argv += ["--model", "sonnet"] if s.aside
        env = s.aside ? { "QM_ASIDE" => s.aside, "QM_ITEM" => "" } : { "QM_ITEM" => s.item }
        { "pane" => s.pane, "cwd" => s.cwd, "argv" => argv, "env" => env }
      end
      pids = world.qm_ruby!(OPENER, { "chats" => chats })
      starts = live.map do |s|
        path = File.join(world.transcripts_dir, Transcript.project_dir(s.cwd), "#{s.id}.jsonl")
        SessionEvents.start(world, s, path, pid: pids.fetch(s.pane))
      end
      world.append_jsonl(File.join(world.qm_root, "sessions.jsonl"), starts)
    end
  end
end

DemoWorld.step("chats") { |world| DemoWorld::Chats.open(world) }
