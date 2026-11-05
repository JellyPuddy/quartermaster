# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/docs_shape_test.rb`).
# Checks the shape of docs/, not its prose: every area page follows the
# template, every code file is owned by exactly one page, links resolve,
# pages stay within their size caps and say what is true now.
require "minitest/autorun"

class DocsShapeTest < Minitest::Test
  REPO = File.expand_path("..", __dir__)
  DOCS = File.join(REPO, "docs")
  AREAS = Dir[File.join(DOCS, "areas", "*.md")].sort
  OWNED = %w[lib/quartermaster/*.rb lib/quartermaster/gui/js/*.js hooks/*.sh].freeze
  CAPS = { "README.md" => 80, "overview.md" => 150, "rejected.md" => 120 }.freeze
  AREA_CAP = 200

  def rel(path) = path.delete_prefix("#{REPO}/")

  # The backticked paths on a page's `**Label:**` line.
  def header_paths(page, label)
    line = File.readlines(page).find { |l| l.start_with?("**#{label}:**") }
    line ? line.scan(/`([^`]+)`/).flatten : []
  end

  def test_there_are_area_pages
    refute_empty AREAS
  end

  def test_every_area_page_follows_the_template
    AREAS.each do |page|
      text = File.read(page)
      %w[Code Tests].each do |label|
        assert_match(/^\*\*#{label}:\*\* \S/, text, "#{rel(page)} needs a **#{label}:** line")
      end
      ["## What it does", "## Rules"].each do |heading|
        assert_match(/^#{Regexp.escape(heading)}$/, text, "#{rel(page)} needs a `#{heading}` heading")
      end
    end
  end

  def test_every_named_path_exists
    AREAS.each do |page|
      %w[Code Tests].each do |label|
        header_paths(page, label).each do |path|
          assert File.exist?(File.join(REPO, path)), "#{rel(page)} names #{path} on its #{label} line, which doesn't exist"
        end
      end
    end
  end

  def test_every_code_file_is_owned_by_exactly_one_page
    owners = Hash.new { |h, k| h[k] = [] }
    AREAS.each { |page| header_paths(page, "Code").each { |path| owners[path] << rel(page) } }
    files = OWNED.flat_map { |glob| Dir[File.join(REPO, glob)] }.map { |f| rel(f) }.sort
    refute_empty files
    unowned = files.reject { |f| owners.key?(f) }
    assert_empty unowned, "these files belong on some docs/areas page's **Code:** line"
    shared = owners.select { |_, pages| pages.size > 1 }
    assert_empty shared, "a file is owned by one page only"
  end

  def test_readme_links_resolve_and_list_every_area_page
    readme = File.join(DOCS, "README.md")
    links = File.read(readme).scan(/\]\(([^)#\s]+)\)/).flatten.reject { |l| l.match?(%r{\A\w+://}) }
    links.each do |link|
      assert File.exist?(File.join(DOCS, link)), "README.md links #{link}, which doesn't exist"
    end
    linked = links.map { |l| File.expand_path(l, DOCS) }
    AREAS.each { |page| assert_includes linked, page, "README.md must link #{rel(page)}" }
  end

  def test_pages_stay_within_their_line_caps
    CAPS.each do |name, cap|
      lines = File.readlines(File.join(DOCS, name)).size
      assert_operator lines, :<=, cap, "docs/#{name} has #{lines} lines, cap #{cap}"
    end
    AREAS.each do |page|
      lines = File.readlines(page).size
      assert_operator lines, :<=, AREA_CAP, "#{rel(page)} has #{lines} lines, cap #{AREA_CAP}"
    end
  end

  def test_area_pages_carry_no_history_markers
    AREAS.each do |page|
      text = File.read(page)
      refute_match(/\b20\d\d-\d\d-\d\d\b/, text, "#{rel(page)} has a date; history lives in git")
      refute_match(/decision \d+/i, text, "#{rel(page)} cites a plan decision; say the rule instead")
    end
  end
end
