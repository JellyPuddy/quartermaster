# frozen_string_literal: true

module Quartermaster
  # An automation's chat (`qm automation new` / `edit`, the GUI's automation-chat
  # action): the item's ordinary tmux chat, started or resumed with a brief qm
  # writes — the item, its two local files, the edit → push → run loop and the
  # house rules — as claude's argument. A live chat is only shown again: the
  # brief comes back for the caller to print, never typed into it.
  class AutomationChat
    HOUSE_RULES = File.expand_path("../../docs/automations-house-rules.md", __dir__)
    ROUTINE_URL = "https://claude.ai/code/routines/%s"

    # A kind: automation item (runner cloud, no routine until the first push)
    # and its empty local files, under the work-item lock.
    def self.create(title, project:, description: nil, store: AutomationStore.new)
      slug = WorkItem.slugify(title)
      raise ArgumentError, "automation files for '#{slug}' already exist in #{AUTOMATIONS_DIR}" if store.exists?(slug)

      WorkItem.with_lock do
        item = WorkItem.create(title, project: project, description: description)
        item.front.merge!("kind" => "automation", "runner" => "cloud")
        item.save
        store.write(item.slug, { "runner" => "cloud", "name" => title, "enabled" => true }, "")
        item
      end
    end

    def self.brief(item, store: AutomationStore.new)
      routine = item.routine ? "Its routine is #{item.routine} (#{format(ROUTINE_URL, item.routine)})." : "It has no routine yet: the first push creates it."
      notes = item.notes.reverse.map { |note| "- #{note.stamp} [#{note.kind}]: #{note.text}" }
      <<~BRIEF
        You are working on the qm automation "#{item.title}" (work item #{item.slug}, project #{item.project}): a claude.ai cloud routine that qm manages. #{routine}

        ## Its files

        - Prompt: #{store.prompt_path(item.slug)} (the routine's prompt, nothing else)
        - Settings: #{store.yml_path(item.slug)} (name, cron in UTC, model, sources, connectors, allowed_tools, environment_id, enabled; keep `v:` and any key you don't know)

        ## The loop

        1. Edit the two files.
        2. `qm automation push #{item.slug}` sends them to the routine (the first push creates it).
        3. `qm automation run #{item.slug}` runs it now.
        4. Read the run: its claude.ai link (`qm automation show #{item.slug}`) or RemoteTrigger get_run_log.
        5. Refine and repeat.

        Never call RemoteTrigger create or update yourself: push is the only way a change reaches the routine.
        Record each decision as a note on the item: `qm note #{item.slug} --kind decision "..."`.

        ## House rules

        #{File.read(HOUSE_RULES).strip}

        ## Description

        #{["", ItemDeletion::PLACEHOLDER].include?(item.description) ? "_none yet_" : item.description}

        ## Notes

        #{notes.empty? ? "_none yet_" : notes.join("\n")}
      BRIEF
    end

    def initialize(tmux:, launcher: Launcher.new, store: AutomationStore.new)
      @tmux = tmux
      @launcher = launcher
      @store = store
    end

    # Opens the item's chat: { "ok", "mode" } once started or resumed,
    # { "ok", "attached", "brief" } when it already runs.
    def open(slug)
      item = automation(slug)
      return { "ok" => true, "attached" => true, "brief" => brief_for(item) } if @tmux.live?(item.slug)

      plan = plan(item)
      raise ArgumentError, "#{item.slug} has a chat running outside the GUI — take it over once it ends" if plan[:mode] == :live

      @tmux.open(item.slug, cwd: plan[:cwd], argv: plan[:argv], env: plan[:env])
      { "ok" => true, "mode" => plan[:mode].to_s }
    end

    # The chat's launch plan with the brief as claude's last argument: a
    # fresh chat when the item has none, else its newest one resumed.
    def plan(item)
      brief = brief_for(item)
      plan = @launcher.chat_plan(item, fresh: item.sessions.empty?, prompt: brief)
      return plan if plan[:mode] == :live || plan[:argv].last == brief

      plan.merge(argv: plan[:argv] + [brief])
    end

    def automation(slug)
      item = WorkItem.find(slug.to_s)
      raise ArgumentError, "#{item.slug} is not an automation (kind: automation)" unless item.automation?

      item
    end

    private

    def brief_for(item) = self.class.brief(item, store: @store)
  end
end
