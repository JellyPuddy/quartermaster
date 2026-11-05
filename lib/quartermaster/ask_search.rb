# frozen_string_literal: true

module Quartermaster
  # Answers a fuzzy-memory question ("the one where resume broke after a
  # worktree move") by handing headless claude a compact index of every work
  # item and asking for the matching slugs. The live search box covers exact
  # recall; this covers recall by meaning. Shared by `qm ask` and the GUI.
  class AskSearch
    PROMPT = <<~PROMPT
      You are a search engine over a developer's work items (stdin holds one
      block per item: slug, title, state, project, branches, description and
      its newest notes). The developer half-remembers an item and describes
      it below. Return the items that match, by meaning rather than keywords,
      best first and at most %<limit>d; each with a one-sentence reason that
      names the note or detail that matches. Leave out weak guesses: an empty
      list is the right answer when nothing plausibly matches.

      Query: %<query>s
    PROMPT

    LIMIT = 8
    ANSWER_SCHEMA = {
      "type" => "object", "required" => ["hits"],
      "properties" => {
        "hits" => { "type" => "array", "items" => {
          "type" => "object", "required" => %w[slug why],
          "properties" => { "slug" => { "type" => "string" }, "why" => { "type" => "string" } }
        } }
      }
    }.freeze
    # Per-item caps keep the index small enough to answer in seconds: the raw
    # notes and descriptions of ~60 items ran to ~430k chars. The newest notes
    # win because they say where an item stands now.
    DESCRIPTION_CHARS = 800
    NOTES_CHARS = 2_000
    NOTE_CHARS = 300

    def initialize(items: WorkItem.all)
      @items = items
    end

    # Returns [{ "slug" =>, "why" => }], best first, limited to slugs that exist.
    def call(query)
      query = query.to_s.strip
      raise ArgumentError, "query is empty" if query.empty?

      out, err, status = Open3.capture3(
        { "QM_SKIP" => "1" },
        "claude", "-p", format(PROMPT, limit: LIMIT, query: query), "--model", "sonnet",
        "--tools", "", "--strict-mcp-config", "--no-session-persistence",
        "--output-format", "json", "--json-schema", JSON.generate(ANSWER_SCHEMA),
        stdin_data: index
      )
      raise ArgumentError, "claude -p failed: #{err.strip.empty? ? out.strip : err.strip}" unless status.success?

      parse(out)
    end

    def index
      @items.map { |item| entry(item) }.join("\n\n")
    end

    private

    def entry(item)
      lines = ["## #{item.slug}", "title: #{item.title}", "state: #{item.state}", "project: #{item.project}"]
      lines << "branches: #{item.branches.join(", ")}" if item.branches.any?
      lines << "issue: ##{item.issue_number}" if item.issue_number
      description = item.description.to_s.strip
      lines << "description: #{clip(description, DESCRIPTION_CHARS)}" unless description.empty?
      notes = newest_notes(item)
      lines << "notes:" << notes.map { |n| "- #{n}" } if notes.any?
      lines.flatten.join("\n")
    end

    def newest_notes(item)
      budget = NOTES_CHARS
      item.notes.each_with_object([]) do |note, kept|
        text = "#{note.stamp} #{clip(note.text, NOTE_CHARS)}"
        break kept if text.size > budget

        budget -= text.size
        kept << text
      end
    end

    def clip(text, max)
      text = text.gsub(/\s+/, " ")
      text.size > max ? "#{text[0, max]}…" : text
    end

    # The answer arrives schema-validated as structured_output; still keep
    # only slugs that name a real item, since the model can invent one.
    def parse(out)
      hits = JSON.parse(out).dig("structured_output", "hits")
      raise ArgumentError, "unexpected answer from claude: #{out.strip[0, 200]}" unless hits.is_a?(Array)

      known = @items.map(&:slug)
      hits.filter_map do |hit|
        next unless hit.is_a?(Hash) && known.include?(hit["slug"])

        { "slug" => hit["slug"], "why" => hit["why"].to_s }
      end.uniq { |hit| hit["slug"] }.first(LIMIT)
    rescue JSON::ParserError
      raise ArgumentError, "unparseable answer from claude: #{out.strip[0, 200]}"
    end
  end
end
