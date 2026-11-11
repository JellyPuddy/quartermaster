# frozen_string_literal: true

module Quartermaster
  # Epics on WorkItem: an item of kind "epic" groups others one level deep. A
  # child names its epic in front key `epic`; the epic stores no list, its
  # children are found by scanning.
  module WorkItemEpic
    EPIC_KIND = "epic"

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

    # Turns this item into an epic; everything else on it stays.
    def make_epic!
      locked do
        raise ArgumentError, "an automation can't be an epic" if automation?
        raise ArgumentError, "'#{slug}' is already an epic" if epic?
        raise ArgumentError, "'#{slug}' is inside epic '#{epic}' (one level only): run `qm epic #{slug} --clear` first" if epic

        front["kind"] = EPIC_KIND
        save
      end
    end

    # Turns this epic back into a plain item, once no item names it as its epic.
    def unmake_epic!
      locked do
        raise ArgumentError, "'#{slug}' is not an epic" unless epic?

        count = children.size
        if count.positive?
          raise ArgumentError, "#{count} #{count == 1 ? "item is" : "items are"} still in '#{slug}': " \
                               "move them out (qm epic CHILD --clear) first"
        end
        front.delete("kind")
        save
      end
    end
  end
end
