# frozen_string_literal: true

module Quartermaster
  # An automation's chat (`qm automation new` / `edit`, the GUI's automation-chat
  # action): the item's ordinary tmux chat, started or resumed with a brief qm
  # writes — the item, its two local files, its runner's edit → try → run loop
  # and the house rules — as claude's argument. A live chat is only shown again: the
  # brief comes back for the caller to print, never typed into it.
  class AutomationChat
    HOUSE_RULES = File.expand_path("../../docs/automations-house-rules.md", __dir__)
    ROUTINE_URL = "https://claude.ai/code/routines/%s"

    RUNNERS = %w[cloud local].freeze

    # A kind: automation item and its empty local files, under the work-item
    # lock: a cloud one enabled, with no routine until the first push; a local
    # one disabled until the user enables it.
    def self.create(title, project:, description: nil, runner: "cloud", store: AutomationStore.new)
      raise ArgumentError, "runner is #{RUNNERS.join(" or ")}, got #{runner}" unless RUNNERS.include?(runner)

      slug = WorkItem.slugify(title)
      raise ArgumentError, "automation files for '#{slug}' already exist in #{AUTOMATIONS_DIR}" if store.exists?(slug)

      WorkItem.with_lock do
        item = WorkItem.create(title, project: project, description: description)
        item.front.merge!("kind" => "automation", "runner" => runner)
        item.save
        store.write(item.slug, { "runner" => runner, "name" => title, "enabled" => runner == "cloud" }, "")
        item
      end
    end

    def self.brief(item, store: AutomationStore.new)
      return local_brief(item, store) if item.runner == "local"

      routine = item.routine ? "Its routine is #{item.routine} (#{format(ROUTINE_URL, item.routine)})." : "It has no routine yet: the first push creates it."
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
        #{brief_tail(item)}
      BRIEF
    end

    # A local automation's brief: the same frame, its own loop — a dry-run
    # tick, a run, its transcript — and nothing to push.
    def self.local_brief(item, store)
      <<~BRIEF
        You are working on the qm automation "#{item.title}" (work item #{item.slug}, project #{item.project}): a local automation, a Claude Code run that qm starts on this machine on a schedule. It runs unattended, with the user's own permissions. It was created disabled: its cron and guard don't run until it is enabled with `qm automation resume #{item.slug}`.

        ## Its files

        - Prompt: #{store.prompt_path(item.slug)} (the run's prompt, nothing else; each guard item is appended to it as a final `## Item` section)
        - Settings: #{store.yml_path(item.slug)} (name, cron in Europe/Amsterdam local time, enabled, when (the guard command), flow, repos (required for flow pr-review: the owner/name repos it may review; an unattended review reads PR text others wrote, so a PR in any other repo is refused), cwd, model, allowed_tools, permission_mode, timeout_minutes, notify; keep `v:` and any key you don't know)

        ## The loop

        1. Edit the two files.
        2. `qm automation tick --dry-run #{item.slug}` runs the guard and prints the items a run would be queued for; it writes nothing.
        3. `qm automation run #{item.slug}` queues a run now; a tick starts it.
        4. Read the run: `qm automation runs #{item.slug}` lists its runs with their session ids; `qm show-session SESSION_ID` shows one, and its transcript is `~/.claude/projects/*/SESSION_ID.jsonl`.
        5. Refine and repeat.

        Nothing to push: qm reads the two files on every tick.
        #{brief_tail(item)}
      BRIEF
    end

    # The brief's end, the same for every runner: how to record decisions,
    # the house rules verbatim, the item's description and its notes.
    def self.brief_tail(item)
      notes = item.notes.reverse.map { |note| "- #{note.stamp} [#{note.kind}]: #{note.text}" }
      <<~TAIL.chomp
        Record each decision as a note on the item: `qm note #{item.slug} --kind decision "..."`.

        ## House rules

        #{File.read(HOUSE_RULES).strip}

        ## Description

        #{["", ItemDeletion::PLACEHOLDER].include?(item.description) ? "_none yet_" : item.description}

        ## Notes

        #{notes.empty? ? "_none yet_" : notes.join("\n")}
      TAIL
    end

    def initialize(tmux:, launcher: nil, store: AutomationStore.new)
      @tmux = tmux
      @launcher = launcher || Launcher.new(automations_dir: store.dir)
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
    # fresh chat when the item has none, else its newest one resumed. A
    # local automation's runs attach to its item too, but are never its chat
    # (Launcher skips them as well).
    def plan(item)
      brief = brief_for(item)
      runs = RunLog.session_ids_for(item, @store.dir)
      fresh = item.sessions.all? { |s| runs.include?(s["id"]) }
      plan = @launcher.chat_plan(item, fresh: fresh, prompt: brief)
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
