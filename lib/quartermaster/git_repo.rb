# frozen_string_literal: true

module Quartermaster
  # Read-only questions cleanup asks of one repo: its worktrees, its local
  # branches, whether a checkout is dirty, and — the one that decides what
  # may be deleted — which commits of a head have no equivalent anywhere
  # else. Nothing here changes the repo; removals go through CommandRunner.
  #
  # One instance serves one plan: which refs exist, and the touched paths and
  # patch-ids of commits (immutable, keyed by sha), are remembered across the
  # heads it is asked about.
  class GitRepo
    Worktree = Struct.new(:path, :branch, :head, :locked, :prunable, keyword_init: true) do
      def locked? = !locked.nil?
      def prunable? = prunable
      def detached? = branch.nil?
    end

    # The trunk refs every safety check compares against, whichever exist.
    TRUNK_REFS = %w[origin/main main origin/master master].freeze

    attr_reader :root

    def initialize(root)
      @root = root
    end

    # Every worktree, the main checkout first (as git lists it).
    def worktrees
      listing = git("worktree", "list", "--porcelain")
      return [] unless listing

      listing.split("\n\n").filter_map do |block|
        fields = block.lines.map(&:chomp)
        path = fields.find { |l| l.start_with?("worktree ") }&.delete_prefix("worktree ")
        next unless path

        branch = fields.find { |l| l.start_with?("branch refs/heads/") }&.delete_prefix("branch refs/heads/")
        lock = fields.find { |l| l == "locked" || l.start_with?("locked ") }
        Worktree.new(path: path, branch: branch,
                     head: fields.find { |l| l.start_with?("HEAD ") }&.delete_prefix("HEAD "),
                     locked: lock && lock.delete_prefix("locked").strip,
                     prunable: fields.any? { |l| l.start_with?("prunable") })
      end
    end

    def main_worktree_path
      worktrees.first&.path
    end

    def local_branches
      out = git("for-each-ref", "--format=%(refname:short)", "refs/heads")
      out ? out.split("\n") : []
    end

    def branch?(name)
      !git("rev-parse", "--verify", "--quiet", "refs/heads/#{name}").nil?
    end

    # A ref name as the user would type it (main, origin/main, a sha).
    def ref?(name)
      !git("rev-parse", "--verify", "--quiet", "#{name}^{commit}").nil?
    end

    def trunk_refs
      existing_refs(TRUNK_REFS)
    end

    # Tracked changes and untracked files of one checkout, as reasons.
    def dirt(path)
      out = Quartermaster.git(path, "status", "--porcelain")
      return ["git status failed"] unless out

      lines = out.split("\n")
      reasons = []
      reasons << "uncommitted changes" if lines.any? { |l| !l.start_with?("??") }
      reasons << "untracked files" if lines.any? { |l| l.start_with?("??") }
      reasons
    end

    # The commits of `head` that would be lost if it went away: not contained
    # in any base, and with no patch-equivalent (what `git cherry` calls one)
    # among the commits the bases hold and head doesn't. A head whose
    # combined change already sits in a `squash_into` ref (trunk unless the
    # caller adds more, e.g. the head's upstream) that is also a base
    # (a squash merge: merging it there changes nothing) loses nothing either
    # — patch equivalence alone can't see a squash of several commits.
    # Newest first, as [sha, subject]. With no base to compare against,
    # nothing counts as preserved. nil when git can't answer — never read
    # that as "nothing to lose".
    def unpreserved_commits(head, bases, squash_into: trunk_refs)
      bases = existing_refs(bases.uniq)
      # Revisions go through stdin: a sweep passes every local branch, and a
      # stdin revision is never mistaken for a path (a branch named docs).
      out = git("log", "--no-merges", "--format=%H %s", "--stdin", stdin: revisions([head], bases))
      return nil if out.nil?
      return [] if out.empty?

      candidates = out.split("\n").map { |line| line.split(" ", 2) }
      return candidates if bases.empty?
      return [] if (squash_into & bases).any? { |base| content_merged?(base, head) }

      left = without_equivalent(candidates.map(&:first), head, bases)
      left && candidates.select { |sha, _| left.include?(sha) }
    end

    private

    # Of `shas`, those whose patch-id no commit reachable from a base but not
    # from head shares — the union of `git cherry base head` over every base,
    # in a fixed number of git calls. Full patch-ids are only computed where
    # the touched paths already agree, as cherry does.
    def without_equivalent(shas, head, bases)
      others = git("rev-list", "--no-merges", "--stdin", stdin: revisions(bases, [head]))
      return nil if others.nil?

      others = others.split("\n")
      paths = touched_paths(shas + others)
      return nil if paths.nil?

      by_paths = others.group_by { |sha| paths[sha] }
      suspects = shas.to_h { |sha| [sha, by_paths.fetch(paths[sha], [])] }
      ids = patch_ids(suspects.reject { |_sha, alike| alike.empty? }.flat_map { |sha, alike| [sha, *alike] })
      return nil if ids.nil?

      # git patch-id prints nothing for an empty commit, where cherry calls
      # two empty commits equivalent. Only a diff touching no path counts
      # as empty: a mode-only change touches one.
      id_of = ->(sha) { paths[sha].empty? ? :empty : ids[sha] }
      shas.reject do |sha|
        id = id_of.(sha)
        id && suspects[sha].any? { |other| id_of.(other) == id }
      end
    end

    # sha => the sorted paths its diff touches, for every sha given; nil
    # when git fails.
    def touched_paths(shas)
      @touched_paths ||= {}
      missing = shas.uniq.reject { |sha| @touched_paths.key?(sha) }
      return @touched_paths if missing.empty?

      out = git("log", "--no-walk=unsorted", "--stdin", "--root", "--no-renames", "--name-only",
                "--format=%x00%H", stdin: missing.join("\n"))
      return nil if out.nil?

      out.split("\0").reject(&:empty?).each do |chunk|
        sha, *names = chunk.split("\n")
        @touched_paths[sha] = names.reject(&:empty?).sort.join("\n")
      end
      missing.all? { |sha| @touched_paths.key?(sha) } ? @touched_paths : nil
    end

    # sha => its patch-id (nil for a commit without a diff); nil when git
    # fails. The diff is pinned against config that would change its text.
    def patch_ids(shas)
      @patch_ids ||= {}
      missing = shas.uniq.reject { |sha| @patch_ids.key?(sha) }
      return @patch_ids if missing.empty?

      diff = git("log", "--no-walk=unsorted", "--stdin", "-p", "--root", "--no-renames", "--full-index",
                 "--binary", "--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/",
                 "--dst-prefix=b/", "--format=commit %H", stdin: missing.join("\n"))
      return nil if diff.nil?

      ids = git("patch-id", "--stable", stdin: "#{diff}\n")
      return nil if ids.nil?

      missing.each { |sha| @patch_ids[sha] = nil }
      ids.split("\n").each do |line|
        id, sha = line.split(" ")
        @patch_ids[sha] = id if sha
      end
      @patch_ids
    end

    def revisions(positive, negative)
      (positive + negative.map { |ref| "^#{ref}" }).join("\n")
    end

    # The names that resolve to a commit, checked in one call and remembered.
    def existing_refs(names)
      @commit_refs ||= {}
      missing = names.uniq.reject { |name| @commit_refs.key?(name) }
      if missing.any?
        out = git("cat-file", "--batch-check=%(objectname)", stdin: missing.map { |n| "#{n}^{commit}" }.join("\n"))
        found = out ? out.split("\n") : []
        missing.each_with_index { |name, i| @commit_refs[name] = found[i].to_s.match?(/\A\h{40}(\h{24})?\z/) }
      end
      names.select { |name| @commit_refs[name] }
    end

    # Merging head into base would leave base's tree untouched.
    def content_merged?(base, head)
      merged = git("merge-tree", "--write-tree", base, head)
      @trees ||= {}
      @trees[base] ||= git("rev-parse", "#{base}^{tree}")
      merged && merged.lines.first&.strip == @trees[base]
    end

    def git(*args, stdin: "")
      Quartermaster.git(@root, *args, stdin: stdin)
    end
  end
end
