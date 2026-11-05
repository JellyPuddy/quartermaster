# frozen_string_literal: true

module Quartermaster
  # The phone page's picture of the user's work items (`qm overview --json`):
  # a mechanical snapshot the /work-items skill writes into the work-items
  # artifact's database, which the page (skills/work-items/page.html)
  # renders. No Claude involved in building it, and no Claude reads it —
  # the skill hands the file to ArtifactData by path.
  #
  # In progress first, then the fridge; resolved items are only counted.
  # Within a state: whose move it is (ChatAttention's order), then the most
  # recent activity. Bounded so it always fits one artifact db document.
  class Overview
    VERSION = 1
    STATE_ORDER = %w[in_progress fridge].freeze
    MAX_ITEMS = 60
    TITLE_CHARS = 160
    NOTE_CHARS = 280
    WAITING_SHOWN = 3
    WAITING_CHARS = 120
    # An artifact db document holds at most 256 KiB; stay well clear of it.
    MAX_BYTES = 200 * 1024
    # config.yml key holding the published work-items page's claude.ai URL.
    CONFIG_KEY = "overview_artifact"
    PAGE = File.expand_path("../../skills/work-items/page.html", __dir__)
    # The SHA-256 of the page as last published, written by --page-published.
    PUBLISHED_PAGE_FILE = File.join(ROOT, "overview-page.sha256")

    def initialize(session_log: SessionLog.new, event_log: EventLog.new, tmux: Tmux.new, now: Time.now,
                   rate_limits: RateLimits.new, max_items: MAX_ITEMS, max_bytes: MAX_BYTES)
      @max_items = max_items
      @max_bytes = max_bytes
      @session_log = session_log
      @chat_attention = ChatAttention.new(session_log: session_log, event_log: event_log)
      @tmux = tmux
      @rate_limits = rate_limits
      @now = now
    end

    def snapshot
      all = WorkItem.all
      shown = all.select { |item| STATE_ORDER.include?(item.state) }
      chats = @chat_attention.entries.to_h { |entry| [entry.slug, entry] }
      panes = @tmux.sessions
      rows = shown.map { |item| row(item, chats[item.slug], panes) }
                  .sort_by { |r, key| [STATE_ORDER.index(r["state"]), *key, r["slug"]] }
                  .map(&:first)
      bounded(rows, counts(all), @rate_limits.payload)
    end

    # Atomic: the skill may hand the file to ArtifactData while a second run
    # is writing, and a torn file would land in the db as a broken page.
    def self.write(path, json)
      dir = File.dirname(File.expand_path(path))
      FileUtils.mkdir_p(dir)
      tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.tmp")
      File.write(tmp, json)
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end

    # The one line the skill replies with, so it never reads the file itself:
    # "14 items: 3 in progress, 11 fridge · 2 blocked, 1 your turn".
    def self.summary(doc)
      counts = doc["counts"]
      states = STATE_ORDER.map { |s| "#{counts["states"][s]} #{STATE_LABELS.fetch(s).downcase}" }
      chats = %w[blocked your_turn waiting].filter_map do |s|
        n = counts["chats"][s]
        "#{n} #{s.tr("_", " ")}" if n.positive?
      end
      line = "#{counts["shown"]} item#{counts["shown"] == 1 ? "" : "s"}: #{states.join(", ")}"
      line += " (#{counts["omitted"]} left out)" if counts["omitted"].positive?
      chats.empty? ? line : "#{line} · #{chats.join(", ")}"
    end

    # nil until the user (or the main session) puts the published page's URL in
    # config.yml. A broken config reads as unset.
    def self.artifact_url(config_file = CONFIG_FILE)
      return nil unless File.exist?(config_file)

      value = (YAML.safe_load(File.read(config_file)) || {})[CONFIG_KEY]
      value.is_a?(String) && !value.strip.empty? ? value.strip : nil
    rescue StandardError => e
      Quartermaster.log_error("overview-config", e)
      nil
    end

    # The repo's page when it differs from what was last published to the
    # artifact, else nil. Nothing republishes the artifact by itself, so a
    # page change sat unpublished until someone noticed what was missing.
    def self.unpublished_page(page = PAGE, record = PUBLISHED_PAGE_FILE)
      published = File.exist?(record) ? File.read(record).strip : nil
      Digest::SHA256.file(page).hexdigest == published ? nil : page
    end

    def self.page_published(page = PAGE, record = PUBLISHED_PAGE_FILE)
      write(record, Digest::SHA256.file(page).hexdigest)
    end

    private

    # [row, sort key within its state].
    def row(item, chat, panes)
      chat_state = chat&.state || "none"
      activity = chat&.activity || last_activity(item)
      rank = chat ? chat.rank : ChatAttention::STATES.index("none")
      data = {
        "slug" => item.slug,
        "title" => Quartermaster.clip(item.title.to_s, TITLE_CHARS),
        "state" => item.state,
        "project" => item.project,
        "branches" => item.branches,
        "chat" => {
          "state" => chat_state,
          "since" => chat&.since&.utc&.iso8601,
          "snoozed" => chat&.snoozed ? true : false,
          "waitingOn" => Array(chat&.waiting_on).first(WAITING_SHOWN).map { |w| Quartermaster.clip(w.to_s, WAITING_CHARS) }
        },
        "paneLive" => panes.include?(item.slug),
        "lastActivity" => activity&.utc&.iso8601,
        "openNotes" => open_notes(item),
        "board" => item.board
      }
      [data, [rank, -activity.to_f]]
    end

    def open_notes(item)
      item.injectable_notes.select(&:open?).map do |note|
        { "position" => note.position, "stamp" => note.stamp, "text" => Quartermaster.clip(note.text, NOTE_CHARS) }
      end
    end

    def last_activity(item)
      ts = Quartermaster.item_sessions(item, session_log: @session_log).first&.last_ts
      ts && Time.parse(ts)
    rescue ArgumentError
      nil
    end

    def counts(all)
      by_state = all.group_by(&:state).transform_values(&:size)
      STATES.to_h { |state| [state, by_state.fetch(state, 0)] }
    end

    # Drops from the tail (the quietest fridge items) until the cap and the
    # byte budget both hold; `omitted` says how many the page doesn't show.
    def bounded(rows, counts, rate_limits)
      rows = rows.first(@max_items)
      dropped = counts.values_at(*STATE_ORDER).sum - rows.size
      loop do
        doc = document(rows, counts, dropped, rate_limits)
        return doc if rows.empty? || JSON.generate(doc).bytesize <= @max_bytes

        rows = rows[0...-1]
        dropped += 1
      end
    end

    def document(rows, counts, omitted, rate_limits)
      chats = ChatAttention::STATES.to_h { |state| [state, rows.count { |r| r["chat"]["state"] == state }] }
      {
        "v" => VERSION,
        "generatedAt" => @now.utc.iso8601,
        "counts" => { "states" => counts, "chats" => chats, "shown" => rows.size, "omitted" => omitted },
        "rateLimits" => rate_limits,
        "items" => rows
      }
    end
  end
end
