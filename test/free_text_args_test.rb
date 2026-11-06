# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/free_text_args_test.rb`).
require_relative "test_helper"

# Free text that starts with a dash is text, `--` ends options, and a bad
# option is a one-line `qm:` error, never a backtrace.
class FreeTextArgsTest < Minitest::Test
  include QmTestHelpers

  def qm(*args)
    Open3.capture3({ "QM_ROOT" => Quartermaster::ROOT, "QM_ITEM" => nil, "QM_ASIDE" => nil, "QM_LOOSE" => nil },
                   RbConfig.ruby, QM_BIN, *args, stdin_data: "")
  end

  def cli(*args)
    capture_io { Quartermaster::CLI.new.run(args) }
  end

  def test_new_takes_a_dash_leading_title
    out, = cli("new", "- dash start")

    assert_equal "dash-start\n", out
    assert_equal "- dash start", Quartermaster::WorkItem.find("dash-start").title
  end

  def test_new_keeps_its_flags_around_dash_leading_text
    cli("new", "--project=My App", "- dash start", "--session", "sess-1", "--description", "- a list")
    item = Quartermaster::WorkItem.find("dash-start")

    assert_equal ["- dash start", "My App", [{ "id" => "sess-1" }]], [item.title, item.project, item.sessions]
    assert_includes item.body, "- a list"
  end

  def test_dash_text_is_never_read_as_an_abbreviated_option
    out, = cli("new", "-d does stuff")
    Quartermaster::WorkItem.create("Target", project: "MyApp")
    cli("note", "target", "-k keeps going")

    assert_equal "d-does-stuff\n", out
    assert_equal "-d does stuff", Quartermaster::WorkItem.find("d-does-stuff").title
    assert_equal [["-k keeps going", Quartermaster::DEFAULT_NOTE_KIND]],
                 Quartermaster::WorkItem.find("target").notes.map { |n| [n.text, n.kind] }
  end

  def test_note_takes_a_dash_leading_text_and_keeps_kind
    Quartermaster::WorkItem.create("Target", project: "MyApp")
    cli("note", "target", "- a bullet")
    cli("note", "target", "--kind", "decision", "- chosen")
    notes = Quartermaster::WorkItem.find("target").notes

    assert_equal [["- chosen", "decision"], ["- a bullet", Quartermaster::DEFAULT_NOTE_KIND]],
                 notes.map { |n| [n.text, n.kind] }
  end

  def test_double_dash_ends_options
    Quartermaster::WorkItem.create("Target", project: "MyApp")
    cli("note", "target", "--", "--kind", "is", "text")
    cli("new", "--", "-x")
    cli("retitle", "target", "--", "-renamed")

    assert_equal "--kind is text", Quartermaster::WorkItem.find("target").notes.first.text
    assert_equal "-x", Quartermaster::WorkItem.find("x").title
    assert_equal "-renamed", Quartermaster::WorkItem.find("target").title
  end

  def test_describe_drops_the_double_dash
    Quartermaster::WorkItem.create("Target", project: "MyApp")
    cli("describe", "target", "--", "- first point")

    assert_includes Quartermaster::WorkItem.find("target").body, "- first point"
    refute_includes Quartermaster::WorkItem.find("target").body, "-- - first point"
  end

  def test_the_issue_reproductions_exit_cleanly
    _out, err, status = qm("new", "- dash start")
    assert status.success?, err

    _out, err, status = qm("note", "dash-start", "- a bullet")
    assert status.success?, err
  end

  def test_a_bad_flag_is_a_one_line_error
    _out, err, status = qm("new", "Title", "--bogus")

    assert_equal 1, status.exitstatus
    assert_equal "qm: invalid option: --bogus\n", err

    _out, err, status = qm("note", "some-slug", "text", "--kind")

    assert_equal 1, status.exitstatus
    assert_equal "qm: missing argument: --kind\n", err
  end
end
