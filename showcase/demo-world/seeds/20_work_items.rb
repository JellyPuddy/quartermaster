# frozen_string_literal: true

# Eight work items over in_progress / fridge / resolved, written by qm's own
# WorkItem (in a child process, each write stamped on the day it happened):
# notes of every kind, branches, temp branches, sessions, a status board, a
# promoted aside, a distilled snapshot and a recorded rotation.
module DemoWorld
  module WorkItems
    SHOP = "Bakery webshop"
    DS = "Bakery design system"
    BOARD = "https://claude.ai/artifact/bk9GiftCardsBuildBoard"

    # [days ago, kind, text]; a :rotation entry records a rotation there.
    def self.specs(world)
      cast = world.cast
      [
        { "slug" => "gift-cards", "title" => "Gift cards: buy, email and redeem at checkout", "project" => SHOP, "created" => 5,
          "branches" => ["feature/gift-cards"], "sessions" => %w[gc1 gc2], "board" => BOARD, "touched" => 0,
          "description" => "Customers buy a gift card with a balance, the recipient gets it by email as a printable PDF, and " \
                           "redeems the code at checkout. Codes are unguessable; a card expires after a year.",
          "notes" => [[4, "decision", "Codes are 12-character has_secure_token values, never sequential."],
                      [4, "history", "Model, migration and redeem-at-checkout committed; 41 tests green."],
                      [3, "open", "Does finance want gift cards VAT-free at purchase and taxed on redemption? Ask Anouk before merging."],
                      [1, "decision", "The form shows the balance the server computed, never one computed in JS."],
                      [0, "history", "Email gift cards as a printable PDF — committed, pushed to PR #38."],
                      [0, "open", "Expiry isn't committed yet: PR #38 still shows cards without it."]] },
        { "slug" => "checkout-flow", "title" => "Checkout in three steps (stacked PRs)", "project" => SHOP, "created" => 6,
          "branches" => DemoWorld::Repos::STACK, "sessions" => %w[co1 co2], "touched" => 0,
          "description" => "Split the one-page checkout into address → payment → confirmation, one PR per step as a gh-stack " \
                           "stack: #41 ← #42 ← #43.",
          "notes" => [[6, "decision", "One PR per step, stacked: address-form ← payment-step ← order-confirmation."],
                      [6, "history", "Stack created; #41, #42 and #43 open, #43 as a draft."],
                      [3, "decision", "iDEAL first, card second — 80% of the orders pay with iDEAL."],
                      [2, "open", "#42 can't merge before the cart rounding fix (#36) is deployed — recorded with qm pr-requires."],
                      [0, "history", "Restacked payment-step onto the approved address form."]] },
        { "slug" => "delivery-slots", "title" => "Two-hour delivery windows", "project" => SHOP, "created" => 9,
          "branches" => ["feature/delivery-slots-v2"], "sessions" => %w[ds1 ds2 ds3], "touched" => 0,
          "description" => "Customers pick a two-hour delivery window instead of a whole day. Capacity is per window; full " \
                           "windows show greyed out. Windows are built in Europe/Amsterdam so DST nights just lose a window.",
          "notes" => [[9, "decision", "Windows are two hours; capacity is per window, not per day."],
                      [9, "decision", "Keep starts_at and derive the end from DeliverySlot::WINDOW."],
                      [9, "open", "Vans can't do the 07:00 window on Mondays — check with the bakery."],
                      [:rotation, cast["ds1"].id, cast["ds2"].start_at - 120],
                      [2, "history", "WINDOW constant and per-window capacity committed."],
                      [1, "decision", "aside: a tstzrange stores two instants, so a window across the DST switch stays exactly two hours."],
                      [0, "open", "Does a full window disappear or show greyed out? Built greyed out for now."]],
          "snapshots" => [[8, "ds1", "Goal: let customers choose a delivery window. Explored DeliverySlot and the vans' routes; " \
                                     "settled on two-hour windows with capacity per window. Next: implement WINDOW and the checkout list."]] },
        { "slug" => "button-variants", "title" => "Ghost and danger button variants", "project" => DS, "created" => 3,
          "branches" => ["feature/button-variants"], "sessions" => %w[bv1], "touched" => 0,
          "description" => "Button gets ghost and danger variants for the kiosk's cancel and delete flows.",
          "notes" => [[3, "decision", "Variants: primary, ghost, danger — no secondary, the brand guide drops it."],
                      [0, "history", "Variants implemented; visual regression run started in the background."]] },
        { "slug" => "cart-rounding", "title" => "Cart totals off by a cent", "project" => SHOP, "created" => 12, "state" => "resolved",
          "branches" => ["fix/cart-rounding"], "sessions" => %w[cr1], "touched" => 11,
          "description" => "Round every cart line, not the order total, as the receipt printer does.",
          "notes" => [[12, "decision", "Round per line, like the receipt printer."], [11, "history", "PR #36 merged."]] },
        { "slug" => "croissant-preorders", "title" => "Spike: croissant pre-orders for Sunday", "project" => SHOP, "created" => 15,
          "state" => "fridge", "temp_branches" => ["worktree-croissant-spike"], "sessions" => %w[cp1], "touched" => 15,
          "description" => "Could customers pre-order croissants on Saturday for a Sunday-morning pick-up? Spike only.",
          "notes" => [[15, "decision", "Pre-orders close Saturday 18:00 for a Sunday pick-up."],
                      [15, "open", "Waiting on the bakery: is 18:00 really the cut-off?"]] },
        { "slug" => "allergen-filter", "title" => "Filter the catalogue by allergen", "project" => SHOP, "created" => 28,
          "sessions" => %w[af1 af2 af3], "touched" => 12,
          "description" => "Let customers hide products with allergens they avoid. Drafted as three issues; #57 is on GitHub.",
          "notes" => [[28, "decision", "Products already carry allergens; the filter is a scope plus checkboxes."],
                      [24, "history", "Three issues drafted for review in the Issues pane."],
                      [12, "history", "#57 created on GitHub."],
                      [12, "open", "Which issue goes first — the scope (#57) or the filter UI?"]],
          "snapshots" => [[28, "af1", "Goal: an allergen filter. Products store allergens as an array; a filter is a " \
                                      "`without_allergens` scope plus checkboxes on the catalogue. Next: draft issues."]] },
        { "slug" => "dark-mode-tokens", "title" => "Dark mode tokens for the kiosk", "project" => DS, "created" => 6, "state" => "fridge",
          "branches" => ["feature/color-tokens"], "sessions" => %w[dm1], "touched" => 6,
          "description" => "The in-store kiosk runs dark at night; it needs its own colour tokens.",
          "notes" => [[6, "decision", "Kiosk dark mode is its own token file, switched by data-theme."],
                      [6, "open", "The crust colour fails contrast on dark flour — needs the designer."]] }
      ].map { |spec| resolve(world, spec) }
    end

    def self.resolve(world, spec)
      cast = world.cast
      day = ->(days) { (world.now.to_date - days).to_s }
      spec.merge("created" => day.(spec["created"]),
                 "sessions" => spec["sessions"].map { |name| cast[name].id },
                 "notes" => spec["notes"].map do |a, b, c|
                   a == :rotation ? { "rotation" => b, "at" => c.utc.iso8601 } : { "day" => day.(a), "kind" => b, "text" => c }
                 end,
                 "snapshots" => (spec["snapshots"] || []).map { |d, name, text| { "day" => day.(d), "session" => cast[name].id, "text" => text } },
                 "touched" => (world.now - (spec["touched"] * 86_400)).to_i)
    end

    WRITER = <<~RUBY
      DATA_IN["items"].each do |spec|
        item = on_day(spec["created"]) do
          Quartermaster::WorkItem.create(spec["slug"], project: spec["project"], description: spec["description"])
        end
        item.retitle(spec["title"])
        Array(spec["branches"]).each { |branch| item.link_branch(branch) }
        Array(spec["temp_branches"]).each { |branch| item.add_temp_branch(branch) }
        spec["sessions"].each { |id| item.attach_session(id) }
        item.link_board(spec["board"], answers_dir: DATA_IN["answers_dir"]) if spec["board"]
        spec["notes"].each do |note|
          if note["rotation"]
            item.record_rotation(from_session: note["rotation"], via: "distill", at: Time.parse(note["at"]))
          else
            on_day(note["day"]) { item.add_note(note["text"], kind: note["kind"]) }
          end
        end
        spec["snapshots"].each { |s| on_day(s["day"]) { item.add_snapshot(s["session"], s["text"]) } }
        item.update_state(spec["state"]) if spec["state"]
      end
    RUBY
  end
end

DemoWorld.step("work-items") do |world|
  specs = DemoWorld::WorkItems.specs(world)
  world.qm_ruby!(DemoWorld::WorkItems::WRITER, { "items" => specs, "answers_dir" => File.join(world.root, "board-answers") })
  specs.each do |spec|
    path = File.join(world.work_items_dir, "#{spec["slug"]}.md")
    File.utime(spec["touched"], spec["touched"], path)
  end
end
