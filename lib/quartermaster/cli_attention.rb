# frozen_string_literal: true

module Quartermaster
  # What needs the user: the inbox, chat attention, nudges and their snoozes,
  # the phone overview, distilling expiring transcripts.
  module CliAttention
    COMMANDS = {
      "inbox" => :cmd_inbox,
      "dismiss" => :cmd_dismiss,
      "attention" => :cmd_attention,
      "overview" => :cmd_overview,
      "ack" => :cmd_ack,
      "snooze" => :cmd_snooze,
      "choose-snooze" => :cmd_choose_snooze,
      "distill" => :cmd_distill
    }.freeze

    private

    def cmd_inbox(argv)
      limit = 15
      OptionParser.new { |o| o.on("-n N", Integer) { |v| limit = v } }.parse(argv)

      unlinked = SessionLog.new.inbox
      if unlinked.empty?
        puts "Inbox empty — every captured session is linked to a work item or dismissed."
        return
      end
      print_session_rows(unlinked, limit)
    end

    def cmd_dismiss(argv)
      session_id = argv.first
      abort("usage: qm dismiss SESSION_ID") unless session_id

      SessionLog.new.dismiss(session_id)
    end

    # Chats first (whose move it is, longest-waiting first), then the
    # slower nudges: expiring transcripts, stale items, merged PRs.
    def cmd_attention(_argv)
      chats = ChatAttention.new.entries
      entries = Attention.new.entries
      if chats.empty? && entries.empty?
        puts "Nothing needs attention."
        return
      end
      print_chat_attention(chats)
      puts if chats.any? && entries.any?
      width = entries.map { |e| e.slug.length }.max
      entries.each do |entry|
        suffix = entry.session_id ? " (session #{entry.session_id[0, 8]})" : ""
        puts "#{entry.slug.ljust(width)}  #{entry.message}#{suffix}"
      end
    end

    # --json [PATH]: the phone page's snapshot, to PATH (atomically) or stdout.
    # --url: the published work-items page from config.yml, for the skill.
    def cmd_overview(argv)
      case argv.first
      when "--json"
        snapshot = Overview.new.snapshot
        json = JSON.generate(snapshot)
        if argv[1]
          Overview.write(argv[1], json)
          puts "#{Overview.summary(snapshot)} → #{argv[1]}"
        else
          puts json
        end
      when "--url"
        url = Overview.artifact_url
        unless url
          abort("qm overview: no #{Overview::CONFIG_KEY}: in #{Quartermaster.shorten_home(CONFIG_FILE)} — " \
                "publish skills/work-items/page.html and put its claude.ai URL there")
        end
        puts url
      when "--page"
        page = Overview.unpublished_page
        puts page if page
      when "--page-published"
        Overview.page_published
      else
        abort("usage: qm overview --json [PATH] | --url | --page | --page-published")
      end
    end

    CHAT_BADGES = {
      "blocked" => ["🔴 blocked", 31],
      "your_turn" => ["🟠 your turn", 33],
      "working" => ["🔵 working", 34],
      "waiting" => ["🟣 waiting on sub-agent", 35],
      "none" => ["⚪ no chat", 90]
    }.freeze

    def print_chat_attention(chats, now: Time.now)
      width = chats.map { |e| e.slug.length }.max
      chats.each do |entry|
        label, color = CHAT_BADGES.fetch(entry.state)
        label = "#{label} (snoozed)" if entry.snoozed
        detail = entry.waiting_on&.first || entry.tool
        waiting = entry.since ? [format_duration((now - entry.since).to_i), detail].compact.join(" · ") : ""
        puts [paint(label.ljust(21), entry.snoozed ? 90 : color), entry.slug.ljust(width),
              waiting.ljust(24), context_label(entry, now)].join("  ").rstrip
      end
    end

    def context_label(entry, now)
      return "" unless entry.context_tokens

      warm = entry.cache_warm_until && entry.cache_warm_until > now
      cache = warm ? "cache warm #{format_duration((entry.cache_warm_until - now).to_i)}" : "cache cold"
      "ctx #{(entry.context_tokens / 1000.0).round}k · #{cache}"
    end

    def cmd_ack(argv)
      slug, session_id = argv
      abort("usage: qm ack SLUG [SESSION_ID]") unless slug

      ids = Attention.new.acknowledge_all(WorkItem.find(slug), session_id: session_id)
      if ids.empty?
        puts "#{slug}: no degradation warnings to acknowledge"
      else
        puts "#{slug}: acknowledged degradation of #{ids.size} session(s)"
      end
    end

    def cmd_snooze(argv)
      slug, duration = argv
      abort("usage: qm snooze SLUG (1d | 7d | Nd | turn | clear)") unless slug && duration

      item = WorkItem.find(slug)
      begin
        date = item.snooze(duration)
      rescue ArgumentError
        abort("usage: qm snooze SLUG (1d | 7d | Nd | turn | clear)")
      end
      puts case date
           when nil then "#{slug}: snooze cleared"
           when Time then "#{slug}: your-turn snoozed until the chat's next turn ends"
           else "#{slug}: snoozed until #{date}"
           end
    end

    def cmd_choose_snooze(argv)
      slug = argv.first
      abort("usage: qm choose-snooze SLUG") unless slug

      WorkItem.find(slug)
      choice = Viewer.pick(%w[1d 7d clear], prompt: "snooze #{slug} >")
      cmd_snooze([slug, choice]) if choice && !choice.empty?
    end

    def cmd_distill(argv)
      slug = argv.shift
      session_id = nil
      force = false
      OptionParser.new do |o|
        o.on("--session SESSION_ID") { |v| session_id = v }
        o.on("--force") { force = true }
      end.parse(argv)
      abort("usage: qm distill SLUG [--session ID] [--force]") unless slug

      Quartermaster.distill(slug, session_id: session_id, force: force).each do |result|
        puts "Distilled session #{result[:session_id][0, 8]} (#{result[:transcript_bytes] / 1000}kB transcript); snapshot added to #{slug}:"
        puts result[:snapshot]
      end
    end
  end
end
