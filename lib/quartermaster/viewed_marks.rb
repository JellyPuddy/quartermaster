# frozen_string_literal: true

module Quartermaster
  # Which files of an item's diff the user has marked viewed in the diff pane.
  # A mark is keyed to (path, digest of that file's diff as shown), so when
  # the file's diff changes — an agent edited it, another scope shows other
  # changes — the mark no longer matches and the file reads unviewed again.
  # No per-scope sets: a mark carries to whichever scope shows the very same
  # diff of that file.
  #
  # One JSON file per item (viewed/<slug>.json): { "v", "marks" => { path =>
  # [digest, …] } }, newest last. A path keeps its newest KEEP_PER_PATH
  # digests (a file's diff differs per scope, so one is too few), and the
  # file keeps its MAX_PATHS most recently marked paths. Resolving the item
  # drops the file.
  class ViewedMarks
    DIR = File.join(ROOT, "viewed")
    VERSION = 1
    KEEP_PER_PATH = 6
    MAX_PATHS = 2000
    DIGEST = /\A\h{16,64}\z/

    MUTEX = Mutex.new

    # A file's diff as the pane shows it: its paths, status and every hunk's
    # header and lines. The branch scope's uncommitted marks are left out, so
    # committing a file doesn't unview it.
    def self.digest(file)
      shown = [file["status"], file["oldPath"], file["path"], file["binary"] ? 1 : 0,
               file["hunks"].map { |h| [h["header"], h["lines"].map { |l| "#{l["t"]}#{l["s"]}" }] }]
      Digest::SHA256.hexdigest(JSON.generate(shown))[0, 20]
    end

    def initialize(slug)
      raise ArgumentError, "'#{slug}' is not a work item slug" unless slug.is_a?(String) && slug.match?(Drafts::SLUG)

      @slug = slug
    end

    def path = File.join(DIR, "#{@slug}.json")

    def marks = read["marks"]

    # Gives each file of a diff payload its "digest" and "viewed" flag.
    def apply(files)
      known = marks
      files.each do |file|
        file["digest"] = self.class.digest(file)
        file["viewed"] = Array(known[file["path"]]).include?(file["digest"])
      end
    end

    # Marks or unmarks one (path, digest). Returns whether it is viewed now.
    def set(file_path, digest, viewed)
      raise ArgumentError, "a viewed mark needs a path" unless file_path.is_a?(String) && !file_path.strip.empty?
      raise ArgumentError, "#{digest.inspect} is not a diff digest" unless digest.is_a?(String) && digest.match?(DIGEST)

      update do |all|
        digests = Array(all.delete(file_path)) - [digest]
        digests << digest if viewed
        all[file_path] = digests.last(KEEP_PER_PATH) unless digests.empty?
        all.shift while all.size > MAX_PATHS
        viewed
      end
    end

    def clear = FileUtils.rm_f(path)

    private

    def read
      data = JSON.parse(File.read(path))
      data["marks"].is_a?(Hash) ? data : empty
    rescue StandardError
      empty
    end

    def empty = { "v" => VERSION, "marks" => {} }

    # As Drafts#update: read-modify-write under the mutex and a flock, then
    # write-temp-and-rename. An item left without marks loses its file.
    def update
      FileUtils.mkdir_p(DIR)
      MUTEX.synchronize do
        File.open(File.join(DIR, ".#{@slug}.lock"), File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          data = read
          result = yield data["marks"]
          if data["marks"].empty?
            FileUtils.rm_f(path)
          else
            temp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
            File.write(temp, JSON.generate(data.merge("v" => VERSION)))
            File.rename(temp, path)
          end
          result
        end
      end
    end
  end
end
