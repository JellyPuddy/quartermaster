# frozen_string_literal: true

module Quartermaster
  # One file as it stands in a commit or tree, as lines: what the diff pane
  # expands a hunk's context from. The rev is a diff payload's "oldRev" and
  # is read in the item's project root, whose object store its worktrees
  # (and their prompt snapshots) share. Only hex reaches git as the rev, and
  # "<rev>:<path>" is one argument, so neither can pose as an option.
  class FileAtRevision
    MAX_BYTES = 1_000_000
    MAX_LINES = 20_000

    def initialize(root)
      @root = root
    end

    # { "lines" => [...], "truncated" => bool }; ArgumentError for a bad rev
    # or path, or when git has no such file there.
    def call(rev, path)
      rev = rev.to_s
      path = path.to_s
      raise ArgumentError, "#{rev.inspect} is not a sha" unless BranchDiff::SHA.match?(rev)
      raise ArgumentError, "no path given" if path.empty? || path.include?("\0")

      text, truncated = read("#{rev}:#{path}")
      lines = text.force_encoding(Encoding::UTF_8).scrub("?").each_line(chomp: true).to_a
      truncated ||= lines.size > MAX_LINES
      { "lines" => lines.first(MAX_LINES), "truncated" => truncated }
    end

    private

    # At most MAX_BYTES of the blob: [bytes, whether there was more]. A cut
    # mid-line drops that partial line.
    def read(object)
      Open3.popen3("git", "-C", @root, "cat-file", "blob", object) do |stdin, stdout, stderr, wait|
        stdin.close
        data = stdout.read(MAX_BYTES + 1) || +""
        more = data.bytesize > MAX_BYTES
        stdout.close
        error = stderr.read
        unless more || wait.value.success?
          raise ArgumentError, "#{object} is not a file in git here#{": #{error.strip}" unless error.strip.empty?}"
        end
        return [data, false] unless more

        data = data.byteslice(0, MAX_BYTES)
        [data.byteslice(0, (data.rindex("\n".b) || -1) + 1), true]
      end
    end
  end
end
