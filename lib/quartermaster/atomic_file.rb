# frozen_string_literal: true

module Quartermaster
  # Replaces a file whole: the content goes to a temp file beside it, which is
  # renamed over the target, so a reader without the writer's lock sees the old
  # file or the new one, never a truncated one. A replaced file keeps its mode.
  module AtomicFile
    def self.write(path, content, fsync: false)
      temp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{Thread.current.object_id}.tmp")
      mode = File.exist?(path) ? File.stat(path).mode & 0o7777 : nil
      begin
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC) do |f|
          f.write(content.to_s)
          f.fsync if fsync
        end
        File.chmod(mode, temp) if mode
        File.rename(temp, path)
      rescue StandardError
        FileUtils.rm_f(temp)
        raise
      end
    end
  end
end
