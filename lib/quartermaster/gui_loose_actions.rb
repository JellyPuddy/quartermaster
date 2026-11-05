# frozen_string_literal: true

module Quartermaster
  # The GUI's loose-chat actions (LooseChat): start, ✕ and → Work item.
  # GuiActions hands every loose-* command here; nil means not one of them.
  class GuiLooseActions
    def initialize(tmux:, jobs:, loose: nil)
      @tmux = tmux
      @jobs = jobs
      @loose = loose
    end

    def dispatch(cmd, args)
      case cmd
      when "loose-start" then start(args)
      when "loose-close" then close(args["id"].to_s)
      when "loose-promote" then promote(args["id"].to_s, args["title"], tell: args["tell"] == true)
      end
    end

    private

    def loose = @loose || LooseChat.new(tmux: @tmux)

    def start(args)
      name = loose.start(project: args["project"], model: args["model"], prompt: args["prompt"], starter: args["starter"])
      { "ok" => true, "name" => name, "id" => LooseChat.id_of(name) }
    end

    # /exit waits for claude to go, so it runs on a job, keyed by the pane.
    def close(id)
      raise ArgumentError, "no loose chat given" if id.empty?

      @jobs.background(LooseChat.session_name(id), "closing…") do
        loose.close(id)
        { "ok" => true, "message" => "loose chat closed" }
      end
    end

    # tell is only ever the user's "Tell the chat" checkbox in the promote dialog.
    def promote(id, title, tell:)
      item, renamed, told = loose.promote(id, title: title, tell: tell)
      reply = { "ok" => true, "slug" => item.slug }
      reply["told"] = told if tell
      return reply if renamed

      reply.merge("warning" => "#{item.slug} is created, but its chat stays under #{LooseChat.session_name(id)}: " \
                               "a chat named #{item.slug} already runs")
    end
  end
end
