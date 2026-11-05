# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/showcase_shots_test.rb`).
# The showcase screenshot list's parsing and the CDP client's WebSocket framing; needs no Chrome.
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../showcase/shots/shot_list"
require_relative "../showcase/shots/cdp"
require_relative "../showcase/video/storyboard"

class ShowcaseShotsTest < Minitest::Test
  SHOTS = File.expand_path("../showcase/shots/shots.yml", __dir__)
  STORYBOARD = File.expand_path("../showcase/video/storyboard.yml", __dir__)
  Frame = ShowcaseShots::Frame

  def list(*shots) = ShowcaseShots::ShotList.new("shots" => shots)
  def shot(fields) = list({ "id" => "s" }.merge(fields)).shots.first

  def assert_invalid(message, &block)
    error = assert_raises(ShowcaseShots::Invalid, &block)
    assert_includes error.message, message
  end

  def test_the_committed_shot_list_is_valid_and_covers_every_storyboard_shot
    shots = ShowcaseShots::ShotList.load(SHOTS).shots.map(&:id)
    Dir.mktmpdir do |out|
      wanted = ShowcaseVideo::Storyboard.load(STORYBOARD, out_dir: out).scenes
                                        .flat_map { |s| s.frames.map(&:file) }
                                        .map { |f| f[%r{\Ashots/(.+)\.png\z}, 1] }.uniq
      refute_includes wanted, nil, "every storyboard visual is a shot under shots/"
      assert_empty wanted - shots, "storyboard shots missing from shots.yml"
    end
  end

  def test_defaults_fill_url_viewport_scale_and_mobile
    s = shot({})
    assert_equal "http://127.0.0.1:7788/", s.url(gui: "http://127.0.0.1:7788", world: "/w")
    assert_equal [1920, 1080], s.viewport
    assert_equal 2, s.scale
    refute s.mobile
    assert_nil s.theme
    assert_nil s.clip
    assert_equal "s.png", s.file_name
  end

  def test_url_placeholders_and_a_narrow_viewport_is_mobile
    s = shot("url" => "{world}/phone/index.html", "viewport" => "390x844")
    assert_equal "file:///tmp/w/phone/index.html", s.url(gui: "http://x", world: "/tmp/w")
    assert_equal [390, 844], s.viewport
    assert s.mobile
    refute shot("viewport" => [390, 844], "mobile" => false).mobile
  end

  def test_steps_parse_and_nested_lists_flatten
    common = [{ "wait_for" => ".card" }, { "key" => %w[j j] }]
    s = shot("steps" => [common, { "eval" => "1" }, { "click" => "#x" }, { "hover" => ".h" }, { "wait" => 0.5 }])
    assert_equal %w[wait_for key eval click hover wait], s.steps.map(&:kind)
    assert_equal %w[j j], s.steps[1].arg
  end

  def test_the_yaml_aliases_in_the_shot_list_load
    Dir.mktmpdir do |dir|
      path = File.join(dir, "shots.yml")
      File.write(path, <<~YAML)
        shots:
          - id: a
            steps:
              - &open
                - wait_for: ".card"
                - key: d
          - id: b
            steps:
              - *open
              - wait: 1
      YAML
      assert_equal %w[wait_for key wait], ShowcaseShots::ShotList.load(path).find("b").steps.map(&:kind)
    end
  end

  def test_clip_takes_a_selector_a_padded_selector_or_a_rect
    assert_equal ".x", shot("clip" => ".x").clip.selector
    assert_equal 8, shot("clip" => { "selector" => ".x", "pad" => 8 }).clip.pad
    assert_equal [1, 2, 3, 4], shot("clip" => [1, 2, 3, 4]).clip.rect
    assert_invalid("clip rect") { shot("clip" => [1, 2, 0, 4]) }
    assert_invalid("clip takes") { shot("clip" => { "selector" => ".x", "margin" => 1 }) }
  end

  def test_validation_names_the_shot_and_the_problem
    assert_invalid("unknown keys focus") { shot("focus" => [1, 2, 3, 4]) }
    assert_invalid("lowercase slug") { list({ "id" => "Board" }) }
    assert_invalid("viewport") { shot("viewport" => "big") }
    assert_invalid("scale") { shot("scale" => 9) }
    assert_invalid("theme") { shot("theme" => "sepia") }
    assert_invalid("unknown step \"type\"") { shot("steps" => [{ "type" => "x" }]) }
    assert_invalid("bad wait") { shot("steps" => [{ "wait" => "soon" }]) }
    assert_invalid("bad key") { shot("steps" => [{ "key" => %w[j Esc] }]) }
    assert_invalid("bad click") { shot("steps" => [{ "click" => " " }]) }
    assert_invalid("one of") { shot("steps" => [{ "key" => "a", "wait" => 1 }]) }
    assert_invalid("duplicate shot ids: a") { list({ "id" => "a" }, { "id" => "a" }) }
    assert_invalid("`shots` list") { ShowcaseShots::ShotList.new({}) }
    assert_invalid("no shot \"nope\"") { list({ "id" => "a" }).find("nope") }
  end

  def test_a_masked_frame_matches_the_rfc_example
    frame = Frame.encode("Hello", Frame::TEXT, mask: [0x37, 0xfa, 0x21, 0x3d].pack("C*"))
    assert_equal "818537fa213d7f9f4d5158", frame.unpack1("H*")
    assert_equal [Frame::TEXT, "Hello", true], Frame.decode(StringIO.new(frame))
  end

  def test_frames_round_trip_across_every_length_encoding
    [0, 1, 125, 126, 127, 200, 65_535, 65_536, 70_000].each do |size|
      payload = ("ab€" * size)[0, size].b
      [nil, "\x01\x02\x03\x04".b].each do |mask|
        opcode, data, fin = Frame.decode(StringIO.new(Frame.encode(payload, Frame::BINARY, mask: mask)))
        assert_equal [Frame::BINARY, payload, true], [opcode, data, fin], "size #{size}, mask #{mask.inspect}"
      end
    end
  end

  def test_a_length_of_exactly_127_uses_the_two_byte_form
    frame = Frame.encode("x" * 127, Frame::TEXT, mask: nil)
    assert_equal "817e007f", frame[0, 4].unpack1("H*")
    assert_equal "x" * 127, Frame.decode(StringIO.new(frame))[1]
  end

  def test_a_fragmented_message_decodes_frame_by_frame
    io = StringIO.new(Frame.encode("Hel", Frame::TEXT, mask: nil, fin: false) + Frame.encode("lo", Frame::CONTINUATION, mask: nil))
    assert_equal [Frame::TEXT, "Hel", false], Frame.decode(io)
    assert_equal [Frame::CONTINUATION, "lo", true], Frame.decode(io)
  end
end
