# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/link_opener_test.rb`).
require_relative "test_helper"

# The installed app's outside links: the page POSTs `open-url` and the server
# hands the URL to macOS `open`, so it lands in the default browser.
class LinkOpenerTest < Minitest::Test
  include QmTestHelpers

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def post(server, url, headers = ok_host)
    server.respond("POST", "/api/action", headers, JSON.generate("cmd" => "open-url", "args" => { "url" => url }))
  end

  def test_an_http_or_https_link_runs_open_with_that_url
    runner = quiet_runner
    server = Quartermaster::Gui.new(port: 4567, runner: runner)

    %w[https://github.com/x/y/pull/1 http://example.com/a?b=c].each do |url|
      assert_equal true, JSON.parse(post(server, url)[2])["ok"], url
    end
    assert_equal [%w[open https://github.com/x/y/pull/1], %w[open http://example.com/a?b=c]],
                 runner.argvs.select { |argv| argv.first == "open" }
  end

  def test_any_other_scheme_is_refused_and_nothing_runs
    runner = quiet_runner
    server = Quartermaster::Gui.new(port: 4567, runner: runner)

    ["file:///etc/passwd", "javascript:alert(1)", "vscode://file/x", "ssh://host", "-a Calculator",
     "https://", "", nil].each do |url|
      reply = JSON.parse(post(server, url)[2])
      assert_equal false, reply["ok"], url.inspect
      assert_match(/http/, reply["error"], url.inspect)
    end
    assert_empty runner.argvs.select { |argv| argv.first == "open" }
  end

  def test_a_foreign_origin_or_no_origin_is_refused_before_anything_runs
    runner = quiet_runner
    server = Quartermaster::Gui.new(port: 4567, runner: runner)

    assert_equal "403 Forbidden", post(server, "https://x.test", ok_host.merge("origin" => "https://evil.example.com"))[0]
    assert_equal "403 Forbidden", post(server, "https://x.test", { "host" => "127.0.0.1:4567" })[0]
    assert_empty runner.argvs.select { |argv| argv.first == "open" }
  end

  def test_a_failing_open_is_an_error_reply
    runner = FakeRunner.new(["open"] => ["", "no application", false])
    server = Quartermaster::Gui.new(port: 4567, runner: runner)

    reply = JSON.parse(post(server, "https://x.test")[2])
    assert_equal false, reply["ok"]
    assert_match(/no application/, reply["error"])
  end

  def test_the_page_loads_the_outside_link_handler
    page = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner), ok_host)
    assert page.include?("display-mode: standalone"), "the page checks it runs as the installed app"
    assert page.include?("\"open-url\""), "the page posts outside links to open-url"
  end
end
