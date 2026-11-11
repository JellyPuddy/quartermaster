# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/gui_globals_test.rb`).
# The GUI's page scripts are classic <script> tags sharing one global scope:
# a top-level name declared in two files makes the later file a SyntaxError
# ("Identifier has already been declared") and none of it runs.
require "minitest/autorun"

class GuiGlobalsTest < Minitest::Test
  JS = File.expand_path("../lib/quartermaster/gui/js", __dir__)
  TOP_LEVEL = /^(?:const|let|var|function\*?|async\s+function\*?|class)\s+([A-Za-z_$][\w$]*)/

  def test_no_top_level_name_is_declared_in_two_page_scripts
    files = Dir[File.join(JS, "*.js")].sort
    refute_empty files

    declared = Hash.new { |h, k| h[k] = [] }
    files.each do |path|
      File.read(path, encoding: "UTF-8").scan(TOP_LEVEL) { |(name)| declared[name] << File.basename(path) }
    end
    twice = declared.select { |_name, where| where.uniq.size > 1 }

    assert_empty twice.map { |name, where| "#{name}: #{where.uniq.join(', ')}" }
  end
end
