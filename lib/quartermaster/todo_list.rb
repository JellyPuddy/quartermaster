# frozen_string_literal: true

module Quartermaster
  # The user's own to-do list: todos.json under the data root, an ordered
  # array whose order is the priority (index 0 on top). Every change rewrites
  # the file whole under an exclusive flock on todos.lock, so the CLI and the
  # GUI both write it directly. Fields qm doesn't know survive a rewrite. An
  # unreadable file reads as empty, is logged once per outage and is never
  # rewritten: changes are refused until the user fixes or removes it.
  class TodoList
    VERSION = 1
    DONE_SHOWN = 20

    def initialize(root: ROOT, clock: -> { Time.now })
      @path = File.join(root, "todos.json")
      @lock_path = File.join(root, "todos.lock")
      @clock = clock
    end

    # Every todo, open and done, in priority order.
    def todos
      read_document["todos"].select { |t| t.is_a?(Hash) }
    rescue JSON::ParserError, TypeError => e
      Quartermaster.log_error("todos", e)
      []
    end

    # all: an array from #todos, so one read can feed both #open and #done_recent.
    def open(all = todos) = all.reject { |t| t["done_at"] }

    # Size and mtime of todos.json, "0" without one: the GUI's pulse moves
    # when the CLI writes the list.
    def signature
      stat = File.stat(@path)
      "#{stat.size}-#{stat.mtime.to_f}"
    rescue SystemCallError
      "0"
    end

    def done_recent(all = todos, limit: DONE_SHOWN)
      all.select { |t| t["done_at"] }.sort_by { |t| t["done_at"].to_s }.reverse.first(limit)
    end

    # item: a work-item slug (it must exist); the todo then shows the item's
    # project, so its own is dropped.
    def add(text, item: nil, project: nil)
      todo = { "id" => SecureRandom.hex(4), "text" => one_line(text), "created" => now }
      WorkItem.find(item) if item
      attach(todo, item: item, project: project)
      change { |list| list.unshift(todo) }
      todo
    end

    # project: "" clears it; a todo on an item keeps none. item: a slug (it
    # must exist) moves the todo onto that item; "" takes it off, keeping
    # the project it showed. outcome: "" clears it.
    def edit(id, text: nil, project: nil, item: nil, outcome: nil)
      target = item.to_s.empty? ? nil : WorkItem.find(item)
      change do |list|
        todo = find(list, id)
        todo["text"] = one_line(text) if text
        set_outcome(todo, outcome) unless outcome.nil?
        if target then attach(todo, item: target.slug)
        elsif item == "" && todo["item"] then attach(todo, project: project.nil? ? former_project(todo.delete("item")) : project)
        elsif !project.nil? then attach(todo, item: todo["item"], project: project)
        end
      end
    end

    # Moves a todo next to a neighbour, so a reorder in a filtered view lands
    # in the right place of the whole list.
    def move(id, before: nil, after: nil)
      raise ArgumentError, "move needs before or after" unless before || after

      change do |list|
        todo = find(list, id)
        neighbour = find(list, before || after)
        next if todo.equal?(neighbour)

        list.delete(todo)
        index = list.index(neighbour)
        list.insert(before ? index : index + 1, todo)
      end
    end

    # item: the work item the todo became; its project goes with it.
    # outcome: how it ended, one line; a blank one leaves any earlier outcome.
    def done(id, item: nil, outcome: nil)
      change do |list|
        todo = find(list, id)
        todo["done_at"] = now
        attach(todo, item: item) if item
        set_outcome(todo, outcome) unless outcome.to_s.strip.empty?
      end
    end

    # Keeps the outcome.
    def undone(id)
      change { |list| find(list, id).delete("done_at") }
    end

    def delete(id)
      change { |list| list.delete(find(list, id)) }
    end

    private

    def read_document
      data = File.exist?(@path) ? JSON.parse(File.read(@path)) : { "v" => VERSION, "todos" => [] }
      raise TypeError, "todos.json holds no todo list" unless data.is_a?(Hash) && data.fetch("todos", []).is_a?(Array)

      Quartermaster.log_success("todos")
      data.merge("todos" => data["todos"] || [])
    end

    def change
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@lock_path, File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        data = begin
          read_document
        rescue JSON::ParserError, TypeError => e
          raise ArgumentError, "todos.json is unreadable (#{e.message}); fix or remove #{@path}"
        end
        yield data["todos"]
        AtomicFile.write(@path, "#{JSON.pretty_generate(data.merge("v" => VERSION))}\n")
      end
    end

    def attach(todo, item: nil, project: nil)
      if item
        todo["item"] = item
        todo.delete("project")
      elsif project.to_s.strip.empty?
        todo.delete("project")
      else
        todo["project"] = project.strip
      end
    end

    def set_outcome(todo, outcome)
      line = outcome.to_s.gsub(/\s+/, " ").strip
      line.empty? ? todo.delete("outcome") : todo["outcome"] = line
    end

    def former_project(slug)
      project = WorkItem.find(slug).project
      project == ProjectMap::NO_PROJECT ? nil : project
    rescue ArgumentError
      nil
    end

    def find(list, id)
      list.find { |t| t.is_a?(Hash) && t["id"] == id } or raise ArgumentError, "no todo '#{id}'"
    end

    def one_line(text)
      line = text.to_s.gsub(/\s+/, " ").strip
      raise ArgumentError, "a todo needs text" if line.empty?

      line
    end

    def now = @clock.call.utc.iso8601
  end
end
