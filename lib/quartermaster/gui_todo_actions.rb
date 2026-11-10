# frozen_string_literal: true

module Quartermaster
  # The Todos tab's actions on the user's own list (TodoList,
  # docs/areas/todos.md). GuiActions hands every one of COMMANDS here, and
  # Gui runs them off the action mutex: TodoList holds its own flock.
  class GuiTodoActions
    COMMANDS = %w[todo-add todo-edit todo-move todo-done todo-delete].freeze

    def initialize(list: TodoList.new)
      @list = list
    end

    def dispatch(cmd, args)
      return ok.merge("todo" => @list.add(args["text"], item: presence(args["item"]), project: args["project"])) if cmd == "todo-add"

      case cmd
      when "todo-edit" then @list.edit(id(args), text: args["text"], project: args["project"])
      when "todo-move" then @list.move(id(args), before: presence(args["before"]), after: presence(args["after"]))
      when "todo-done" then args["done"] == false ? @list.undone(id(args)) : @list.done(id(args))
      when "todo-delete" then @list.delete(id(args))
      end
      ok
    end

    # The state's todos: the open ones in order, then the newest done. A
    # todo on an item shows that item's project and title; a deleted item
    # leaves only its slug.
    def self.payload(list = TodoList.new, items: WorkItem.all.to_h { |item| [item.slug, item] })
      (list.open + list.done_recent).map do |todo|
        item = items[todo["item"]]
        { "id" => todo["id"], "text" => todo["text"], "created" => todo["created"], "done_at" => todo["done_at"],
          "item" => todo["item"], "project" => item ? item.project : todo["project"], "itemTitle" => item&.title }
      end
    end

    private

    def ok = { "ok" => true }

    def id(args) = args["id"].to_s

    def presence(value) = value.to_s.empty? ? nil : value.to_s
  end
end
