# frozen_string_literal: true

module Quartermaster
  # The fzf viewer's rows and pickers, and printing an item or session
  # (viewer, sessions-view, inbox-view and cycle-filter dispatch in CLI#run).
  module CliViewer
    COMMANDS = {
      "sessions" => :cmd_sessions,
      "show" => :cmd_show,
      "show-session" => :cmd_show_session,
      "viewer-rows" => :cmd_viewer_rows,
      "session-rows" => :cmd_session_rows,
      "inbox-rows" => :cmd_inbox_rows,
      "choose-state" => :cmd_choose_state,
      "choose-project" => :cmd_choose_project,
      "attach-session" => :cmd_attach_session,
      "item-from-session" => :cmd_item_from_session,
      "session-item" => :cmd_session_item
    }.freeze

    private

    def cmd_sessions(argv)
      limit = 15
      OptionParser.new { |o| o.on("-n N", Integer) { |v| limit = v } }.parse(argv)

      print_session_rows(SessionLog.new.sessions, limit)
    end

    STATE_BADGES = {
      "in_progress" => ["●", 32],
      "fridge" => ["❄", 36],
      "resolved" => ["✓", 90]
    }.freeze

    TIER_BADGES = {
      "live" => ["● live", 33],
      "resumable" => ["↻ resumable", 32],
      "expired" => ["✗ expired", 90]
    }.freeze

    def cmd_viewer_rows(argv)
      state = nil
      OptionParser.new { |o| o.on("--state STATE") { |v| state = v } }.parse(argv)
      state ||= viewer_filter(cycle: false)

      items = WorkItem.all
      items = case state
              when "all" then items
              when "open" then items.reject { |i| i.state == "resolved" }
              else items.select { |i| i.state == state }
              end
      live_ids = SessionLog.new.sessions.select(&:live?).map(&:id)
      scan = Attention.new
      attention = scan.entries.group_by(&:slug)
      items = items.sort_by { |i| [attention.key?(i.slug) ? 0 : 1, -scan.activity_at(i).to_f] }

      items.each do |item|
        badge, color = STATE_BADGES.fetch(item.state, ["?", 0])
        live = item.sessions.any? { |s| live_ids.include?(s["id"]) }
        state_col = paint(("#{badge} #{item.state}#{live ? " ▶" : ""}").ljust(15), color)
        reasons = attention[item.slug]&.map(&:message)&.uniq&.join("; ")
        puts [item.slug, state_col, item.project.to_s.ljust(12),
              item.title.to_s[0, 44].ljust(44),
              item.branches.empty? ? "-" : item.branches.join(" "),
              reasons ? paint("⚠ #{reasons}", 33) : ""].join("\t")
      end
    end

    def cmd_session_rows(argv)
      item = WorkItem.find(argv.first || abort("usage: qm session-rows SLUG"))
      puts session_lines(item)
    end

    def cmd_inbox_rows(_argv)
      SessionLog.new.inbox.sort_by(&:last_ts).reverse.each do |session|
        snippet = session.first_prompt.to_s.gsub(/\s+/, " ")[0, 60]
        puts [session.id, session.last_ts[0, 16],
              short_path(session.cwd).ljust(34)[0, 34], snippet].join("\t")
      end
    end

    def cmd_show(argv)
      item = WorkItem.find(argv.first || abort("usage: qm show SLUG"))
      GhStack.sync(item)
      stacks = GhStack.chains(item).select { |chain| chain["kind"] == "stack" }
      pr_status = PrStatus.new
      branch_bits = item.branches.map do |branch|
        state = pr_status.state_for(item, branch)
        state ? "#{branch} (PR #{state})" : branch
      end
      meta = [item.state, item.project, *branch_bits,
              item.issue_number && "issue ##{item.issue_number}",
              item.front["snooze_until"] && "snoozed until #{item.front["snooze_until"]}",
              (server = item.dev_server) && "#{server.command} #{item.pf_mode}",
              "created #{item.front["created"]}"].compact.join(" · ")

      puts paint(item.title.to_s, 1)
      puts meta
      stacks.each { |chain| puts stack_line(chain) }
      # The one thing to know about this item, up top — same rule as the GUI card.
      if (headline = item.headline_note)
        puts note_line(headline)
      end
      Attention.new.entries_for(item).each { |e| puts paint("⚠ #{e.message}", 33) }
      puts "", paint("Sessions", 1)
      lines = session_lines(item)
      puts(lines.empty? ? "(none)" : lines.map { |l| l.tr("\t", "  ") })
      usage_lines(item).each { |line| puts line }
      puts
      puts show_body(item)
    end

    # Tokens and API-equivalent cost (docs/areas/side-panel.md): the total, then a line
    # per session. Nothing for an item without sessions.
    def usage_lines(item)
      ledger = UsageLedger.new
      usage = ItemUsage.for(item, ledger: ledger)
      ledger.save
      return [] if usage.empty?

      lines = ["", "#{paint("Usage", 1)}  #{usage.line}"]
      lines << paint("  partial: no price for #{usage.unpriced.join(", ")}", 33) if usage.partial?
      usage.rows.each do |row|
        spent = row["known"] ? ["#{ItemUsage.human_tokens(row["tokens"])} tok", "~#{ItemUsage.dollars(row["cost"])}"] : ["expired, never tallied"]
        bits = [row["id"][0, 8], row["aside"] ? "aside" : nil, *spent,
                row["agents"].positive? ? "#{row["agents"]} sub-agent#{"s" unless row["agents"] == 1}" : nil]
        lines << "  #{bits.compact.join(" · ")}"
      end
      lines
    end

    # The body verbatim, except that notes gain their position and kind — the
    # handles `qm retag` takes, and the marker is invisible on a default note.
    def show_body(item)
      item.body_with_notes { |note| note_line(note) }.strip
    end

    def cmd_show_session(argv)
      session_id = argv.first
      abort("usage: qm show-session SESSION_ID") unless session_id

      session = SessionLog.new.session_for(session_id)
      abort("qm: unknown session #{session_id}") unless session

      puts paint("Session #{session_id}", 1)
      puts "tier: #{session.tier}"
      puts "cwd: #{short_path(session.cwd)}"
      puts "branch: #{session.branch || "-"} · project: #{session.project || "-"} · work item: #{session.item_label || "-"}"
      puts "started: #{session.started_ts}"
      if session.ended?
        puts "ended: #{session.last_ts} (#{format_duration(session.duration_s)}, #{session.end_reason})"
        session.commits.each { |c| puts "  commit: #{c}" }
      end
      return unless session.first_prompt

      puts
      puts paint("First prompt", 1)
      puts session.first_prompt[0, 400]
    end

    def cmd_choose_state(argv)
      slug = argv.first
      abort("usage: qm choose-state SLUG") unless slug

      item = WorkItem.find(slug)
      choice = Viewer.pick(STATES, prompt: "state for #{item.slug} >")
      item.update_state(choice) if choice && !choice.empty?
    end

    def cmd_choose_project(argv)
      slug = argv.first
      abort("usage: qm choose-project SLUG") unless slug

      item = WorkItem.find(slug)
      options = (ProjectMap.new.known_projects + [ProjectMap::NO_PROJECT]).uniq
      choice = Viewer.pick(options, prompt: "project for #{item.slug} >")
      item.move_to(choice) if choice && !choice.empty?
    end

    def cmd_attach_session(argv)
      session_id = argv.first
      abort("usage: qm attach-session SESSION_ID") unless session_id

      items = WorkItem.all.reject { |i| i.state == "resolved" }
      choice = Viewer.pick(items.map { |i| "#{i.slug}\t#{i.title}" },
                           prompt: "attach #{session_id[0, 8]} to >")
      return unless choice && !choice.empty?

      slug = choice.split("\t").first
      report_claim(WorkItem.find(slug).claim_session(session_id), session_id, slug)
    end

    def cmd_item_from_session(argv)
      session_id = argv.first
      abort("usage: qm item-from-session SESSION_ID") unless session_id

      abort("qm: unknown session #{session_id}") unless SessionLog.new.last_start_for(session_id)

      print "Title for the new work item: "
      title = $stdin.gets.to_s.strip
      return if title.empty?

      item, vacated = WorkItem.from_session(session_id, title: title)
      report_claim(vacated, session_id, item.slug)
      puts "Created #{item.slug}"
    rescue ArgumentError => e
      abort("qm: #{e.message}")
    end

    # Print the title of the work item a session is linked to (nothing if
    # unlinked). Read-only and quiet — the status line calls this every refresh.
    def cmd_session_item(argv)
      item = WorkItem.for_session(argv.first)
      puts item.title if item
    end

    # The viewer's state filter persists in a file so a single fzf key can
    # cycle it — macOS terminals have no reliable Alt key for per-state binds.
    def viewer_filter(cycle:)
      stored = begin
        File.read(Viewer::FILTER_FILE).strip
      rescue StandardError
        Viewer::FILTER_CYCLE.first
      end
      stored = Viewer::FILTER_CYCLE.first unless Viewer::FILTER_CYCLE.include?(stored)
      if cycle
        stored = Viewer::FILTER_CYCLE[(Viewer::FILTER_CYCLE.index(stored) + 1) % Viewer::FILTER_CYCLE.size]
        Quartermaster.ensure_setup
        File.write(Viewer::FILTER_FILE, stored)
      end
      stored
    end

    # One gh-stack, trunk first: "stack: main → a (#1) → b (#2) ⟳".
    def stack_line(chain)
      layers = chain["layers"].map do |layer|
        [layer["branch"], layer["pr_number"] && "(##{layer["pr_number"]})", ("⟳" if layer["needsRestack"])].compact.join(" ")
      end
      "stack: #{[chain["trunk"], *layers].join(" → ")}"
    end

    # Newest first, matching what plain resume picks — the top row of the ^X
    # view is the session enter on the work item would resume. Sessions the
    # log never captured sink to the bottom. 'when' is last activity, like
    # every session list.
    def session_lines(item)
      Quartermaster.item_sessions(item).map do |session|
        if session.tier == "uncaptured"
          [session.id, paint("? uncaptured".ljust(12), 90), "-", "-"].join("\t")
        else
          label, color = TIER_BADGES.fetch(session.tier)
          [session.id, paint(label.ljust(12), color), session.last_ts && session.last_ts[0, 16],
           short_path(session.cwd)].join("\t")
        end
      end
    end
  end
end
