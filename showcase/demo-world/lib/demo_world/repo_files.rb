# frozen_string_literal: true

module DemoWorld
  # File contents the Bakery repos' history is made of: small, Rails-ish and
  # believable on screen in a diff pane.
  class Repos
    GEMFILE = <<~RUBY
      source "https://rubygems.org"

      gem "rails", "~> 7.1"
      gem "pg"
      gem "puma"
      gem "turbo-rails"
      gem "stimulus-rails"
      gem "mollie-api-ruby"
    RUBY

    PRODUCT_RB = <<~RUBY
      class Product < ApplicationRecord
        ALLERGENS = %w[gluten milk eggs nuts sesame soy].freeze

        has_many :order_lines
        validates :name, :price, presence: true
        validates :stock, numericality: { greater_than_or_equal_to: 0 }

        scope :available, -> { where("stock > 0") }

        def restock(quantity)
          update!(stock: stock + quantity)
        end
      end
    RUBY

    CART_RB = <<~RUBY
      class Cart
        Line = Struct.new(:product, :quantity) do
          def total = product.price * quantity
        end

        def initialize(session)
          @session = session
          @session[:cart] ||= {}
        end

        def add(product, quantity = 1)
          @session[:cart][product.id.to_s] = @session[:cart].fetch(product.id.to_s, 0) + quantity
        end

        def lines
          Product.where(id: @session[:cart].keys).map { |p| Line.new(p, @session[:cart][p.id.to_s]) }
        end

        def total
          lines.sum(&:total)
        end
      end
    RUBY

    CHECKOUT_RB = <<~RUBY
      class CheckoutsController < ApplicationController
        def new
          @checkout = Checkout.new(cart: current_cart)
        end

        def create
          @checkout = Checkout.new(checkout_params.merge(cart: current_cart))
          if @checkout.save
            redirect_to @checkout.payment_url, allow_other_host: true
          else
            render :new, status: :unprocessable_entity
          end
        end

        private

        def checkout_params
          params.require(:checkout).permit(:name, :email, :street, :postcode, :city, :fulfilment)
        end
      end
    RUBY

    SLOT_RB = <<~RUBY
      class DeliverySlot < ApplicationRecord
        belongs_to :location
        has_many :orders

        validates :starts_at, :capacity, presence: true

        scope :upcoming, -> { where("starts_at > ?", Time.current).order(:starts_at) }

        def full? = orders.count >= capacity
      end
    RUBY

    GIFT_CARD_RB = <<~RUBY
      class GiftCard < ApplicationRecord
        has_secure_token :code, length: 12
        validates :balance, numericality: { greater_than_or_equal_to: 0 }

        def redeem!(amount)
          raise ArgumentError, "not enough balance" if amount > balance

          update!(balance: balance - amount)
        end
      end
    RUBY

    SHOP_INITIAL = {
      "Gemfile" => GEMFILE,
      "README.md" => "# Bakery webshop\n\nOrder bread, pastries and cakes from De Bakkerij online: pick up in store or have it delivered.\n",
      "config/routes.rb" => "Rails.application.routes.draw do\n  root \"products#index\"\nend\n",
      "app/controllers/application_controller.rb" => "class ApplicationController < ActionController::Base\nend\n"
    }.freeze

    SHOP_PRODUCTS = {
      "app/models/product.rb" => PRODUCT_RB,
      "db/migrate/20260901093000_create_products.rb" => <<~RUBY,
        class CreateProducts < ActiveRecord::Migration[7.1]
          def change
            create_table :products do |t|
              t.string :name, null: false
              t.decimal :price, precision: 8, scale: 2, null: false
              t.integer :stock, null: false, default: 0
              t.string :allergens, array: true, default: []
              t.timestamps
            end
          end
        end
      RUBY
      "app/controllers/products_controller.rb" => "class ProductsController < ApplicationController\n  def index\n    @products = Product.available.order(:name)\n  end\nend\n",
      "app/views/products/index.html.erb" => "<h1>Fresh today</h1>\n<%= render partial: \"products/card\", collection: @products, as: :product %>\n",
      "app/views/products/_card.html.erb" => "<article class=\"product-card\">\n  <h3><%= product.name %></h3>\n  <p class=\"price\"><%= number_to_currency(product.price) %></p>\n</article>\n",
      "config/routes.rb" => "Rails.application.routes.draw do\n  root \"products#index\"\n  resources :products, only: %i[index show]\nend\n"
    }.freeze

    SHOP_CART = {
      "app/models/cart.rb" => CART_RB,
      "app/controllers/carts_controller.rb" => "class CartsController < ApplicationController\n  def update\n    current_cart.add(Product.find(params[:product_id]), params.fetch(:quantity, 1).to_i)\n    redirect_back fallback_location: root_path\n  end\nend\n"
    }.freeze

    SHOP_CHECKOUT = {
      "app/controllers/checkouts_controller.rb" => CHECKOUT_RB,
      "config/routes.rb" => "Rails.application.routes.draw do\n  root \"products#index\"\n  resources :products, only: %i[index show]\n  resource :cart, only: :update\n  resource :checkout, only: %i[new create]\nend\n"
    }.freeze

    SHOP_SLOTS = {
      "app/models/delivery_slot.rb" => SLOT_RB,
      "db/migrate/20260920141500_create_delivery_slots.rb" => <<~RUBY
        class CreateDeliverySlots < ActiveRecord::Migration[7.1]
          def change
            create_table :delivery_slots do |t|
              t.references :location, null: false, foreign_key: true
              t.datetime :starts_at, null: false
              t.integer :capacity, null: false, default: 8
              t.timestamps
            end
          end
        end
      RUBY
    }.freeze

    STACK_COMMITS = {
      "checkout/address-form" => "Extract the address form into its own checkout step",
      "checkout/payment-step" => "Payment step with iDEAL and card",
      "checkout/order-confirmation" => "Order confirmation page and email"
    }.freeze

    STACK_FILES = {
      "checkout/address-form" => {
        "app/views/checkouts/_address.html.erb" => "<fieldset>\n  <%= form.text_field :street %>\n  <%= form.text_field :postcode %>\n  <%= form.text_field :city %>\n</fieldset>\n"
      },
      "checkout/payment-step" => {
        "app/controllers/payments_controller.rb" => "class PaymentsController < ApplicationController\n  METHODS = %w[ideal creditcard].freeze\n\n  def create\n    payment = Mollie::Payment.create(amount: current_order.amount, method: params[:method])\n    redirect_to payment.checkout_url, allow_other_host: true\n  end\nend\n"
      },
      "checkout/order-confirmation" => {
        "app/views/orders/show.html.erb" => "<h1>Thank you, <%= @order.name %>!</h1>\n<p>Your order #<%= @order.number %> is confirmed.</p>\n",
        "app/mailers/order_mailer.rb" => "class OrderMailer < ApplicationMailer\n  def confirmed(order)\n    @order = order\n    mail(to: order.email, subject: \"Your order at De Bakkerij\")\n  end\nend\n"
      }
    }.freeze

    TOKENS_CSS = ":root {\n  --flour: #fdf8f0;\n  --crust: #b5651d;\n  --ink: #333;\n}\n"
    BUTTON_TSX = <<~TSX
      type Variant = "primary";

      export function Button({ variant = "primary", ...props }: { variant?: Variant } & React.ButtonHTMLAttributes<HTMLButtonElement>) {
        return <button className={`bk-button bk-button--${variant}`} {...props} />;
      }
    TSX

    DS_INITIAL = {
      "package.json" => "{\n  \"name\": \"@bakery/design-system\",\n  \"version\": \"0.4.0\",\n  \"private\": true\n}\n",
      "README.md" => "# Bakery design system\n\nTokens and React components shared by the webshop and the in-store kiosk.\n",
      "src/tokens.css" => TOKENS_CSS,
      "src/components/Button.tsx" => BUTTON_TSX
    }.freeze
  end
end
