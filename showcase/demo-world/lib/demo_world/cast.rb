# frozen_string_literal: true

module DemoWorld
  # Every session of the demo world, scripted relative to the seed time so
  # the world never looks stale: which item it served, where it ran, what was
  # said, and whether it is still running (a tmux chat the chats step starts).
  # The seeding steps all read this one cast, so ids and times agree across
  # sessions.jsonl, transcripts, events, work items and prompt snapshots.
  class Cast
    # pane: the tmux session the live chat runs in (the item's slug, or
    # <slug>--aside for an aside); nil once the session ended.
    Session = Struct.new(:name, :item, :aside, :project, :transcript, :start_at, :end_at, :pane, :model,
                         :prompt_ats, keyword_init: true) do
      def id = transcript.id
      def cwd = transcript.cwd
      def branch = transcript.branch
      def live? = !pane.nil?
    end

    def self.uuid(name)
      hex = Digest::MD5.hexdigest("bakery-#{name}")
      [hex[0, 8], hex[8, 4], "4#{hex[13, 3]}", "a#{hex[17, 3]}", hex[20, 12]].join("-")
    end

    attr_reader :sessions

    def initialize(world)
      @world = world
      @now = world.now
      @sessions = []
      gift_cards
      checkout_flow
      delivery_slots
      button_variants
      quieter_items
      inbox
    end

    def [](name) = @sessions.find { |s| s.name == name } || raise(KeyError, "no session #{name}")
    def for_item(slug) = @sessions.select { |s| s.item == slug }
    def ago(days: 0, hours: 0, minutes: 0) = @now - (days * 86_400) - (hours * 3600) - (minutes * 60)

    private

    def shop = @world.repo("bakery-shop")
    def ds = @world.repo("bakery-design-system")

    # A session script: the block gets the Transcript and a clock `m.(n)` =
    # start + n minutes.
    def session(name, item:, cwd:, branch:, start:, project: "Bakery webshop", pane: nil, aside: nil,
                model: Transcript::MODEL, ends_after: nil)
      t = Transcript.new(id: Cast.uuid(name), cwd: cwd, branch: branch, model: model)
      prompts = []
      clock = ->(n) { start + (n * 60).round }
      yield t, clock, prompts
      end_at = pane ? nil : (t.last_at || start) + (ends_after || 90)
      @sessions << Session.new(name: name, item: item, aside: aside, project: project, transcript: t, start_at: start,
                               end_at: end_at, pane: pane, model: model, prompt_ats: prompts)
    end

    def gift_cards
      wt = @world.worktree("bakery-shop", "gift-cards")
      session("gc1", item: "gift-cards", cwd: wt, branch: "feature/gift-cards", start: ago(days: 4, hours: 2)) do |t, m|
        t.prompt(m.(0), "Add gift cards: customers buy one with a balance, and the code must be unguessable.")
        t.tool(m.(1), "Read", { "file_path" => "#{wt}/app/models/product.rb" }, ctx: 21_000)
        t.tool(m.(2), "Write", { "file_path" => "#{wt}/app/models/gift_card.rb" }, ctx: 24_000)
        t.work(m.(2.2), m.(3.9), 30, ctx: 24_000..27_000, files: %w[app/models/gift_card.rb app/controllers/checkouts_controller.rb app/models/cart.rb app/views/checkouts/new.html.erb].map { |f| "#{wt}/#{f}" })
        t.tool(m.(4), "Bash", { "command" => "bin/rails g migration CreateGiftCards code:string:uniq balance:decimal", "description" => "Generate the migration" }, ctx: 27_000)
        t.tool(m.(6), "Bash", { "command" => "bin/rails test test/models/gift_card_test.rb" }, ctx: 30_000, result: "5 runs, 9 assertions, 0 failures")
        t.say(m.(7), "Added `GiftCard` with a 12-character `has_secure_token` code and a non-negative balance. " \
                     "`redeem!` refuses to go below zero. Tests are green (5 runs).", ctx: 31_000)
        t.stop(m.(7))
        t.prompt(m.(30), "Now let customers redeem a code at checkout.")
        t.tool(m.(31), "Edit", { "file_path" => "#{wt}/app/controllers/checkouts_controller.rb" }, ctx: 38_000)
        t.tool(m.(33), "Bash", { "command" => "bin/rails test test/controllers/checkouts_controller_test.rb" }, ctx: 41_000)
        t.say(m.(34), "Checkout now takes an optional gift card code and redeems it before payment; the rest goes to Mollie as before.", ctx: 42_000)
        t.stop(m.(34))
      end
      session("gc2", item: "gift-cards", cwd: wt, branch: "feature/gift-cards", start: ago(minutes: 52), pane: "gift-cards") do |t, m, p|
        p << m.(0)
        t.prompt(m.(0), "Email the gift card to the recipient as a printable PDF.")
        t.tool(m.(1), "Read", { "file_path" => "#{wt}/app/models/gift_card.rb" }, ctx: 64_000)
        t.tool(m.(3), "Write", { "file_path" => "#{wt}/app/mailers/gift_card_mailer.rb" }, ctx: 71_000)
        t.tool(m.(6), "Bash", { "command" => "bin/rails test test/mailers" }, ctx: 78_000, result: "3 runs, 6 assertions, 0 failures")
        t.tool(m.(7), "Bash", { "command" => "git commit -am 'Email gift cards as a printable PDF'" }, ctx: 80_000)
        t.say(m.(8), "The mailer attaches `gift-card.pdf` rendered by `GiftCardPdf` and is committed.", ctx: 81_000)
        t.stop(m.(8))
        p << m.(24)
        t.prompt(m.(24), "Cards should expire after a year, and the form should show the remaining balance.")
        t.tool(m.(25), "Edit", { "file_path" => "#{wt}/app/models/gift_card.rb" }, ctx: 96_000)
        t.tool(m.(28), "Write", { "file_path" => "#{wt}/app/javascript/components/GiftCardForm.jsx" }, ctx: 104_000)
        t.tool(m.(31), "Bash", { "command" => "bin/rails test" }, ctx: 112_000, result: "48 runs, 131 assertions, 0 failures")
        t.work(m.(31.5), m.(37.5), 50, ctx: 112_000..118_000, files: %w[app/models/gift_card.rb app/controllers/checkouts_controller.rb app/models/cart.rb app/views/checkouts/new.html.erb].map { |f| "#{wt}/#{f}" })
        t.say(m.(38), "Done:\n\n- `GiftCard` gets `expires_at` (one year from purchase) and `redeem!` refuses an expired card.\n" \
                      "- `GiftCardForm` shows the balance left after this order.\n\nAll 48 tests pass. Not committed yet — " \
                      "want me to commit and push so PR #38 picks it up?", ctx: 118_400)
        t.stop(m.(38))
      end
    end

    def checkout_flow
      root = @world.worktree("bakery-shop", "checkout-flow")
      session("co1", item: "checkout-flow", cwd: shop, branch: "main", start: ago(days: 6, hours: 4)) do |t, m|
        t.prompt(m.(0), "The checkout is one long form. Split it into address, payment and confirmation steps, one PR each as a gh stack.")
        t.tool(m.(2), "Skill", { "skill" => "gh-stack" }, ctx: 18_000)
        t.tool(m.(4), "Bash", { "command" => "gh stack init checkout/address-form" }, ctx: 22_000)
        t.work(m.(5), m.(39), 60, ctx: 22_000..57_000, files: %w[app/controllers/checkouts_controller.rb app/controllers/payments_controller.rb app/views/orders/show.html.erb app/mailers/order_mailer.rb].map { |f| "#{shop}/#{f}" })
        t.say(m.(40), "The stack has three layers: `checkout/address-form` ← `checkout/payment-step` ← `checkout/order-confirmation`. " \
                      "PRs #41, #42 and #43 are open; #43 is a draft until the email copy is final.", ctx: 57_000)
        t.stop(m.(40))
      end
      session("co2", item: "checkout-flow", cwd: root, branch: "checkout/order-confirmation", start: ago(minutes: 26), pane: "checkout-flow") do |t, m|
        t.prompt(m.(0), "Tom approved the address form. Restack the payment step on it and push the stack.")
        t.tool(m.(1), "Bash", { "command" => "gh stack sync" }, ctx: 61_000)
        t.tool(m.(4), "Bash", { "command" => "bin/rails test test/controllers/payments_controller_test.rb" }, ctx: 63_000)
        t.say(m.(20), "Restacked cleanly and the payment tests pass. Pushing needs a force-push of all three layers.", ctx: 64_200)
        t.tool(m.(23), "Bash", { "command" => "gh stack push --force-with-lease", "description" => "Push the restacked layers" }, ctx: 64_900, pending: true)
      end
    end

    def delivery_slots
      wt = @world.worktree("bakery-shop", "delivery-slots-v2")
      session("ds1", item: "delivery-slots", cwd: wt, branch: "feature/delivery-slots-v2", start: ago(days: 9, hours: 5)) do |t, m|
        t.prompt(m.(0), "Customers want to pick a delivery window instead of a whole day. Explore what that means for DeliverySlot.")
        t.tool(m.(2), "Grep", { "pattern" => "DeliverySlot", "path" => wt }, ctx: 40_000)
        t.tool(m.(5), "Read", { "file_path" => "#{wt}/app/models/delivery_slot.rb" }, ctx: 52_000)
        t.work(m.(6), m.(89), 80, ctx: 52_000..191_000, files: %w[app/models/delivery_slot.rb app/controllers/checkouts_controller.rb app/views/checkouts/new.html.erb db/schema.rb].map { |f| "#{wt}/#{f}" })
        t.say(m.(90), "Two-hour windows fit the vans' routes; capacity should be per window, not per day. " \
                      "I'd keep `starts_at` and derive the end from a WINDOW constant.", ctx: 191_000)
        t.stop(m.(90))
      end
      session("ds2", item: "delivery-slots", cwd: wt, branch: "feature/delivery-slots-v2", start: ago(days: 2, hours: 3)) do |t, m|
        t.prompt(m.(0), "Implement the two-hour WINDOW and let checkout show the windows that still have room.")
        t.tool(m.(3), "Edit", { "file_path" => "#{wt}/app/models/delivery_slot.rb" }, ctx: 34_000)
        t.work(m.(4), m.(8.5), 20, ctx: 34_000..41_000, files: %w[app/models/delivery_slot.rb app/controllers/checkouts_controller.rb app/views/checkouts/new.html.erb db/schema.rb].map { |f| "#{wt}/#{f}" })
        t.tool(m.(9), "Bash", { "command" => "bin/rails test test/models/delivery_slot_test.rb" }, ctx: 41_000)
        t.say(m.(12), "WINDOW is two hours and `full?` counts orders per window. Committed as \"Let customers pick a two-hour delivery window\".", ctx: 43_000)
        t.stop(m.(12))
      end
      session("ds3", item: "delivery-slots", cwd: wt, branch: "feature/delivery-slots-v2", start: ago(hours: 5), pane: "delivery-slots") do |t, m|
        t.prompt(m.(0), "Show the windows on the checkout page, greyed out when full, and handle the DST switch on Sunday.")
        t.tool(m.(4), "Read", { "file_path" => "#{wt}/app/views/checkouts/new.html.erb" }, ctx: 82_000)
        t.work(m.(5), m.(39), 30, ctx: 82_000..141_000, files: %w[app/models/delivery_slot.rb app/controllers/checkouts_controller.rb app/views/checkouts/new.html.erb db/schema.rb].map { |f| "#{wt}/#{f}" })
        t.tool(m.(40), "Edit", { "file_path" => "#{wt}/app/views/checkouts/_delivery_windows.html.erb" }, ctx: 141_000)
        t.work(m.(41), m.(119), 90, ctx: 141_000..198_000, files: %w[app/models/delivery_slot.rb app/controllers/checkouts_controller.rb app/views/checkouts/new.html.erb db/schema.rb].map { |f| "#{wt}/#{f}" })
        t.say(m.(120), "Windows render greyed out when full. Around the DST switch I build windows in Europe/Amsterdam, so the 02:00–04:00 window " \
                       "simply doesn't exist that night.", ctx: 198_000)
        t.stop(m.(120))
        t.prompt(m.(296), "Add a system test that books the last place in a window.")
        t.tool(m.(297), "Write", { "file_path" => "#{wt}/test/system/delivery_windows_test.rb" }, ctx: 231_000)
        t.tool(m.(298), "Bash", { "command" => "bin/rails test:system TEST=test/system/delivery_windows_test.rb" }, ctx: 236_500, result: "running…")
      end
      session("aside1", item: nil, aside: "delivery-slots", cwd: wt, branch: "feature/delivery-slots-v2", start: ago(days: 1, hours: 2),
                        model: "claude-sonnet-5-5") do |t, m|
        t.prompt(m.(0), "Does Postgres tstzrange handle the DST switch for a two-hour window?")
        t.say(m.(1), "Yes — a `tstzrange` stores two instants, so a window crossing the switch is still exactly two hours long. " \
                     "Build the bounds in the shop's time zone and store them as timestamptz.", ctx: 12_000)
      end
      session("aside2", item: nil, aside: "delivery-slots", cwd: wt, branch: "feature/delivery-slots-v2", start: ago(minutes: 7),
                        pane: "delivery-slots--aside", model: "claude-sonnet-5-5") do |t, m|
        t.prompt(m.(0), "What's the Rails way to validate that two delivery windows of one location don't overlap?")
        t.say(m.(1), "Use an exclusion constraint in Postgres (`EXCLUDE USING gist (location_id WITH =, window WITH &&)`) and rescue " \
                     "`ActiveRecord::StatementInvalid` into a validation error — a Ruby-only validation races.", ctx: 13_500)
      end
    end

    def button_variants
      wt = @world.worktree("bakery-design-system", "button-variants")
      session("bv1", item: "button-variants", cwd: wt, branch: "feature/button-variants", start: ago(minutes: 41),
                     project: "Bakery design system", pane: "button-variants") do |t, m|
        t.prompt(m.(0), "Add ghost and danger variants to Button, then run the visual regression suite in the background.")
        t.tool(m.(2), "Edit", { "file_path" => "#{wt}/src/components/Button.tsx" }, ctx: 71_000)
        t.tool(m.(5), "Edit", { "file_path" => "#{wt}/src/components/Button.css" }, ctx: 79_000)
        t.work(m.(6), m.(29), 30, ctx: 79_000..91_000, files: %w[src/components/Button.tsx src/components/Button.css src/tokens.css].map { |f| "#{wt}/#{f}" })
        t.background_agent(m.(30), "a7f3c2e91b", "Run visual regression snapshots for Button", ctx: 91_000)
        t.say(m.(31), "Both variants are in. The visual regression run is going in the background; I'll report when it's done.", ctx: 92_300)
        t.stop(m.(31))
      end
    end

    def quieter_items
      session("cr1", item: "cart-rounding", cwd: shop, branch: "fix/cart-rounding", start: ago(days: 12, hours: 6)) do |t, m|
        t.prompt(m.(0), "A customer was charged €12.01 for €12.00 of bread. Find out why.")
        t.tool(m.(3), "Read", { "file_path" => "#{shop}/app/models/cart.rb" }, ctx: 22_000)
        t.say(m.(20), "The cart summed unrounded line totals. Rounding per line fixes it — PR #36.", ctx: 35_000)
        t.stop(m.(20))
      end
      spike = @world.worktree("bakery-shop", "croissant-spike")
      session("cp1", item: "croissant-preorders", cwd: spike, branch: "worktree-croissant-spike", start: ago(days: 15, hours: 1)) do |t, m|
        t.prompt(m.(0), "Spike: could customers pre-order croissants for Sunday morning on Saturday?")
        t.say(m.(25), "It works with a `preorder_until` on Product and a pick-up slot; the bakery needs to confirm the cut-off time.", ctx: 48_000)
        t.stop(m.(25))
      end
      session("af1", item: "allergen-filter", cwd: shop, branch: "main", start: ago(days: 28)) do |t, m|
        t.prompt(m.(0), "Customers ask to hide everything with nuts. What would an allergen filter take?")
        t.say(m.(10), "Products already store allergens; a filter is a scope plus checkboxes.", ctx: 20_000)
        t.stop(m.(10))
      end
      session("af2", item: "allergen-filter", cwd: shop, branch: "main", start: ago(days: 24)) do |t, m|
        t.prompt(m.(0), "Draft the issues for the allergen filter.")
        t.say(m.(15), "Drafted three issues in the Issues pane: the scope, the filter UI and remembering the choice.", ctx: 33_000)
        t.stop(m.(15))
      end
      session("af3", item: "allergen-filter", cwd: shop, branch: "main", start: ago(days: 12, hours: 3)) do |t, m|
        t.prompt(m.(0), "Create the first issue on GitHub.")
        t.say(m.(4), "Created #57 \"Filter products by allergen\".", ctx: 26_000)
        t.stop(m.(4))
      end
      session("dm1", item: "dark-mode-tokens", cwd: ds, branch: "feature/color-tokens", start: ago(days: 6, hours: 2),
                     project: "Bakery design system") do |t, m|
        t.prompt(m.(0), "Add dark mode tokens for the kiosk.")
        t.say(m.(14), "Added `tokens-dark.css`; the crust colour needs a lighter tone to pass contrast on dark flour.", ctx: 29_000)
        t.stop(m.(14))
      end
    end

    def inbox
      session("in1", item: nil, cwd: shop, branch: "main", start: ago(days: 1, hours: 4)) do |t, m|
        t.prompt(m.(0), "Why does bin/dev print a Mollie webhook warning on boot?")
        t.say(m.(3), "The webhook URL is built from `APP_HOST`, which bin/dev doesn't set. Harmless locally.", ctx: 19_000)
        t.stop(m.(3))
      end
      session("in2", item: nil, cwd: @world.home, branch: nil, start: ago(hours: 3), project: "No project") do |t, m|
        t.prompt(m.(0), "Explain Turbo Frames vs Turbo Streams in two paragraphs for a colleague.")
        t.say(m.(2), "Frames scope navigation to part of a page; Streams push changes to any part of it, often over a socket.", ctx: 9_000)
        t.stop(m.(2))
      end
    end
  end
end
