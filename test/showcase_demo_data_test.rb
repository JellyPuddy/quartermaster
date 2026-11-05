# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/showcase_demo_data_test.rb`).
# The full demo world, every seeding step included: the data each story of
# the showcase needs is there, consistent, and stays inside the world.
require_relative "test_helper"
require "etc"
require_relative "../showcase/demo-world/lib/demo_world"

class ShowcaseDemoDataTest < Minitest::Test
  # One full seed for the whole class (a few seconds: git, tmux, qm children).
  def self.world
    @world ||= begin
      root = File.join(Dir.mktmpdir("qm-demo-data"), "world")
      world = DemoWorld::World.new(root, tmux_socket: "qm-test-demo-#{Process.pid}")
      Minitest.after_run do
        system("tmux", "-L", world.tmux_socket, "kill-server", out: File::NULL, err: File::NULL)
        FileUtils.rm_rf(File.dirname(root))
      end
      DemoWorld.seed(root, tmux_socket: world.tmux_socket)
    end
  end

  def world = self.class.world
  def qm_file(name) = File.join(world.qm_root, name)
  def jsonl(name) = File.readlines(qm_file(name)).map { |line| JSON.parse(line) }
  def overview = @overview ||= JSON.parse(world.qm!("overview", "--json"))

  def test_work_items_cover_every_state_and_note_kind
    items = Dir[File.join(world.work_items_dir, "*.md")].map { |path| File.read(path) }
    states = items.map { |text| text[/^state: (\w+)/, 1] }.tally
    assert_equal({ "in_progress" => 5, "fridge" => 2, "resolved" => 1 }, states)
    notes = items.flat_map { |text| text.scan(/^- \d{4}-\d{2}-\d{2}(?: \[(\w+)\])?: /).flatten }
    assert_equal %w[decision history open], notes.map { |kind| kind || "decision" }.uniq.sort
    delivery = File.read(File.join(world.work_items_dir, "delivery-slots.md"))
    assert_match(/rotations:/, delivery)
    assert_match(/### \d{4}-\d{2}-\d{2} — session /, delivery)
    assert_match(%r{board: https://claude.ai/artifact/}, File.read(File.join(world.work_items_dir, "gift-cards.md")))
    assert_operator File.mtime(File.join(world.work_items_dir, "allergen-filter.md")), :<, world.now - (10 * 86_400), "an item must be stale"
  end

  def test_chats_show_every_attention_state_and_run_in_tmux
    chats = overview["items"].to_h { |item| [item["slug"], item["chat"]["state"]] }
    assert_equal({ "checkout-flow" => "blocked", "gift-cards" => "your_turn", "delivery-slots" => "working",
                   "button-variants" => "waiting" }, chats.reject { |_, state| state == "none" })
    panes = world.run!("tmux", "-L", world.tmux_socket, "list-sessions", "-F", '#{session_name}').split("\n")
    assert_equal %w[button-variants checkout-flow delivery-slots delivery-slots--aside gift-cards], panes.sort
    assert_equal({ "blocked" => 1, "your_turn" => 1, "working" => 1, "waiting" => 1, "none" => 3 }, overview["counts"]["chats"])
  end

  def test_sessions_have_transcripts_an_inbox_an_aside_and_an_expired_one
    starts = jsonl("sessions.jsonl").select { |e| e["event"] == "start" }
    assert_equal world.cast.sessions.map(&:id).sort, starts.map { |e| e["session_id"] }.sort
    assert(starts.any? { |e| e["aside"] == "delivery-slots" })
    claimed = Dir[File.join(world.work_items_dir, "*.md")].flat_map { |path| File.read(path).scan(/- id: (\S+)/).flatten }
    inbox = starts.reject { |e| e["aside"] || e["work_item"] || claimed.include?(e["session_id"]) }
    assert_equal 2, inbox.size
    transcripts = Dir[File.join(world.transcripts_dir, "*", "*.jsonl")].map { |path| File.basename(path, ".jsonl") }
    assert_equal [world.cast["af1"].id], world.cast.sessions.map(&:id) - transcripts, "only af1's transcript is pruned"
    assert(JSON.parse(File.read(qm_file("usage-cache.json")))["sessions"].key?(world.cast["af1"].id), "the ledger keeps the pruned session's tally")
  end

  def test_review_data_sits_on_lines_the_diff_shows
    drafts = JSON.parse(File.read(qm_file("drafts/gift-cards.json")))["entries"]
    assert_equal %w[annotation diff-comment github-comment thread-reply], drafts.map { |d| d["kind"] }.uniq.sort
    assert(drafts.any? { |d| d["author"] == "claude" }, "Claude's review draft is there")
    assert_equal 2, JSON.parse(File.read(qm_file("viewed/gift-cards.json")))["marks"].size
    snapshots = jsonl("prompt-snapshots.jsonl")
    assert_equal 2, snapshots.size
    snapshots.each { |s| assert_equal "tree", world.git!(s["toplevel"], "cat-file", "-t", s["tree"]).strip }
    status = world.git!(world.worktree("bakery-shop", "gift-cards"), "status", "--porcelain", "--untracked-files=all")
    assert_match(/^ M app\/models\/gift_card\.rb$/, status)
    assert_match(/^\?\? app\/javascript\/components\/GiftCardForm\.jsx$/, status)
  end

  def test_github_answers_every_call_from_fixtures_and_origin_lives_in_the_world
    unmatched = File.readlines(File.join(world.log_dir, "gh.jsonl")).map { |l| JSON.parse(l) }.select { |e| e["matched"].nil? }
    assert_empty unmatched.map { |e| e["argv"].join(" ") }
    assert_equal 8, JSON.parse(File.read(qm_file("pr-inbox.json")))["prs"].size
    assert_equal "MERGED", JSON.parse(File.read(qm_file("pr-cache.json")))["Bakery webshop#fix/cart-rounding"]["state"]
    verdicts = JSON.parse(File.read(qm_file("pr-deployment.json")))["verdicts"].values.map { |v| v["deployed"] }
    assert_equal [false, true], verdicts.sort_by { |v| v ? 1 : 0 }
    shop = world.repo("bakery-shop")
    heads = world.run!("git", "ls-remote", "origin", "refs/pull/38/head", chdir: shop)
    assert_match(%r{refs/pull/38/head}, heads)
    _out, err, status = Open3.capture3(world.env, "git", "ls-remote", "https://github.com/rails/rails", unsetenv_others: true)
    refute status.success?
    assert_match(/not allowed/, err)
  end

  def test_issues_side_panel_and_phone_page
    issues = Dir[File.join(world.qm_root, "issues", "*", "*.md")].map { |path| File.basename(path) }
    assert_equal 4, issues.size
    assert File.exist?(File.join(world.qm_root, "issues", "allergen-filter", ".prev", "02-allergen-checkboxes.md.json"))
    assert_equal 42, JSON.parse(File.read(qm_file("rate-limits.json")))["five_hour"]["used_percentage"]
    assert_operator File.readlines(qm_file("board-writes.jsonl")).size, :>=, 5
    page = File.read(File.join(world.root, "phone", "index.html"))
    assert_includes page, "window.claude = { use:"
    assert_includes page, "Gift cards: buy, email and redeem at checkout"
  end

  def test_nothing_points_outside_the_world_or_at_live_state
    real_claude = File.join(Etc.getpwuid.dir, ".claude")
    Dir[File.join(world.qm_root, "**", "*")].select { |path| File.file?(path) }.each do |path|
      refute_includes File.read(path), real_claude, "#{path} mentions the user's live ~/.claude"
    end
    jsonl("sessions.jsonl").select { |e| e["event"] == "start" }.each do |event|
      assert event["cwd"].start_with?(world.root), event["cwd"]
      assert event["transcript_path"].start_with?(world.transcripts_dir), event["transcript_path"]
    end
    refute_equal DemoWorld::World.socket_for(File.expand_path(DemoWorld::DEFAULT_ROOT)), world.tmux_socket
  end
end
