# frozen_string_literal: true

module Quartermaster
  # Output helpers several CLI command groups share, and `qm help`'s text.
  module CliFormat
    private

    def note_line(note)
      "#{paint("##{note.position}", 36)} #{paint("[#{note.kind}]", 90)} #{note.stamp}: #{note.text}"
    end

    def short_path(path)
      Quartermaster.shorten_home(path || "?")
    end

    def paint(text, code)
      "\e[#{code}m#{text}\e[0m"
    end

    def print_session_rows(sessions, limit)
      sessions.sort_by(&:last_ts).reverse.first(limit).each do |session|
        status = session.live? ? "● live " : "  ended"
        duration = session.ended? ? format_duration(session.duration_s) : "-"
        puts [status, session.id[0, 8], session.item_label || "-", short_path(session.cwd),
              session.branch || "-", session.started_ts[0, 16], duration].join("  ")
      end
    end

    def format_duration(seconds)
      return "-" unless seconds

      if seconds < 60 then "#{seconds}s"
      elsif seconds < 3600 then "#{seconds / 60}m"
      else "#{seconds / 3600}h#{format("%02d", (seconds % 3600) / 60)}m"
      end
    end

    USAGE_SECTIONS = {
      "Viewer" => [
        ["qm [viewer]", "open the fzf UI: filter, search, preview, resume, triage (default in a terminal)"],
        ["qm gui", "open the web UI in a browser: kanban board, detail view, inbox rail"],
        ["qm caffeinate on|off|auto|status", "keep the Mac from idle-sleeping while the running qm gui lives, or (auto) while any session works (its ☕ toggle)"],
        ["qm open-chat SLUG [--benchmark BRANCH]", "bring the qm gui up on the item's (or a loose--<id>) chat: its open Arc tab, else a new browser tab (a notification's click); --benchmark also opens that branch's benchmark modal"]
      ],
      "Work items" => [
        ["qm new TITLE [flags]", "create a work item, prints its slug (--project P, --branch B, --session ID, --description TEXT, --pf-mode MODE; --kind epic makes an epic, --epic SLUG puts the item in one)"],
        ["qm epic SLUG EPIC_SLUG|--clear|--make|--unmake", "put the item in an epic (one level: not an epic or automation itself) or take it out; --make turns it into an epic (not while in one), --unmake back into a work item (once no item is in it)"],
        ['qm link SLUG "LABEL" URL|--remove', "add a link (an http(s) url) to the item, replacing one with the same label, or remove it"],
        ["qm link SLUG --refresh", "add the Tracker, Notion and heading links an item's GitHub issue (URL in its description) gives and it lacks; never replaces one"],
        ["qm attach SLUG --session ID", "attach a session to a work item (detaches it from any other item)"],
        ["qm detach SLUG --session ID", "detach a session, leaving it unlinked"],
        ["qm note SLUG TEXT", "append a dated progress note (--kind #{NOTE_KINDS.join("|")}, default #{DEFAULT_NOTE_KIND}); text may start with \"- \", or follow --"],
        ["qm retag SLUG POSITION KIND", "change a note's kind (POSITION is the number qm show prints)"],
        ["qm state SLUG STATE", "set the state: #{STATES.join(" | ")}"],
        ["qm link-branch SLUG [BRANCH]", "add a branch to the item (stacks welcome; default: the current branch; --temp: a scratch branch cleanup may delete)"],
        ["qm unlink-branch SLUG BRANCH", "remove a branch (a rename is unlink + link)"],
        ["qm board SLUG [URL]", "set the item's status board URL; no URL prints it, 'clear' removes it (--answers-dir DIR: where blocked answers go)"],
        ["qm board-rows SLUG", "the item's board rows, mirrored from the board-writes hook log (--json)"],
        ["qm board-answer SLUG ROW TEXT", "answer a blocked board row (writes ROW.md into the answers dir)"],
        ["qm move SLUG PROJECT", "reassign the item to another project"],
        ["qm retitle SLUG NEW_TITLE", "change the title (the slug never changes)"],
        ["qm describe SLUG [TEXT]", "replace the Description; '-' or no TEXT reads stdin"],
        ["qm show SLUG", "print the item with its sessions and warnings (an epic: its children and links; a child: its epic)"],
        ["qm draft add SLUG --path P --line N --body TEXT", "record a review finding as a 🤖 GitHub draft on the item's PR for the user to curate and post (--start-line, --side old, --commit SHA, --file, --reply-to THREAD_ID, --pr URL, --body-file F; --summary [--verdict V] for the overall verdict; see qm draft add --help)"],
        ["qm draft list SLUG [--json]", "the item's drafts: review comments, replies, review summaries, chat comments, annotations"],
        ["qm issues-dir SLUG", "print the item's issue drafts directory, creating it (the /draft-issues skill writes there)"],
        ["qm cleanup SLUG [--yes] [--force P]", "plan removing the item's worktrees, test DBs, merged and temp branches, issue drafts; --yes runs the [x] ones, --force adds a ⚠ one"],
        ["qm sweep [--yes] [--force P]", "the same over every .claude/worktrees worktree and worktree-* branch of every known repo, and the issue drafts of resolved or deleted items"],
        ["qm delete SLUG [--force]", "remove an item made by accident and kill its chat; refuses one with notes, branches, 2+ sessions, a board or a description unless --force (sessions just unlink; run qm cleanup first for worktrees)"],
        ["qm list [--kind automation|epic]", "table of all work items (also the default without a terminal), ◆ marking epics and a child's epic; automations only with --kind automation, epics only with --kind epic"],
        ["qm ask QUERY", "find items by meaning: describe what you half-remember (headless claude -p)"],
        ["qm feature-use [--days N]", "which commands, GUI actions and GUI reads were used in the last N days (default 30), and which known ones weren't"],
        ["qm grep PHRASE", "find sessions whose prompts or replies contain PHRASE (rg over transcripts, asides left out), by work item"]
      ],
      "Todos (your own to-do list; the qm gui's Todos tab)" => [
        ['qm todo add [--item SLUG | --project NAME] "text"', "add a todo on top; --item ties it to a work item (shown with the item's project), --project to a project; neither is ever guessed"],
        ["qm todo list", "open todos, numbered in priority order, with project and item"],
        ["qm todo done N", "tick off todo N as qm todo list numbers it"]
      ],
      "Attention" => [
        ["qm attention", "chats by whose move it is (blocked, your turn, working) with context size; expiring transcripts, stale items, merged PRs"],
        ["qm overview --json [PATH]", "snapshot of in-progress and fridge items (chat state, pane, open notes) for the phone work-items page; PATH is written atomically"],
        ["qm overview --url", "print the work-items page's URL (config.yml #{Overview::CONFIG_KEY}:)"],
        ["qm overview --page", "print the page file's path when it changed since last published, else nothing"],
        ["qm overview --page-published", "record the page file as published"],
        ["qm ack SLUG [SESSION_ID]", "accept a transcript degrading un-distilled (permanent, per session)"],
        ["qm snooze SLUG DURATION", "mute the staleness nudge: 1d | 7d | Nd; quiet the chat's current your-turn: turn; or clear"],
        ["qm distill SLUG [--session ID] [--force]", "snapshot every expiring transcript, or the latest (headless claude -p); --force replaces an existing snapshot"]
      ],
      "Sessions" => [
        ["qm resume SLUG [--session ID]", "resume the newest surviving session in a new Warp tab (--here: this terminal)"],
        ["qm start SLUG", "new session for the item, linked via QM_ITEM (--here: this terminal)"],
        ["qm pane-start SLUG", "fresh chat for the item in its pane of the running qm gui (pane-resume SLUG [--session ID]: resume there)"],
        ["qm start-issue N [--project P] [--as-item] [--epic SLUG]", "work item + issue/N-… worktree off fresh origin for GitHub issue N, chat opened in the running qm gui with a read-the-issue kickoff (default project: this repo's, else config.yml's default_project; an item already holding it is reused); every item gets the issue's links (issue_links settings); an issue of an epics.issue_types type starts as an epic, no branch or chat, joined by the items holding its sub-issues, unless --as-item; --epic SLUG: the new item sits in that epic"],
        ['qm loose [--project P] [--model M] [--starter NAME] ["prompt"]', "a loose chat (no work item) in the running qm gui, the prompt as its first message (default project: this repo's; --starter: a config.yml loose_starters entry loads something first); no gui → prints how to start one"],
        ["qm rotate SLUG [--close]", "the running qm gui's context rotation of the item's chat (--close: wrap up & close)"],
        ["qm rotate --self [--close]", "run by a GUI chat after writing its notes: hand over to a fresh chat once this turn ends (the /rotate skill)"],
        ["qm pr SLUG", "open the linked branch's PR in the browser"],
        ["qm pr-requires PR-OR-SHA [--pr PR] [--note TEXT]", "record (locally) that a PR may only merge once an earlier PR or commit is deployed; --note sets/replaces its note (e.g. a backfill to run first), \"\" clears it; --remove, --list (--pr default: the current branch's PR)"],
        ["qm work-on SLUG [--mode M] [--worktree PATH]", "dev-server switch (when the project has one) + the IDE (when configured) on the item's target worktree (stack top, else last linked; created when missing)"],
        ["qm pf-switch SLUG [--mode M] [--worktree PATH]", "serve the item's target worktree with the project's dev server in the item's mode (or --mode)"],
        ["qm ide SLUG [--worktree PATH]", "open the item's target worktree in the IDE (config.yml's ide_command; off when unset)"],
        ["qm term SLUG [--worktree PATH]", "open a Warp tab in the item's target worktree"],
        ["qm pf-mode SLUG [MODE]", "set or print the item's dev-server mode (one of its project's dev_server modes in config.yml)"],
        ["qm pf-status / pf-stop", "what the dev server serves (mode, worktree, running); stop it"],
        ["qm sessions [-n N]", "recently captured sessions"],
        ["qm inbox [-n N]", "captured sessions not linked to any work item"],
        ["qm dismiss SESSION_ID", "drop a session from the inbox"],
        ["qm show-session SESSION_ID", "session details, including its first prompt"],
        ["qm session-item SESSION_ID", "print the title of the work item a session is linked to (for the status line)"]
      ],
      "Hooks" => [
        ["qm hook-session-start", "called by Claude Code: capture, link, inject context"],
        ["qm hook-session-end", "called by Claude Code: capture duration, commits, diff stat"],
        ["qm install-hooks", "print the settings.json hooks snippet (session capture + event/board/snapshot appenders)"],
        ["qm pin-ruby [VERSION|--clear]", "run qm (hooks included) on this Ruby whatever a session's directory pins (default: the running one); --clear unpins"],
        ["qm doctor", "check hooks, Ruby pin and floor, data root, qm.log errors and recent capture; exits 1 on a ✗"]
      ],
      "Settings" => [
        ["qm config get [PATH]", "print config.yml (or the value at a dotted PATH, e.g. projects.App.test_db; unset: exit 1)"],
        ["qm config set PATH VALUE", "set a key; VALUE is YAML ([dev, ngrok] a list, true, 4); errors refuse the write (exit 1), warnings don't"],
        ["qm config unset PATH", "remove a key or a whole project (warns how many work items still name it)"],
        ["qm config path", "print config.yml's location"]
      ],
      "Automations (claude.ai routines, on with automations.token_source; runner: local ones run on this machine)" => [
        ["qm automation new TITLE --project P", "create a claude.ai routine as a kind: automation item with empty local files, then open its chat with qm's brief (--description TEXT; --runner local: one that runs on this machine, created disabled)"],
        ["qm automation edit SLUG", "open or resume the automation's chat with the brief; a running chat gets nothing typed, the brief is printed"],
        ["qm automation list", "every automation; local ones' queue and last run, the tick; each routine's last and next run, drift, and routines not managed by qm"],
        ["qm automation show SLUG", "one automation: schedule, repos, connectors, links and its last 10 runs (local: guard, flow, queue, runs)"],
        ["qm automation adopt ID --project P [--slug S]", "take a routine under qm: local files + a kind: automation work item"],
        ["qm automation push SLUG [--force]", "send the local files (creates the routine the first time); refuses a routine changed outside qm unless --force"],
        ["qm automation pull SLUG", "the routine overwrites the local files (kept as .bak)"],
        ["qm automation pause|resume|run SLUG", "pause or resume (a local edit, then push), or run it now; local: queue a run (its guard's new items) and tick"],
        ["qm automation resume SLUG --skip-existing", "local: mark the guard's current items seen, then enable; only later items queue runs"],
        ["qm automation delete SLUG [--yes]", "delete the routine (or pause it when the API can't) and resolve the item; local: refused while a run is live"],
        ["qm automation runs SLUG", "a local automation's queued runs and its last 20 runs with their status"],
        ["qm automation retry SLUG RUN_ID", "queue an ended local run's item again, then tick"],
        ["qm automation tick [--dry-run [SLUG]]", "one local scheduler pass (launchd runs it every 5 min); --dry-run only runs guards and writes nothing"],
        ["qm automation install-tick [--print]", "install the LaunchAgent that ticks every 5 min (--print: show its plist, write nothing)"],
        ["qm automation uninstall-tick", "remove that LaunchAgent"]
      ]
    }.freeze

    def usage
      puts "qm — Claude Code session & work-item tracker"
      width = USAGE_SECTIONS.values.flatten(1).map { |entry, _| entry.length }.max
      USAGE_SECTIONS.each do |section, entries|
        puts "", "#{section}:"
        entries.each { |entry, description| puts "  #{entry.ljust(width)}  #{description}" }
      end
    end
  end
end
