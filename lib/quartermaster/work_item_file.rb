# frozen_string_literal: true

module Quartermaster
  # A work item file's front matter and body, parsed once per version of the
  # file for the life of the process: a GUI state build reads every item
  # several times (the items, the inbox, the chat list) and the files rarely
  # change between builds. The version is the file's stat (mtime, ctime,
  # size, inode), which every write moves, so a qm write or a hand edit shows
  # on the next read. No reader can change what the next one gets: each gets
  # a deep copy of the front matter and the one frozen body. What WorkItem
  # derives from a cached body (sections, notes) is kept with it, so it lasts
  # exactly as long as that version of the file. Entries of files no longer
  # listed go whenever the directory is listed.
  module WorkItemFile
    FORMAT = /\A---\n(.*?)\n---\n(.*)\z/m
    PARSED = {}
    DERIVED = {}.compare_by_identity
    MUTEX = Mutex.new

    module_function

    # [front, body] for the item file at path.
    def read(path, slug)
      version = version(path)
      raise ArgumentError, "no work item '#{slug}'" unless version

      cached = MUTEX.synchronize { PARSED[path] }
      unless cached && cached[:version] == version
        cached = parse(path).merge(version: version)
        MUTEX.synchronize { store(path, cached) }
      end
      [Marshal.load(Marshal.dump(cached[:front])), cached[:body]]
    end

    # What the block derives from body under key: once per cached body,
    # every time for any other. The block's result must be frozen.
    def derived(body, key)
      memo = MUTEX.synchronize { DERIVED[body] }
      return yield unless memo

      found = MUTEX.synchronize { memo.fetch(key, memo) }
      return found unless found.equal?(memo)

      value = yield
      MUTEX.synchronize { memo[key] = value }
    end

    def forget_all_but(paths)
      keep = paths.to_h { |path| [path, true] }
      MUTEX.synchronize { (PARSED.keys - keep.keys).each { |path| DERIVED.delete(PARSED.delete(path)[:body]) } }
    end

    def clear
      MUTEX.synchronize do
        PARSED.clear
        DERIVED.clear
      end
    end

    def version(path)
      stat = File.stat(path)
      [stat.mtime, stat.ctime, stat.size, stat.ino]
    rescue Errno::ENOENT
      nil
    end

    def parse(path)
      match = File.read(path).match(FORMAT)
      raise ArgumentError, "malformed work item file #{path}" unless match

      { front: (YAML.safe_load(match[1], permitted_classes: [Date]) || {}).freeze, body: match[2].freeze }
    end

    # Under MUTEX.
    def store(path, entry)
      DERIVED.delete(PARSED[path][:body]) if PARSED[path]
      PARSED[path] = entry
      DERIVED[entry[:body]] = {}
    end
  end
end
