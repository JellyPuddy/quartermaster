# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/size_ratchet_test.rb`).
# Big files may only shrink: a file over its threshold is pinned at its size in
# test/size_limits.json, and CLAUDE.md (paid by every session) is always pinned.
# `ruby test/size_ratchet_test.rb --lower` locks shrinkage in; it never raises a limit.
require "json"

module SizeRatchet
  REPO = File.expand_path("..", __dir__)
  LIMITS_FILE = File.join(REPO, "test", "size_limits.json")
  ALWAYS_PINNED = "CLAUDE.md" # measured in bytes, every other file in lines
  THRESHOLDS = {
    "lib/quartermaster/**/*.rb" => 400,
    "lib/quartermaster/gui/js/*.js" => 400,
    "lib/quartermaster/gui/css/*.css" => 400,
    "lib/quartermaster/gui/page.html" => 400,
    "test/*.rb" => 800
  }.freeze
  SLACK = 0.9 # a pinned file at or below 90% of its limit must be lowered
  ADVICE = "Split the file along a real seam, or deliberately raise its limit in " \
           "test/size_limits.json, saying so in its own line of the commit message."

  module_function

  def threshold_by_path(root)
    THRESHOLDS.each_with_object({}) do |(glob, max), out|
      Dir[File.join(root, glob)].each { |f| out[f.delete_prefix("#{root}/")] = max }
    end
  end

  def size(root, path)
    full = File.join(root, path)
    return nil unless File.file?(full)
    path == ALWAYS_PINNED ? File.size(full) : File.foreach(full).count
  end

  def unit(path) = path == ALWAYS_PINNED ? "bytes" : "lines"

  def problems(root, limits)
    out = []
    limits.each do |path, limit|
      now = size(root, path)
      if now.nil?
        out << "#{path} is pinned but gone: run `ruby test/size_ratchet_test.rb --lower`."
      elsif now > limit
        out << "#{path} grew to #{now} #{unit(path)}, past its limit of #{limit}. #{ADVICE}"
      elsif now <= limit * SLACK
        out << "#{path} shrank to #{now} #{unit(path)} (limit #{limit}): lock that in with " \
               "`ruby test/size_ratchet_test.rb --lower`."
      end
    end
    out << "#{ALWAYS_PINNED} must be pinned in test/size_limits.json." if size(root, ALWAYS_PINNED) && !limits.key?(ALWAYS_PINNED)
    threshold_by_path(root).each do |path, max|
      next if limits.key?(path)
      now = size(root, path)
      out << "#{path} has #{now} lines, over the #{max}-line threshold. #{ADVICE}" if now > max
    end
    out
  end

  # Lowers each limit to the file's current size, drops deleted files and files
  # back at or under their threshold. Never raises a limit, never pins a new file.
  def lowered(root, limits)
    thresholds = threshold_by_path(root)
    limits.each_with_object({}) do |(path, limit), out|
      now = size(root, path)
      next if now.nil?
      next if path != ALWAYS_PINNED && thresholds.key?(path) && now <= thresholds[path]
      out[path] = [now, limit].min
    end
  end

  def load(file = LIMITS_FILE) = JSON.parse(File.read(file))

  def write(limits, file = LIMITS_FILE)
    File.write(file, "#{JSON.pretty_generate(limits.sort.to_h)}\n")
  end
end

if $PROGRAM_NAME == __FILE__ && ARGV == ["--lower"]
  before = SizeRatchet.load
  after = SizeRatchet.lowered(SizeRatchet::REPO, before)
  SizeRatchet.write(after)
  (before.keys | after.keys).sort.each do |path|
    next if before[path] == after[path]
    puts "#{path}: #{before[path]} -> #{after[path] || 'unpinned'}"
  end
  exit
end

require "minitest/autorun"
require "tmpdir"
require "fileutils"

class SizeRatchetTest < Minitest::Test
  def test_the_tree_keeps_within_its_limits
    problems = SizeRatchet.problems(SizeRatchet::REPO, SizeRatchet.load)
    assert_empty problems, problems.join("\n")
  end

  def test_the_baseline_lists_only_pinned_files
    limits = SizeRatchet.load
    assert limits.key?("CLAUDE.md")
    thresholds = SizeRatchet.threshold_by_path(SizeRatchet::REPO)
    limits.each_key do |path|
      next if path == "CLAUDE.md"
      assert thresholds.key?(path), "#{path} is outside the ratchet's scope"
      assert_operator limits[path], :>, thresholds[path], "#{path} is pinned at or under its threshold"
    end
  end

  def test_a_pinned_file_growing_past_its_limit_fails
    in_tree("lib/quartermaster/big.rb" => 500, "CLAUDE.md" => 100) do |root|
      problems = SizeRatchet.problems(root, "lib/quartermaster/big.rb" => 499, "CLAUDE.md" => 200)
      assert_equal 1, problems.size
      assert_match(/big\.rb grew to 500 lines, past its limit of 499\. Split the file/, problems.first)
      assert_match(%r{raise its limit in test/size_limits\.json}, problems.first)
    end
  end

  def test_a_pinned_file_within_its_limit_passes
    in_tree("lib/quartermaster/big.rb" => 500, "CLAUDE.md" => 100) do |root|
      assert_empty SizeRatchet.problems(root, "lib/quartermaster/big.rb" => 520, "CLAUDE.md" => 200)
    end
  end

  def test_claude_md_is_measured_in_bytes
    in_tree("CLAUDE.md" => 100) do |root|
      problems = SizeRatchet.problems(root, "CLAUDE.md" => 99)
      assert_match(/CLAUDE\.md grew to \d+ bytes/, problems.first)
      assert_equal ["CLAUDE.md must be pinned in test/size_limits.json."], SizeRatchet.problems(root, {})
    end
  end

  def test_an_unpinned_file_crossing_its_threshold_fails
    in_tree("lib/quartermaster/a.rb" => 401, "lib/quartermaster/b.rb" => 400,
            "lib/quartermaster/gui/js/c.js" => 401, "test/d_test.rb" => 800, "test/e_test.rb" => 801,
            "lib/elsewhere.rb" => 9000, "CLAUDE.md" => 10) do |root|
      problems = SizeRatchet.problems(root, "CLAUDE.md" => 9000)
      flagged = problems.map { |p| p[/\A\S+/] }
      assert_equal %w[lib/quartermaster/a.rb lib/quartermaster/gui/js/c.js test/e_test.rb].sort,
                   (flagged - ["CLAUDE.md"]).sort
      assert_includes problems.join, "over the 800-line threshold"
    end
  end

  def test_a_pinned_file_shrinking_ten_percent_asks_for_lower
    in_tree("lib/quartermaster/big.rb" => 450, "lib/quartermaster/near.rb" => 451, "CLAUDE.md" => 45) do |root|
      problems = SizeRatchet.problems(root, "lib/quartermaster/big.rb" => 500,
                                            "lib/quartermaster/near.rb" => 500, "CLAUDE.md" => 100)
      assert_equal 2, problems.size, problems.join("\n")
      assert_match(/big\.rb shrank to 450 lines \(limit 500\).*--lower/, problems[0])
      assert_match(/CLAUDE\.md shrank.*--lower/, problems[1])
    end
  end

  def test_a_deleted_pinned_file_asks_for_lower
    in_tree("CLAUDE.md" => 10) do |root|
      problems = SizeRatchet.problems(root, "lib/quartermaster/gone.rb" => 500, "CLAUDE.md" => 20)
      assert_equal ["lib/quartermaster/gone.rb is pinned but gone: run `ruby test/size_ratchet_test.rb --lower`."],
                   problems
    end
  end

  def test_lower_lowers_and_drops_but_never_raises
    in_tree("lib/quartermaster/shrunk.rb" => 450, "lib/quartermaster/grew.rb" => 600,
            "lib/quartermaster/small.rb" => 380, "lib/quartermaster/fresh.rb" => 900,
            "CLAUDE.md" => 25) do |root|
      limits = { "lib/quartermaster/shrunk.rb" => 500, "lib/quartermaster/grew.rb" => 550,
                 "lib/quartermaster/small.rb" => 500, "lib/quartermaster/gone.rb" => 500, "CLAUDE.md" => 60 }
      lowered = SizeRatchet.lowered(root, limits)
      assert_equal({ "lib/quartermaster/shrunk.rb" => 450, "lib/quartermaster/grew.rb" => 550,
                     "CLAUDE.md" => File.size(File.join(root, "CLAUDE.md")) }, lowered)
    end
  end

  def test_lower_keeps_claude_md_pinned_however_small
    in_tree("CLAUDE.md" => 1) do |root|
      assert_equal ["CLAUDE.md"], SizeRatchet.lowered(root, "CLAUDE.md" => 9000).keys
    end
  end

  def test_write_round_trips_sorted
    Dir.mktmpdir do |dir|
      file = File.join(dir, "limits.json")
      SizeRatchet.write({ "b" => 2, "CLAUDE.md" => 3, "a" => 1 }, file)
      assert_equal %w[CLAUDE.md a b], SizeRatchet.load(file).keys
    end
  end

  private

  # Builds a tree of files of the given line counts under a temp root.
  def in_tree(lines_by_path)
    Dir.mktmpdir do |root|
      lines_by_path.each do |path, lines|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, "x\n" * lines)
      end
      yield root
    end
  end
end
