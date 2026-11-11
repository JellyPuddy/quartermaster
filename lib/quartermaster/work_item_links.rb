# frozen_string_literal: true

module Quartermaster
  # Links on WorkItem: any item may carry {label, url} links in front key
  # `links`, each label once, every url http(s).
  module WorkItemLinks
    LINK_URL = %r{\Ahttps?://\S+\z}i

    def links = Array(front["links"]).select { |link| link.is_a?(Hash) }

    # Adds the link, or replaces the url of the one with the same label.
    def set_link(label, url)
      label = label.to_s.strip
      raise ArgumentError, "a link needs a label" if label.empty?
      raise ArgumentError, "a link's url must be http(s)://…" unless url.to_s.match?(LINK_URL)

      locked do
        list = links.map(&:dup)
        existing = list.find { |link| link["label"] == label }
        existing ? existing["url"] = url : list << { "label" => label, "url" => url }
        store_links(list)
      end
    end

    # Adds each candidate link whose label and url the item doesn't carry yet,
    # replacing and removing nothing; returns the ones added.
    def add_missing_links(candidates)
      locked do
        list = links.map(&:dup)
        added = candidates.reject { |link| list.any? { |own| own["label"] == link["label"] || own["url"] == link["url"] } }
        store_links(list + added) unless added.empty?
        added
      end
    end

    def remove_link(label)
      locked do
        raise ArgumentError, "'#{slug}' has no link '#{label}'" unless links.any? { |link| link["label"] == label }

        store_links(links.reject { |link| link["label"] == label })
      end
    end

    private

    def store_links(list)
      list.empty? ? front.delete("links") : front["links"] = list
      save
    end
  end
end
