# frozen_string_literal: true

module Quartermaster
  # `qm cleanup` and `qm sweep`: the plan, and running it with a progress bar;
  # `qm delete`, which removes the item itself.
  module CliCleanup
    COMMANDS = {
      "cleanup" => :cmd_cleanup,
      "sweep" => :cmd_sweep,
      "delete" => :cmd_delete
    }.freeze

    private

    def cmd_delete(argv)
      force = argv.delete("--force") ? true : false
      slug = argv.first
      abort("usage: qm delete SLUG [--force]") unless slug && argv.size == 1

      ItemDeletion.new(runner: @runner || CommandRunner.new).call(slug, force: force)
      puts "deleted #{slug}"
    end

    def cmd_cleanup(argv)
      options = cleanup_options(argv)
      slug = argv.shift
      abort("usage: qm cleanup SLUG [--yes] [--force PATH|BRANCH ...]") unless slug

      cleanup = Cleanup.new
      run_cleanup(cleanup, cleanup.plan_item(WorkItem.find(slug)), options)
    end

    def cmd_sweep(argv)
      options = cleanup_options(argv)
      cleanup = Cleanup.new
      run_cleanup(cleanup, cleanup.plan_sweep, options)
    end

    def cleanup_options(argv)
      options = { yes: false, force: [] }
      OptionParser.new do |o|
        o.on("--yes") { options[:yes] = true }
        o.on("--force KEY") { |v| options[:force] << v }
      end.parse!(argv)
      options
    end

    # Prints the plan; --yes removes what is ticked plus every --force entry.
    def run_cleanup(cleanup, plan, options)
      force = Cleanup.resolve_ids(plan, options[:force])
      plan.notes.each { |note| puts paint(note, 90) }
      puts "#{plan.scope}: #{plan.summary}"
      plan.entries.each { |entry| puts cleanup_line(entry, force) }
      return if plan.empty?
      unless options[:yes]
        puts paint("--yes removes the [x] entries; --force PATH|BRANCH|SLUG/FILE adds a ⚠ one", 90)
        return
      end

      outcomes = execute_cleanup(cleanup, plan, force)
      puts paint("nothing ticked", 90) if outcomes.empty?
      outcomes.each { |outcome| puts outcome_line(outcome) } if $stdout.tty?
      exit 1 if outcomes.any? { |o| o.result == "failed" }
    end

    # A terminal gets a progress bar redrawn in place, naming the entry being
    # worked on; anything else (a pipe, a background run) gets each outcome
    # line as it happens, flushed for a tailing reader.
    def execute_cleanup(cleanup, plan, force)
      selected = plan.entries.select(&:ticked).map(&:id)
      unless $stdout.tty?
        stream = lambda do |outcome, _index, _total|
          puts outcome_line(outcome)
          $stdout.flush
        end
        return cleanup.execute(plan, selected: selected, force: force, on_outcome: stream)
      end

      drawn = false
      draw = lambda do |done, total, doing|
        drawn = true
        $stdout.print "\r#{progress_bar(done, total, doing)}\e[K"
        $stdout.flush
      end
      outcomes = cleanup.execute(plan, selected: selected, force: force,
                                       on_start: ->(entry, index, total) { draw.(index - 1, total, cleanup_doing(entry)) },
                                       on_outcome: ->(_outcome, index, total) { draw.(index, total, "") })
      $stdout.print "\n" if drawn
      outcomes
    end

    def outcome_line(outcome)
      color = { "removed" => 32, "skipped" => 33, "failed" => 31 }.fetch(outcome.result)
      "#{paint(outcome.result.ljust(7), color)} #{outcome.id.sub(/\A\w+:/, "")}: #{outcome.message}"
    end

    def cleanup_doing(entry)
      return "removing worktree #{File.basename(entry.path)}…" if entry.worktree?
      return "deleting issue draft #{File.basename(entry.path)}…" if entry.issue_draft?

      "deleting branch #{entry.branch}…"
    end

    # "[#####     ] 112/248  removing worktree agent-a1b2…", cut to the
    # terminal's width so the \r redraw never wraps.
    def progress_bar(done, total, doing)
      width = terminal_width
      count = "#{done}/#{total}"
      bar_width = (width / 3).clamp(10, 40)
      filled = total.zero? ? bar_width : bar_width * done / total
      line = "[#{"#" * filled}#{" " * (bar_width - filled)}] #{count}#{doing.empty? ? "" : "  #{doing}"}"
      line.length < width ? line : "#{line[0, width - 2]}…"
    end

    def terminal_width
      cols = $stdout.winsize[1]
      cols.positive? ? cols : 80
    rescue StandardError
      80
    end

    CLEANUP_MARKS = { "ok" => ["", 0], "warn" => ["⚠ ", 33], "blocked" => ["⛔ ", 31] }.freeze

    def cleanup_line(entry, force)
      ticked = entry.ticked || force.include?(entry.id)
      mark, color = CLEANUP_MARKS.fetch(entry.status)
      target = if entry.worktree? then short_path(entry.path)
               elsif entry.issue_draft? then "#{entry.item}/#{File.basename(entry.path)}"
               else entry.branch
               end
      head = if entry.worktree? then " (#{entry.branch || "detached"})"
             elsif entry.issue_draft? then " “#{entry.title}”"
             else ""
             end
      dbs = entry.db_names&.any? ? " · test DBs: #{entry.db_names.join(", ")}" : ""
      details = (entry.reasons + entry.notes).join("; ")
      line = "  [#{ticked ? "x" : " "}] #{paint("#{mark}#{entry.kind}", color)} #{target}#{head}#{dbs}"
      details.empty? ? line : "#{line} — #{details}"
    end
  end
end
