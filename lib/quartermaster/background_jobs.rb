# frozen_string_literal: true

module Quartermaster
  # The background agents, workflows and shell commands a session launched
  # that have not reported back yet, read from its transcript. A launch is a
  # tool result with status "async_launched" (agentId + description, or a
  # workflow's taskId + workflowName) or one carrying a backgroundTaskId (a
  # Bash run in the background, or moved there when it hit its timeout; its
  # description and command live on the Bash tool_use the result answers), or
  # a SendMessage result carrying resumedAgentId (a stopped sub-agent revived),
  # or a status-less <task-notification> saying the user resumed that agent.
  # Its end is the next <task-notification> naming that id, or the successful
  # TaskStop result naming it (a stop writes no notification), but not an
  # interim notification, whose <note> says the result may be interim: the
  # sub-agent stopped with its own background work running and notifies
  # again when it resumes, so the job stays pending and that notification
  # only refreshes its age (seen_at). Hooks see
  # neither end: the wake-up a notification causes fires no UserPromptSubmit
  # and SubagentStop isn't registered, so the transcript is the only record
  # that needs nothing from the session itself.
  #
  # A launch can sit far back in a long transcript, so each one is folded
  # once and then only from its last offset (process-wide cache; the GUI
  # rebuilds its state every few seconds). Of the Bash calls only those still
  # awaiting their result are remembered.
  module BackgroundJobs
    Job = Struct.new(:id, :description, :workflow, :launched_at, :command, :seen_at, keyword_init: true) do
      # A watcher (a CI or PR watch) waits on the world, not on work: while
      # only watchers run, the turn is still the user's. Judged by the name the
      # session gave it, or for a shell by a watching gh command, so nothing
      # has to be remembered when launching one.
      def watcher? = !workflow && (WATCHER_NAME.match?(description.to_s) || WATCHER_COMMAND.match?(command.to_s))
    end

    WATCHER_NAME = /\b(watch\w*|monitor\w*|babysit\w*)\b/i
    WATCHER_COMMAND = /\bgh\s+(pr\s+checks\b[^\n;&|]*\s--watch\b|run\s+watch\b)/
    # A session resumed after a crash or restart lost its background jobs
    # without a notification; past this age since its launch, or since its
    # last interim notification, a job no longer counts.
    MAX_AGE = 12 * 3600
    TASK_ID = %r{<task-id>([^<\\]+)</task-id>}
    INTERIM = "the result below may be interim"
    USER_RESUMED = %r{<summary>Agent "(.*)" was resumed by the user</summary>}
    BASH_USE = '"name":"Bash"'
    STOPPED = "Successfully stopped task"
    SHELL_DESCRIPTION_MAX = 80
    MARKERS = [STOPPED, "<task-notification>", "async_launched", "resumedAgentId", BASH_USE].freeze

    @cache = {}
    @mutex = Mutex.new

    module_function

    # Jobs still running, oldest launch first.
    def pending(path, now: Time.now)
      return [] unless path && File.exist?(path)

      @mutex.synchronize { fold(path) }.values
                                       .select { |job| (seen = job.seen_at || job.launched_at).nil? || now - seen < MAX_AGE }
                                       .sort_by { |job| job.launched_at.to_f }
    rescue StandardError
      []
    end

    def fold(path)
      size = File.size(path)
      offset, jobs, shells, agents = @cache[path]
      offset, jobs, shells, agents = 0, {}, {}, {} if offset.nil? || size < offset
      return jobs if size == offset

      File.open(path, "rb") do |f|
        f.seek(offset)
        f.each_line do |line|
          break unless line.end_with?("\n") # a line still being written: next time

          offset += line.bytesize
          apply(jobs, shells, agents, line)
        end
      end
      @cache[path] = [offset, jobs, shells, agents]
      jobs
    end

    # shells: Bash tool_use id => [description, command], until its result.
    # agents: agent id => the description it was launched with, so a resume
    # (which names only the id) shows and judges it by that name.
    def apply(jobs, shells, agents, line)
      return if shells.any? && shell_result(jobs, shells, line)
      return unless MARKERS.any? { |marker| line.include?(marker) }

      entry = Quartermaster.json_object(line) or return
      if (id = stopped_id(entry))
        jobs.delete(id)
      elsif (text = notification(entry))
        if (job = user_resume(entry, text, agents))
          jobs[job.id] = job
        elsif text.include?(INTERIM)
          text.scan(TASK_ID).flatten.each { |id| jobs[id]&.seen_at = launched_at(entry) }
        else
          text.scan(TASK_ID).flatten.each { |ended| jobs.delete(ended) }
        end
      elsif (job = launch(entry) || resume(entry, agents))
        agents[job.id] = job.description unless job.workflow
        jobs[job.id] = job
      else
        remember_shells(shells, entry)
      end
    rescue ArgumentError
      nil
    end

    def launch(entry)
      result = entry["toolUseResult"]
      return if entry["isSidechain"] || !result.is_a?(Hash) || result["status"] != "async_launched"

      id = result["agentId"] || result["taskId"] or return
      Job.new(id: id, description: result["description"] || result["workflowName"],
              workflow: result["taskType"] == "local_workflow", launched_at: launched_at(entry))
    end

    # SendMessage reviving a sub-agent that had stopped: a launch of that
    # agent again, ended by its next notification. A message queued to a
    # still-running agent carries no resumedAgentId; that job is still out.
    def resume(entry, agents)
      result = entry["toolUseResult"]
      return if entry["isSidechain"] || entry["type"] != "user" || !result.is_a?(Hash)

      id = result["resumedAgentId"]
      return unless id.is_a?(String) && !id.empty?

      Job.new(id: id, description: agents[id] || result["message"], workflow: false, launched_at: launched_at(entry))
    end

    # The user resuming a sub-agent from its transcript view: a notification
    # with no <status> whose summary says so starts that agent again, ended
    # like any launch. Named as launched, else by the summary's agent name.
    def user_resume(entry, text, agents)
      return if text.include?("<status>")

      name = text[USER_RESUMED, 1] or return
      id = text[TASK_ID, 1] or return
      Job.new(id: id, description: agents[id] || name, workflow: false, launched_at: launched_at(entry))
    end

    # Only the notification itself ends a job: a task id quoted in an
    # assistant message, a tool call or a tool result (a brief, a grep) is
    # not one.
    def notification(entry)
      return if entry["isSidechain"]

      text = case entry["type"]
             when "queue-operation" then entry["content"]
             when "user"
               content = entry.dig("message", "content")
               content.is_a?(String) ? content : Array(content).find { |b| b.is_a?(Hash) && b["type"] == "text" }&.dig("text")
             end
      text if text.is_a?(String) && text.lstrip.start_with?("<task-notification>")
    end

    # Only TaskStop's own structured result: a failed stop's is an error
    # string, and a Bash or Read output quoting a stop carries no message.
    def stopped_id(entry)
      result = entry["toolUseResult"]
      return if entry["isSidechain"] || entry["type"] != "user" || !result.is_a?(Hash)

      id = result["task_id"] || result["shell_id"]
      id if id.is_a?(String) && result["message"].to_s.start_with?("#{STOPPED}: #{id}")
    end

    def remember_shells(shells, entry)
      return if entry["isSidechain"] || entry["type"] != "assistant"

      Array(entry.dig("message", "content")).each do |block|
        next unless block.is_a?(Hash) && block["type"] == "tool_use" && block["name"] == "Bash" && block["id"]

        input = block["input"].is_a?(Hash) ? block["input"] : {}
        shells[block["id"]] = [input["description"], input["command"].to_s]
      end
    end

    # The result answering a pending Bash call: it stops being pending, and is
    # a launch when it carries a backgroundTaskId. Hook attachments mention the
    # id too (a PreToolUse one even before the result), so only a tool_result
    # entry counts.
    def shell_result(jobs, shells, line)
      use_id = shells.each_key.find { |id| line.include?(id) } or return false
      entry = Quartermaster.json_object(line) or return false
      answers = Array(entry.dig("message", "content")).any? do |block|
        block.is_a?(Hash) && block["type"] == "tool_result" && block["tool_use_id"] == use_id
      end
      return false unless answers
    
      description, command = shells.delete(use_id)
      result = entry["toolUseResult"]
      id = result.is_a?(Hash) && result["backgroundTaskId"] or return true
    
      description = command.lines.first.to_s.strip[0, SHELL_DESCRIPTION_MAX] if description.to_s.strip.empty?
      jobs[id] = Job.new(id: id, description: description, workflow: false, command: command,
                         launched_at: launched_at(entry))
      true
    end

    def launched_at(entry) = entry["timestamp"] && Time.parse(entry["timestamp"])

    def reset! = @mutex.synchronize { @cache.clear }
  end
end
