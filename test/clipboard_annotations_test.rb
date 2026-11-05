# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/clipboard_annotations_test.rb`).
require_relative "test_helper"

module ClipboardHelpers
  ENTRY = { "comment" => "rename this", "selector" => "#x",
            "owners" => [{ "name" => "Card", "file" => "app/javascript/card.tsx", "line" => 2 }] }.freeze

  def payload(id: "a1b2c3d4e5f60718", v: 1, annotations: [ENTRY])
    { "v" => v, "id" => id, "url" => "https://x.ngrok.app/courses", "title" => "Courses", "annotations" => annotations }
  end

  def clip(json)
    json = JSON.generate(json) unless json.is_a?(String)
    "Annotations on Courses (https://x.ngrok.app/courses) — 1 element:\n\nrename this\nselector: #x\n\n" \
      "```pf-annotations\n#{json}\n```\n"
  end
end

# The clipboard contract with a page overlay: the last fenced block, v1.
class ClipboardAnnotationsTest < Minitest::Test
  include ClipboardHelpers

  def parse(text) = Quartermaster::ClipboardAnnotations.parse(text)

  def refusal(text)
    assert_raises(ArgumentError) { parse(text) }.message
  end

  def test_the_block_after_the_readable_message_is_the_payload
    parsed = parse(clip(payload))

    assert_equal({ "id" => "a1b2c3d4e5f60718", "url" => "https://x.ngrok.app/courses", "title" => "Courses",
                   "annotations" => [ENTRY] }, parsed)
  end

  def test_the_last_block_wins
    text = "#{clip(payload(id: "old"))}\nand later\n#{clip(payload(id: "new"))}"

    assert_equal "new", parse(text)["id"]
  end

  def test_an_unclosed_header_in_the_message_cannot_swallow_the_real_block
    entry = ENTRY.merge("selector" => "a\n```pf-annotations\nunterminated\n")
    text = "Annotations on Courses — 1 element:\n\n1. rename this\n   selector: a\n```pf-annotations\nunterminated\n\n" \
           "```pf-annotations\r\n#{JSON.generate(payload(annotations: [entry]))}\r\n```\r\n"

    assert_equal [entry], parse(text)["annotations"]
  end

  def test_refusals_say_what_is_wrong
    assert_match(/no pf-annotations block/, refusal("just some text\n```js\n{}\n```"))
    assert_match(/no pf-annotations block/, refusal(nil))
    assert_match(/not valid JSON/, refusal(clip("{\"v\":1,")))
    assert_match(/not valid JSON/, refusal(clip("[1]")))
    assert_match(/unknown pf-annotations version 2/, refusal(clip(payload(v: 2))))
    assert_match(/unknown pf-annotations version nil/, refusal(clip(payload.except("v"))))
    assert_match(/no annotations/, refusal(clip(payload(annotations: []))))
    assert_match(/no annotations/, refusal(clip(payload.merge("annotations" => "x"))))
    assert_match(/has no id/, refusal(clip(payload(id: " "))))
    assert_match(/too many annotations/, refusal(clip(payload(annotations: [ENTRY] * 101))))
    assert_match(/too much/, refusal("x" * (513 * 1024)))
  end
end

# Owners' `code`, read from the item's checkout under pf's rules.
class ClipboardQuoteTest < Minitest::Test
  def with_checkout
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app/javascript"))
      File.write(File.join(root, "app/javascript/card.tsx"), "import x\r\n  <Card size=\"lg\" />\n#{"y" * 501}\n\xFF bad\n")
      File.write(File.join(root, "outside.tsx"), "a\nb\n")
      yield root
    end
  end

  def code_for(owner, root)
    annotations = Quartermaster::ClipboardAnnotations.quote([{ "comment" => "c", "owners" => [owner] }], root)
    annotations.first["owners"].first["code"]
  end

  def owner(file, line) = { "name" => "Card", "file" => file, "line" => line }

  def test_a_good_line_becomes_code
    with_checkout do |root|
      assert_equal "  <Card size=\"lg\" />", code_for(owner("app/javascript/card.tsx", 2), root)
      assert_equal "import x", code_for(owner("app/javascript/card.tsx", 1), root), "a CR is no part of the line"
      assert_equal "� bad", code_for(owner("app/javascript/card.tsx", 4), root), "invalid UTF-8 is scrubbed"
    end
  end

  def test_refused_paths_and_lines_get_no_code
    with_checkout do |root|
      File.symlink(File.join(root, "outside.tsx"), File.join(root, "app/javascript/link.tsx"))
      [owner("outside.tsx", 1), owner("app/javascript/../outside.tsx", 1), owner("app/javascript/gone.tsx", 1),
       owner("app/javascript/card.tsx", 99), owner("app/javascript/card.tsx", 3), owner("app/javascript/card.tsx", 0),
       owner("app/javascript/card.tsx", "2"), owner("app/javascript/card\0.tsx", 1), owner("app/javascript/link.tsx", 1),
       { "name" => "Card" }].each do |o|
        assert_nil code_for(o, root), o.inspect
      end
    end
  end

  def test_an_oversized_file_gets_no_code
    with_checkout do |root|
      File.write(File.join(root, "app/javascript/big.tsx"), "a\n" * (300 * 1024))
      assert_nil code_for(owner("app/javascript/big.tsx", 1), root)
    end
  end

  def test_without_a_checkout_no_owner_gets_code_and_clipboard_code_never_stays
    annotations = [{ "comment" => "c", "owners" => [owner("app/javascript/card.tsx", 2).merge("code" => "forged")] }, "junk"]

    quoted = Quartermaster::ClipboardAnnotations.quote(annotations, nil)

    assert_equal [{ "comment" => "c", "owners" => [owner("app/javascript/card.tsx", 2)] }, "junk"], quoted
  end
end

# The GUI's drafts-load: the clicked item gets the drafts, once per payload.
class DraftsLoadActionTest < Minitest::Test
  include QmTestHelpers
  include StackRepoHelpers
  include ClipboardHelpers

  def ok_host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }

  def with_item_checkout
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "repo"))
      repo = make_repo(File.join(dir, "repo"))
      Quartermaster.ensure_setup
      File.write(Quartermaster::CONFIG_FILE, { "projects" => { "Qm" => repo } }.to_yaml)
      worktree = add_worktree(repo, "feature", "wt-feature")
      FileUtils.mkdir_p(File.join(worktree, "app/javascript"))
      File.write(File.join(worktree, "app/javascript/card.tsx"), "x\n  <Card />\n")
      Quartermaster::WorkItem.create("Feat", project: "Qm", branch: "feature")
      yield Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)
    end
  end

  def load(gui, text, slug = "feat")
    JSON.parse(gui.respond("POST", "/api/action", ok_host,
                           JSON.generate("cmd" => "drafts-load", "slug" => slug, "args" => { "text" => text }))[2])
  end

  def test_loads_the_payload_into_the_item_with_code_from_its_checkout
    with_item_checkout do |gui|
      reply = load(gui, clip(payload(annotations: [ENTRY, { "comment" => " " }])))

      assert_equal [true, 1], reply.values_at("ok", "loaded"), reply["error"]
      entry = Quartermaster::Drafts.new("feat").entries.first
      assert_equal reply["ids"], [entry["id"]]
      assert_equal ["annotation", "rename this", "#x", "https://x.ngrok.app/courses", "Courses"],
                   entry.values_at("kind", "comment", "selector", "url", "title")
      assert_equal [{ "name" => "Card", "file" => "app/javascript/card.tsx", "line" => 2, "code" => "  <Card />" }],
                   entry["owners"]
    end
  end

  def test_a_payload_loads_once_even_after_its_drafts_are_gone
    with_item_checkout do |gui|
      assert_equal true, load(gui, clip(payload))["ok"]
      Quartermaster::Drafts.new("feat").remove

      again = load(gui, clip(payload))

      assert_equal false, again["ok"]
      assert_match(/already loaded/, again["error"])
      assert_empty Quartermaster::Drafts.new("feat").entries
      assert_equal true, load(gui, clip(payload(id: "another")))["ok"]
    end
  end

  def test_only_the_newest_load_ids_are_remembered
    drafts = Quartermaster::Drafts.new("item")
    (Quartermaster::Drafts::LOADED_IDS + 1).times { |i| drafts.add_annotations([{ "comment" => "c" }], load_id: "id#{i}") }

    assert_equal Quartermaster::Drafts::LOADED_IDS, JSON.parse(File.read(drafts.path))["loaded"].size
    assert drafts.add_annotations([{ "comment" => "c" }], load_id: "id0"), "the oldest id was forgotten"
    assert_raises(ArgumentError) { drafts.add_annotations([{ "comment" => "c" }], load_id: "id5") }
  end

  def test_an_item_without_a_checkout_gets_the_drafts_without_code
    Quartermaster::WorkItem.create("Loose", project: "No project")
    gui = Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new)

    reply = load(gui, clip(payload), "loose")

    assert_equal true, reply["ok"], reply["error"]
    refute Quartermaster::Drafts.new("loose").entries.first["owners"].first.key?("code")
  end

  def test_refusals_reach_the_page_and_store_nothing
    with_item_checkout do |gui|
      assert_match(/no pf-annotations block/, load(gui, "hello")["error"])
      assert_match(/not valid JSON/, load(gui, clip("{"))["error"])
      assert_match(/unknown pf-annotations version/, load(gui, clip(payload(v: 9)))["error"])
      assert_match(/no annotations/, load(gui, clip(payload(annotations: [])))["error"])
      assert_equal "no annotations to send", load(gui, clip(payload(annotations: [{ "comment" => "" }])))["error"]
      assert_equal "no work item 'nobody'", load(gui, clip(payload), "nobody")["error"]
      assert_empty Quartermaster::Drafts.counts
      assert_equal true, load(gui, clip(payload))["ok"], "a refused load remembers no id"
    end
  end

  def test_needs_our_origin
    with_item_checkout do |gui|
      body = JSON.generate("cmd" => "drafts-load", "slug" => "feat", "args" => { "text" => clip(payload) })
      ["https://evil.example.com", nil].each do |origin|
        headers = { "host" => "127.0.0.1:4567" }
        headers["origin"] = origin if origin
        status, = gui.respond("POST", "/api/action", headers, body)
        assert_equal "403 Forbidden", status, origin.inspect
      end
      assert_empty Quartermaster::Drafts.counts
    end
  end
end

# The page: a 📋 load beside Diff that posts the clipboard and toasts.
class ClipboardLoadPageTest < Minitest::Test
  include QmTestHelpers

  def test_the_load_button_reads_the_clipboard_and_posts_it
    host = { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
    html = served_page(Quartermaster::Gui.new(port: 4567, runner: quiet_runner, tmux: FakeTmux.new), host)

    [%q{bar.querySelector('.act[data-act="diff"]').after(clipboardLoadButton());}, 'action("drafts-load", "load-btn", "📋 load", "")',
     'case "drafts-load": loadClipboardAnnotations(it.slug);', "await navigator.clipboard.readText()",
     'postQuietly("drafts-load", slug, { text })', "toast(`couldn't read the clipboard:",
     'toast(`${plural(res.loaded || 0, "annotation")} loaded`);'].each { |seam| assert_includes html, seam }
    refute_match(/function loadClipboardAnnotations[^}]*toggleDiff/, html, "loading never opens the diff")
  end
end
