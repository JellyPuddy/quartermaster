# frozen_string_literal: true

module Quartermaster
  # Elements the user pointed at on a page the dev server serves (its overlay's Annotate
  # mode), as the one message the chat receives: a header naming the page,
  # then per element what he wrote first and what identifies the element
  # after it. Fields arrive from a browser, so long ones are cut here.
  module PageAnnotations
    module_function

    HTML_LIMIT = 600
    TEXT_LIMIT = 200
    PAGE_LIMIT = 300
    CONTEXT_LIMIT = 300
    COMPONENT_LIMIT = 80
    CHAIN_LIMIT = 300
    REGIONS_LIMIT = 200
    OWNER_FILE_LIMIT = 200
    OWNERS_MAX = 6

    # entries: [{ "comment", "page", "selector", "text", "html", "component", "components", "owners", "context", "regions" }]
    def message(entries, url: nil, title: nil)
      raise ArgumentError, "annotations must be a list" unless entries.is_a?(Array)

      annotations = entries.select { |e| e.is_a?(Hash) && !e["comment"].to_s.strip.empty? }
      raise ArgumentError, "no annotations to send" if annotations.empty?

      url = squish(url)
      page = header_page(annotations, url)
      blocks = annotations.map { |e| entry(e, page, url) }
      ([header(page, url, title, blocks.size)] + blocks).join("\n\n")
    end

    # The tray spans navigations, so the header names the page most annotations were
    # captured on (the first of a tie), not necessarily the one they were sent from.
    def header_page(annotations, url)
      annotations.map { |e| page_of(e, url) }.tally.max_by { |_, count| count }.first
    end

    def page_of(raw, url)
      page = squish(raw["page"])
      page.empty? ? url : page
    end

    # The title belongs to the page sent from, so another header page goes by its URL.
    def header(page, url, title, count)
      "Annotations on #{page == url ? sent_page(url, title) : other_page(page, url)} — " \
        "#{count} element#{"s" unless count == 1}:"
    end

    def sent_page(url, title)
      title = squish(title)
      name = title.empty? ? "a page" : "the page \"#{title}\""
      url.empty? ? name : "#{name} (#{url})"
    end

    def other_page(page, url)
      name = cut(page, PAGE_LIMIT)
      url.empty? ? name : "#{name} (sent from #{cut(path_of(url), PAGE_LIMIT)})"
    end

    def path_of(url)
      uri = URI.parse(url)
      path = uri.path.to_s.empty? ? "/" : uri.path
      uri.query ? "#{path}?#{uri.query}" : path
    rescue URI::Error
      url
    end

    # An element's own page is named only when it isn't the header's.
    def entry(raw, header_page, url)
      comment = raw["comment"].to_s.strip
      page = page_of(raw, url)
      fields = { "page" => page == header_page ? "" : cut(page, PAGE_LIMIT), "selector" => squish(raw["selector"]),
                 **component_fields(raw),
                 "context" => cut(squish(raw["context"]), CONTEXT_LIMIT),
                 "regions" => cut(squish(raw["regions"]), REGIONS_LIMIT),
                 "text" => cut(squish(raw["text"]), TEXT_LIMIT), "html" => cut(squish(raw["html"]), HTML_LIMIT) }
      [comment, *fields.reject { |_, value| value.empty? }.map { |name, value| field_line(name, value) }].join("\n")
    end

    def field_line(name, value) = value.is_a?(Array) ? ["#{name}:", *value].join("\n") : "#{name}: #{value}"

    # Owners (who rendered the element, with their source files) say more than the
    # parent chain, so they take its place when the overlay could read them.
    def component_fields(raw)
      rendered_by = owners(raw["owners"])
      return { "rendered by" => rendered_by } unless rendered_by.empty?

      chain = components(raw["components"])
      chain.empty? ? { "component" => squish(raw["component"]) } : { "components" => chain }
    end

    # Innermost owner first, as the relay sends them. An owner it resolved by its name's
    # one app definition (`via: "definition"`) points at where the component is
    # written, not at the JSX that rendered it, so its line says so. `as` is the
    # name the JSX above uses for it (an aliased or lazy import).
    def owners(raw)
      return [] unless raw.is_a?(Array)

      raw.grep(Hash).filter_map { |owner| owner_line(owner) }.first(OWNERS_MAX)
    end

    def owner_line(owner)
      name = owner["name"].is_a?(String) ? cut(squish(owner["name"]), COMPONENT_LIMIT) : ""
      return nil if name.empty?

      alias_name = owner["as"].is_a?(String) ? cut(squish(owner["as"]), COMPONENT_LIMIT) : ""
      name += " (as <#{alias_name}>)" unless alias_name.empty? || alias_name == name

      file = owner["file"].is_a?(String) ? cut(squish(owner["file"]), OWNER_FILE_LIMIT) : ""
      line = owner["line"]
      file += ":#{line}" if !file.empty? && line.is_a?(Integer) && line.positive?
      return "  - #{name}" if file.empty?

      "  - #{name} · #{owner["via"] == "definition" ? "defined in" : "JSX in"} #{file}"
    end

    # Innermost component first, as the overlay sends them.
    def components(raw)
      return "" unless raw.is_a?(Array)

      names = raw.grep(String).map { |name| cut(squish(name), COMPONENT_LIMIT) }.reject(&:empty?)
      cut(names.join(" < "), CHAIN_LIMIT)
    end

    # One line: a newline inside a field would read as the next field.
    def squish(value) = value.to_s.gsub(/\s+/, " ").strip

    def cut(value, limit) = value.length > limit ? "#{value[0, limit - 1]}…" : value
  end
end
