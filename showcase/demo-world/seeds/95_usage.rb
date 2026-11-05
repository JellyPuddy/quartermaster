# frozen_string_literal: true

# usage-cache.json as qm's UsageLedger keeps it — a record that outlives the
# transcripts it tallied. Tallied while every transcript still exists; then
# af1's transcript goes, as Claude Code prunes one after cleanupPeriodDays:
# its session reads expired and only its snapshot and its tally remain.
DemoWorld.step("usage") do |world|
  world.qm_ruby!(<<~'RUBY')
    ledger = Quartermaster::UsageLedger.new
    Quartermaster::SessionLog.new.sessions.each { |session| ledger.session_usage(session) }
    ledger.save
  RUBY
  expired = world.cast["af1"]
  FileUtils.rm_f(File.join(world.transcripts_dir, DemoWorld::Transcript.project_dir(expired.cwd), "#{expired.id}.jsonl"))
end
