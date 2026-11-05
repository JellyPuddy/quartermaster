# frozen_string_literal: true

module Quartermaster
  # The GitHub issues Claude drafts for an item (the /draft-issues skill):
  # one markdown file per issue, issues/<slug>/NN-short-name.md, frontmatter
  # (title, kind, group, parent, deps, change, number) over the issue body.
  # Claude writes them; qm only reads them, apart from the snapshots below
  # and deleting a file (Clear created, cleanup).
  #
  # Revisions: qm keeps, per file, the content it last saw and the one it saw
  # before that (.prev/<file>.json, {v, seen, previous}). Reading a file whose
  # content differs from `seen` moves `seen` to `previous` — unless `seen`
  # is younger than SETTLE: Claude revises a file in several Edits, and each
  # in-between state is not a version. Both live on disk, so a GUI restart
  # neither loses a previous version nor makes one up; a file seen for the
  # first time has none. Only files that parse are recorded, so a
  # half-written file never becomes someone's previous. Acknowledging a
  # file's revision (the pane's "Mark seen") makes `seen` its own previous
  # and flags the snapshot `acked`: nothing reads as changed until the next
  # revision, and Edits still settling after it compare against what was
  # acknowledged.
  class IssueDrafts
    DIR = File.join(ROOT, "issues")
    PREV = ".prev"
    VERSION = 1
    SETTLE = 120
    KINDS = %w[feature bug].freeze
    FILE_NAME = /\A[^.\/][^\/]*\.md\z/
    FRONTMATTER = /\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)(.*)\z/m
    NO_DEPS = ["—", "-", "none"].freeze

    # Moves whenever any item's issue files are added, changed or removed:
    # part of both pulse values. "0" while there are none. Snapshots (.prev)
    # are left out — qm's own writes must not move the pulse.
    def self.signature
      files = Dir.glob(File.join(DIR, "*", "*.md")).sort
      return "0" if files.empty?

      stats = files.map do |path|
        stat = File.stat(path)
        "#{path.delete_prefix(DIR)}:#{stat.size}:#{stat.mtime.to_r}"
      rescue SystemCallError
        ""
      end
      Digest::SHA1.hexdigest(stats.join("|"))[0, 12]
    end

    attr_reader :slug

    # clock: when a version was seen (SETTLE), stubbed in tests.
    def initialize(slug, clock: -> { Time.now })
      raise ArgumentError, "'#{slug}' is not a work item slug" unless slug.is_a?(String) && slug.match?(Drafts::SLUG)

      @slug = slug
      @clock = clock
    end

    def dir = File.join(DIR, @slug)

    def files
      Dir.glob(File.join(dir, "*.md")).map { |path| File.basename(path) }.grep(FILE_NAME).sort
    end

    # { "issues" => [...], "errors" => [{ "file", "error" }] }. Issues not yet
    # created on GitHub first, then the created ones, each in filename order.
    # Each issue: file, title, kind, group, parent, deps, change, number (nil
    # until created), created, body, version (a digest of the file),
    # previous ({ "title", "body" } of the version seen before, or nil) and
    # acknowledged (its revision was marked seen: no previous, change hidden).
    def read
      issues = []
      errors = []
      names = files
      names.each do |name|
        content = File.read(File.join(dir, name))
        issue = parse(content)
        snapshot = remember(name, content)
        issue["acknowledged"] = snapshot["acked"] == true
        issue["previous"] = issue["acknowledged"] ? nil : previous(snapshot["previous"])
        issues << { "file" => name }.merge(issue).merge("version" => version(content))
      rescue ArgumentError, SystemCallError, Psych::Exception, EncodingError => e
        errors << { "file" => name, "error" => e.message }
      end
      prune_snapshots(names)
      { "issues" => issues.sort_by.with_index { |issue, index| [issue["created"] ? 1 : 0, index] }, "errors" => errors }
    end

    # What the chat toolbar and a revision toast need, without the bodies:
    # how many files, how many still to create, and each file's version.
    def summary
      data = read
      { "count" => data["issues"].size + data["errors"].size,
        "open" => data["issues"].count { |issue| !issue["created"] },
        "errors" => data["errors"].size,
        "versions" => data["issues"].to_h { |issue| [issue["file"], issue["version"]] } }
    end

    # Removes one issue file and its snapshot; the directory goes with its
    # last file. True when the file was there.
    def delete(name)
      raise ArgumentError, "'#{name}' is not an issue file" unless name.is_a?(String) && name.match?(FILE_NAME)

      path = File.join(dir, name)
      existed = File.file?(path)
      FileUtils.rm_f(path)
      FileUtils.rm_f(snapshot_path(name))
      Drafts.new(@slug).forget_issue(name)
      remove_dir if files.empty?
      existed
    end

    # Mark seen: the file's current revision stops reading as changed. False
    # when there is no such file or it doesn't parse (nothing was seen).
    def acknowledge(name)
      raise ArgumentError, "'#{name}' is not an issue file" unless name.is_a?(String) && name.match?(FILE_NAME)

      path = File.join(dir, name)
      return false unless File.file?(path)

      content = File.read(path)
      return false unless previous(content)

      snapshot = remember(name, content)
      write_snapshot(snapshot_path(name), snapshot.merge("previous" => content, "acked" => true))
      true
    end

    # Clear created: every issue that has its GitHub number. Returns their files.
    def delete_created
      read["issues"].select { |issue| issue["created"] }.map { |issue| issue["file"] }.each { |name| delete(name) }
    end

    # Unsent comments per issue file ({ file => count }): what deleting that
    # file would throw away, for cleanup's warnings.
    def unsent_comments = Drafts.new(@slug).issue_comment_counts

    private

    def parse(content)
      match = content.match(FRONTMATTER) or raise ArgumentError, "no frontmatter (--- title: … ---) at the top"
      front = YAML.safe_load(match[1]) || {}
      raise ArgumentError, "frontmatter is not a set of fields" unless front.is_a?(Hash)

      title = scalar(front, "title").strip
      raise ArgumentError, "title is missing" if title.empty?

      kind = scalar(front, "kind").strip
      raise ArgumentError, "kind must be #{KINDS.join(" or ")}, not '#{kind}'" unless KINDS.include?(kind)

      number = number(front["number"])
      { "title" => title, "kind" => kind, "group" => scalar(front, "group").strip,
        "parent" => scalar(front, "parent").strip, "deps" => deps(front["deps"]),
        "change" => scalar(front, "change").strip, "number" => number, "created" => !number.nil?,
        "body" => match[2].sub(/\A(?:[ \t]*\r?\n)+/, "").rstrip }
    end

    def scalar(front, key)
      value = front[key]
      raise ArgumentError, "#{key} must be text" if value.is_a?(Hash) || value.is_a?(Array)

      value.to_s
    end

    def deps(value)
      list = case value
             when nil then []
             when Array then value
             when Hash then raise ArgumentError, "deps must be a list"
             else [value]
             end
      raise ArgumentError, "deps must be a list of text" if list.any? { |dep| dep.is_a?(Hash) || dep.is_a?(Array) }

      list.map { |dep| dep.to_s.strip }.reject { |dep| dep.empty? || NO_DEPS.include?(dep) }
    end

    def number(value)
      return nil if value.nil? || value.to_s.strip.empty?

      digits = value.to_s.strip.delete_prefix("#")
      unless (value.is_a?(Integer) || value.is_a?(String)) && digits.match?(/\A\d+\z/) && digits.to_i.positive?
        raise ArgumentError, "number must be the issue's number, not '#{value}'"
      end

      digits.to_i
    end

    def version(content) = Digest::SHA1.hexdigest(content)[0, 12]

    def snapshot_path(name) = File.join(dir, PREV, "#{name}.json")

    # Records content as seen and returns its snapshot. A new version drops
    # `acked`: that acknowledged the one before.
    def remember(name, content)
      path = snapshot_path(name)
      snapshot = begin
        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end
      snapshot = nil unless snapshot.is_a?(Hash) && snapshot["seen"].is_a?(String)
      unless snapshot && snapshot["seen"] == content
        now = @clock.call.to_f
        settled = snapshot.nil? || now - snapshot["seen_at"].to_f >= SETTLE
        snapshot = { "v" => VERSION, "seen" => content, "seen_at" => now,
                     "previous" => settled ? snapshot&.dig("seen") : snapshot["previous"] }
        write_snapshot(path, snapshot)
      end
      snapshot
    end

    def previous(content)
      return nil unless content.is_a?(String)

      parse(content).slice("title", "body")
    rescue StandardError
      nil
    end

    def write_snapshot(path, snapshot)
      FileUtils.mkdir_p(File.dirname(path))
      temp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.write(temp, JSON.generate(snapshot))
      File.rename(temp, path)
    end

    # Only what qm knows: anything else left in the directory keeps it.
    def remove_dir
      FileUtils.rm_rf(File.join(dir, PREV))
      Dir.rmdir(dir)
    rescue SystemCallError
      nil
    end

    # A snapshot whose file is gone (deleted by hand, renamed) would hand a
    # later file of that name a previous version it never had.
    def prune_snapshots(names)
      Dir.glob(File.join(dir, PREV, "*.json")).each do |path|
        FileUtils.rm_f(path) unless names.include?(File.basename(path, ".json"))
      end
    end
  end
end
