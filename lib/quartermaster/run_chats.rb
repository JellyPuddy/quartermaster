# frozen_string_literal: true

module Quartermaster
  # The live `<slug>--run-<id>` chats of local automation runs among the tmux
  # session names, shaped as the chats list's loose rows with a `run` field:
  # GuiState hands them out with the loose chats, so the Automations tab's
  # "open chat" and a run notification's `qm open-chat` land in the chat pane.
  # Titled by the automation's name and the run's subject, with whose move it
  # is from the session qm gave the run; a `notify: quiet` automation's runs
  # say `quiet`, so the page leaves them out of its whose-move count.
  class RunChats
    def initialize(session_log: SessionLog.new, dir: AUTOMATIONS_DIR)
      @session_log = session_log
      @dir = dir
      @store = AutomationStore.new(dir)
    end

    def chats(panes, attention: ChatAttention.new(session_log: @session_log))
      panes.filter_map do |name|
        slug, id = name.to_s.split(ChatFlow::SEPARATOR, 2)
        next unless id && slug.match?(AutomationStore::SLUG) && (entry = @store.read(slug))

        run = RunLog.new(slug, dir: @dir).run(id)
        session = run&.session_id && @session_log.session_for(run.session_id)
        turn = session ? attention.turn_for(session) : { state: "none" }
        { "name" => name, "id" => name, "run" => { "slug" => slug, "id" => id, "quiet" => entry.record["notify"] == "quiet" },
          "session" => session&.id,
          "title" => [entry.record["name"] || slug, subject(run) || "run #{id}"].join(" · "),
          "project" => session&.project, "cwd" => session&.cwd && Quartermaster.shorten_home(session.cwd),
          "state" => turn[:state], "since" => turn[:since]&.utc&.iso8601, "tool" => turn[:tool] }
      end
    end

    private

    def subject(run)
      item = run&.item
      item.is_a?(Hash) ? item["title"] || item["key"] : nil
    end
  end
end
