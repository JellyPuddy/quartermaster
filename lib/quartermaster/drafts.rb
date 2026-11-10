# frozen_string_literal: true

module Quartermaster
  # What the user means to tell an item's chat but hasn't sent yet: comments on
  # lines of the diff pane, page annotations, which a page overlay relayed or
  # the GUI loaded from what the overlay copied (ClipboardAnnotations), and
  # comments on the item's issue drafts (IssueDrafts) — and replies to a
  # PR's review threads, which go to GitHub instead (put_thread_reply).
  # One JSON file per item (drafts/<slug>.json), so every GUI tab sees the
  # same drafts and they survive restarts. Sent together as one message
  # (GuiActions' drafts-send); only the entries actually sent are removed.
  #
  # Each entry: { "id", "kind" (KINDS), "comment", "rev" (bumped on every
  # edit), "createdAt", "updatedAt" } plus its kind's fields — a diff comment its line address (DIFF_FIELDS: a range's first line in
  # start_line/start_side, every line's text in code) and, made in the PR
  # scope, its PR (PR_FIELDS); a GitHub comment the same, always with its
  # PR, waits for the pending review instead of the chat. An annotation what
  # PageAnnotations reads (ANNOTATION_FIELDS) and its batch's url/title, an
  # issue comment its issue's file, the block's source text ("" for the
  # whole issue) and the issue's title (ISSUE_FIELDS), a thread reply its
  # thread and PR (REPLY_FIELDS), which like a GitHub comment waits for the
  # pending review; a review summary (ReviewSummaryDrafts). `qm draft add`
  # writes here too, from another process: #update's flock makes that safe.
  class Drafts
    include ReviewSummaryDrafts

    DIR = File.join(ROOT, "drafts")
    VERSION = 1
    KINDS = %w[diff-comment github-comment annotation issue-comment thread-reply review-summary].freeze
    LINE_KINDS = %w[diff-comment github-comment].freeze
    # branch: the one the pane showed when the comment was written;
    # committed: that branch had no checkout, so its numbers are the ref's.
    DIFF_FIELDS = %w[path side line code range start_line start_side branch committed].freeze
    # repo ("owner/name") and number name the PR; base is its base sha and
    # commit the one the comment anchors to (the head, or a selected run's
    # last commit), both as at draft time. subject "file" is a comment on
    # the whole file (its line only says where it shows); author "user" or
    # "claude".
    PR_FIELDS = %w[repo number base commit subject author].freeze
    # What Drafts#relocate may change: the address, the anchor, "pin"
    # ("commit": post on its commit, not the head — the outdated card's
    # Comment on the old commit) and "failed" (why the last post didn't take).
    RELOCATED = %w[path side line code range start_line start_side base commit subject pin].freeze
    SUBJECTS = %w[line file].freeze
    AUTHORS = %w[user claude].freeze
    REPO = %r{\A[\w.-]+/[\w.-]+\z}
    SHA = /\A\h{7,64}\z/
    BRANCH = /\A[^\s~^:?*\[\\[:cntrl:]]{1,255}\z/
    ISSUE_FIELDS = %w[file block title].freeze
    REPLY_FIELDS = %w[thread repo number url path line author].freeze
    # Kinds the tray pastes into the chat; a GitHub comment and a thread
    # reply go to GitHub with the pending review.
    CHAT_KINDS = %w[diff-comment annotation issue-comment].freeze
    ANNOTATION_FIELDS = %w[page selector text html component components owners context regions url title].freeze
    # Owners as a page overlay's relay sends them; `code` (the JSX line's source text) is optional.
    OWNER_FIELDS = %w[name as file line via code].freeze
    SLUG = /\A[a-z0-9][\w.-]*\z/i
    LOADED_IDS = 50

    # The GUI's threads write under its action mutex, but an annotation relay and a
    # second GUI may not: the mutex covers threads, the flock processes.
    MUTEX = Mutex.new

    # Every item's draft count, for the page's badges. Cheap: one small JSON
    # read per item that has drafts at all. A stray file whose name is no
    # slug is skipped, not fatal: the attention poll reads this every pulse.
    def self.counts
      Dir.glob(File.join(DIR, "*.json")).map { |path| File.basename(path, ".json") }.grep(SLUG)
         .to_h { |slug| [slug, new(slug).entries.size] }
         .reject { |_, count| count.zero? }
    end

    # Moves whenever any item's drafts change: the pulse's drafts part. "0"
    # while no item has a drafts file (one may hold only clipboard load ids).
    def self.signature
      files = Dir.glob(File.join(DIR, "*.json")).sort
      return "0" if files.empty?

      stats = files.map do |path|
        stat = File.stat(path)
        "#{File.basename(path)}:#{stat.size}:#{stat.mtime.to_r}"
      rescue SystemCallError
        ""
      end
      Digest::SHA1.hexdigest(stats.join("|"))[0, 12]
    end

    attr_reader :slug

    def initialize(slug, now: -> { Time.now })
      raise ArgumentError, "'#{slug}' is not a work item slug" unless slug.is_a?(String) && slug.match?(SLUG)

      @slug = slug
      @now = now
    end

    def path = File.join(DIR, "#{@slug}.json")

    def entries
      read["entries"]
    end

    # A diff line holds one draft, for the chat or for the review: putting
    # another on the same address (its PR, if any, included) replaces it —
    # kind and fields too, so saving a chat draft as a GitHub one turns it
    # into one — and a blank comment removes it. raw["kind"]
    # "github-comment" makes a GitHub draft; whether GitHub takes its line is
    # the caller's check (ReviewAnchors.refusal). A block gets the draft the
    # put would replace (or nil) under the file's lock and may refuse by
    # raising. Returns the stored entry, or nil when it was removed.
    def put_diff_comment(raw, &guard)
      raise ArgumentError, "a diff comment must be an object" unless raw.is_a?(Hash)

      kind = raw["kind"].to_s.empty? ? "diff-comment" : raw["kind"].to_s
      raise ArgumentError, "'#{kind}' is not a diff comment kind" unless LINE_KINDS.include?(kind)

      fields = line_fields(raw, kind)
      comment = raw["comment"].to_s
      update do |list|
        existing = list.find { |entry| LINE_KINDS.include?(entry["kind"]) && diff_address(entry) == diff_address(fields) }
        guard&.call(existing)
        if comment.strip.empty?
          list.delete(existing)
          next nil
        end
        next reshape(existing, kind, fields, comment) if existing

        added = new_entry(kind, comment, fields)
        list << added
        added
      end
    end

    # The chip on a PR-scope draft: to "github" (the review) or "chat"; its
    # line and text stay. Only a draft made in the PR scope knows its PR, so
    # only it can go to the review — and whether GitHub takes its line is the
    # caller's check. Returns the entry.
    def move(id, to)
      kind = { "github" => "github-comment", "chat" => "diff-comment" }[to.to_s] or
        raise ArgumentError, "a draft moves to github or chat, not #{to.inspect}"
      update do |list|
        entry = list.find { |candidate| candidate["id"] == id } or raise ArgumentError, "no draft #{id} on #{@slug}"
        raise ArgumentError, "only a diff comment moves between the review and the chat" unless LINE_KINDS.include?(entry["kind"])
        raise ArgumentError, "only a draft made in the PR scope can go to the review" if kind == "github-comment" && !entry["number"]
        next entry if entry["kind"] == kind

        # A file comment keeps its subject in the chat, so it comes back one.
        entry["kind"] = kind
        entry.delete("failed")
        if kind == "github-comment"
          entry["subject"] ||= "line"
          entry["author"] ||= "user"
        end
        entry.merge!("rev" => entry["rev"].to_i + 1, "updatedAt" => @now.call.utc.iso8601)
      end
    end

    def find(id) = entries.find { |entry| entry["id"] == id }

    # Like a diff comment, one draft per address: the issue's file and the
    # block's source text, trimmed — blank for a comment on the whole issue.
    # The title is only for display and the message, so a put that replaces
    # the text refreshes it too, unless it carries none.
    def put_issue_comment(raw)
      raise ArgumentError, "an issue comment must be an object" unless raw.is_a?(Hash)

      file = raw["file"]
      raise ArgumentError, "'#{file}' is not an issue file" unless file.is_a?(String) && file.match?(IssueDrafts::FILE_NAME)

      fields = { "file" => file, "block" => raw["block"].to_s.strip, "title" => raw["title"].to_s.strip }
      comment = raw["comment"].to_s
      update do |list|
        existing = list.find { |entry| entry["kind"] == "issue-comment" && issue_address(entry) == issue_address(fields) }
        if comment.strip.empty?
          list.delete(existing)
          next nil
        end
        existing["title"] = fields["title"] if existing && !fields["title"].empty?
        next revise(existing, comment) if existing

        added = new_entry("issue-comment", comment, fields)
        list << added
        added
      end
    end

    # A reply to an existing review thread on GitHub, posted into the
    # pending review by the poster (PendingReview#post), never sent to
    # the chat. One per thread, like a line's comment: a put replaces it and
    # a blank one removes it. Fields (REPLY_FIELDS): the thread's node id,
    # the PR (repo "owner/name", number, url), the thread's path and line
    # for display, and who wrote it ("user", or "claude" for a draft the
    # chat added). A block guards the replace as put_diff_comment's does.
    def put_thread_reply(raw, &guard)
      raise ArgumentError, "a reply must be an object" unless raw.is_a?(Hash)

      thread = raw["thread"]
      raise ArgumentError, "'#{thread}' is not a review thread id" unless thread.is_a?(String) && thread.match?(ReviewThreads::NODE_ID)
      raise ArgumentError, "'#{raw["repo"]}' is not an owner/name repo" unless raw["repo"].is_a?(String) && raw["repo"].match?(ReviewThreads::REPO)
      raise ArgumentError, "a reply needs its pull request's number" unless raw["number"].to_i.positive?

      fields = raw.slice(*REPLY_FIELDS).reject { |_, value| value.nil? || value == "" }
                  .merge("number" => raw["number"].to_i, "author" => AUTHORS.include?(raw["author"]) ? raw["author"] : "user")
      comment = raw["comment"].to_s
      update do |list|
        existing = list.find { |entry| entry["kind"] == "thread-reply" && entry["thread"] == thread }
        guard&.call(existing)
        if comment.strip.empty?
          list.delete(existing)
          next nil
        end
        next revise(existing.merge!(fields), comment) if existing

        added = new_entry("thread-reply", comment, fields)
        list << added
        added
      end
    end

    # Unsent issue comments per issue file: what deleting the file would lose.
    def issue_comment_counts
      entries.select { |entry| entry["kind"] == "issue-comment" }.map { |entry| entry["file"] }.tally
    end

    # The issue comments on a deleted issue file go with it. Returns how many.
    def forget_issue(file)
      return 0 unless File.exist?(path)

      update do |list|
        before = list.size
        list.reject! { |entry| entry["kind"] == "issue-comment" && entry["file"] == file }
        before - list.size
      end
    end

    # One relayed or loaded batch: every annotation with a comment becomes an
    # entry, carrying the batch's url and title. A clipboard load passes its
    # payload id, and an id this item already loaded is refused — the last
    # LOADED_IDS are kept, and they keep the file even once every draft is
    # sent. Returns the stored entries.
    def add_annotations(raw, url: nil, title: nil, load_id: nil)
      raise ArgumentError, "annotations must be a list" unless raw.is_a?(Array)

      annotations = raw.select { |entry| entry.is_a?(Hash) && !entry["comment"].to_s.strip.empty? }
      raise ArgumentError, "no annotations to send" if annotations.empty?

      update do |list, data|
        if load_id
          loaded = Array(data["loaded"])
          raise ArgumentError, "already loaded — these annotations are in #{@slug}'s drafts or were sent" if loaded.include?(load_id)

          data["loaded"] = (loaded + [load_id]).last(LOADED_IDS)
        end
        added = annotations.map do |annotation|
          fields = annotation.slice(*ANNOTATION_FIELDS).merge("url" => url.to_s, "title" => title.to_s)
          fields["owners"] = owners(fields["owners"]) if fields.key?("owners")
          new_entry("annotation", annotation["comment"].to_s.strip, fields)
        end
        list.concat(added)
        added
      end
    end

    # Edits the comment text only; what an entry points at stays. Returns the
    # entry, or raises when it is gone (sent or deleted in another tab).
    def edit(id, comment)
      raise ArgumentError, "a draft can't be blank — delete it instead" if comment.to_s.strip.empty?

      update do |list|
        entry = list.find { |candidate| candidate["id"] == id } or raise ArgumentError, "no draft #{id} on #{@slug}"
        # A draft Claude wrote is the user's once they have changed it.
        entry["author"] = "user" if entry["author"] == "claude" && entry["comment"] != comment.to_s
        revise(entry, comment.to_s)
      end
    end

    # Moves a GitHub draft to where it posts now, its comment unchanged:
    # re-anchored on a newer head or a rebased commit (ReviewPlan, no rev
    # bump — nothing the user wrote changed), or placed by them from the
    # outdated card (bump: true). A nil value drops the field; "failed"
    # always goes, a new place deserves a new try. rev: only while the entry
    # is still at that rev. Returns the entry, or nil when it is gone or was
    # edited since.
    def relocate(id, fields, rev: nil, bump: false)
      update do |list|
        entry = list.find { |candidate| candidate["id"] == id && candidate["kind"] == "github-comment" }
        next nil unless entry && (rev.nil? || entry["rev"] == rev)

        fields = fields.slice(*RELOCATED)
        fields.merge("failed" => nil).each { |key, value| value.nil? ? entry.delete(key) : entry[key] = value }
        entry.merge!("rev" => entry["rev"].to_i + 1) if bump
        entry.merge!("updatedAt" => @now.call.utc.iso8601)
      end
    end

    # What posting said about a draft GitHub didn't take: it stays, marked,
    # until it is posted or changed (RELOCATED's "failed").
    def mark_failed(id, rev, message)
      update do |list|
        entry = list.find { |candidate| candidate["id"] == id && candidate["rev"] == rev }
        entry && entry.merge!("failed" => message.to_s)
      end
    end

    # True when it was there.
    def delete(id)
      update { |list| list.reject! { |entry| entry["id"] == id } ? true : false }
    end

    # Removes exactly these {id => rev} entries: one edited since (another
    # rev) stays. Without a map, everything. Returns how many went.
    def remove(revs = nil)
      update do |list|
        before = list.size
        list.reject! { |entry| revs.nil? || revs[entry["id"]] == entry["rev"] }
        before - list.size
      end
    end

    private

    def diff_address(fields)
      [fields["range"].to_s, fields["side"].to_s, fields["line"].to_s, fields["path"].to_s, fields["number"].to_s]
    end

    # The address and, when it names a PR, the PR fields: a GitHub draft must
    # name one and the commit it anchors to, and has an author.
    def line_fields(raw, kind)
      fields = raw.slice(*DIFF_FIELDS).reject { |_, value| value.nil? || value == "" }
      raise ArgumentError, "a diff comment needs a path" if fields["path"].to_s.strip.empty?
      if fields.key?("branch") && !(fields["branch"].is_a?(String) && fields["branch"].match?(BRANCH))
        raise ArgumentError, "a diff comment's branch must be a branch name"
      end
      fields.delete("committed") unless fields["committed"] == true
      return fields if kind == "diff-comment" && raw["number"].to_s.empty?

      pr = raw.slice(*PR_FIELDS).reject { |_, value| value.nil? || value == "" }
      pr["number"] = Integer(pr["number"].to_s, exception: false)
      unless pr["repo"].to_s.match?(REPO) && pr["number"].to_i.positive?
        raise ArgumentError, "a review draft needs its PR's repo and number"
      end
      raise ArgumentError, "a review draft needs the commit it anchors to" unless pr["commit"].to_s.match?(SHA)
      raise ArgumentError, "a review draft's base must be a sha" if pr.key?("base") && !pr["base"].to_s.match?(SHA)
      return fields.merge(pr.except("subject", "author")) if kind == "diff-comment"

      pr["subject"] ||= "line"
      pr["author"] ||= "user"
      raise ArgumentError, "subject must be line or file" unless SUBJECTS.include?(pr["subject"])
      raise ArgumentError, "author must be user or claude" unless AUTHORS.include?(pr["author"])

      fields.merge(pr)
    end

    # A put on an address that holds a draft: kind, fields and comment become
    # the put's; the rev moves only when something changed.
    def reshape(entry, kind, fields, comment)
      before = entry.dup
      # Like edit: a draft Claude wrote stays his until its text changes.
      fields = fields.merge("author" => entry["author"]) if fields.key?("author") && entry["author"] && entry["comment"] == comment
      (DIFF_FIELDS + PR_FIELDS + %w[pin failed]).each { |key| entry.delete(key) unless fields.key?(key) }
      entry.merge!(fields, "kind" => kind, "comment" => comment)
      return entry if entry == before

      entry.merge!("rev" => entry["rev"].to_i + 1, "updatedAt" => @now.call.utc.iso8601)
    end

    def issue_address(fields) = [fields["file"].to_s, fields["block"].to_s]

    def owners(raw)
      return [] unless raw.is_a?(Array)

      raw.grep(Hash).map { |owner| owner.slice(*OWNER_FIELDS) }
    end

    def new_entry(kind, comment, fields)
      at = @now.call.utc.iso8601
      { "id" => SecureRandom.hex(6), "kind" => kind, "comment" => comment, "rev" => 1,
        "createdAt" => at, "updatedAt" => at }.merge(fields)
    end

    def revise(entry, comment)
      return entry if entry["comment"] == comment

      entry.delete("failed")
      entry.merge!("comment" => comment, "rev" => entry["rev"].to_i + 1, "updatedAt" => @now.call.utc.iso8601)
    end

    def read
      data = JSON.parse(File.read(path))
      data["entries"].is_a?(Array) ? data : empty
    rescue StandardError
      empty
    end

    def empty = { "v" => VERSION, "entries" => [] }

    # Read-modify-write under both locks, then write-temp-and-rename so a
    # reader (the pulse, another tab's state build) never sees half a file.
    # An item left without drafts or clipboard load ids loses its file.
    def update
      FileUtils.mkdir_p(DIR)
      MUTEX.synchronize do
        File.open(File.join(DIR, ".#{@slug}.lock"), File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          data = read
          result = yield data["entries"], data
          if data["entries"].empty? && Array(data["loaded"]).empty?
            FileUtils.rm_f(path)
          else
            temp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
            File.write(temp, JSON.pretty_generate(data.merge("v" => VERSION)))
            File.rename(temp, path)
          end
          result
        end
      end
    end
  end
end
