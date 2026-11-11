# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/issue_links_test.rb`).
require_relative "issue_start_helpers"

# IssueLinks' links from issue-body headings (docs/areas/issues.md): the
# first URL under the first heading holding a rule's word, read from three
# real issue bodies (names changed, shape kept); and every start (normal, inside an epic, epic) carrying
# them.
class IssueLinksTest < Minitest::Test
  include QmTestHelpers
  include IssueStartHelpers

  BODIES = File.join(__dir__, "fixtures", "issue-bodies")

  def real(name) = { "number" => 123, "body" => File.read(File.join(BODIES, "#{name}.md")) }

  def links(issue, headings: [%w[Design Design]], **rest)
    settings = Quartermaster::ProjectSettings::IssueLinkSettings.new(notion_label: "Notion", headings: headings, **rest)
    Quartermaster::IssueLinks.new(settings).for(issue, "acme/widget")
  end

  def design(url) = [{ "label" => "Design", "url" => url }]

  def test_the_first_url_under_each_real_bodys_design_heading
    assert_equal design("https://www.figma.com/design/Qx7Lm2Fk9Rz/Record-display-name?node-id=11-1219&t=Wd3kPq8ZbT1-1"),
                 links(real("proposed-design")), "# Proposed Design; the markdown link's ) after a newline"
    assert_equal design("https://www.figma.com/design/Hn4Tc8Vw2Ys/Rating-levels--characters---availability?node-id=14-1083&t=Kb5mJr7NxQ2-1"),
                 links(real("design-two-links")), "## Design; the URL stops at the ) before 'and'"
    assert_equal design("https://www.figma.com/design/Zp2Rg6Hd8Lc/Coach-dashboard?node-id=153-11805&p=f&t=Vm9xTq4LsB0-0"),
                 links(real("commented-template")), "the first of two"
  end

  def test_html_comments_hide_headings_and_urls_and_no_match_gives_no_link
    assert_empty links(real("commented-template"), headings: [["test plan", "QA"]]), "its test-plan heading sits in a comment"
    assert_empty links(real("commented-template"), headings: [["development notes", "Dev"]]), "a heading with no URL under it"
    assert_empty links(real("design-two-links"), headings: [%w[Figma Figma]]), "no heading holds the word"
    body = "Design: https://not.example/plain-text\n\n### design notes\n<!-- https://hidden.example/x -->\n" \
           "see <https://a.example/1> and https://a.example/2\n####### Design\n## Other\nhttps://b.example/3"
    assert_equal design("https://a.example/1"), links({ "body" => body }), "any level, any case; a non-heading line is text"
    assert_empty links({ "body" => "## Design\n## Mockups\nhttps://b.example/3" }), "the first matching heading only"
    assert_equal design("https://c.example/4"), links({ "body" => "## Design\n[https://c.example/4](https://c.example/4)" }),
                 "a markdown link whose text is the URL"
  end

  def test_tracker_notion_then_headings_each_url_and_label_once
    issue = real("design-two-links").merge("number" => 123, "comments" => { "nodes" => [NOTES_BOT] },
                              "body" => "## Design\nhttps://tracker.example/123\n## Mockups\nhttps://m.example/1\n" \
                                        "## Design review\nhttps://r.example/1")
    found = links(issue, headings: [%w[Design Design], %w[Mockups Design], %w[review Design]],
                         tracker_url: "https://tracker.example/{number}", notion_author: "notes-bot")
    assert_equal [{ "label" => "Tracker", "url" => "https://tracker.example/123" },
                  { "label" => "Notion", "url" => NOTION_URL }, { "label" => "Design", "url" => "https://m.example/1" }],
                 found, "the first Design repeats the Tracker URL, so Mockups' takes the label and review's comes too late"
    assert_equal [{ "label" => "Review", "url" => "https://r.example/1" }],
                 links(issue, headings: [%w[review Review]]), "a word anywhere in the heading"
  end

  def body = real("design-two-links")["body"]

  def expected_links
    [TRACKER, { "label" => "Notion page", "url" => NOTION_URL },
     design("https://www.figma.com/design/Hn4Tc8Vw2Ys/Rating-levels--characters---availability?node-id=14-1083&t=Kb5mJr7NxQ2-1").first]
  end

  def with_design_links(epics: EPIC_SETTINGS, &)
    with_widget_repo(epics: epics, links: LINK_SETTINGS.merge("heading_links" => ["Design"]), &)
  end

  def test_an_epic_start_carries_the_tracker_and_design_links
    with_design_links do
      start = starter(epic_runner(body: body))
      epic = start.start(start.preview(123, "Widget"))[:item]
      assert_equal [true, expected_links], [epic.epic?, epic.links]
    end
  end

  def test_a_sub_issue_started_inside_an_epic_carries_them
    with_design_links do
      Quartermaster::WorkItem.create("Rubrics", project: "Widget", front: { "kind" => "epic" })
      start = starter(issue_runner(body: body, comments: [NOTES_BOT]))
      inside = start.start(start.preview(123, "Widget"), epic: "rubrics")[:item]
      assert_equal ["rubrics", expected_links], [inside.epic, inside.links]
    end
  end

  def test_a_normal_start_carries_them
    with_design_links(epics: nil) do
      start = starter(issue_runner(body: body, comments: [NOTES_BOT]))
      assert_equal expected_links, start.start(start.preview(123, "Widget"))[:item].links
    end
  end
end
