# frozen_string_literal: true

module Quartermaster
  # The live edit chats of automations (Edit with Claude, `qm automation edit`):
  # an automation item's own tmux chat, named by its slug. Automations stay off
  # the chats list's item rows (ChatAttention), so GuiState hands these out with
  # the loose chats, shaped as loose rows with an `automation` field, and the
  # page lists them under "Automations" — else the chat vanishes once another
  # one is selected.
  class AutomationEditChats
    def initialize(session_log: SessionLog.new, dir: AUTOMATIONS_DIR)
      @session_log = session_log
      @dir = dir
      @store = AutomationStore.new(dir)
    end

    def chats(panes, attention: ChatAttention.new(session_log: @session_log))
      panes.filter_map do |name|
        next unless name.to_s.match?(AutomationStore::SLUG) && @store.exists?(name)

        item = WorkItem.find(name)
        next unless item.automation?

        session = edit_session(item)
        turn = session ? attention.turn_for(session) : { state: "none" }
        { "name" => name, "id" => name, "automation" => name, "session" => session&.id,
          "title" => item.title || name, "project" => item.project,
          "state" => turn[:state], "since" => turn[:since]&.utc&.iso8601, "tool" => turn[:tool] }
      rescue ArgumentError
        nil
      end
    end

    private

    # The newest live session of the item that isn't one of its runs.
    def edit_session(item)
      runs = RunLog.session_ids_for(item, @dir)
      item.sessions.reverse_each.filter_map { |s| @session_log.session_for(s["id"]) unless runs.include?(s["id"]) }.find(&:live?)
    end
  end
end
