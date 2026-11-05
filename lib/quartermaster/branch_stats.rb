# frozen_string_literal: true

module Quartermaster
  # The diff pane's branch stats: lines changed on a branch since its merge
  # base, by category, largest file and commit. The numbers are the
  # branch-stats skill's own script, run unchanged in the branch's checkout
  # (a ref-only branch's: the project root) against the diff pane's base
  # (BranchDiff#tip), so qm never fetches for it. Its markdown is kept as
  # printed and parsed into structure for the modal; a parse that fails
  # leaves stats nil and the page renders the markdown.
  #
  # Cached in branch-stats.json, one entry per (repo root, branch): a lookup
  # is a hit only while the branch's head, merge base and base ref are the
  # ones the entry was computed at; a new answer replaces the entry. A real
  # cache: safe to delete, an unreadable or foreign-version file reads as
  # empty. A script that fails or prints nothing is shown, never cached.
  #
  # "What stands out" is a headless haiku call over the markdown, on the user's
  # click only, run as a GuiJobs job (job_key); its sentences are stored on
  # the entry only while the entry's shas still match the ones it read.
  class BranchStats
    CACHE_FILE = File.join(ROOT, "branch-stats.json")
    VERSION = 1
    SCRIPT = File.expand_path("../../skills/branch-stats/scripts/branch-stats.sh", __dir__)
    CACHE_LOCK = Mutex.new

    PROMPT = <<~PROMPT
      Below is a markdown rundown of the lines a git branch changes since its
      merge base: totals by category, the largest files, and one row per
      commit. Write two or three plain sentences of what stands out, drawn
      from the numbers: which commit carries the real change, whether a big
      commit is mostly generated fan-out (locale JSON, a generated API
      client, lockfiles), and the approximate hand-written non-test surface
      (backend + frontend + docs + openapi + locales). Do not restate the
      tables in prose, and do not judge whether the change is too large.
      Answer with the sentences only.
    PROMPT

    # The GUI job of one branch's commentary, apart from the item's own jobs.
    def self.job_key(target) = "branch-stats:#{target["root"]}:#{target["branch"]}"

    # runner: the script's and the model's door (CommandRunner); tests stub it.
    def initialize(runner: CommandRunner.new, tmux: Tmux.new, branch_diff: nil, now: -> { Time.now })
      @runner = runner
      @branch_diff = branch_diff || BranchDiff.new(tmux: tmux, runner: runner)
      @now = now
    end

    # The branch and base the stats of item's branch are measured on.
    def target(item, branch: nil) = @branch_diff.tip(item, branch: branch.to_s.empty? ? nil : branch)

    # { branch, base, head, mergeBase, computedAt, markdown, stats, commentary,
    #   commentaryAt, error, jobKey, commentaryRunning }. running: the keys
    # of the GUI's running jobs.
    def call(item, branch: nil, refresh: false, running: [])
      target = target(item, branch: branch)
      entry = (lookup(target) unless refresh) || compute(target)
      key = self.class.job_key(target)
      payload(entry).merge("jobKey" => key, "commentaryRunning" => running.include?(key))
    end

    # Blocking: what the commentary job runs. The entry it reads must be
    # cached for the current shas; the answer is stored only if it still is.
    def comment(target)
      entry = lookup(target)
      raise ArgumentError, "#{target["branch"]} has no branch stats for its current head yet" unless entry

      result = @runner.call(["env", "QM_SKIP=1", "claude", "-p", "#{PROMPT}\n#{entry["markdown"]}", "--model", "haiku",
                             "--tools", "", "--strict-mcp-config", "--no-session-persistence"])
      text = result.out.to_s.strip
      raise ArgumentError, "claude -p failed: #{(result.err.to_s.strip.empty? ? text : result.err.to_s.strip)[0, 200]}" unless result.success? && !text.empty?

      stored = update(target) { |current| current.merge("commentary" => text, "commentaryAt" => @now.call.iso8601) }
      return { "ok" => true, "message" => "#{target["branch"]}: what stands out is ready" } if stored

      { "ok" => false, "error" => "#{target["branch"]} moved on while its stats were read: the commentary was dropped" }
    end

    # The script's markdown as structure, or nil when it isn't the shape the
    # script prints.
    def self.parse(markdown)
      header = markdown[/^# Branch stats: `(.+?)` vs `(.+?)` \(merge base `(\h+)`\)$/] && [$1, $2, $3]
      totals = markdown.match(%r{^\*\*Whole branch: (\d+) files, \+(\d+) / -(\d+)\*\*$})
      return nil unless header && totals

      categories = markdown.scan(/^\| ([a-z]+) \| (\d+) \| (\d+) \| (\d+) \| (\d+)% \|$/).map do |name, files, add, del, share|
        { "name" => name, "files" => files.to_i, "add" => add.to_i, "del" => del.to_i, "share" => share.to_i }
      end
      largest = markdown.scan(%r{^- `(.+)` \+(\d+) / -(\d+)$}).map do |path, add, del|
        { "path" => path, "add" => add.to_i, "del" => del.to_i }
      end
      { "branch" => header[0], "base" => header[1], "mergeBase" => header[2],
        "totals" => { "files" => totals[1].to_i, "add" => totals[2].to_i, "del" => totals[3].to_i },
        "categories" => categories, "largest" => largest, "commits" => commit_rows(markdown) }
    end

    # A subject may hold a pipe; the seven cells after it never do.
    COMMIT_ROW = /^\| `(\h+)` (.*) \| (\d+) \| ([^|]*) \| ([^|]*) \| ([^|]*) \| ([^|]*) \| ([^|]*) \| ([^|]*) \|$/
    COLUMNS = %w[backend frontend tests generated].freeze

    def self.commit_rows(markdown)
      markdown.scan(COMMIT_ROW).map do |sha, subject, files, total, *cells, other|
        categories = COLUMNS.zip(cells).filter_map { |name, cell| [name, cell_lines(cell)] unless cell.strip.empty? }.to_h
        other.split(", ").each { |part| categories[$1] = cell_lines($2) if part =~ /\A([a-z]+) (.+)\z/ }
        { "sha" => sha, "subject" => subject, "files" => files.to_i, **cell_lines(total), "categories" => categories }
      end
    end

    # "+9 / -2" or "+983" → { add, del }.
    def self.cell_lines(cell) = { "add" => cell[/\+(\d+)/, 1].to_i, "del" => cell[/-(\d+)/, 1].to_i }

    private

    def payload(entry)
      { "branch" => entry["branch"], "base" => entry["base"], "head" => entry["head"], "mergeBase" => entry["mergeBase"],
        "computedAt" => entry["computedAt"], "markdown" => entry["markdown"],
        "stats" => entry["markdown"] && self.class.parse(entry["markdown"]),
        "commentary" => entry["commentary"], "commentaryAt" => entry["commentaryAt"], "error" => entry["error"] }
    end

    def compute(target)
      fields = key_fields(target)
      result = @runner.call([SCRIPT, target["base"]["ref"], target["ref"]], chdir: target["path"])
      markdown = result.out.to_s
      unless result.success? && !markdown.strip.empty?
        reason = [result.err, markdown].map { |s| s.to_s.strip }.find { |s| !s.empty? } || "it printed nothing"
        return fields.merge("error" => "the branch-stats script failed: #{reason[0, 500]}")
      end

      entry = fields.merge("computedAt" => @now.call.iso8601, "markdown" => markdown)
      CACHE_LOCK.synchronize do
        cache = read_cache
        (cache["entries"][target["root"]] ||= {})[target["branch"]] = entry
        write_cache(cache)
      end
      entry
    end

    def key_fields(target)
      { "branch" => target["branch"], "base" => target["base"]["ref"], "head" => target["head"],
        "mergeBase" => target["base"]["sha"] }
    end

    def lookup(target)
      entry = read_cache["entries"].dig(target["root"], target["branch"])
      entry if matches?(entry, target)
    end

    def matches?(entry, target)
      entry.is_a?(Hash) && key_fields(target).all? { |field, value| entry[field] == value }
    end

    # Changes the branch's entry only while it still matches target; false otherwise.
    def update(target)
      CACHE_LOCK.synchronize do
        cache = read_cache
        entry = cache["entries"].dig(target["root"], target["branch"])
        return false unless matches?(entry, target)

        cache["entries"][target["root"]][target["branch"]] = yield(entry)
        write_cache(cache)
        true
      end
    end

    def read_cache
      data = JSON.parse(File.read(CACHE_FILE))
      raise "unknown cache version" unless data["v"] == VERSION && data["entries"].is_a?(Hash)

      data
    rescue StandardError
      { "v" => VERSION, "entries" => {} }
    end

    def write_cache(cache)
      Quartermaster.ensure_setup
      temp = "#{CACHE_FILE}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.write(temp, JSON.pretty_generate(cache))
      File.rename(temp, CACHE_FILE)
    end
  end
end
