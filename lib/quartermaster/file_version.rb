# frozen_string_literal: true

module Quartermaster
  # Whether a file changed, without reading it: its stat's mtime, ctime, size
  # and inode, which every write, replace and chmod moves. The caches that
  # keep a parsed file for the life of the process (ProjectConfig,
  # WorkItemFile) compare it to decide whether to read the file again. nil
  # when the file can't be stat'ed.
  module FileVersion
    module_function

    def of(path)
      stat = File.stat(path)
      [stat.mtime, stat.ctime, stat.size, stat.ino]
    rescue SystemCallError
      nil
    end
  end
end
