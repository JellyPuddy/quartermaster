# frozen_string_literal: true

module Quartermaster
  # Comments the user left on an item's issue drafts (IssueDrafts), as the
  # chat's message: a header naming the issues directory, then per issue
  # file its title and comments — the whole-issue ones first, then those on
  # a block, the block's source text quoted, in the body's order. A block
  # no longer in the body (Claude revised it since) still sends, quoting the
  # text the comment was made on and saying it changed.
  module IssueComments
    module_function

    # entries: [{ "file", "block", "title", "comment" }]
    # issues: { file => { "title", "body" } } as the files read now;
    # broken: the files there that don't parse right now.
    def message(entries, issues: {}, broken: [], dir: nil)
      comments = Array(entries).select { |e| e.is_a?(Hash) && !e["comment"].to_s.strip.empty? && !e["file"].to_s.empty? }
      raise ArgumentError, "no issue comments to send" if comments.empty?

      on = dir.to_s.strip.empty? ? "the issue drafts" : "the issue drafts in #{dir}"
      header = "Comments on #{on} — #{comments.size} comment#{"s" unless comments.size == 1}:"
      sections = comments.group_by { |e| e["file"] }.sort_by(&:first).map do |file, on_file|
        section(file, on_file, issues[file], broken: broken.include?(file))
      end
      ([header] + sections).join("\n\n")
    end

    def section(file, comments, issue, broken: false)
      title = issue ? issue["title"] : comments.map { |e| e["title"].to_s.strip }.reject(&:empty?).last
      heading = "## #{file}"
      heading += " — #{title}" unless title.to_s.strip.empty?
      heading += broken ? " (doesn't parse right now)" : " (no longer in the issue drafts)" unless issue
      body = issue ? issue["body"].to_s : ""
      ordered = comments.each_with_index.sort_by do |entry, index|
        block = entry["block"].to_s.strip
        at = block.empty? ? -1 : body.index(block)
        [at ? 0 : 1, at || 0, index]
      end
      ([heading] + ordered.map { |entry, _| comment(entry, issue ? body : nil) }).join("\n\n")
    end

    def comment(entry, body)
      block = entry["block"].to_s.strip
      text = entry["comment"].to_s.strip
      return "On the whole issue:\n#{text}" if block.empty?

      quoted = block.lines.map { |line| line.strip.empty? ? ">" : "> #{line.chomp}" }.join("\n")
      changed = "(this block has changed since; the text above is what the comment was made on)" if body && !body.include?(block)
      [quoted, changed, text].compact.join("\n")
    end
  end
end
