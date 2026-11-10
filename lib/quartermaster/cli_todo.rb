# frozen_string_literal: true

module Quartermaster
  # `qm todo`: the user's own to-do list (TodoList). The item or project is
  # only ever what the flags say, never guessed from QM_ITEM or the cwd.
  module CliTodo
    COMMANDS = { "todo" => :cmd_todo }.freeze
    TODO_USAGE = 'usage: qm todo add [--item SLUG | --project NAME] [--] "text" | qm todo list | qm todo done N'

    private

    def cmd_todo(argv)
      case argv.shift
      when "add" then todo_add(argv)
      when "list" then todo_list
      when "done" then todo_done(argv)
      else abort(TODO_USAGE)
      end
    rescue ArgumentError => e
      abort("qm: #{e.message}")
    end

    def todo_add(argv)
      options = {}
      parser = OptionParser.new do |o|
        o.on("--item SLUG") { |v| options[:item] = v }
        o.on("--project NAME") { |v| options[:project] = v }
      end
      text = FreeTextArgs.parse(parser, argv).join(" ").strip
      abort(TODO_USAGE) if text.empty?
      raise ArgumentError, "give --item or --project, not both (a todo on an item shows the item's project)" if options[:item] && options[:project]

      todo = TodoList.new.add(text, item: options[:item], project: options[:project])
      puts "added on top: #{todo["text"]}#{todo_tag(todo)}"
    end

    def todo_list
      TodoList.new.open.each.with_index(1) do |todo, n|
        puts "#{n}. #{todo["text"]}#{todo_tag(todo)}"
      end
    end

    def todo_done(argv)
      n = Integer(argv.first.to_s, exception: false)
      list = TodoList.new
      todo = n&.positive? && list.open[n - 1]
      raise ArgumentError, "no open todo #{argv.first} (numbers as qm todo list prints them)" unless todo

      list.done(todo["id"])
      puts "done: #{todo["text"]}"
    end

    def todo_tag(todo)
      project = todo["item"] ? todo_item_project(todo["item"]) : todo["project"]
      tag = [project, todo["item"]].compact.join(" · ")
      tag.empty? ? "" : "  [#{tag}]"
    end

    def todo_item_project(slug)
      WorkItem.find(slug).project
    rescue ArgumentError
      nil
    end
  end
end
