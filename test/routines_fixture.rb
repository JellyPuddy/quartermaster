# frozen_string_literal: true

# The fixture routine and a stub routines API, shared by the automation CLI and GUI tests.
require_relative "test_helper"

module RoutinesFixture
  DIGEST = JSON.parse(File.read(File.join(__dir__, "fixtures", "routines-list-response.json")))["data"].first
  ID = DIGEST["id"]
  DEFAULT_MODEL = "claude-default-model"

  # The routines API as a hash of routines: records every call, applies
  # creates and updates the way the API would (via the real request body)
  # and stamps a new updated_at on each write.
  class StubClient
    attr_reader :calls, :routines
    attr_accessor :fail_with, :delete_answer

    def initialize(*routines)
      @routines = routines.to_h { |r| [r["id"], JSON.parse(JSON.generate(r))] }
      @calls = []
      @stamp = 0
      @delete_answer = :unsupported
    end

    def list
      record(:list)
      @routines.values.map { |r| copy(r) }
    end

    def get(id)
      record(:get, id)
      copy(routine!(id))
    end

    # Like the API, a created routine is enabled and gets a model unless the
    # body names them.
    def create(fields)
      record(:create, fields)
      body = Quartermaster::RoutinesClient.request_body(fields)
      context = body.dig("job_config", "ccr", "session_context")
      context["model"] ||= DEFAULT_MODEL if context
      apply({ "id" => "trig_NEW", "enabled" => true }, body)
    end

    def update(id, fields)
      record(:update, id, fields)
      apply(routine!(id), Quartermaster::RoutinesClient.request_body(fields))
    end

    def run(id)
      record(:run, id)
      { "session_id" => "cse_RUN" }
    end

    def runs(id, limit:)
      record(:runs, id, limit)
      [{ "id" => "cse_1", "title" => "Digest run", "status" => "completed", "created_at" => "2026-11-05T07:10:10Z",
         "updated_at" => nil, "url" => "https://claude.ai/code/cse_1" }]
    end

    def delete(id)
      record(:delete, id)
      @routines.delete(id) if @delete_answer == :deleted
      @delete_answer
    end

    def touch(id) = @routines[id]["updated_at"] = "2026-11-06T10:00:00Z"

    private

    def routine!(id) = @routines.fetch(id) { raise Quartermaster::RoutinesClient::RoutineMissing, id }

    def record(*call)
      raise fail_with if fail_with

      @calls << call
    end

    def apply(routine, body)
      routine = routine.merge(body.except("clear_mcp_connections")).merge("updated_at" => "2026-11-06T09:00:0#{@stamp += 1}Z")
      @routines[routine["id"]] = routine
      copy(routine)
    end

    def copy(routine) = JSON.parse(JSON.generate(routine))
  end
end
