# frozen_string_literal: true

module Quartermaster
  # Page annotations a dev server's page overlay copied to the clipboard (its
  # way across a read-only tunnel), as the GUI's 📋 load posts them. The
  # contract with any overlay: a readable message, then last in the text a fenced
  # ```pf-annotations block holding one line of JSON,
  # {"v":1,"id","url","title","annotations":[…]} — entries as its relay
  # sends them (page-annotations). Only the last such block counts, so text
  # quoting an older copy above it is harmless.
  #
  # The browser has no source, so owners arrive without `code`: quote fills
  # it from the item's checkout under the rules a relay applies to the files
  # it serves.
  class ClipboardAnnotations
    VERSION = 1
    HEADER = /^```pf-annotations[ \t]*\r?\n/
    BODY = /\G(.*?)^```[ \t]*\r?$/m
    MAX_BYTES = 512 * 1024
    MAX_COUNT = 100
    SOURCE_DIR = "app/javascript"
    MAX_FILE_BYTES = 512 * 1024
    MAX_CODE = 500

    # The last block's payload: { "id", "url", "title", "annotations" }.
    # Raises ArgumentError with what the page toasts.
    def self.parse(text)
      text = text.to_s
      raise ArgumentError, "too much on the clipboard to load" if text.bytesize > MAX_BYTES

      json = last_block(text.dup.force_encoding(Encoding::UTF_8).scrub)
      raise ArgumentError, "no pf-annotations block on the clipboard — copy them in the page's annotation overlay first" unless json

      payload = begin
        JSON.parse(json)
      rescue JSON::ParserError
        nil
      end
      raise ArgumentError, "the pf-annotations block is not valid JSON" unless payload.is_a?(Hash)
      raise ArgumentError, "unknown pf-annotations version #{payload["v"].inspect} (qm reads #{VERSION})" unless payload["v"] == VERSION

      annotations = payload["annotations"]
      raise ArgumentError, "the pf-annotations block holds no annotations" unless annotations.is_a?(Array) && !annotations.empty?
      raise ArgumentError, "too many annotations (max #{MAX_COUNT})" if annotations.size > MAX_COUNT

      id = payload["id"]
      raise ArgumentError, "the pf-annotations block has no id" unless id.is_a?(String) && !id.strip.empty?

      { "id" => id.strip, "url" => payload["url"].to_s, "title" => payload["title"].to_s, "annotations" => annotations }
    end

    # The body of the block opened by the last header, so a header-like line
    # in the readable part above it can't run on into the real block.
    def self.last_block(text)
      start = text.rindex(HEADER) or return nil

      body = text.match(BODY, text.match(HEADER, start).end(0))
      body && body[1]
    end

    # The annotations with each owner that has a file and a positive line
    # given that line's text from the checkout at root as `code`. A `code`
    # on the clipboard is never kept: only qm's reading of the checkout
    # anchors. No root, or a file or line the rules refuse, means no `code`.
    def self.quote(annotations, root)
      files = {}
      annotations.map do |annotation|
        next annotation unless annotation.is_a?(Hash) && annotation["owners"].is_a?(Array)

        owners = annotation["owners"].map do |owner|
          next owner unless owner.is_a?(Hash)

          owner = owner.except("code")
          next owner unless owner["file"].is_a?(String) && owner["line"].is_a?(Integer) && owner["line"].positive?

          lines = files.fetch(owner["file"]) { files[owner["file"]] = source_lines(root, owner["file"]) }
          code = lines && code_line(lines[owner["line"] - 1])
          code ? owner.merge("code" => code) : owner
        end
        annotation.merge("owners" => owners)
      end
    end

    def self.source_lines(root, file)
      return nil unless root && file.start_with?("#{SOURCE_DIR}/") && !file.include?("..") && !file.include?("\0")

      path = File.join(root, file)
      stat = File.lstat(path)
      return nil unless stat.file? && stat.size <= MAX_FILE_BYTES

      File.binread(path).split("\n")
    rescue SystemCallError
      nil
    end

    def self.code_line(line)
      return nil unless line

      code = line.chomp("\r").force_encoding(Encoding::UTF_8).scrub
      code.length <= MAX_CODE ? code : nil
    end

    private_class_method :last_block, :source_lines, :code_line
  end
end
