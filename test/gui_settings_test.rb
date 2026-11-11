# frozen_string_literal: true

# Loaded by quartermaster_test.rb; also runs alone (`ruby test/gui_settings_test.rb`).
require_relative "test_helper"

class GuiSettingsTest < Minitest::Test
  include QmTestHelpers

  # Every folder and command the warnings look for is there.
  class AllThere
    def dir?(_path) = true

    def command?(_name) = true
  end

  def gui
    @gui ||= Quartermaster::Gui.new(port: 4567, runner: quiet_runner, settings_probe: AllThere.new)
  end

  def ok_host
    { "host" => "127.0.0.1:4567", "origin" => "http://127.0.0.1:4567" }
  end

  def file = Quartermaster::CONFIG_FILE

  def write_config(text)
    Quartermaster.ensure_setup
    File.write(file, text)
  end

  def get_settings
    status, content_type, body = gui.respond("GET", "/api/settings", { "host" => "127.0.0.1:4567" }, "")
    assert_equal "200 OK", status
    assert_includes content_type, "application/json"
    JSON.parse(body)
  end

  def post(route, payload, headers = ok_host)
    status, _ct, body = gui.respond("POST", route, headers, JSON.generate(payload))
    [status, (JSON.parse(body) rescue body)]
  end

  APP = <<~YAML
    projects:
      Plain: /code/plain
      App:
        root: /code/app
        dev_server: pf
        test_db: app-test-db
    ide_command: [code, PATH]
    my_notes: { keep: 1 }
  YAML

  def test_the_payload_carries_schema_config_digest_issues_features_counts_prices_and_path
    write_config(APP)
    Quartermaster::WorkItem.create("One", project: "App")
    Quartermaster::WorkItem.create("Two", project: "App")

    payload = get_settings

    assert_equal Quartermaster::ConfigSchema.payload, payload["schema"]
    assert_equal({ "root" => "/code/plain" }, payload["config"]["projects"]["Plain"], "a shorthand opens into its mapping")
    assert_equal({ "command" => "pf" }, payload["config"]["projects"]["App"]["dev_server"])
    assert_equal({ "keep" => 1 }, payload["config"]["my_notes"], "keys the schema doesn't govern come along")
    assert_equal Digest::SHA256.hexdigest(APP), payload["digest"]
    assert_equal [], payload["issues"]
    assert_equal "on", payload["features"]["App"]["dev_server"]["state"]
    assert_equal "inherit", payload["features"]["Plain"]["ide"]["state"]
    assert_equal 2, payload["items"]["App"]
    assert_equal [4, 5, 8, 0.2, 20], payload["priceDefaults"]["claude-opus-5-5"].values
    assert_equal file, payload["path"]
  end

  def test_an_unparsable_file_is_an_empty_form_with_its_error
    write_config("projects: [unclosed\n")

    payload = get_settings

    assert_equal({}, payload["config"])
    assert_equal "error", payload["issues"].first["level"]
    assert_match(/not valid YAML/, payload["issues"].first["message"])
  end

  def test_check_answers_issues_and_features_for_a_draft_without_writing
    write_config(APP)
    draft = { "projects" => { "App" => { "root" => "/code/app", "typo" => 1, "benchmark" => { "database" => "x" } } },
              "default_project" => "Nope" }

    status, answer = post("/api/settings/check", { "config" => draft })

    assert_equal "200 OK", status
    errors = answer["issues"].select { |i| i["level"] == "error" }.map { |i| i["path"] }
    assert_includes errors, "projects.App.typo"
    assert_includes errors, "default_project"
    assert_equal "error", answer["features"]["App"]["benchmarks"]["state"]
    assert_equal APP, File.read(file)
  end

  def test_save_writes_the_draft_and_answers_the_new_payload_and_a_fresh_state
    write_config(APP)
    loaded = get_settings
    draft = loaded["config"]
    draft["projects"]["App"]["review_skill"] = "/review-app"
    draft["default_project"] = "App"

    status, answer = post("/api/settings/save", { "config" => draft, "digest" => loaded["digest"] })

    assert_equal "200 OK", status
    assert answer["ok"]
    written = YAML.safe_load(File.read(file))
    assert_equal "/review-app", written["projects"]["App"]["review_skill"]
    assert_equal "/code/plain", written["projects"]["Plain"], "a root-only project goes back to its shorthand"
    assert_equal({ "keep" => 1 }, written["my_notes"])
    assert_equal APP, File.read("#{file}.bak")
    assert_equal Digest::SHA256.hexdigest(File.read(file)), answer["settings"]["digest"]
    assert_equal "App", answer["state"]["defaultProject"]
  end

  def test_save_rebuilds_the_state_so_a_new_dev_server_shows_at_once
    write_config("projects:\n  App: /code/app\n")
    assert_nil gui.state.build["pf"]["command"]
    loaded = get_settings
    draft = loaded["config"]
    draft["projects"]["App"]["dev_server"] = { "command" => "pf" }

    _status, answer = post("/api/settings/save", { "config" => draft, "digest" => loaded["digest"] })

    assert answer["ok"], answer.inspect
    assert_equal "pf", answer["state"]["pf"]["command"], "the save's answer is a build after the write"
    assert_equal "pf", gui.state.build["pf"]["command"]
  end

  def test_save_over_a_file_changed_since_it_was_loaded_is_refused_as_stale_with_the_current_payload
    write_config(APP)
    loaded = get_settings
    File.write(file, "#{APP}default_project: Plain\n")

    status, answer = post("/api/settings/save", { "config" => loaded["config"], "digest" => loaded["digest"] })

    assert_equal "409 Conflict", status
    refute answer["ok"]
    assert answer["stale"]
    assert_equal Digest::SHA256.hexdigest(File.read(file)), answer["settings"]["digest"]
    assert_equal "Plain", answer["settings"]["config"]["default_project"]
    assert_equal "#{APP}default_project: Plain\n", File.read(file)
  end

  def test_save_with_errors_is_refused_and_writes_nothing
    write_config(APP)
    loaded = get_settings
    draft = loaded["config"]
    draft["projects"]["App"]["ide_command"] = ["code"]

    status, answer = post("/api/settings/save", { "config" => draft, "digest" => loaded["digest"] })

    assert_equal "422 Unprocessable Content", status
    refute answer["ok"]
    assert_equal ["projects.App.ide_command"], answer["issues"].select { |i| i["level"] == "error" }.map { |i| i["path"] }
    assert_equal APP, File.read(file)
    refute File.exist?("#{file}.bak")
  end

  # The page draws every field through SETTINGS_WIDGETS (settings-widgets.js),
  # one entry per line; a schema type without one would render as a text box.
  def test_the_page_has_a_widget_for_every_schema_type
    page = served_page(gui, { "host" => "127.0.0.1:4567" })
    table = page[/const SETTINGS_WIDGETS = \{\n(.*?)\n\};/m, 1]
    refute_nil table, "settings-widgets.js is served and declares SETTINGS_WIDGETS"
    widgets = table.scan(/^  (\w+):/).flatten

    assert_equal Quartermaster::ConfigSchema::TYPES.sort, widgets.sort
  end

  # A project key renders only under a section SETTINGS_PROJECT_SECTIONS lists.
  def test_every_project_section_in_the_schema_has_a_title_on_the_page
    page = served_page(gui, { "host" => "127.0.0.1:4567" })
    listed = page[/const SETTINGS_PROJECT_SECTIONS = (\[.*?\]);/m, 1].scan(/\["(\w+)", "[^"]+"\]/).flatten
    used = Quartermaster::ConfigSchema::KEYS.select { |k| k.path.start_with?("projects.*.") }.map(&:section).uniq

    assert_includes listed, "epics"
    assert_includes listed, "issue_links"
    assert_empty used - listed
  end

  def test_settings_opens_from_the_header_cog_not_a_mode_tab
    page = served_page(gui, { "host" => "127.0.0.1:4567" })

    modes = page[%r{<div class="segmented" id="modes".*?</div>}m]
    refute_includes modes, "settings", "the mode switcher has no Settings tab"
    assert_match(%r{<button class="btn icon" id="settings-btn" aria-pressed="false" title="Settings \(,\)" aria-label="Settings">}, page)
    assert_match(%r{<kbd>,</kbd><span>settings</span>}, page)
    assert_includes page, %(if (e.key === ",") { e.preventDefault(); toggleSettings(); return; })
    assert_operator page.index("/assets/js/settings.js"), :<, page.index("/assets/js/events.js"), "settings.js loads before events.js"
  end

  def test_save_and_check_refuse_a_foreign_or_missing_origin
    write_config(APP)
    loaded = get_settings
    body = { "config" => { "projects" => {} }, "digest" => loaded["digest"] }
    foreign = ok_host.merge("origin" => "https://evil.example.com")
    no_origin = { "host" => "127.0.0.1:4567" }

    ["/api/settings/save", "/api/settings/check"].each do |route|
      [foreign, no_origin].each do |headers|
        status, = post(route, body, headers)
        assert_equal "403 Forbidden", status, "#{route} #{headers}"
      end
    end
    assert_equal APP, File.read(file)
    status, = gui.respond("GET", "/api/settings", { "host" => "evil.example.com" }, "")
    assert_equal "403 Forbidden", status
  end
end
