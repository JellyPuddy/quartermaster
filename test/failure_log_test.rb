# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/failure_log_test.rb`).
require_relative "test_helper"

# qm.log's line format: one header per failure, two-space-indented lib/
# frames under it, a success-reporting context's transient failures once per
# outage.
class FailureLogTest < Minitest::Test
  include QmTestHelpers

  REPO = File.expand_path("..", __dir__)
  OFFLINE = 'gh api graphql failed: Post "https://api.github.com/graphql": read tcp 10.0.0.2:5000->10.0.0.9:443: read: connection reset by peer'

  # A socket asking for a page that 404s; a closed one fails the write as a
  # tab closed mid-response does.
  def browser_client(closed:)
    reads = ["GET /nope HTTP/1.1\r\n", "Host: 127.0.0.1:4567\r\n", "\r\n"]
    client = Object.new
    client.define_singleton_method(:gets) { reads.shift }
    client.define_singleton_method(:write) { |*| closed ? raise(Errno::EPIPE) : nil }
    client.define_singleton_method(:close) { nil }
    client
  end

  def log_lines = File.readlines(Quartermaster::LOG_FILE, chomp: true)

  def headers = log_lines.reject { |line| line.start_with?(" ") }

  def error(klass, message, backtrace = nil)
    e = klass.new(message)
    e.set_backtrace(backtrace) if backtrace
    e
  end

  def test_a_failure_logs_its_header_and_up_to_three_lib_frames_relative_to_the_repo
    trace = ["/usr/lib/ruby/3.4.0/json/common.rb:10:in 'parse'",
             "#{REPO}/lib/quartermaster/gh_stack.rb:95:in 'sync'",
             "#{REPO}/lib/quartermaster/gui_state.rb:40:in 'build'",
             "#{REPO}/quartermaster:12:in '<main>'",
             "#{REPO}/lib/quartermaster/gui.rb:200:in 'serve'",
             "#{REPO}/lib/quartermaster/gui.rb:180:in 'block in start'"]
    Quartermaster.log_error("gh-stack-sync", error(TypeError, "no implicit conversion of Hash into String", trace))

    header, *frames = log_lines
    assert_match(/\A\S+ \[gh-stack-sync\] TypeError: no implicit conversion of Hash into String\z/, header)
    assert_equal ["  lib/quartermaster/gh_stack.rb:95:in 'sync'",
                  "  lib/quartermaster/gui_state.rb:40:in 'build'",
                  "  lib/quartermaster/gui.rb:200:in 'serve'"], frames
  end

  def test_an_error_without_a_backtrace_logs_its_header_alone
    Quartermaster.log_error("overview-config", error(ArgumentError, "bad"))

    assert_equal 1, log_lines.size
  end

  def test_a_multi_line_message_stays_on_the_header_line
    Quartermaster.log_error("pr-deployment", error(RuntimeError, "gh pr view failed: boom\ncheck this\n"))

    assert_equal 1, log_lines.size
    assert_match(/\] RuntimeError: gh pr view failed: boom check this\z/, log_lines.first)
  end

  def test_a_transient_failure_is_logged_once_per_outage_and_its_end_once
    3.times { Quartermaster.log_error("pr-inbox", error(RuntimeError, OFFLINE)) }
    Quartermaster.log_success("pr-inbox")
    Quartermaster.log_success("pr-inbox")
    Quartermaster.log_error("pr-inbox", error(RuntimeError, OFFLINE))

    lines = log_lines
    assert_equal 3, lines.size
    assert_match(/\A\S+ \[pr-inbox\] transient RuntimeError: gh api graphql failed/, lines[0])
    assert_match(/\A\S+ \[pr-inbox\] recovered after 3 failures\z/, lines[1])
    assert_match(/\] transient RuntimeError/, lines[2])
  end

  def test_a_context_that_never_reports_success_logs_every_transient_failure
    3.times { Quartermaster.log_error("gui-prs", error(RuntimeError, OFFLINE)) }
    Quartermaster.log_success("gui-prs")

    assert_equal 3, log_lines.size
    log_lines.each { |line| assert_match(/\A\S+ \[gui-prs\] transient RuntimeError: gh api graphql failed/, line) }
  end

  def test_the_success_reporting_contexts_are_exactly_those_with_a_log_success_call_site
    calls = Dir[File.join(REPO, "lib", "**", "*.rb")].flat_map { |path| File.read(path).scan(/log_success\((.*?)\)/).flatten }
    literal = calls.filter_map { |arg| arg[/\A"([^"]+)"\z/, 1] }

    assert_equal ["context"], calls - calls.grep(/\A"/), "log_success takes a literal context outside its definition"
    assert_equal Quartermaster::FailureLog::SUCCESS_REPORTING.sort, literal.uniq.sort
  end

  def test_a_single_failure_outage_recovers_in_the_singular
    Quartermaster.log_error("pr-inbox", error(RuntimeError, OFFLINE))
    Quartermaster.log_success("pr-inbox")

    assert_match(/\] recovered after 1 failure\z/, log_lines.last)
  end

  def test_success_without_an_outage_logs_nothing
    Quartermaster.log_success("pr-inbox")

    refute File.exist?(Quartermaster::LOG_FILE)
  end

  def test_outages_are_kept_per_context
    Quartermaster.log_error("pr-inbox", error(RuntimeError, OFFLINE))
    Quartermaster.log_error("pr-deployment", error(RuntimeError, OFFLINE))
    Quartermaster.log_success("pr-deployment")

    assert_equal 3, log_lines.size
    assert_match(/\[pr-deployment\] recovered/, log_lines.last)
  end

  def test_a_non_transient_failure_during_an_outage_is_logged_in_full
    Quartermaster.log_error("pr-inbox", error(RuntimeError, OFFLINE))
    Quartermaster.log_error("pr-inbox", error(TypeError, "no implicit conversion", ["#{REPO}/lib/quartermaster/pr_inbox.rb:1:in 'x'"]))
    Quartermaster.log_error("pr-inbox", error(TypeError, "no implicit conversion"))

    assert_equal 4, log_lines.size
    assert_match(/\] TypeError: no implicit conversion\z/, log_lines.last)
  end

  def test_network_failures_seen_from_gh_count_as_transient
    ["gh pr view failed: error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com",
     'gh api repos/acme/webshop/releases/latest failed: Get "https://api.github.com/x": dial tcp 10.0.0.9:443: i/o timeout',
     'gh api graphql failed: Post "https://api.github.com/graphql": net/http: TLS handshake timeout',
     'gh api graphql failed: read tcp 10.0.0.2:5000->10.0.0.9:443: read: operation timed out',
     'gh api graphql failed: Post "https://api.github.com/graphql": EOF'].each do |message|
      assert Quartermaster::FailureLog.transient?(error(RuntimeError, message)), message
    end
    refute Quartermaster::FailureLog.transient?(error(TypeError, "no implicit conversion of Hash into String"))
    refute Quartermaster::FailureLog.transient?(error(RuntimeError, "gh pr view failed: no pull requests found for branch \"x\""))
    refute Quartermaster::FailureLog.transient?(error(EOFError, "end of file reached"))
  end

  def test_a_browser_tab_closing_mid_write_is_transient
    assert Quartermaster::FailureLog.transient?(Errno::EPIPE.new)
    assert Quartermaster::FailureLog.transient?(Errno::ECONNRESET.new)
  end

  def test_the_pr_inbox_poller_reports_its_recovery
    calls = 0
    inbox = Quartermaster::PrInbox.new(fetcher: -> { (calls += 1) < 3 ? raise(OFFLINE) : [] })
    3.times { inbox.refresh }

    assert_equal 2, headers.size
    assert_match(/\[pr-inbox\] recovered after 2 failures\z/, headers.last)
  end

  def test_the_gui_serving_a_request_ends_a_client_disconnect_outage
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner)
    2.times { gui.send(:handle_client, browser_client(closed: true)) }
    gui.send(:handle_client, browser_client(closed: false))

    assert_equal 2, headers.size
    assert_match(/\[gui-client\] transient Errno::EPIPE/, headers.first)
    assert_match(/\[gui-client\] recovered after 2 failures\z/, headers.last)
  end
end
