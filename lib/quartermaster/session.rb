# frozen_string_literal: true

module Quartermaster
  # One captured Claude Code session, built by SessionLog from its JSONL
  # events — the only reader of the event schema. Everything else asks the
  # session; nothing else indexes into event hashes.
  class Session
    attr_reader :id

    # A session an item lists but the log never captured (pre-qm, or another
    # machine): identity only, every other question answers nil/false.
    def self.uncaptured(id)
      new(id: id, start_event: nil, last_event: nil, live: false)
    end

    def initialize(id:, start_event:, last_event:, live:)
      @id = id
      @start_event = start_event
      @last_event = last_event
      @live = live
    end

    def captured? = !@start_event.nil?
    def live? = @live

    # Timestamps stay the stored ISO strings: they sort lexically and every
    # surface slices or Time.parses to taste.
    def started_ts = @start_event && @start_event["ts"]
    def last_ts = @last_event && @last_event["ts"]

    def cwd = @start_event && @start_event["cwd"]
    # The claude process, as the SessionStart hook found it; #live? checks it.
    def pid = @start_event && @start_event["pid"]
    def branch = @start_event && @start_event["branch"]
    def project = @start_event && @start_event["project"]
    # The QM_ITEM slug the session was launched for, when the viewer/GUI
    # started it for an item — pre-claimed, so the inbox skips it.
    def launched_for = @start_event && @start_event["work_item"]
    # The item an aside (QM_ASIDE) was asked about; asides belong to no one.
    def aside_for = @start_event && @start_event["aside"]
    # The QM_LOOSE id of a loose chat (LooseChat): no item, by intent.
    def loose_id = @start_event && @start_event["loose"]
    # What listings show in the work-item column: the launch item, or the aside/loose marker.
    def item_label = launched_for || (aside_for && "aside:#{aside_for}") || (loose_id && "loose:#{loose_id}")

    def ended? = @last_event && @last_event["event"] == "end"
    def duration_s = ended? ? @last_event["duration_s"] : nil
    def end_reason = ended? ? @last_event["reason"] : nil
    def commits = ended? ? Array(@last_event["commits"]) : []

    # live: running right now (never resume — it would fork). resumable: the
    # transcript still exists, claude --resume works. expired: Claude Code
    # pruned the transcript; only rehydration from the item's notes remains.
    def tier
      return "uncaptured" unless captured?
      return "live" if live?

      transcript ? "resumable" : "expired"
    end

    def transcript
      return @transcript if defined?(@transcript)

      @transcript = Quartermaster.locate_transcript(id, @start_event && @start_event["transcript_path"], live: live?)
    end

    def first_prompt
      return @first_prompt if defined?(@first_prompt)

      @first_prompt = Quartermaster.first_prompt(transcript, live: live?)
    end
  end
end
