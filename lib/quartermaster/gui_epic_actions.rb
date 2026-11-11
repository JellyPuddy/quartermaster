# frozen_string_literal: true

module Quartermaster
  # The board's item-shaping actions (docs/areas/work-items.md): the New item
  # dialog's `new`, which may make an epic or put the item in one, an item's
  # epic set or cleared, and an epic's links. Each is a WorkItem mutation under
  # its lock, run under the action mutex like every write to an item.
  class GuiEpicActions
    COMMANDS = %w[new epic-set epic-make epic-unmake link-set link-remove].freeze

    def dispatch(cmd, slug, args)
      case cmd
      when "new" then create(args)
      when "epic-set" then set_epic(WorkItem.find(slug), presence(args["epic"]))
      when "epic-make" then WorkItem.find(slug).make_epic!.then { ok }
      when "epic-unmake" then WorkItem.find(slug).unmake_epic!.then { ok }
      when "link-set" then WorkItem.find(slug).set_link(args["label"], args["url"].to_s).then { ok }
      when "link-remove" then WorkItem.find(slug).remove_link(args["label"].to_s).then { ok }
      end
    end

    private

    def create(args)
      title = args["title"].to_s.strip
      raise ArgumentError, "title is required" if title.empty?

      item = WorkItem.create(title, project: args["project"] || ProjectMap::NO_PROJECT,
                                    description: presence(args["description"].to_s.strip), front: front_of(args))
      ok.merge("slug" => item.slug)
    end

    def front_of(args)
      kind = presence(args["kind"])
      raise ArgumentError, "kind takes only 'epic'" unless [nil, WorkItem::EPIC_KIND].include?(kind)
      return { "kind" => kind } if kind

      epic = presence(args["epic"])
      epic ? { "epic" => epic } : {}
    end

    def set_epic(item, epic)
      epic ? item.join_epic(epic) : item.leave_epic
      ok
    end

    def ok = { "ok" => true }

    def presence(value) = value.to_s.empty? ? nil : value.to_s
  end
end
