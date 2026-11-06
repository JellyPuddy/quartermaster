# frozen_string_literal: true

require "json"
require "yaml"
require "date"
require "time"
require "fileutils"
require "open3"
require "optparse"
require "shellwords"
require "socket"
require "pathname"
require "securerandom"
require "digest"
require "uri"
require "net/http"
require "pty"
require "io/console"
require "rbconfig"
require "tmpdir"

module Quartermaster
  # Raised when distill targets a session that already has a snapshot and no
  # force was given. A distinct class so the GUI can turn it into a confirm
  # dialog while the CLI's generic ArgumentError handling still aborts cleanly.
  class AlreadyDistilledError < ArgumentError; end

  EXECUTABLE = File.expand_path("../quartermaster", __dir__)
  LIVE_ROOT = File.expand_path("~/.claude/quartermaster")
  ROOT = File.expand_path(ENV.fetch("QM_ROOT", LIVE_ROOT))
  TRANSCRIPTS_DIR = File.expand_path(ENV.fetch("QM_TRANSCRIPTS_DIR", "~/.claude/projects"))
  WORK_ITEMS_DIR = File.join(ROOT, "work-items")
  AUTOMATIONS_DIR = File.join(ROOT, "automations")
  CONFIG_FILE = File.join(ROOT, "config.yml")
  LOG_FILE = File.join(ROOT, "qm.log")
  EVENT_VERSION = 1
  WORK_ITEM_VERSION = 1
  STATES = %w[in_progress active fridge resolved].freeze
  # What a note is for, which decides whether the SessionStart hook injects it.
  # 'open' is unresolved and user-facing, so it outranks recency; 'decision' is a
  # choice or finding a later session would get wrong without; 'history' is how the
  # work got done — kept in the file, never injected.
  NOTE_KINDS = %w[open decision history].freeze
  # An untagged note is a decision: an untagged mechanics note merely ages out of
  # the window, while an untagged decision defaulted to history would vanish
  # silently and only surface as a repeated mistake sessions later.
  DEFAULT_NOTE_KIND = "decision"
  # How many of the newest notes the SessionStart hook injects. The rest stay one
  # `qm show` away — a long-running item's full note history costs thousands of
  # tokens in every session, and its oldest notes are the least likely to matter.
  INJECTED_NOTES = 5
  # Open notes are injected on top of that window, since an item's blockers are the
  # one thing that must not age out. Capped because nothing un-tags a stale one.
  INJECTED_OPEN_NOTES = 3
  # Human copy for the taxonomies, keyed by the model values above. Served to
  # the GUI page as a JSON bootstrap (Gui#page), so the JS renders the model
  # instead of restating it — fetch raises when a new value ships without copy.
  STATE_LABELS = {
    "in_progress" => "In progress", "active" => "Active", "fridge" => "Fridge", "resolved" => "Resolved"
  }.freeze
  NOTE_KIND_HINTS = {
    "open" => "unresolved, always re-injected",
    "decision" => "a choice or finding",
    "history" => "mechanics, never re-injected"
  }.freeze
  # What the session sheet says when there are no turns to show for a tier.
  TIER_FALLBACKS = {
    "expired" => "Transcript pruned by Claude Code — only capture metadata and snapshots remain.",
    "uncaptured" => "Session was never captured (it predates qm's hooks)."
  }.freeze

  def self.taxonomies
    {
      "states" => STATES.map { |s| { "key" => s, "label" => STATE_LABELS.fetch(s) } },
      "noteKinds" => NOTE_KINDS.map { |k| { "key" => k, "hint" => NOTE_KIND_HINTS.fetch(k) } },
      "defaultNoteKind" => DEFAULT_NOTE_KIND,
      "tierFallbacks" => TIER_FALLBACKS
    }
  end

  # The first-run config.yml: what ConfigFile writes for no projects.
  CONFIG_SEED = <<~YAML
    # Edited by qm (Settings view / qm config); key reference: docs/overview.md
    projects: {}
  YAML

  # Whether this process runs on the live data root, not a test or smoke-test one.
  def self.live_root?(root = ROOT) = root == LIVE_ROOT

  def self.ensure_setup
    FileUtils.mkdir_p(WORK_ITEMS_DIR)
    File.write(CONFIG_FILE, CONFIG_SEED) unless File.exist?(CONFIG_FILE)
  end

  # qm.log's format and the once-per-outage rule live in FailureLog.
  def self.log_error(context, error)
    FailureLog.failure(context, error)
  rescue StandardError
    nil
  end

  # A poller that can fail transiently reports each success, which ends that
  # context's outage in qm.log.
  def self.log_success(context)
    FailureLog.success(context)
  rescue StandardError
    nil
  end

  # pid and its ancestors, nearest first, as far as ps can see them.
  def self.process_lineage(pid)
    pids = []
    while pid > 1 && pids.size < 16
      pids << pid
      out, _err, status = Open3.capture3("ps", "-o", "ppid=", "-p", pid.to_s)
      break unless status.success?

      pid = out.strip.to_i
    end
    pids
  rescue SystemCallError
    pids
  end

  def self.git(cwd, *args, stdin: "")
    return nil unless cwd && File.directory?(cwd)

    out, _err, status = Open3.capture3("git", "-C", cwd, *args, stdin_data: stdin)
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

  # "Owner/Name" of the GitHub repo a checkout's origin points at, nil when
  # there is no origin or it doesn't look like one.
  def self.github_repo(root)
    remote = git(root, "remote", "get-url", "origin").to_s
    remote[%r{[:/]([^/:]+/[^/]+?)(?:\.git)?/?\z}, 1]
  end

  # The transcript_path a hook reports is keyed to the session's cwd and can
  # be wrong — `claude --worktree --resume` reports the worktree's slug while
  # the transcript actually lives under the original project's. Session ids
  # are globally unique, so fall back to searching all project directories.
  def self.locate_transcript(session_id, recorded_path)
    return recorded_path if recorded_path && File.exist?(recorded_path)
    return nil unless session_id

    Dir[File.join(TRANSCRIPTS_DIR, "*", "#{session_id}.jsonl")].first
  end

  def self.shorten_home(path)
    path&.sub(Dir.home, "~")
  end

  # Which branch is checked out where, across a repo's worktrees (the main
  # checkout included) — one porcelain listing, keyed by branch name.
  # Detached-HEAD worktrees have no branch line and drop out.
  def self.branch_worktrees(root)
    listing = git(root, "worktree", "list", "--porcelain")
    return {} unless listing

    map = {}
    path = nil
    listing.split("\n").each do |line|
      path = line.delete_prefix("worktree ") if line.start_with?("worktree ")
      map[line.delete_prefix("branch refs/heads/")] = path if line.start_with?("branch refs/heads/") && path
    end
    map
  end

  # Claude Code prunes transcripts cleanupPeriodDays after their last touch;
  # this drives the degradation warnings.
  def self.transcript_retention_days
    settings = JSON.parse(File.read(File.expand_path("~/.claude/settings.json")))
    settings["cleanupPeriodDays"] || 30
  rescue StandardError
    30
  end

  # One JSONL line as an object, or nil when it is garbled or valid JSON of
  # another kind (5, [], "x", null): every per-line reader skips both alike.
  def self.json_object(line)
    entry = JSON.parse(line)
    entry.is_a?(Hash) ? entry : nil
  rescue JSON::ParserError
    nil
  end

  def self.first_prompt(transcript_path)
    return nil unless transcript_path && File.exist?(transcript_path)

    File.foreach(transcript_path) do |line|
      entry = json_object(line) or next
      next unless entry["type"] == "user"

      text = prompt_text(entry)
      return text if text
    end
    nil
  rescue StandardError
    nil
  end

  # The human-typed text of a transcript user entry — nil for tool results,
  # meta entries, and injected content (hook output, slash-command echoes),
  # which all arrive as user entries but were never typed by the user.
  def self.prompt_text(entry)
    return nil if entry["isMeta"] || entry["toolUseResult"]

    content = entry.dig("message", "content")
    text = content.is_a?(String) ? content : Array(content).filter_map { |c| c["text"] if c.is_a?(Hash) && c["type"] == "text" }.join(" ")
    text = text.to_s.strip
    text.empty? || text.start_with?("<") ? nil : text
  end

  # An item's sessions, newest captured first, uncaptured last — the order
  # plain resume would pick, so the top row is what resume lands on.
  def self.item_sessions(item, session_log: SessionLog.new)
    item.sessions
        .map { |s| session_log.session_for(s["id"]) || Session.uncaptured(s["id"]) }
        .sort_by { |session| session.last_ts ? [0, -Time.parse(session.last_ts).to_f] : [1, 0] }
  end

  # Claude Code's per-turn summaries (/focus, session recap) are rendered live
  # and never written to disk, so the session sheet derives its own from what
  # the transcript does record: each turn's tool tallies, touched files, and
  # the reply's opening text. Clipping happens here so a megabyte transcript
  # never crosses the wire.
  TURN_PROMPT_CHARS = 700
  TURN_REPLY_CHARS = 360
  TURN_FILES_SHOWN = 6

  def self.session_turns(transcript_path)
    return nil unless transcript_path && File.exist?(transcript_path)

    turns = []
    title = branch = model = nil
    File.foreach(transcript_path) do |line|
      entry = json_object(line) or next
      next if entry["isSidechain"]

      branch = entry["gitBranch"] if entry["gitBranch"] && !entry["gitBranch"].empty?
      case entry["type"]
      when "ai-title"
        title = entry["aiTitle"]
      when "user"
        text = prompt_text(entry)
        next unless text

        turns << { "ts" => entry["timestamp"], "prompt" => clip(text, TURN_PROMPT_CHARS),
                   "tools" => Hash.new(0), "files" => [], "reply" => nil }
      when "assistant"
        next unless (turn = turns.last)

        model = entry.dig("message", "model") || model
        Array(entry.dig("message", "content")).each do |block|
          next unless block.is_a?(Hash)

          case block["type"]
          when "tool_use"
            turn["tools"][block["name"] || "?"] += 1
            file = block.dig("input", "file_path")
            turn["files"] << File.basename(file) if file.is_a?(String)
          when "text"
            turn["reply"] = block["text"]
          end
        end
      end
    end
    turns.each do |turn|
      turn["tools"] = turn["tools"].map { |name, count| { "name" => name, "count" => count } }
      turn["files"] = turn["files"].uniq.first(TURN_FILES_SHOWN)
      turn["reply"] = turn["reply"] && clip(turn["reply"].strip, TURN_REPLY_CHARS)
    end
    { "turns" => turns, "title" => title, "branch" => branch, "model" => model }
  rescue StandardError
    nil
  end

  def self.clip(text, limit)
    text.length > limit ? "#{text[0, limit].rstrip}…" : text
  end

  # Everything the GUI's session sheet needs for one session: the capture
  # metadata plus, while the transcript survives, the parsed turns. A pruned
  # or never-captured session keeps turns nil — the sheet degrades. The sheet
  # is the one surface that shows the start time ('when'); lists show last
  # activity.
  def self.session_detail(session_id, session_log: SessionLog.new)
    session = session_log.session_for(session_id) || Session.uncaptured(session_id)
    parsed = session_turns(session.transcript)
    { "id" => session.id, "tier" => session.tier,
      "when" => session.started_ts && session.started_ts[0, 16],
      "cwd" => shorten_home(session.cwd), "prompt" => session.first_prompt,
      "last_ts" => session.last_ts }
      .merge(parsed || { "turns" => nil, "title" => nil, "branch" => nil, "model" => nil })
  end

  DISTILL_PROMPT = <<~PROMPT
    You are distilling a Claude Code session transcript into a durable context
    snapshot. The original transcript will be deleted; this snapshot is what a
    future session gets to continue the work. Write, in under 300 words:
    what the goal was, what was done and decided (with key files, commands,
    and gotchas), the state things were left in, and the concrete next steps.
    Plain markdown, no heading, no preamble.
  PROMPT

  TRANSCRIPT_TAIL_BYTES = 400_000
  # A dense JSONL tail can still overflow haiku's context (~2 bytes/token was
  # observed on a code-heavy transcript); distill halves the tail and retries
  # down to this floor before giving up.
  TRANSCRIPT_MIN_TAIL_BYTES = 50_000

  # Preserve surviving transcripts as work-item snapshots before Claude Code
  # prunes them. Shared by the CLI and the GUI so the distill logic lives once;
  # raises ArgumentError on anything the caller must surface (no transcript,
  # headless claude failed) and AlreadyDistilledError when the target needs
  # force. Returns one result hash per distilled session.
  def self.distill(slug, session_id: nil, force: false)
    item, sessions = distill_plan(slug, session_id: session_id, force: force)
    sessions.map { |session| distill_session(item, session) }
  end

  # The cheap half of a distill: resolve the item and its target sessions,
  # raising everything the caller must surface *before* any claude run. The
  # GUI plans synchronously (so the already-distilled confirm still works)
  # and runs distill_session per target on a background thread.
  def self.distill_plan(slug, session_id: nil, force: false)
    item = WorkItem.find(slug)
    [item, distill_targets(item, SessionLog.new, session_id: session_id, force: force)]
  end

  # Which sessions a distill covers. An explicit --session targets exactly that
  # one. Bare distill covers every session currently carrying a degradation
  # warning — the point is that one action clears all of them — and only falls
  # back to the newest resumable session when nothing is expiring. Warned
  # sessions are un-snapshotted by definition, so the already-distilled guard
  # can only fire on the explicit and fallback paths.
  def self.distill_targets(item, log, session_id: nil, force: false, attention: Attention.new(session_log: log))
    if session_id
      session = item.sessions.any? { |s| s["id"] == session_id } && log.session_for(session_id)
      unless session && session.tier == "resumable"
        raise ArgumentError, "session #{session_id} of '#{item.slug}' has no surviving transcript to distill"
      end

      guard_already_distilled(item, session_id, force)
      return [session]
    end

    expiring = attention.degradations(item)
                        .filter_map { |entry| log.session_for(entry.session_id) }
                        .select { |s| s.tier == "resumable" }
    return expiring if expiring.any?

    latest = item.sessions.filter_map { |s| log.session_for(s["id"]) }
                 .select { |s| s.tier == "resumable" }
                 .max_by(&:last_ts)
    raise ArgumentError, "no session of '#{item.slug}' has a surviving transcript to distill" unless latest

    guard_already_distilled(item, latest.id, force)
    [latest]
  end

  def self.guard_already_distilled(item, session_id, force)
    return if force || !item.snapshot_for?(session_id)

    raise AlreadyDistilledError,
          "session #{session_id[0, 8]} of '#{item.slug}' is already distilled — re-run with --force to replace its snapshot"
  end
  private_class_method :guard_already_distilled

  def self.distill_session(item, session)
    raw = File.read(session.transcript)
    tail = TRANSCRIPT_TAIL_BYTES
    loop do
      transcript = raw
      if raw.bytesize > tail
        transcript = "(transcript truncated — only the tail follows)\n#{raw.byteslice(-tail..)}"
      end

      out, err, status = Open3.capture3(
        { "QM_SKIP" => "1" },
        "claude", "-p", DISTILL_PROMPT, "--model", "haiku",
        stdin_data: transcript
      )
      if status.success? && !out.strip.empty?
        item.add_snapshot(session.id, out.strip)
        return { session_id: session.id, transcript_bytes: transcript.bytesize, snapshot: out.strip }
      end

      # An over-limit prompt is reported on *stdout* (exit 1, stderr empty) —
      # a byte budget maps to a token budget differently per transcript, so
      # shrink and retry instead of guessing a universally safe constant.
      if out.match?(/prompt is too long/i) && tail > TRANSCRIPT_MIN_TAIL_BYTES
        tail /= 2
        next
      end

      raise ArgumentError, "claude -p failed: #{err.strip.empty? ? out.strip : err.strip}"
    end
  end
end

require_relative "quartermaster/failure_log"
require_relative "quartermaster/error_log"
require_relative "quartermaster/note"
require_relative "quartermaster/ide"
require_relative "quartermaster/config_reader"
require_relative "quartermaster/project_settings"
require_relative "quartermaster/project_config"
require_relative "quartermaster/project_map"
require_relative "quartermaster/session"
require_relative "quartermaster/session_log"
require_relative "quartermaster/atomic_file"
require_relative "quartermaster/automation_store"
require_relative "quartermaster/local_schedule"
require_relative "quartermaster/work_item"
require_relative "quartermaster/command_runner"
require_relative "quartermaster/gh_stack"
require_relative "quartermaster/stack_layers"
require_relative "quartermaster/pf"
require_relative "quartermaster/pf_fence"
require_relative "quartermaster/target_worktree"
require_relative "quartermaster/issue_start"
require_relative "quartermaster/git_repo"
require_relative "quartermaster/cleanup"
require_relative "quartermaster/warp_tab"
require_relative "quartermaster/workspace"
require_relative "quartermaster/tmux"
require_relative "quartermaster/pane_follows_session"
require_relative "quartermaster/web_socket"
require_relative "quartermaster/launcher"
require_relative "quartermaster/ruby_floor"
require_relative "quartermaster/ruby_pin"
require_relative "quartermaster/doctor"
require_relative "quartermaster/aside"
require_relative "quartermaster/item_deletion"
require_relative "quartermaster/loose_chat"
require_relative "quartermaster/gui_loose_actions"
require_relative "quartermaster/pr_status"
require_relative "quartermaster/pr_prerequisites"
require_relative "quartermaster/pr_deployment"
require_relative "quartermaster/pr_inbox"
require_relative "quartermaster/board_mirror"
require_relative "quartermaster/attention"
require_relative "quartermaster/event_log"
require_relative "quartermaster/prompt_snapshots"
require_relative "quartermaster/transcript_vitals"
require_relative "quartermaster/background_jobs"
require_relative "quartermaster/transcript_usage"
require_relative "quartermaster/price_table"
require_relative "quartermaster/config_schema"
require_relative "quartermaster/config_check"
require_relative "quartermaster/config_file"
require_relative "quartermaster/usage_ledger"
require_relative "quartermaster/item_usage"
require_relative "quartermaster/chat_attention"
require_relative "quartermaster/rate_limits"
require_relative "quartermaster/overview"
require_relative "quartermaster/context_meter"
require_relative "quartermaster/transcript_history"
require_relative "quartermaster/chat_history"
require_relative "quartermaster/rotation"
require_relative "quartermaster/ask_search"
require_relative "quartermaster/build_progress"
require_relative "quartermaster/transcript_search"
require_relative "quartermaster/viewer"
require_relative "quartermaster/caffeinate"
require_relative "quartermaster/drops"
require_relative "quartermaster/feature_use"
require_relative "quartermaster/unified_diff"
require_relative "quartermaster/uncommitted_marks"
require_relative "quartermaster/pr_memo"
require_relative "quartermaster/pr_revisions"
require_relative "quartermaster/review_anchors"
require_relative "quartermaster/review_threads"
require_relative "quartermaster/review_plan"
require_relative "quartermaster/pending_review"
require_relative "quartermaster/branch_diff"
require_relative "quartermaster/branch_stats"
require_relative "quartermaster/benchmark_report"
require_relative "quartermaster/benchmark_run"
require_relative "quartermaster/benchmark_pipeline"
require_relative "quartermaster/gui_benchmark_actions"
require_relative "quartermaster/prompt_diff"
require_relative "quartermaster/file_at_revision"
require_relative "quartermaster/diff_comments"
require_relative "quartermaster/page_annotations"
require_relative "quartermaster/issue_comments"
require_relative "quartermaster/drafts"
require_relative "quartermaster/chat_review_drafts"
require_relative "quartermaster/issue_drafts"
require_relative "quartermaster/viewed_marks"
require_relative "quartermaster/issue_index"
require_relative "quartermaster/clipboard_annotations"
require_relative "quartermaster/loopback_guard"
require_relative "quartermaster/terminal_bridge"
require_relative "quartermaster/gui_jobs"
require_relative "quartermaster/turn_notifier"
require_relative "quartermaster/chat_opener"
require_relative "quartermaster/gui_state"
require_relative "quartermaster/gui_settings"
require_relative "quartermaster/pr_items"
require_relative "quartermaster/gui_actions"
require_relative "quartermaster/gui"
require_relative "quartermaster/free_text_args"
require_relative "quartermaster/cli_format"
require_relative "quartermaster/cli_viewer"
require_relative "quartermaster/cli_workspace"
require_relative "quartermaster/cli_prs"
require_relative "quartermaster/cli_cleanup"
require_relative "quartermaster/cli_chats"
require_relative "quartermaster/cli_attention"
require_relative "quartermaster/cli_setup"
require_relative "quartermaster/cli_config"
require_relative "quartermaster/cli"
require_relative "quartermaster/hook_handler"
