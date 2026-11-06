# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/pr_review_start_test.rb`).
require_relative "test_helper"

# The Review service without a GUI: what the pr-review automation flow calls.
# tmux is a FakeTmux; the PR is a hash, as the inbox cache holds it.
class PrReviewStartTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers

  URL = "https://github.com/acme/WebApp/pull/42"
  PR = { "url" => URL, "number" => 42, "title" => "Add the thing", "repo" => "acme/WebApp",
         "author" => "someone", "head" => "feature-x", "base" => "main" }.freeze

  def with_project
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      system("git", "-C", repo, "remote", "add", "origin", "git@github.com:acme/WebApp.git")
      configure_projects({ "WebApp" => featured_project(repo) })
      yield repo
    end
  end

  def service(tmux) = Quartermaster::PrReviewStart.new(tmux: tmux, pr_items: Quartermaster::PrItems.new)

  def test_start_puts_extra_argv_before_the_kickoff_and_appends_the_suffix
    with_project do |repo|
      tmux = FakeTmux.new

      reply = service(tmux).start(PR, extra_argv: ["--session-id", "abc", "--model", "opus"],
                                      kickoff_suffix: "Focus on the migrations.")

      assert_equal "review-webapp-42-add-the-thing", reply["slug"]
      assert_equal "start", reply["mode"]
      opened = tmux.opened.first
      assert_equal reply["slug"], opened[:name]
      assert_equal ["--session-id", "abc", "--model", "opus"], opened[:argv][-5..-2]
      skill, instruction, suffix = opened[:argv].last.split("\n\n")
      assert_equal "/review-app-pr #{URL}", skill
      assert_includes instruction, "qm draft add #{reply["slug"]}"
      assert_equal "Focus on the migrations.", suffix
      assert_equal({ "QM_ITEM" => reply["slug"] }, opened[:env])
      assert_equal repo, File.realpath(opened[:cwd])
    end
  end

  def test_a_blank_suffix_leaves_the_kickoff_as_the_review_button_sends_it
    with_project do
      tmux = FakeTmux.new

      service(tmux).start(PR, kickoff_suffix: "  ")

      assert_equal 2, tmux.opened.first[:argv].last.split("\n\n").size
    end
  end

  def test_live_reports_the_review_chat_without_starting_or_creating_anything
    with_project do
      tmux = FakeTmux.new
      refute service(tmux).live?(PR)
      assert_empty Quartermaster::WorkItem.all, "asking must not create the Review item"

      slug = service(tmux).item_for(PR).slug
      refute service(tmux).live?(PR)
      assert service(FakeTmux.new([slug])).live?(PR), "a live pane is a live chat"
      assert_empty tmux.opened
    end
  end

  def test_a_session_running_outside_a_pane_is_live_and_refuses_a_start
    with_project do
      item = service(FakeTmux.new).item_for(PR)
      item.attach_session("s-outside")
      Quartermaster::SessionLog.new.append("event" => "start", "session_id" => "s-outside", "cwd" => "/",
                                           "pid" => Process.pid, "ts" => Time.now.iso8601)
      tmux = FakeTmux.new

      assert service(tmux).live?(PR)
      error = assert_raises(ArgumentError) { service(tmux).start(PR) }
      assert_includes error.message, "has a chat running outside the GUI"
      assert_empty tmux.opened
    end
  end

  def test_a_live_pane_is_attached_not_restarted
    with_project do
      slug = service(FakeTmux.new).item_for(PR).slug
      tmux = FakeTmux.new([slug])

      assert_equal({ "slug" => slug, "attached" => true }, service(tmux).start(PR, extra_argv: ["--session-id", "x"]))
      assert_empty tmux.opened
    end
  end
end
