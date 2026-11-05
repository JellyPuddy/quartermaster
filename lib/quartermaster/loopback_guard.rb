# frozen_string_literal: true

module Quartermaster
  # The GUI's request checks for a server bound to 127.0.0.1 on one port: a
  # loopback tool needs no other auth, but a browser will send any website's
  # requests there with our own Host.
  class LoopbackGuard
    def initialize(port)
      @allowed_hosts = ["127.0.0.1:#{port}", "localhost:#{port}"]
    end

    # Reject anything whose Host isn't our loopback origin — cheap defense
    # against DNS-rebinding, since a loopback tool needs no other auth.
    def allowed_host?(host)
      host && @allowed_hosts.include?(host)
    end

    # The Host check doesn't stop a cross-site form or no-cors fetch: the
    # browser sends our own Host for it. It does send that page's Origin, and
    # actions now force-remove worktrees and run bin/update, so a POST from
    # any other origin is refused.
    def foreign_origin?(origin)
      origin && !@allowed_hosts.include?(origin.delete_prefix("http://"))
    end

    # The actions a local process may post without an Origin: the qm CLI's
    # caffeinate, pane, rotate, start-issue and loose commands, and pf relaying
    # page annotations. Everything else is the page's, which always sends one.
    LOCAL_ACTIONS = %w[caffeinate pane-start pane-resume rotate issue-start loose-start page-annotations].freeze

    def local_action?(route, action)
      route == "/api/action" && action.is_a?(Hash) && LOCAL_ACTIONS.include?(action["cmd"])
    end
  end
end
