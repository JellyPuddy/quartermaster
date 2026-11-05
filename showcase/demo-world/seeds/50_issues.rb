# frozen_string_literal: true

# Story 5, from issue to merged: Claude's issue drafts for the allergen
# filter (the /draft-issues skill's files) — one already created as #57, one
# Claude revised since the user last looked (qm's own revision snapshot, so the
# pane marks the changed blocks), and the user's comments on them as drafts.
module DemoWorld
  module Issues
    SCOPE = <<~MD
      ---
      title: Filter products by allergen
      kind: feature
      group: Allergen filter
      number: 57
      ---
      Customers with allergies ask to hide every product containing what they avoid.

      ## What

      - A `Product.without_allergens(*list)` scope over the existing `allergens` array.
      - Unknown allergen names are ignored, not an error.

      ## Done when

      - The catalogue accepts `?without=nuts,sesame` and shows only safe products.
    MD

    UI_V1 = <<~MD
      ---
      title: Allergen checkboxes on the catalogue
      kind: feature
      group: Allergen filter
      parent: "#57"
      deps: ["#57"]
      ---
      Add a row of checkboxes above the product grid, one per allergen.

      - Ticking one reloads the grid with `?without=…`.
      - The choice shows as chips that can be removed one by one.
    MD

    UI_V2 = <<~MD
      ---
      title: Allergen checkboxes on the catalogue
      kind: feature
      group: Allergen filter
      parent: "#57"
      deps: ["#57"]
      change: Filtering is now a Turbo Frame, so the page doesn't reload; added a mobile layout.
      ---
      Add a row of checkboxes above the product grid, one per allergen.

      - Ticking one updates the grid in a Turbo Frame with `?without=…`, without a full page load.
      - The choice shows as chips that can be removed one by one.
      - On a phone the checkboxes fold into a "Filter" sheet.

      | Allergen | Icon |
      |---|---|
      | gluten | 🌾 |
      | nuts | 🥜 |
      | milk | 🥛 |
    MD

    REMEMBER = <<~MD
      ---
      title: Remember the allergen choice
      kind: feature
      group: Allergen filter
      deps: ["Allergen checkboxes on the catalogue"]
      ---
      Keep the chosen allergens in a cookie for 90 days so returning customers see a safe catalogue straight away.

      Logged-in customers keep it on their account instead.
    MD

    SPAM = <<~MD
      ---
      title: Order confirmation email lands in spam
      kind: bug
      ---
      Gmail files the confirmation mail as spam since the move to the new mail provider: SPF passes, DKIM is missing.
    MD

    WRITER = <<~'RUBY'
      include Quartermaster
      dir = DATA_IN["dir"]
      day_ago = Time.now - 86_400
      File.write(File.join(dir, "02-allergen-checkboxes.md"), DATA_IN["ui_v1"])
      IssueDrafts.new("allergen-filter", clock: -> { day_ago }).read
      File.write(File.join(dir, "02-allergen-checkboxes.md"), DATA_IN["ui_v2"])
      IssueDrafts.new("allergen-filter").read
      drafts = Drafts.new("allergen-filter")
      DATA_IN["comments"].each { |c| drafts.put_issue_comment(c) }
    RUBY
  end
end

DemoWorld.step("issues") do |world|
  issues = DemoWorld::Issues
  dir = world.qm!("issues-dir", "allergen-filter").strip
  File.write(File.join(dir, "01-allergen-scope.md"), issues::SCOPE)
  File.write(File.join(dir, "03-remember-choice.md"), issues::REMEMBER)
  File.write(File.join(world.qm!("issues-dir", "checkout-flow").strip, "01-confirmation-spam.md"), issues::SPAM)
  title = "Allergen checkboxes on the catalogue"
  world.qm_ruby!(issues::WRITER, {
    "dir" => dir, "ui_v1" => issues::UI_V1, "ui_v2" => issues::UI_V2,
    "comments" => [
      { "file" => "02-allergen-checkboxes.md", "block" => "", "title" => title,
        "comment" => "Split the mobile sheet into its own issue — it needs a design first." },
      { "file" => "02-allergen-checkboxes.md", "title" => title,
        "block" => "- Ticking one updates the grid in a Turbo Frame with `?without=…`, without a full page load.",
        "comment" => "Keep `?without=` in the URL so a filtered catalogue can be shared." }
    ]
  })
end
