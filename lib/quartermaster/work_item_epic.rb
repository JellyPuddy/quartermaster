# frozen_string_literal: true

module Quartermaster
  # Epics on WorkItem: an item of kind "epic" groups others one level deep. A
  # child names its epic in front key `epic`; the epic stores no list, its
  # children are found by scanning. Links ({label, url}) may hang on any item.
  module WorkItemEpic
    EPIC_KIND = "epic"
    LINK_URL = %r{\Ahttps?://\S+\z}i

    def self.included(base) = base.extend(ClassMethods)

    module ClassMethods
      # Raises unless an item of `kind` named `slug` may sit in epic_slug.
      def check_epic_target!(epic_slug, kind:, slug:)
        raise ArgumentError, "an epic can't be inside another epic (one level only)" if kind == EPIC_KIND
        raise ArgumentError, "an automation can't join an epic" if kind == "automation"

        target = epic_slug == slug ? nil : find(epic_slug)
        raise ArgumentError, "'#{epic_slug}' is not an epic (kind: epic)" unless target&.epic?
      end

      def children_of(epic_slug) = all.select { |item| item.epic == epic_slug }
    end

    def epic? = kind == EPIC_KIND
    def epic = front["epic"]
    def links = Array(front["links"]).select { |link| link.is_a?(Hash) }
    def children = self.class.children_of(slug)

    # The epic this item sits in, or nil when it has none or its slug dangles.
    def epic_item
      return nil unless epic && File.exist?(self.class.path_for(epic))

      found = self.class.find(epic)
      found.epic? ? found : nil
    end

    def join_epic(epic_slug)
      locked do
        self.class.check_epic_target!(epic_slug, kind: kind, slug: slug)
        front["epic"] = epic_slug
        save
      end
    end

    def leave_epic
      locked do
        front.delete("epic")
        save
      end
    end

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
