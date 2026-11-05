# frozen_string_literal: true

module Quartermaster
  # A chat's tmux session is named after its item, so when its session moves
  # to another item (attach, item-from-session) the pane must follow: else the
  # new item shows no pane and the old one keeps a chat that is no longer its.
  # Only a pane whose process is that session's claude moves — a slug alone
  # proves nothing about which chat runs there.
  class PaneFollowsSession
    def initialize(tmux: Tmux.new, session_log: SessionLog.new)
      @tmux = tmux
      @session_log = session_log
    end

    # Renames the vacated item's tmux session to `to` when it runs
    # `session_id`. Returns a warning for the frontends when the pane can't
    # follow because `to` already has a chat running, else nil. Never raises.
    def move(session_id, from:, to:)
      session = @session_log.session_for(session_id)
      return nil unless session&.pid && !session.aside_for

      from.each do |old|
        next unless @tmux.pane_pid(old) == session.pid
        return "#{old}'s chat pane stays named #{old}: #{to} already has a chat running" if @tmux.live?(to)

        @tmux.rename(old, to)
      end
      nil
    rescue StandardError => e
      Quartermaster.log_error("pane-follows-session", e)
      nil
    end
  end
end
