# frozen_string_literal: true

# Transcript, session and tmux stand-ins shared by the history, rotation and finish tests.
require_relative "test_helper"

module HistoryHelpers
  def at(ago) = (Time.now - ago).utc.iso8601

  def said(ago, text) = { "type" => "user", "timestamp" => at(ago), "message" => { "role" => "user", "content" => text } }

  def replied(ago, id, *blocks)
    { "type" => "assistant", "timestamp" => at(ago),
      "message" => { "id" => id, "role" => "assistant", "model" => "claude-opus", "content" => blocks } }
  end

  def text_block(t) = { "type" => "text", "text" => t }
  def tool_block(name, input) = { "type" => "tool_use", "id" => "tu-#{rand(1_000_000)}", "name" => name, "input" => input }

  def tool_result(ago)
    { "type" => "user", "timestamp" => at(ago), "toolUseResult" => { "stdout" => "x" },
      "message" => { "role" => "user", "content" => [{ "type" => "tool_result", "tool_use_id" => "tu", "content" => "x" }] } }
  end

  def log_session(id, ago:, transcript: nil, ended: true, pid: 999_999_999)
    log = Quartermaster::SessionLog.new
    log.append("event" => "start", "session_id" => id, "cwd" => "/", "transcript_path" => transcript,
               "pid" => pid, "ts" => (Time.now - ago).iso8601)
    log.append("event" => "end", "session_id" => id, "ts" => (Time.now - ago + 60).iso8601) if ended
  end

  def item_with_sessions(title, *ids)
    item = Quartermaster::WorkItem.create(title, project: "No project")
    ids.each { |id| item.attach_session(id) }
    Quartermaster::WorkItem.find(item.slug)
  end
end

# A tmux stand-in that plays the chat: the wrap-up prompt makes "claude" add
# a note and end its turn, /exit kills the pane's program.
class RotationTmux < FakeTmux
  attr_reader :calls
  attr_accessor :on_submit

  def initialize(live = [])
    super
    @calls = []
    @typed = {}
    @dead = []
  end

  def send_text(name, text)
    @calls << [:send_text, name, text]
    @typed[name] = text
    live?(name)
  end

  def send_enter(name)
    @calls << [:send_enter, name]
    on_submit&.call(@typed.delete(name))
    live?(name)
  end

  def keep_on_exit(name, keep)
    @calls << [:keep_on_exit, name, keep]
    true
  end

  def die(name) = @dead << name
  def pane_dead?(name) = @dead.include?(name)

  def respawn(name, cwd:, argv:, env: {})
    @calls << [:respawn, name, env]
    @dead.delete(name)
    true
  end

  def open(name, cwd:, argv:, env: {})
    @calls << [:open, name, env]
    super
  end
end
