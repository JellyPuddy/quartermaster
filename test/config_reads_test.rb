# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/config_reads_test.rb`).
require_relative "test_helper"

# Code reads config.yml only through ConfigReader (ProjectConfig and
# ProjectSettings ask it; ConfigFile and ConfigCheck own the editable
# document). At run time the strict reader fails a test that asks for a key
# ConfigSchema doesn't list; this scan catches the other way around it: code
# outside that layer opening the file or reading a config key off a raw hash.
class ConfigReadsTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  # Files allowed to touch the file and its raw mapping.
  ACCESSOR_LAYER = %w[
    quartermaster/config_reader.rb quartermaster/config_schema.rb quartermaster/config_check.rb
    quartermaster/config_file.rb quartermaster/project_config.rb quartermaster/project_settings.rb
  ].freeze

  # Where CONFIG_FILE may appear outside the layer: its definition and the
  # first-run seed.
  FILE_USERS = %w[quartermaster.rb quartermaster/cli_config.rb quartermaster/gui_settings.rb].freeze

  # Schema key names other data also uses (transcripts' input/output, a
  # job's label, a hook's command, a status's root): a read of one can't be
  # told from a config read by its spelling, so the scan leaves them out.
  SHARED_WORDS = %w[root command label prompt input output database skill notes modes
                    cache_read cache_write_5m cache_write_1h].freeze

  def config_words
    names = (Quartermaster::ConfigSchema.keys.map(&:path) + Quartermaster::ConfigSchema::CONTAINERS.keys)
            .flat_map { |path| path.split(".") }
    (names.uniq - ["*"] - SHARED_WORDS).sort
  end

  # [line number, line] of each raw read of a config key in source text:
  # `x["test_db"]`, `x.dig("projects", …)`, `x.fetch("prices")` (YAML keys
  # are strings, so `x[:prices]` is some other hash; an assignment
  # `x["k"] = …` is a write, not a read).
  def raw_reads(source)
    words = Regexp.union(config_words)
    read = /(?:\[\s*(["'])#{words}\1\s*\](?!\s*=[^=])|\.(?:dig|fetch)\(\s*(["'])#{words}\2)/
    source.each_line.with_index(1).select { |line, _| line.match?(read) }.map { |line, n| [n, line.strip] }
  end

  def lib_files
    Dir[File.join(LIB, "**", "*.rb")].map { |f| f.delete_prefix("#{LIB}/") }.sort - ACCESSOR_LAYER
  end

  def test_the_scan_catches_raw_config_reads
    hits = raw_reads(<<~RUBY)
      data["projects"]["App"]["test_db"]
      config.dig("prices", model)
      settings.fetch("review_skill")
      data['ide_label']
      payload["test_db"] = value
      context[:prices]
      tokens["input"]
    RUBY

    assert_equal [1, 2, 3, 4], hits.map(&:first)
    assert_includes config_words, "dev_server"
    assert_includes config_words, "overview_artifact"
  end

  def test_no_code_outside_the_accessor_layer_reads_config_keys_off_a_raw_hash
    hits = lib_files.flat_map do |file|
      raw_reads(File.read(File.join(LIB, file))).map { |n, line| "lib/#{file}:#{n}: #{line}" }
    end

    assert_empty hits, "read config through ProjectConfig / ProjectSettings (ConfigReader), not the raw mapping"
  end

  def test_only_the_accessor_layer_opens_config_yml
    hits = (lib_files - FILE_USERS).select { |file| File.read(File.join(LIB, file)).include?("CONFIG_FILE") }

    assert_empty hits, "ask ProjectConfig.current (or ConfigFile to edit) instead of reading CONFIG_FILE"
  end
end
