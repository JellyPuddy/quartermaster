# frozen_string_literal: true

require "digest"

module DemoWorld
  # A fake Claude Code session: its transcript lines (the JSONL Claude Code
  # writes under ~/.claude/projects) and, alongside, the hook events
  # record-event.sh would have appended for it — both from one script of
  # prompts, tool calls and answers, so the chat history, the attention
  # state and the context meter agree.
  class Transcript
    MODEL = "claude-opus-5-5"

    attr_reader :id, :cwd, :branch, :lines, :events, :last_at

    def initialize(id:, cwd:, branch: nil, model: MODEL, sidechain: false)
      @id = id
      @cwd = cwd
      @branch = branch
      @model = model
      @sidechain = sidechain
      @lines = []
      @events = []
      @messages = 0
      @uses = 0
      @parent = nil
    end

    # What the user typed; a hook UserPromptSubmit.
    def prompt(at, text)
      user(at, text)
      event(at, "UserPromptSubmit")
    end

    # Claude's text; ctx is the context the reply was answered from.
    def say(at, text, ctx:)
      assistant(at, [{ "type" => "text", "text" => text }], ctx)
    end

    # A tool call and (unless pending) its result. pending: the call waits on
    # a permission prompt — the hook's PermissionRequest.
    def tool(at, name, input, ctx:, result: "ok", pending: false)
      use_id = "toolu_#{Digest::SHA1.hexdigest("#{@id}-#{@uses += 1}")[0, 24]}"
      assistant(at, [{ "type" => "tool_use", "id" => use_id, "name" => name, "input" => input }], ctx)
      return event(at + 1, "PermissionRequest", name) if pending

      line(at + 2, "user", { "role" => "user", "content" => [{ "type" => "tool_result", "tool_use_id" => use_id, "content" => result }] },
           "toolUseResult" => { "stdout" => result, "stderr" => "", "interrupted" => false })
      event(at + 2, "PostToolUse", name)
      use_id
    end

    # An Agent launched into the background (async_launched): the chat waits
    # on it after its Stop until a <task-notification> names it.
    def background_agent(at, agent_id, description, ctx:)
      use_id = "toolu_#{Digest::SHA1.hexdigest("#{@id}-#{@uses += 1}")[0, 24]}"
      assistant(at, [{ "type" => "tool_use", "id" => use_id, "name" => "Agent",
                       "input" => { "description" => description, "subagent_type" => "general-purpose", "run_in_background" => true } }], ctx)
      line(at + 1, "user", { "role" => "user", "content" => [{ "type" => "tool_result", "tool_use_id" => use_id, "content" => "Async agent launched" }] },
           "toolUseResult" => { "status" => "async_launched", "agentId" => agent_id, "description" => description })
      event(at + 1, "PostToolUse", "Agent")
    end

    # n tool calls spread from `from` to `to` while the context grows from
    # ctx.first to ctx.last — the reading, editing and test runs a real
    # turn is mostly made of (and what its usage is mostly made of).
    def work(from, to, n, ctx:, files:)
      step = (to - from) / n
      n.times do |i|
        at = from + (i * step)
        size = ctx.first + ((ctx.last - ctx.first) * i / n)
        file = files[i % files.size]
        case i % 4
        when 0, 1 then tool(at, "Read", { "file_path" => file }, ctx: size)
        when 2 then tool(at, "Edit", { "file_path" => file }, ctx: size)
        else tool(at, "Bash", { "command" => "bin/rails test #{file.sub(%r{.*/app/}, "test/").sub(".rb", "_test.rb")}" }, ctx: size)
        end
      end
    end

    def stop(at) = event(at, "Stop")

    # Esc: Claude Code writes the interrupt into the transcript; no hook fires.
    def interrupt(at) = user(at, "[Request interrupted by user]")

    def write(dir)
      path = File.join(dir, "#{@id}.jsonl")
      FileUtils.mkdir_p(dir)
      File.write(path, @lines.map { |l| JSON.generate(l) }.join("\n") + "\n")
      File.utime(@last_at, @last_at, path) if @last_at
      path
    end

    # The directory Claude Code files a cwd's transcripts under.
    def self.project_dir(cwd) = cwd.gsub(/[^a-zA-Z0-9]/, "-")

    private

    def user(at, text)
      line(at, "user", { "role" => "user", "content" => text })
    end

    def assistant(at, content, ctx)
      @messages += 1
      created = [ctx / 40, 1500].max
      usage = { "input_tokens" => 6, "cache_read_input_tokens" => ctx - created - 6, "cache_creation_input_tokens" => created,
                "cache_creation" => { "ephemeral_1h_input_tokens" => created, "ephemeral_5m_input_tokens" => 0 },
                "output_tokens" => 180 + ((@messages * 137) % 900) }
      line(at, "assistant", { "id" => "msg_#{Digest::SHA1.hexdigest("#{@id}-m#{@messages}")[0, 24]}", "type" => "message",
                              "role" => "assistant", "model" => @model, "content" => content, "usage" => usage })
    end

    def line(at, type, message, extra = {})
      uuid = Cast.uuid("#{@id}-#{@lines.size}")
      @lines << { "parentUuid" => @parent, "isSidechain" => @sidechain, "userType" => "external", "cwd" => @cwd,
                  "sessionId" => @id, "version" => "2.4.1", "gitBranch" => @branch.to_s, "type" => type,
                  "message" => message, "uuid" => uuid, "timestamp" => stamp(at) }.merge(extra)
      @parent = uuid
      @last_at = at
    end

    def event(at, name, tool = "")
      @events << { "v" => 1, "ts" => at.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "session_id" => @id, "event" => name,
                   "tool" => tool.to_s, "agent" => "" }
      @last_at = at if @last_at.nil? || at > @last_at
    end

    def stamp(at) = at.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
  end
end
