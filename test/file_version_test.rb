# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/file_version_test.rb`).
require_relative "test_helper"

class FileVersionTest < Minitest::Test
  include QmTestHelpers

  def setup
    super
    Quartermaster.ensure_setup
    @path = File.join(Quartermaster::ROOT, "versioned.txt")
    File.write(@path, "first")
  end

  def version = Quartermaster::FileVersion.of(@path)

  def test_an_untouched_file_keeps_its_version
    assert_equal version, version
  end

  def test_a_chmod_changes_the_version
    before = version
    File.chmod(0o600, @path)

    refute_equal before, version
  end

  def test_a_rewrite_of_the_same_size_changes_the_version
    before = version
    File.write(@path, "other")

    refute_equal before, version
  end

  def test_a_replaced_file_changes_the_version
    before = version
    Quartermaster::AtomicFile.write(@path, "first")

    refute_equal before, version
  end

  def test_a_missing_file_has_no_version
    File.delete(@path)

    assert_nil version
  end
end
