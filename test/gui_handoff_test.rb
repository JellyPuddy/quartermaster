# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/gui_handoff_test.rb`).
require_relative "test_helper"
require "socket"

# The CLI hands an action to the running GUI only when that GUI serves the
# CLI's own data root: GET /api/root answers a digest of its realpath'd root.
class GuiHandoffTest < Minitest::Test
  include QmTestHelpers

  # A Net::HTTP stand-in: answers GET /api/root with root_reply (a body
  # string) and records every POST, answering post_reply.
  class FakeHttp
    Response = Struct.new(:code, :body)
    attr_accessor :open_timeout, :read_timeout
    attr_reader :posts

    def initialize(root_reply, code: "200", post_reply: { "ok" => true })
      @root_reply = root_reply
      @code = code
      @post_reply = post_reply
      @posts = []
    end

    def get(path)
      raise "unexpected GET #{path}" unless path == "/api/root"

      Response.new(@code, @root_reply)
    end

    def post(path, body, _headers)
      @posts << [path, JSON.parse(body)]
      Response.new("200", JSON.generate(@post_reply))
    end
  end

  # A free, closed port, so a hand-off that bypasses the stub finds no GUI
  # instead of the user's live one on the default port.
  def setup
    super
    @port = ENV["QM_GUI_PORT"]
    free = TCPServer.new("127.0.0.1", 0)
    ENV["QM_GUI_PORT"] = free.addr[1].to_s
    free.close
  end

  def teardown
    @port ? ENV["QM_GUI_PORT"] = @port : ENV.delete("QM_GUI_PORT")
    super
  end

  def qm(http, *argv)
    exited = nil
    out, err = capture_io do
      Quartermaster::CLI.new(cwd: Dir.home, gui_http: ->(_port) { http }).run(argv)
    rescue SystemExit => e
      exited = e.status
    end
    [out, err, exited]
  end

  def own_root_reply
    Quartermaster.ensure_setup
    JSON.generate("root" => Digest::SHA256.hexdigest(File.realpath(Quartermaster::ROOT)))
  end

  def test_the_root_id_is_a_digest_of_the_realpath_never_the_path
    Dir.mktmpdir do |dir|
      real = File.join(dir, "real")
      Dir.mkdir(real)
      File.symlink(real, File.join(dir, "link"))

      assert_equal Digest::SHA256.hexdigest(File.realpath(real)), Quartermaster.root_id(real)
      assert_equal Quartermaster.root_id(real), Quartermaster.root_id(File.join(dir, "link"))
      refute_equal Quartermaster.root_id(real), Quartermaster.root_id(dir)
    end
  end

  def test_the_gui_answers_its_root_id_on_get_without_an_origin
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    status, type, body = gui.respond("GET", "/api/root", { "host" => "127.0.0.1:4567" }, "")

    assert_equal "200 OK", status
    assert_match %r{\Aapplication/json}, type
    assert_equal own_root_reply, body
  end

  def test_a_gui_on_this_root_gets_the_action
    http = FakeHttp.new(own_root_reply, post_reply: { "ok" => true, "caffeinate" => { "mode" => "off" } })
    out, err, exited = qm(http, "caffeinate", "off")

    assert_nil exited, err
    assert_equal "caffeinate off\n", out
    assert_equal [["/api/action", { "cmd" => "caffeinate", "args" => { "mode" => "off" } }]], http.posts
  end

  def test_a_gui_on_another_root_is_no_gui_and_gets_nothing
    http = FakeHttp.new(JSON.generate("root" => Digest::SHA256.hexdigest("/Users/someone/.claude/quartermaster")))
    _out, err, exited = qm(http, "caffeinate", "on")

    assert_equal 1, exited
    assert_match(/qm caffeinate: 127\.0\.0\.1:\d+ is not a qm gui on this data root .* nothing done/, err)
    assert_empty http.posts
  end

  def test_a_server_that_names_no_root_is_no_gui_and_an_optional_handoff_falls_back
    with_project_root do
      http = FakeHttp.new("not found", code: "404")
      out, err, exited = qm(http, "loose", "--project", "Widget", "Why is CI red?")

      assert_nil exited, err
      assert_includes out, "no qm gui running — start the loose chat with:"
      assert_empty http.posts
    end
  end

  def test_a_reply_without_a_root_field_is_no_gui
    http = FakeHttp.new(JSON.generate("ok" => true))
    _out, err, exited = qm(http, "caffeinate", "status")

    assert_equal 1, exited
    assert_includes err, "is not a qm gui on this data root"
    assert_empty http.posts
  end

  private

  def with_project_root
    Dir.mktmpdir do |dir|
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Widget" => File.realpath(dir) } }.to_yaml)
      yield
    end
  end
end
