# frozen_string_literal: true

# The chat side panel and header: the usage-limits chip (rate-limits.json as
# the status line writes it), the gift-cards status board (board-writes.jsonl
# as the ArtifactData hook appends it, one blocked row with an answer box)
# and a Workflow run still going in the live gift-cards chat, so "Check build
# progress" has agents to estimate (the stub claude answers for the model).
module DemoWorld
  module SidePanel
    RUN_ID = "wf_7c1e9a42"
    TASKS = [
      ["pdf-email", "PDF gift card email", "done", "Mailer + GiftCardPdf, 3 tests", 1],
      ["expiry", "Cards expire after a year", "review", "expires_at + redeem! guard; migration added", 2],
      ["balance-page", "Balance on the account page", "running", "account/gift_cards#show, Turbo Frame", 3],
      ["vat", "VAT on gift cards", "blocked", "Taxed at purchase or at redemption? Finance decides.", 4],
      ["zero-payment", "Skip Mollie for fully covered orders", "queued", "", 5]
    ].freeze
    AGENTS = { "balance-page" => ["a91c0e7d2b", "build:balance-page"], "expiry" => ["a4be81f05c", "review:expiry"] }.freeze

    def self.rate_limits(world)
      now = world.now.to_i
      { "v" => 1, "five_hour" => { "used_percentage" => 42, "resets_at" => now + (2 * 3600) + (15 * 60) },
        "seven_day" => { "used_percentage" => 61, "resets_at" => now + (3 * 86_400) + (4 * 3600) }, "captured_at" => now - 60 }
    end

    def self.board_writes(world)
      url = WorkItems::BOARD
      batch = (world.now - 3 * 3600).utc.strftime("%Y-%m-%dT%H:%M")
      writes = TASKS.each_with_index.map do |(id, title, status, note, order), i|
        at = world.now - ((90 - (i * 12)) * 60)
        board_line(at, url, "set", id, { "status" => "queued", "title" => title, "note" => "", "batch" => batch,
                                         "batchLabel" => "Gift cards", "order" => order, "dependsOn" => order > 3 ? ["expiry"] : [] })
      end
      writes + TASKS.each_with_index.filter_map do |(id, _title, status, note, _order), i|
        next if status == "queued"

        board_line(world.now - ((40 - (i * 7)) * 60), url, "update", id, { "status" => status, "note" => note,
                                                                         "updatedAt" => world.now.utc.iso8601 })
      end
    end

    def self.board_line(at, url, action, doc_id, data)
      { "v" => 1, "ts" => at.utc.iso8601,
        "payload" => { "session_id" => "", "hook_event_name" => "PostToolUse", "tool_name" => "ArtifactData",
                       "tool_input" => { "action" => action, "url" => url, "collection" => "tasks", "doc_id" => doc_id, "data" => data },
                       "tool_response" => "Database #{action} committed: \"tasks\"/\"#{doc_id}\"." } }
    end

    # A Workflow run in the live gift-cards session: journal + one transcript per agent.
    def self.workflow(world)
      session = world.cast["gc2"]
      dir = File.join(world.transcripts_dir, Transcript.project_dir(session.cwd), session.id, "subagents", "workflows", RUN_ID)
      FileUtils.mkdir_p(dir)
      journal = AGENTS.map do |key, (agent_id, label)|
        { "type" => "started", "key" => key, "agentId" => agent_id, "label" => label, "phase" => label.split(":").first,
          "ts" => (world.now - 1500).utc.iso8601 }
      end
      world.append_jsonl(File.join(dir, "journal.jsonl"), journal)
      AGENTS.each do |key, (agent_id, label)|
        t = Transcript.new(id: session.id, cwd: session.cwd, branch: session.branch, sidechain: true)
        start = world.now - 1500
        t.prompt(start, "You are the builder of task \"#{key}\" (#{label}). Build it on feature/gift-cards and hand back a verdict.")
        12.times { |i| t.tool(start + 60 + (i * 90), %w[Read Edit Bash].fetch(i % 3), { "file_path" => "app/models/gift_card.rb" }, ctx: 30_000 + (i * 6000)) }
        t.say(start + 1200, "Balance page renders; writing the system test next.", ctx: 104_000)
        File.write(File.join(dir, "agent-#{agent_id}.jsonl"), t.lines.map { |l| JSON.generate(l) }.join("\n") + "\n")
        world.write_json(File.join(dir, "agent-#{agent_id}.meta.json"), { "description" => label })
      end
      world.write_json(File.join(world.claude_fixtures_dir, "structured.json"), { "structured_output" => { "agents" => [
        { "label" => "build:balance-page", "percent" => 60, "doing" => "Balance page renders; writing its system test" },
        { "label" => "review:expiry", "percent" => 35, "doing" => "Checking the expiry guard against time zones" }
      ] } })
    end
  end
end

DemoWorld.step("side-panel") do |world|
  side = DemoWorld::SidePanel
  world.write_json(File.join(world.qm_root, "rate-limits.json"), side.rate_limits(world))
  world.append_jsonl(File.join(world.qm_root, "board-writes.jsonl"), side.board_writes(world))
  FileUtils.mkdir_p(File.join(world.root, "board-answers"))
  side.workflow(world)
end
