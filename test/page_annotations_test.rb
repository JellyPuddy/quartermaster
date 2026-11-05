# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/page_annotations_test.rb`).
require_relative "test_helper"

class PageAnnotationsTest < Minitest::Test
  def test_one_message_with_the_page_then_comment_first_per_element
    text = Quartermaster::PageAnnotations.message(
      [{ "comment" => "Too much padding\nhere", "selector" => "main > .card:nth-of-type(2)",
         "text" => "  Course\n  overview ", "html" => "<div class=\"card\">\n  <h2>Course</h2>\n</div>",
         "component" => "CourseCard" },
       { "comment" => "   ", "selector" => "skipped" },
       { "comment" => "Wrong colour", "selector" => "#save", "component" => nil, "text" => "", "html" => "<button id=\"save\">" }],
      url: "http://localhost:3000/courses/1", title: "Course 1"
    )

    assert_equal <<~MSG.chomp, text
      Annotations on the page "Course 1" (http://localhost:3000/courses/1) — 2 elements:

      Too much padding
      here
      selector: main > .card:nth-of-type(2)
      component: CourseCard
      text: Course overview
      html: <div class="card"> <h2>Course</h2> </div>

      Wrong colour
      selector: #save
      html: <button id="save">
    MSG
  end

  def test_cuts_long_text_and_html_and_names_an_untitled_page
    text = Quartermaster::PageAnnotations.message([{ "comment" => "x", "text" => "t" * 500, "html" => "h" * 5000 }])
    lines = text.lines(chomp: true)

    assert_equal "Annotations on a page — 1 element:", lines.first
    assert_equal "text: #{"t" * 199}…", lines.find { |l| l.start_with?("text: ") }
    assert_equal "html: #{"h" * 599}…", lines.find { |l| l.start_with?("html: ") }
  end

  def test_names_an_elements_page_only_when_it_is_not_the_batchs
    url = "http://localhost:3000/courses/1"
    text = Quartermaster::PageAnnotations.message(
      [{ "comment" => "elsewhere", "page" => "http://localhost:3000/courses/2", "selector" => "#a" },
       { "comment" => "same", "page" => " #{url} ", "selector" => "#b" },
       { "comment" => "missing", "selector" => "#c" },
       { "comment" => "blank", "page" => "  ", "selector" => "#d" },
       { "comment" => "long", "page" => "http://x/#{"p" * 500}" }],
      url: url
    )
    blocks = text.split("\n\n").drop(1)

    assert_equal "elsewhere\npage: http://localhost:3000/courses/2\nselector: #a", blocks[0]
    assert_equal ["same\nselector: #b", "missing\nselector: #c", "blank\nselector: #d"], blocks[1, 3]
    assert_equal 300, blocks[4].lines(chomp: true).last.delete_prefix("page: ").length
    assert blocks[4].end_with?("…")
  end

  def test_names_the_other_page_all_annotations_share_in_the_header
    text = Quartermaster::PageAnnotations.message(
      [{ "comment" => "one", "page" => "http://localhost:3000/courses/2", "selector" => "#a" },
       { "comment" => "two", "page" => " http://localhost:3000/courses/2", "selector" => "#b" }],
      url: "http://localhost:3000/progress?week=3#top", title: "Progress"
    )

    assert_equal <<~MSG.chomp, text
      Annotations on http://localhost:3000/courses/2 (sent from /progress?week=3) — 2 elements:

      one
      selector: #a

      two
      selector: #b
    MSG
  end

  def test_names_the_page_most_annotations_share_and_the_others_per_element
    text = Quartermaster::PageAnnotations.message(
      [{ "comment" => "batch", "selector" => "#a" },
       { "comment" => "other", "page" => "http://x/courses/2", "selector" => "#b" },
       { "comment" => "other too", "page" => "http://x/courses/2", "selector" => "#c" }],
      url: "http://x/", title: "Home"
    )
    lines = text.split("\n\n")

    assert_equal "Annotations on http://x/courses/2 (sent from /) — 3 elements:", lines[0]
    assert_equal ["batch\npage: http://x/\nselector: #a", "other\nselector: #b", "other too\nselector: #c"], lines.drop(1)
  end

  def test_keeps_the_batch_page_header_when_every_annotation_is_on_it
    text = Quartermaster::PageAnnotations.message(
      [{ "comment" => "a", "page" => "http://x/p" }, { "comment" => "b" }], url: "http://x/p", title: "P"
    )

    assert_equal "Annotations on the page \"P\" (http://x/p) — 2 elements:\n\na\n\nb", text
  end

  def test_a_tie_puts_the_first_occurring_page_in_the_header
    text = Quartermaster::PageAnnotations.message(
      [{ "comment" => "a", "page" => "http://x/b" }, { "comment" => "b", "page" => "http://x/a" }],
      url: "not a url at all", title: "T"
    )

    assert_equal "Annotations on http://x/b (sent from not a url at all) — 2 elements:\n\na\n\nb\npage: http://x/a", text
  end

  def block_for(annotation)
    Quartermaster::PageAnnotations.message([{ "comment" => "c", "selector" => "#s" }.merge(annotation)]).split("\n\n").last
  end

  def test_shows_the_component_chain_in_place_of_the_component_then_the_context
    block = block_for("component" => "Inner", "components" => ["Inner", " Goal\nList ", "", "  ", "Page"],
                      "context" => "heading \"Order my goals\"\n · in #comment", "text" => "t")

    assert_equal "c\nselector: #s\ncomponents: Inner < Goal List < Page\ncontext: heading \"Order my goals\" · in #comment\ntext: t",
                 block
  end

  def test_falls_back_to_the_component_without_a_usable_chain
    [nil, [], ["  ", ""], "Inner < Page", { "a" => "b" }, [1, nil, ["x"]]].each do |chain|
      assert_equal "c\nselector: #s\ncomponent: Inner", block_for("component" => "Inner", "components" => chain), chain.inspect
    end
  end

  def test_skips_non_string_chain_entries
    assert_equal "c\nselector: #s\ncomponents: A < B", block_for("components" => ["A", 7, nil, { "x" => 1 }, "B"])
  end

  def test_cuts_each_component_the_chain_and_the_context
    long_names = block_for("components" => ["n" * 200, "Short"]).lines(chomp: true)
    assert_equal "components: #{"n" * 79}… < Short", long_names.find { |l| l.start_with?("components: ") }

    many = block_for("components" => Array.new(10) { "m" * 80 }, "context" => "x" * 1000).lines(chomp: true)
    chain = many.find { |l| l.start_with?("components: ") }.delete_prefix("components: ")
    assert_equal 300, chain.length
    assert chain.end_with?("…")
    assert_equal "context: #{"x" * 299}…", many.find { |l| l.start_with?("context: ") }
  end

  def test_shows_who_rendered_the_element_in_place_of_the_chain
    block = block_for("component" => "Inner", "components" => ["Inner", "Page"],
                      "owners" => [{ "name" => "GoalCard", "file" => "app/frontend/goals/GoalCard.tsx", "line" => 42 },
                                   { "name" => " Goal\nList ", "file" => "app/frontend/goals/GoalList.tsx" },
                                   { "name" => "Page", "file" => "  ", "line" => 7 }],
                      "context" => "heading \"Goals\"", "regions" => "sidebar \"Review\"\n open", "text" => "t")

    assert_equal <<~BLOCK.chomp, block
      c
      selector: #s
      rendered by:
        - GoalCard · JSX in app/frontend/goals/GoalCard.tsx:42
        - Goal List · JSX in app/frontend/goals/GoalList.tsx
        - Page
      context: heading "Goals"
      regions: sidebar "Review" open
      text: t
    BLOCK
  end

  def test_keeps_owners_without_source_info_by_name_among_filed_ones
    block = block_for("owners" => [{ "name" => "CollectionCard", "file" => "app/frontend/CollectionList.tsx", "line" => 88 },
                                   { "name" => "DraggableCollectionCard" },
                                   { "name" => "AppLaunch", "file" => "app/frontend/AppLaunch.tsx", "line" => 12 }])

    assert_equal <<~BLOCK.chomp, block
      c
      selector: #s
      rendered by:
        - CollectionCard · JSX in app/frontend/CollectionList.tsx:88
        - DraggableCollectionCard
        - AppLaunch · JSX in app/frontend/AppLaunch.tsx:12
    BLOCK
  end

  def test_names_where_an_owner_resolved_by_definition_is_defined
    block = block_for("owners" => [{ "name" => "GoalCard", "file" => "app/javascript/goals/GoalCard.tsx", "line" => 42 },
                                   { "name" => "GoalList", "file" => "app/javascript/goals/GoalList.tsx", "line" => 3,
                                     "via" => "definition" },
                                   { "name" => "Shell", "file" => "app/javascript/Shell.tsx", "line" => 8, "via" => "callsite" },
                                   { "name" => "Item", "via" => "definition" },
                                   { "name" => "Page", "file" => "app/javascript/Page.tsx", "via" => "definition" }])

    assert_equal <<~BLOCK.chomp, block
      c
      selector: #s
      rendered by:
        - GoalCard · JSX in app/javascript/goals/GoalCard.tsx:42
        - GoalList · defined in app/javascript/goals/GoalList.tsx:3
        - Shell · JSX in app/javascript/Shell.tsx:8
        - Item
        - Page · defined in app/javascript/Page.tsx
    BLOCK
  end

  def test_names_the_alias_the_jsx_above_an_owner_uses
    block = block_for("owners" => [{ "name" => "RouteSettings", "file" => "app/javascript/RouteSettings.tsx", "line" => 3,
                                     "as" => "RouteAdminSettings" },
                                   { "name" => "Same", "file" => "s.tsx", "as" => "Same" },
                                   { "name" => "Odd", "as" => 7 }])

    assert_equal <<~BLOCK.chomp, block
      c
      selector: #s
      rendered by:
        - RouteSettings (as <RouteAdminSettings>) · JSX in app/javascript/RouteSettings.tsx:3
        - Same · JSX in s.tsx
        - Odd
    BLOCK
  end

  def test_ignores_a_via_other_than_definition
    ["Definition", "callsite", "", nil, 1, ["definition"]].each do |via|
      line = block_for("owners" => [{ "name" => "A", "file" => "a.tsx", "line" => 2, "via" => via }]).lines(chomp: true).last
      assert_equal "  - A · JSX in a.tsx:2", line, via.inspect
    end
  end

  def test_shows_a_line_number_only_when_it_is_a_positive_integer
    lines = [0, -3, "42", 4.5, nil, [1]].map do |line|
      block_for("owners" => [{ "name" => "A", "file" => "a.tsx", "line" => line }]).lines(chomp: true).last
    end

    assert_equal ["  - A · JSX in a.tsx"] * 6, lines
  end

  def test_ignores_unusable_owners_and_falls_back_to_the_chain
    [nil, [], "A", { "name" => "A" }, [nil, 1, "A", ["A"]], [{ "name" => "  " }, { "name" => 5 }, { "file" => "a.tsx" }]].each do |owners|
      assert_equal "c\nselector: #s\ncomponents: A < B", block_for("components" => %w[A B], "owners" => owners), owners.inspect
    end

    mixed = block_for("owners" => [nil, { "name" => " " }, { "name" => "A", "file" => 3, "line" => 2 }, "B"])
    assert_equal "c\nselector: #s\nrendered by:\n  - A", mixed
  end

  def test_cuts_owner_names_files_count_and_the_regions
    owners = [{ "name" => "n" * 200, "file" => "f" * 500, "line" => 9 }] + Array.new(9) { |i| { "name" => "O#{i}" } }
    lines = block_for("owners" => owners, "regions" => "r" * 500).lines(chomp: true)

    assert_equal "  - #{"n" * 79}… · JSX in #{"f" * 199}…:9", lines[3]
    assert_equal ["  - O0", "  - O1", "  - O2", "  - O3", "  - O4"], lines[4, 5]
    assert_equal "regions: #{"r" * 199}…", lines[9]
    assert_equal 10, lines.size
  end

  def test_refuses_nothing_to_send
    [nil, [], [{ "comment" => " " }], ["not a hash"], { "comment" => "x" }].each do |entries|
      assert_raises(ArgumentError) { Quartermaster::PageAnnotations.message(entries) }
    end
  end
end

