# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/showcase_video_test.rb`).
# The showcase video's storyboard parsing and scene cache keys; needs no ffmpeg.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../showcase/video/storyboard"

class ShowcaseVideoTest < Minitest::Test
  STORYBOARD = File.expand_path("../showcase/video/storyboard.yml", __dir__)

  def setup
    @out = Dir.mktmpdir("qm-showcase-video")
    FileUtils.mkdir_p(File.join(@out, "shots"))
  end

  def teardown = FileUtils.rm_rf(@out)

  def board(data) = ShowcaseVideo::Storyboard.new(data, out_dir: @out)

  def scenes
    [
      { "id" => "intro", "style" => "title", "visual" => "shots/board.png", "caption" => "Hi", "voiceover" => "Hello." },
      { "id" => "board", "visual" => "shots/board.png", "focus" => [10, 20, 300, 200], "caption" => "The board" },
      { "id" => "seq", "visual" => [{ "file" => "shots/a.png", "duration" => 2 }, "shots/b.png"], "caption" => "Two", "duration" => 5 }
    ]
  end

  def keys(data) = board(data).scenes.to_h { |s| [s.id, s.cache_key] }

  def assert_invalid(data, message)
    error = assert_raises(ShowcaseVideo::Invalid) { board(data) }
    assert_includes error.message, message
  end

  def test_the_committed_storyboard_is_valid_and_has_an_intro_and_outro
    sb = ShowcaseVideo::Storyboard.load(STORYBOARD, out_dir: @out)
    assert_equal "intro", sb.scenes.first.id
    assert_equal "outro", sb.scenes.last.id
    assert_operator sb.scenes.size, :>=, 8
    sb.scenes.each { |s| s.frames.each { |f| assert_match(%r{\Ashots/[a-z0-9-]+\.png\z}, f.file) } }
  end

  def test_parses_settings_defaults_and_scene_fields
    sb = board("settings" => { "voice" => "Samantha", "caption" => { "size" => 50 } }, "scenes" => scenes)
    assert_equal "Samantha", sb.settings["voice"]
    assert_equal 1920, sb.settings["width"]
    assert_equal 50, sb.settings.dig("caption", "size")
    assert_equal "lower_third", sb.settings.dig("caption", "style")
    intro, focused, seq = sb.scenes
    assert_equal "title", intro.style
    assert_equal "lower_third", focused.style
    assert_equal [10, 20, 300, 200], focused.frames.first.focus
    assert_equal [2.0, nil], seq.frames.map(&:duration)
    assert_equal 5.0, seq.duration
    assert_equal %w[shots/a.png shots/b.png], seq.missing_visuals
    assert_same seq, sb.scene("seq")
  end

  def test_rejects_malformed_storyboards_with_every_problem_named
    assert_invalid({ "scenes" => [] }, "scenes must be a non-empty list")
    assert_invalid({ "scenes" => scenes + [scenes.first] }, "scene intro: duplicate id")
    assert_invalid({ "scenes" => [{ "id" => "Bad Id", "visual" => "shots/a.png", "caption" => "x" }] }, "lowercase slug")
    assert_invalid({ "scenes" => [{ "id" => "a", "visual" => "shots/a.png" }] }, "caption must be text")
    assert_invalid({ "scenes" => [{ "id" => "a", "visual" => "/etc/a.png", "caption" => "x" }] }, "relative to showcase/out")
    assert_invalid({ "scenes" => [{ "id" => "a", "visual" => "shots/a.png", "caption" => "x", "focus" => [1, 2, 0, 4] }] }, "focus must be")
    assert_invalid({ "scenes" => [{ "id" => "a", "visual" => "shots/a.png", "caption" => "x", "duraton" => 3 }] }, "unknown key duraton")
    assert_invalid({ "scenes" => [{ "id" => "a", "visual" => "shots/a.png", "caption" => "x", "style" => "big" }] }, "style must be")
    assert_invalid({ "settings" => { "fsp" => 30 }, "scenes" => scenes }, "settings: unknown key fsp")
    assert_invalid({ "settings" => { "caption" => "title" }, "scenes" => scenes }, "settings.caption must be a mapping")
    assert_invalid({ "settings" => { "voice" => 3 }, "scenes" => scenes }, "settings.voice must be a voice name")
    error = assert_raises(ShowcaseVideo::Invalid) { board("scenes" => [{ "id" => "a", "duration" => -1 }]) }
    assert_includes error.message, "caption must be text"
    assert_includes error.message, "duration must be a positive number"
    assert_includes error.message, "visual must be"
  end

  def test_a_scene_key_is_stable_across_loads_and_neighbours
    before = keys("scenes" => scenes)
    assert_equal before, keys("scenes" => scenes)
    assert_equal before, keys("scenes" => scenes.reverse), "order and neighbours are not a scene's inputs"
    assert_equal before.except("seq"), keys("scenes" => scenes.first(2))
  end

  def test_editing_one_scene_changes_only_its_key
    before = keys("scenes" => scenes)
    { "caption" => "New", "voiceover" => "Hi again.", "focus" => [0, 0, 5, 5], "duration" => 9, "style" => "title" }.each do |field, value|
      edited = scenes.tap { |s| s[1] = s[1].merge(field => value) }
      after = keys("scenes" => edited)
      refute_equal before["board"], after["board"], "#{field} is an input"
      assert_equal before.except("board"), after.except("board")
    end
  end

  def test_a_visual_file_changing_or_appearing_changes_the_key_of_scenes_that_show_it
    before = keys("scenes" => scenes)
    File.write(File.join(@out, "shots", "board.png"), "v1")
    v1 = keys("scenes" => scenes)
    refute_equal before["board"], v1["board"]
    refute_equal before["intro"], v1["intro"]
    assert_equal before["seq"], v1["seq"]
    File.write(File.join(@out, "shots", "board.png"), "v2")
    v2 = keys("scenes" => scenes)
    refute_equal v1["board"], v2["board"]
    assert_equal v1["seq"], v2["seq"]
    File.write(File.join(@out, "shots", "board.png"), "v1")
    assert_equal v1, keys("scenes" => scenes), "same bytes, same key"
  end

  def test_scene_settings_change_every_key_but_stitch_settings_change_none
    before = keys("scenes" => scenes)
    voiced = keys("settings" => { "voice" => "Samantha" }, "scenes" => scenes)
    before.each_key { |id| refute_equal before[id], voiced[id] }
    restyled = keys("settings" => { "caption" => { "bar" => "#000000" } }, "scenes" => scenes)
    before.each_key { |id| refute_equal before[id], restyled[id] }
    assert_equal before, keys("settings" => { "crossfade" => 1.2 }, "scenes" => scenes)
    assert_equal before, keys("settings" => { "voice" => "Daniel" }, "scenes" => scenes), "spelling out a default is no change"
  end
end
