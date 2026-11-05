# frozen_string_literal: true

module Quartermaster
  # A local mirror of the delegate-build status boards, folded from the
  # PostToolUse hook's `board-writes.jsonl` (one line per ArtifactData call,
  # sub-agents included). The artifact itself can't be iframed and headless
  # sessions can't read it, so this is how the GUI renders a board natively.
  #
  # Folding mirrors the artifact database's own semantics: set replaces,
  # update deep-merges (a `{"__delete__": true}` value drops the field),
  # str_replace edits one string field in place, delete removes, batch
  # applies each entry in order; last write wins.
  # Reads and refused writes leave no trace.
  #
  # The file only grows, so a mirror keeps its byte offset and folds just the
  # new complete lines on each #refresh; a shrunken file (rotated or
  # truncated) is refolded from the start.
  class BoardMirror
    WRITES_FILE = File.join(ROOT, "board-writes.jsonl")
    ROW_COLLECTION = "tasks"
    ROW_FIELDS = %w[status title note order dependsOn batch batchLabel updatedAt].freeze
    WRITE_ACTIONS = %w[set update str_replace delete batch].freeze
    BLOCKED = "blocked"
    # An answer file name is the row's doc_id, so it must stay one plain
    # path segment — the same alphabet the artifact database allows.
    DOC_ID = /\A(?!\.\.?\z)[A-Za-z0-9_\-.~:@+]{1,200}\z/

    # One mirror per file per process, so the GUI's ~1 s polls each fold only
    # what was appended since the last one.
    SHARED = {}
    SHARED_MUTEX = Mutex.new

    def self.shared(path = WRITES_FILE)
      SHARED_MUTEX.synchronize { SHARED[path] ||= new(path) }
    end

    # Artifact links come as claude.ai/artifact/{id} and
    # claude.ai/code/artifact/{uuid}, with or without a query or trailing
    # slash; the id is what identifies the board.
    def self.board_key(url)
      url = url.to_s.strip
      url[%r{/artifact/([^/?#]+)}, 1] || url.sub(%r{[/?#]+\z}, "")
    end

    def initialize(path = WRITES_FILE)
      @path = path
      @mutex = Mutex.new
      reset
    end

    # Rows of an item's board (via its `board:` record), or [] without one.
    def rows_for(item)
      item.board ? rows(item.board) : []
    end

    # The board's task rows, newest batch first (batch ids are ISO-prefixed,
    # rows without one last) and in plan order within a batch (rows without
    # an order last) — the order the artifact itself shows them in.
    def rows(url)
      docs = refresh.dig(self.class.board_key(url), ROW_COLLECTION) || {}
      rows = docs.map { |doc_id, data| row(doc_id, data) }
      batches = rows.map { |r| r["batch"].to_s }.uniq.reject(&:empty?).sort.reverse
      rows.sort_by do |r|
        ordered = r["order"].is_a?(Numeric)
        [batches.index(r["batch"].to_s) || batches.size, ordered ? 0 : 1, ordered ? r["order"] : 0, r["doc_id"]]
      end
    end

    def row_for(url, doc_id)
      rows(url).find { |r| r["doc_id"] == doc_id }
    end

    # Answers a BLOCKED row by writing `<answers_dir>/<doc_id>.md`, the file
    # the blocked sub-agent is polling for. Written to a temp name and renamed
    # so the agent's `[ -f ]` wait can never see a half-written answer. Only a
    # row currently blocked is answerable: an answer file left for a running
    # task would be read as the answer to its next, unasked question.
    def answer(item, doc_id, text)
      raise ArgumentError, "'#{item.slug}' has no status board" unless item.board
      raise ArgumentError, "'#{item.slug}' has no answers directory (qm board #{item.slug} URL --answers-dir DIR)" unless item.board_answers_dir
      raise ArgumentError, "invalid row id '#{doc_id}'" unless DOC_ID.match?(doc_id.to_s)
      raise ArgumentError, "an empty answer" if text.to_s.strip.empty?

      current = row_for(item.board, doc_id)
      raise ArgumentError, "no row '#{doc_id}' on the board" unless current
      raise ArgumentError, "row '#{doc_id}' is #{current["status"] || "unset"}, not #{BLOCKED}" unless current["status"].to_s.casecmp?(BLOCKED)

      dir = item.board_answers_dir
      FileUtils.mkdir_p(dir)
      target = File.join(dir, "#{doc_id}.md")
      temp = File.join(dir, ".#{doc_id}.md.#{Process.pid}.tmp")
      File.write(temp, text.to_s.end_with?("\n") ? text.to_s : "#{text}\n")
      File.rename(temp, target)
      target
    end

    # Folds whatever was appended since the last call; returns the state
    # {board_key => {collection => {doc_id => data}}}.
    def refresh
      @mutex.synchronize do
        size = File.exist?(@path) ? File.size(@path) : 0
        reset if size < @offset
        read_new_lines if size > @offset
        @boards
      end
    end

    private

    def reset
      @offset = 0
      @boards = {}
    end

    # Only complete lines are consumed: the hook may be mid-append, and a
    # partial line is picked up whole on the next refresh.
    def read_new_lines
      File.open(@path, "rb") do |f|
        f.seek(@offset)
        chunk = f.read
        complete = chunk.rindex("\n")
        return unless complete

        chunk[0..complete].each_line do |line|
          fold_line(line)
        end
        @offset += complete + 1
      end
    end

    def fold_line(line)
      entry = JSON.parse(line.force_encoding(Encoding::UTF_8))
      return unless entry.is_a?(Hash)

      # The hook writes either the raw PostToolUse payload (maybe with a
      # `ts` added) or a {ts, payload} wrapper — accept both.
      payload = entry["payload"].is_a?(Hash) ? entry["payload"] : entry
      ts = entry["ts"] || payload["ts"]
      fold(payload, ts)
    rescue JSON::ParserError, EncodingError
      nil
    end

    def fold(payload, ts)
      return unless payload["tool_name"].to_s.end_with?("ArtifactData")

      input = payload["tool_input"]
      return unless input.is_a?(Hash) && WRITE_ACTIONS.include?(input["action"])
      return if failed?(payload["tool_response"])

      board = self.class.board_key(input["url"])
      return if board.empty?

      writes = input["action"] == "batch" ? Array(input["writes"]) : [input.merge("op" => input["action"])]
      writes.each { |write| apply(board, write, ts) if write.is_a?(Hash) }
    end

    def apply(board, write, ts)
      collection = write["collection"]
      doc_id = write["doc_id"]
      return unless collection.is_a?(String) && doc_id.is_a?(String)

      docs = ((@boards[board] ||= {})[collection] ||= {})
      case write["op"]
      when "delete" then docs.delete(doc_id)
      when "set"
        data = write_data(write) or return
        docs[doc_id] = stamp(strip_deletes(data), ts)
      when "update"
        data = write_data(write) or return
        docs[doc_id] = stamp(deep_merge(docs[doc_id] || {}, data), ts)
      when "str_replace"
        replaced = str_replace(docs[doc_id], write) or return
        docs[doc_id] = replaced
      end
    end

    # The database writes nothing unless old_str occurs exactly once (or at
    # least once with replace_all), so the mirror applies the same rule.
    def str_replace(doc, write)
      field, old_str, new_str = write.values_at("field", "old_str", "new_str")
      return nil unless doc && doc[field].is_a?(String) && old_str.is_a?(String) && !old_str.empty?

      count = doc[field].scan(old_str).size
      return nil if count.zero? || (count > 1 && write["replace_all"] != true)

      value = write["replace_all"] == true ? doc[field].gsub(old_str) { new_str.to_s } : doc[field].sub(old_str) { new_str.to_s }
      doc.merge(field => value)
    end

    # A write's fields come inline, or from a local JSON file it named — read
    # best-effort, since that file may be gone by the time we fold.
    def write_data(write)
      return write["data"] if write["data"].is_a?(Hash)
      return nil unless write["file_path"].is_a?(String) && File.file?(write["file_path"])

      data = JSON.parse(File.read(write["file_path"]))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    # The row's own updatedAt is the writer's clock; the hook's ts only
    # stands in when a write didn't carry one.
    def stamp(data, ts)
      data["updatedAt"] ||= ts if ts
      data
    end

    def deep_merge(base, changes)
      changes.each_with_object(base.dup) do |(key, value), merged|
        if delete_marker?(value)
          merged.delete(key)
        elsif value.is_a?(Hash) && merged[key].is_a?(Hash)
          merged[key] = deep_merge(merged[key], value)
        else
          merged[key] = value.is_a?(Hash) ? strip_deletes(value) : value
        end
      end
    end

    def strip_deletes(data)
      data.each_with_object({}) do |(key, value), clean|
        next if delete_marker?(value)

        clean[key] = value.is_a?(Hash) ? strip_deletes(value) : value
      end
    end

    def delete_marker?(value)
      value.is_a?(Hash) && value["__delete__"] == true && value.size == 1
    end

    # A refused write (version conflict, unread document, access) still
    # reaches PostToolUse, carrying its error in the response. Successful
    # results read "... committed"; anything flagged as an error, or whose
    # text says nothing was written, is dropped. Quoted names are blanked
    # first: a committed write to row "merge-conflict" is still a success.
    FAILURE_TEXT = /\A\s*(<tool_use_error>|error\b)|nothing (is |was )?written|\brefused\b|\bconflict\b/i

    def failed?(response)
      case response
      when Hash
        return true if response["is_error"] == true || response["isError"] == true
        return true if response["error"] && response["error"] != false

        failed?(response["content"] || response["text"] || response["result"])
      when Array then response.any? { |part| failed?(part) }
      when String then FAILURE_TEXT.match?(response.gsub(/"[^"]*"/, %q("")))
      else false
      end
    end

    def row(doc_id, data)
      { "doc_id" => doc_id }.merge(ROW_FIELDS.to_h { |field| [field, data[field]] })
    end
  end
end
