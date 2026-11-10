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

    # → Work item: the board's new item (WorkItem.create) and the chat pane's
    # Start (Launcher#chat_plan, fresh, in the project's main checkout), then
    # the todo is done and tied to the new item. Checked before anything is
    # made, so an unknown todo or a blank title leaves no stray item. Under
    # the action mutex like `new` and `pane-start`: it creates an item.
    def to_item(args, tmux:)
      todo_id = id(args)
      @list.todos.find { |t| t["id"] == todo_id } or raise ArgumentError, "no todo '#{todo_id}'"
      title = args["title"].to_s.strip
      raise ArgumentError, "title is required" if title.empty?

      item = WorkItem.create(title, project: presence(args["project"]) || ProjectMap::NO_PROJECT)
      plan = Launcher.new.chat_plan(item, fresh: true, prompt: presence(args["prompt"].to_s.strip))
      tmux.open(item.slug, cwd: plan[:cwd], argv: plan[:argv], env: plan[:env])
      @list.done(todo_id, item: item.slug)
      ok.merge("slug" => item.slug, "mode" => plan[:mode].to_s)
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
