# frozen_string_literal: true

module Quartermaster
  # Files dropped onto a GUI terminal. A browser never tells a page where a
  # dropped file lives, so the page uploads it and types the path this
  # returns into the chat — claude attaches an image path the way it does
  # when Warp inserts one. Kept a week, then pruned on the next drop.
  class Drops
    MAX_BYTES = 32 * 1024 * 1024
    KEEP_SECONDS = 7 * 24 * 60 * 60

    def initialize(dir: File.join(ROOT, "drops"), clock: -> { Time.now })
      @dir = dir
      @clock = clock
    end

    # The saved file's absolute path. The name is reduced to characters
    # that need no shell quoting, so the typed path is one word.
    def save(name, bytes)
      raise ArgumentError, "dropped file is empty" if bytes.empty?
      raise ArgumentError, "dropped file is over #{MAX_BYTES / 1024 / 1024} MB" if bytes.bytesize > MAX_BYTES

      FileUtils.mkdir_p(@dir)
      prune
      path = File.join(@dir, "#{@clock.call.strftime("%Y%m%d-%H%M%S")}-#{SecureRandom.hex(3)}-#{safe_name(name)}")
      File.binwrite(path, bytes)
      path
    end

    private

    def safe_name(name)
      base = File.basename(name.to_s).gsub(/[^A-Za-z0-9._-]+/, "-").gsub(/\A[-.]+/, "")
      base.empty? ? "drop" : base[-80..] || base
    end

    def prune
      cutoff = @clock.call - KEEP_SECONDS
      Dir[File.join(@dir, "*")].each { |file| File.delete(file) if File.mtime(file) < cutoff }
    rescue SystemCallError
      nil
    end
  end
end
