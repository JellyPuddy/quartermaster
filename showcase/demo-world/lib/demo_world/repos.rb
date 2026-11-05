# frozen_string_literal: true

module DemoWorld
  # The two git repos of the fictional Bakery webshop: history on main,
  # feature branches, worktrees under .claude/worktrees, a merged spike
  # cleanup can remove, and a three-layer gh-stack stack. origin is a GitHub
  # URL that is never fetched (the world's gitconfig refuses https and ssh);
  # its refs are written locally.
  class Repos
    MARA = ["Mara de Vries", "mara@bakery.example"].freeze
    TOM = ["Tom Bakker", "tom@bakery.example"].freeze

    # PR numbers the next seeding steps' gh fixtures answer for.
    PULLS = {
      "bakery-shop" => {
        "fix/cart-rounding" => 36, "feature/gift-cards" => 38,
        "checkout/address-form" => 41, "checkout/payment-step" => 42, "checkout/order-confirmation" => 43
      },
      "bakery-design-system" => { "feature/button-variants" => 12 }
    }.freeze
    STACK = %w[checkout/address-form checkout/payment-step checkout/order-confirmation].freeze
    WORKTREES = {
      "bakery-shop" => {
        "gift-cards" => "feature/gift-cards", "delivery-slots-v2" => "feature/delivery-slots-v2",
        "checkout-flow" => "checkout/order-confirmation", "croissant-spike" => "worktree-croissant-spike"
      },
      "bakery-design-system" => { "button-variants" => "feature/button-variants" }
    }.freeze

    def initialize(world, now: Time.now)
      @world = world
      @now = now
    end

    def build
      shop
      design_system
    end

    def self.pull_url(repo, number) = "https://github.com/#{GITHUB_OWNER}/#{repo}/pull/#{number}"

    private

    def shop
      init("bakery-shop")
      commit(30, MARA, "Initial Rails app for the bakery webshop", SHOP_INITIAL)
      commit(27, TOM, "Add Product model and catalogue page", SHOP_PRODUCTS)
      commit(24, MARA, "Keep the cart in the session", SHOP_CART)
      commit(20, TOM, "Show allergens on product cards",
             "app/views/products/_card.html.erb" => <<~ERB)
               <article class="product-card">
                 <h3><%= product.name %></h3>
                 <p class="price"><%= number_to_currency(product.price) %></p>
                 <p class="allergens"><%= product.allergens.join(", ") %></p>
               </article>
             ERB
      commit(17, MARA, "Checkout: collect the address, pick-up or delivery", SHOP_CHECKOUT)
      spike = head
      commit(14, MARA, "Delivery slots per bakery location", SHOP_SLOTS)
      commit(10, TOM, "Stop sourdough stock going negative after refunds",
             "app/models/product.rb" => PRODUCT_RB.sub("  def restock", "  def refund(quantity)\n    update!(stock: stock + quantity)\n  end\n\n  def restock"))
      commit(6, MARA, "Bump Rails to 7.2", "Gemfile" => GEMFILE.sub('"~> 7.1"', '"~> 7.2"'))
      main = head

      branch("worktree-croissant-spike", spike)
      branch("fix/cart-rounding", main)
      commit(5, TOM, "Round cart totals per line, not per order",
             "app/models/cart.rb" => CART_RB.sub("lines.sum(&:total)", "lines.sum { |line| line.total.round(2) }"))
      branch("feature/gift-cards", main)
      commit(4, MARA, "Add GiftCard with a balance", "app/models/gift_card.rb" => GIFT_CARD_RB)
      commit(3, MARA, "Redeem gift cards at checkout",
             "app/controllers/checkouts_controller.rb" => CHECKOUT_RB.sub("  def create\n", "  def create\n    redeem_gift_card(params[:gift_card_code])\n"))
      commit(1, MARA, "Email gift cards as a printable PDF",
             "app/mailers/gift_card_mailer.rb" => "class GiftCardMailer < ApplicationMailer\n  def purchased(gift_card)\n    @gift_card = gift_card\n    attachments[\"gift-card.pdf\"] = GiftCardPdf.new(gift_card).render\n    mail(to: gift_card.recipient_email, subject: \"A treat from De Bakkerij\")\n  end\nend\n")
      branch("feature/delivery-slots-v2", main)
      commit(2, MARA, "Let customers pick a two-hour delivery window",
             "app/models/delivery_slot.rb" => SLOT_RB.sub("validates :starts_at", "WINDOW = 2.hours\n\n  validates :starts_at"))
      stack(main)
      checkout("main")
      push_all
      worktrees
    end

    def design_system
      init("bakery-design-system")
      commit(40, TOM, "Initial design tokens and button component", DS_INITIAL)
      commit(35, TOM, "Add card and badge components",
             "src/components/Card.tsx" => "export function Card({ children }: { children: React.ReactNode }) {\n  return <div className=\"bk-card\">{children}</div>;\n}\n",
             "src/components/Badge.tsx" => "export function Badge({ label }: { label: string }) {\n  return <span className=\"bk-badge\">{label}</span>;\n}\n")
      commit(21, MARA, "Warm colour palette for the bakery brand", "src/tokens.css" => TOKENS_CSS.sub("#333", "#5b3a29"))
      commit(9, TOM, "Accessible focus rings", "src/components/Button.css" => ".bk-button:focus-visible {\n  outline: 3px solid var(--crust);\n  outline-offset: 2px;\n}\n")
      main = head
      branch("feature/color-tokens", main)
      commit(6, TOM, "Dark mode tokens", "src/tokens-dark.css" => ":root[data-theme=dark] {\n  --flour: #1f1a17;\n  --crust: #e0a96d;\n}\n")
      branch("feature/button-variants", main)
      commit(2, MARA, "Ghost and danger button variants", "src/components/Button.tsx" => BUTTON_TSX.sub('"primary"', '"primary" | "ghost" | "danger"'))
      checkout("main")
      push_all
      worktrees
    end

    def stack(main)
      parent = main
      STACK.each_with_index do |name, i|
        branch(name, parent)
        commit(3 - i, MARA, STACK_COMMITS.fetch(name), STACK_FILES.fetch(name))
        parent = head
      end
      @world.write_json(File.join(@path, ".git", "gh-stack"), {
        "stacks" => [{
          "trunk" => { "branch" => "main" },
          "branches" => STACK.map do |name|
            number = PULLS.fetch("bakery-shop").fetch(name)
            { "branch" => name, "pullRequest" => { "number" => number, "url" => Repos.pull_url("bakery-shop", number) } }
          end
        }]
      })
    end

    def init(name)
      @name = name
      @path = @world.repo(name)
      FileUtils.mkdir_p(@path)
      git("init", "--quiet", "--initial-branch=main")
      git("remote", "add", "origin", "https://github.com/#{GITHUB_OWNER}/#{name}.git")
      File.write(File.join(@path, ".git", "info", "exclude"), ".claude/worktrees/\n", mode: "a")
    end

    # files: path => content (nil deletes).
    def commit(days_ago, author, message, files)
      files.each do |rel, content|
        full = File.join(@path, rel)
        if content.nil?
          FileUtils.rm_f(full)
        else
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
      end
      git("add", "-A")
      date = (@now - (days_ago * 86_400) - 3600).strftime("%Y-%m-%dT%H:%M:%S%z")
      git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", message,
          extra_env: { "GIT_AUTHOR_NAME" => author[0], "GIT_AUTHOR_EMAIL" => author[1], "GIT_AUTHOR_DATE" => date,
                       "GIT_COMMITTER_NAME" => author[0], "GIT_COMMITTER_EMAIL" => author[1], "GIT_COMMITTER_DATE" => date })
    end

    def head = git("rev-parse", "HEAD").strip
    def branch(name, at) = git("checkout", "--quiet", "-B", name, at)
    def checkout(name) = git("checkout", "--quiet", name)

    # Every branch except worktree-* is "pushed": origin/<branch> at its tip, tracked.
    def push_all
      git("for-each-ref", "--format=%(refname:short)", "refs/heads").split("\n").each do |name|
        next if name.start_with?("worktree-")

        git("update-ref", "refs/remotes/origin/#{name}", "refs/heads/#{name}")
        git("config", "branch.#{name}.remote", "origin")
        git("config", "branch.#{name}.merge", "refs/heads/#{name}")
      end
      git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    end

    def worktrees
      WORKTREES.fetch(@name).each do |dir, name|
        git("worktree", "add", "--quiet", File.join(@path, ".claude", "worktrees", dir), name)
      end
    end

    def git(*args, extra_env: {}) = @world.run!("git", *args, chdir: @path, extra_env: extra_env)
  end
end

require_relative "repo_files"
