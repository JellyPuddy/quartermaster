# frozen_string_literal: true

# Story 4, reviewing what Claude did, on the gift-cards item:
# - uncommitted work in its worktree (the expiry Claude hasn't committed, a
#   new React form), so Branch shows committed and uncommitted lines;
# - a prompt snapshot per prompt of the live chat (what snapshot-worktree.sh
#   records), so Since prompt shows what the last prompt changed;
# - viewed marks, chat diff comments, a page annotation anchored on the
#   form, the user's GitHub review draft, Claude's (via `qm draft add`) and a
#   reply to a review thread — all through qm's own Drafts and ViewedMarks.
module DemoWorld
  module Review
    GIFT_CARD = <<~RUBY
      class GiftCard < ApplicationRecord
        VALID_FOR = 1.year

        has_secure_token :code, length: 12
        validates :balance, numericality: { greater_than_or_equal_to: 0 }

        before_create { self.expires_at ||= VALID_FOR.from_now }

        def expired? = expires_at.past?

        def redeem!(amount)
          raise ArgumentError, "gift card expired" if expired?
          raise ArgumentError, "not enough balance" if amount > balance

          update!(balance: balance - amount)
        end
      end
    RUBY

    FORM = <<~JSX
      import { useState } from "react";

      export default function GiftCardForm({ balance, total }) {
        const [code, setCode] = useState("");
        const remaining = Math.max(balance - total, 0);

        return (
          <form className="gift-card-form">
            <label htmlFor="gift_card_code">Gift card code</label>
            <input id="gift_card_code" value={code} onChange={(e) => setCode(e.target.value)} maxLength={12} />
            <p className="gift-card-balance">Balance after this order: €{remaining.toFixed(2)}</p>
            <button type="submit">Apply</button>
          </form>
        );
      }
    JSX

    MIGRATION = <<~RUBY
      class AddExpiresAtToGiftCards < ActiveRecord::Migration[7.2]
        def change
          add_column :gift_cards, :expires_at, :datetime
        end
      end
    RUBY

    # Runs in qm: line numbers come from the diff qm itself serves, so every
    # draft sits on the line the pane shows.
    WRITER = <<~'RUBY'
      include Quartermaster
      item = WorkItem.find("gift-cards")
      branch = "feature/gift-cards"
      files = BranchDiff.new.call(item, branch: branch)["files"]
      line_of = lambda do |path, needle|
        file = files.find { |f| f["path"] == path } or raise "no #{path} in the diff"
        line = file["hunks"].flat_map { |h| h["lines"] }.find { |l| l["s"].include?(needle) && l["n"] } or raise "no #{needle} in #{path}"
        [line["n"], line["s"]]
      end
      marks = ViewedMarks.new(item.slug)
      DATA_IN["viewed"].each do |path|
        file = files.find { |f| f["path"] == path } or raise "no #{path} to mark viewed"
        marks.set(path, ViewedMarks.digest(file), true)
      end
      drafts = Drafts.new(item.slug)
      DATA_IN["comments"].each do |c|
        n, code = line_of.(c["path"], c["needle"])
        drafts.put_diff_comment("path" => c["path"], "side" => "new", "line" => n, "code" => code, "branch" => branch, "comment" => c["comment"])
      end
      pr = DATA_IN["pr"]
      root = item.project && ProjectMap.new.root_for(item.project)
      head = Quartermaster.git(root, "rev-parse", "refs/remotes/origin/" + branch).strip
      base = Quartermaster.git(root, "merge-base", "origin/main", head).strip
      g = DATA_IN["github"]
      drafts.put_diff_comment("kind" => "github-comment", "path" => g["path"], "side" => "new", "line" => g["line"],
                              "code" => g["code"], "repo" => pr["repo"], "number" => pr["number"], "base" => base,
                              "commit" => head, "branch" => branch, "comment" => g["comment"])
      r = DATA_IN["reply"]
      drafts.put_thread_reply(r.merge("repo" => pr["repo"], "number" => pr["number"], "url" => pr["url"], "author" => "user"))
      form = DATA_IN["annotation"]
      n, code = line_of.(form["file"], form["needle"])
      drafts.add_annotations([form["entry"].merge("owners" => [{ "name" => "GiftCardForm", "file" => form["file"], "line" => n, "code" => code.strip },
                                                               { "name" => "CheckoutPage", "file" => "app/javascript/pages/CheckoutPage.jsx", "line" => 42 }])],
                             url: form["url"], title: "Checkout — De Bakkerij")
    RUBY

    def self.uncommitted(world)
      wt = world.worktree("bakery-shop", "gift-cards")
      { "app/models/gift_card.rb" => GIFT_CARD, "app/javascript/components/GiftCardForm.jsx" => FORM,
        "db/migrate/20261101120000_add_expires_at_to_gift_cards.rb" => MIGRATION }.each do |rel, content|
        FileUtils.mkdir_p(File.dirname(File.join(wt, rel)))
        File.write(File.join(wt, rel), content)
      end
      world.git!(wt, "add", "db/migrate")
    end

    # snapshot-worktree.sh's lines for the live chat: the tree before each prompt.
    def self.snapshots(world)
      session = world.cast["gc2"]
      wt = session.cwd
      trees = [world.git!(wt, "rev-parse", "HEAD~1^{tree}").strip, world.git!(wt, "rev-parse", "HEAD^{tree}").strip]
      rows = session.prompt_ats.zip(trees).map do |at, tree|
        { "v" => 1, "session_id" => session.id, "cwd" => wt, "toplevel" => wt, "tree" => tree,
          "at" => (at + 1).utc.strftime("%Y-%m-%dT%H:%M:%SZ") }
      end
      world.append_jsonl(File.join(world.qm_root, "prompt-snapshots.jsonl"), rows)
    end
  end
end

DemoWorld.step("review") do |world|
  review = DemoWorld::Review
  review.uncommitted(world)
  review.snapshots(world)
  pr = DemoWorld::GitHub::PRS.find { |p| p["number"] == 38 && p["repo"] == DemoWorld::GitHub::SHOP }
  world.qm_ruby!(review::WRITER, {
    "viewed" => ["app/mailers/gift_card_mailer.rb", "db/migrate/20261101120000_add_expires_at_to_gift_cards.rb"],
    "comments" => [
      { "path" => "app/models/gift_card.rb", "needle" => "VALID_FOR.from_now",
        "comment" => "Use the shop's time zone here — a card bought at 23:30 shouldn't expire a day early." },
      { "path" => "app/javascript/components/GiftCardForm.jsx", "needle" => "maxLength={12}",
        "comment" => "Codes are case-sensitive tokens; uppercase what people type before sending it." }
    ],
    "pr" => pr,
    "github" => { "path" => "app/controllers/checkouts_controller.rb", "line" => 7,
                  "code" => "    redeem_gift_card(params[:gift_card_code])",
                  "comment" => "Redeem inside the same transaction as the order, or a failed payment burns the card's balance." },
    "reply" => { "thread" => "PRRT_kwDOBk38b", "path" => "app/controllers/checkouts_controller.rb", "line" => 7,
                 "comment" => "Good catch — when the card covers everything we now skip Mollie and confirm the order directly." },
    "annotation" => { "file" => "app/javascript/components/GiftCardForm.jsx", "needle" => "gift-card-balance",
                      "url" => "http://localhost:3000/checkout/new",
                      "entry" => { "comment" => "Balance reads €0.00 before a code is entered — hide it until a card is applied.",
                                   "page" => "/checkout/new", "selector" => "form.gift-card-form > p.gift-card-balance",
                                   "text" => "Balance after this order: €0.00", "component" => "GiftCardForm",
                                   "components" => %w[GiftCardForm CheckoutPage], "context" => "Payment · Gift card",
                                   "html" => "<p class=\"gift-card-balance\">Balance after this order: €0.00</p>" } }
  })
  world.qm!("draft", "add", "gift-cards", "--path", "app/mailers/gift_card_mailer.rb", "--line", "4",
            "--branch", "feature/gift-cards", "--body",
            "`GiftCardPdf` renders synchronously inside the mailer; with a queue backlog this blocks checkout. " \
            "Render the PDF in the job instead.")
end
