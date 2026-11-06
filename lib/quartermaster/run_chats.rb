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
    # A chat-flow run as attention and notifications name it: its session, its
    # own tmux, its automation and run, and "<automation name> · <subject>".
    Chat = Struct.new(:session_id, :tmux, :slug, :run_id, :title, :quiet, keyword_init: true)

    # Every chat-flow run that has a session, by that session id (from the run
    # logs, whatever the run's status: a finished run's chat stays open).
    def self.by_session(dir = AUTOMATIONS_DIR)
      AutomationStore.new(dir).list.select { |entry| entry.record["runner"] == "local" }.each_with_object({}) do |entry, out|
        RunLog.new(entry.slug, dir: dir).runs.each do |run|
          next unless run.session_id && run.tmux.to_s.include?(ChatFlow::SEPARATOR)

          out[run.session_id] = Chat.new(session_id: run.session_id, tmux: run.tmux, slug: entry.slug, run_id: run.id,
                                         title: title(entry, run), quiet: entry.record["notify"] == "quiet")
        end
      end
    rescue StandardError => e
      Quartermaster.log_error("run-chats", e)
      {}
    end

    def self.title(entry, run)
      item = run.item
      subject = item.is_a?(Hash) ? item["title"] || item["key"] : nil
      [entry.record["name"] || entry.slug, subject || "run #{run.id}"].join(" · ")
    end

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
          "title" => self.class.title(entry, run || RunLog::Run.new(id: id)),
          "project" => session&.project, "cwd" => session&.cwd && Quartermaster.shorten_home(session.cwd),
          "state" => turn[:state], "since" => turn[:since]&.utc&.iso8601, "tool" => turn[:tool] }
      end
    end
  end
end
