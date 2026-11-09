# frozen_string_literal: true

module Quartermaster
  # The flows a local automation's run can take, by the yml's `flow:` name
  # (default chat). Each flow has a name, the item fields it needs and
  # start(automation, item, prompt, run_id:, session_id:), which answers
  # { item_slug:, tmux: } once a chat runs, or { waiting: reason } when the
  # run can't start yet and stays queued.
  class AutomationFlows
    DEFAULT = "chat"

    # A flow refusing an item its automation may not run (pr-review: a repo
    # outside its repos list); the tick records it as refused, not failed.
    class Refused < ArgumentError; end

    def initialize(tmux:, runner: CommandRunner.new, project_map: nil, pr_items: PrItems.new, pr_inbox: PrInbox.new)
      flows = [ChatFlow.new(tmux: tmux, project_map: project_map),
               PrReviewFlow.new(tmux: tmux, runner: runner, project_map: project_map, pr_items: pr_items, pr_inbox: pr_inbox)]
      @flows = flows.to_h { |flow| [flow.name, flow] }
    end

    def names = @flows.keys

    def fetch(name)
      @flows[name || DEFAULT] or raise ArgumentError, "unknown flow #{name.inspect} (#{names.join(", ")})"
    end

    # Why the flow can't take this item, or nil: an unknown flow, or a field
    # its needs lists that the item lacks or leaves blank. A cron run's item
    # is nil, so it lacks every field.
    def problem(name, item)
      flow = fetch(name)
      missing = flow.needs.reject { |field| item.is_a?(Hash) && !item[field].to_s.strip.empty? }
      return nil if missing.empty?

      what = item.is_a?(Hash) ? "item #{item["key"].to_s.inspect}" : "a run without an item"
      "#{what} lacks #{missing.join(", ")}, which the #{flow.name} flow needs"
    rescue ArgumentError => e
      e.message
    end

    # Why the automation may not run this item through the flow, or nil;
    # only a flow with a refusal rule (pr-review) refuses.
    def refusal(name, record, item)
      flow = fetch(name)
      flow.respond_to?(:refusal) ? flow.refusal(record, item) : nil
    end

    # Starts the run through the automation's flow; raises ArgumentError when
    # the item doesn't suit it or the yml (hand-edited past the store) is invalid.
    def start(automation, item, prompt, run_id:, session_id:)
      AutomationStore.validate_local(automation.record)
      name = AutomationStore.local_settings(automation.record)["flow"]
      reason = problem(name, item)
      raise ArgumentError, reason if reason

      fetch(name).start(automation, item, prompt, run_id: run_id, session_id: session_id)
    end

    # The claude flags a local automation's yml sets, before the prompt.
    def self.flags(record, session_id)
      tools = Array(record["allowed_tools"])
      ["--session-id", session_id,
       *(record["model"] ? ["--model", record["model"].to_s] : []),
       *(record["permission_mode"] ? ["--permission-mode", record["permission_mode"].to_s] : []),
       *(tools.empty? ? [] : ["--allowedTools=#{tools.join(",")}"])]
    end
  end
end
