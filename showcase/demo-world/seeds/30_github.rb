# frozen_string_literal: true

# The Bakery's GitHub, faked twice over and kept in agreement:
# - "origin" is a bare repo inside the world (remote/bakery-co/<repo>.git,
#   reached through an insteadOf rewrite of the github.com URL) holding the
#   pushed branches and refs/pull/<n>/head, so the diff pane's PR scope can
#   fetch a PR as it would from GitHub;
# - fixtures/gh/30-github.json answers every gh call qm makes about PRs,
#   checks, review threads, issues and releases.
# Then qm's own PrStatus, PrInbox, PrPrerequisites and PrDeployment fill
# their caches by asking that stub gh, exactly as the GUI would.
module DemoWorld
  module GitHub
    SHOP = "#{GITHUB_OWNER}/bakery-shop"
    DS = "#{GITHUB_OWNER}/bakery-design-system"
    RELEASE = { SHOP => "v2026.10.4", DS => "v0.4.0" }.freeze
    CHECKS = %w[lint unit-tests system-tests brakeman assets importmap-audit erb-lint i18n-tasks].freeze

    # head, base, title, author, roles, review decision, CI (:green, :red, :running), draft, state.
    PRS = [
      [SHOP, 36, "fix/cart-rounding", "main", "Round cart totals per line", "tom-bakes", [], "APPROVED", :green, false, "MERGED", 11],
      [SHOP, 38, "feature/gift-cards", "main", "Gift cards: buy, email and redeem at checkout", "mara-dev", %w[author], "CHANGES_REQUESTED", :green, false, "OPEN", 0.05],
      [SHOP, 41, "checkout/address-form", "main", "Checkout step 1: address form", "mara-dev", %w[author], "APPROVED", :green, false, "OPEN", 0.3],
      [SHOP, 42, "checkout/payment-step", "checkout/address-form", "Checkout step 2: iDEAL and card payment", "mara-dev", %w[author], nil, :red, false, "OPEN", 0.02],
      [SHOP, 43, "checkout/order-confirmation", "checkout/payment-step", "Checkout step 3: confirmation page and email", "mara-dev", %w[author], nil, :running, true, "OPEN", 0.02],
      [SHOP, 44, "feature/sourdough-subscriptions", "main", "Weekly sourdough subscriptions", "tom-bakes", %w[review], nil, :green, false, "OPEN", 0.2],
      [SHOP, 45, "fix/kiosk-receipt-printer", "main", "Kiosk: retry the receipt printer once", "anouk-ops", %w[assignee], nil, :red, false, "OPEN", 2],
      [DS, 12, "feature/button-variants", "main", "Ghost and danger button variants", "mara-dev", %w[author], nil, :green, false, "OPEN", 0.1],
      [DS, 14, "feature/spring-palette", "main", "Spring campaign palette", "tom-bakes", %w[review], "APPROVED", :green, false, "OPEN", 1]
    ].map do |repo, number, head, base, title, author, roles, decision, ci, draft, state, days|
      { "repo" => repo, "number" => number, "head" => head, "base" => base, "title" => title, "author" => author, "roles" => roles,
        "decision" => decision, "ci" => ci, "draft" => draft, "state" => state, "days" => days,
        "url" => "https://github.com/#{repo}/pull/#{number}" }
    end.freeze

    ISSUES = { 57 => ["Filter products by allergen", "OPEN"], 61 => ["Show the gift card balance on the account page", "OPEN"],
               63 => ["Delivery windows: block the 07:00 window on Mondays", "OPEN"], 29 => ["Order confirmation email lands in spam", "CLOSED"] }.freeze

    def self.mirror(world)
      config = +""
      PROJECTS.each_value do |name|
        bare = File.join(world.root, "remote", GITHUB_OWNER, "#{name}.git")
        world.run!("git", "init", "--quiet", "--bare", bare)
        refspecs = ["refs/remotes/origin/*:refs/heads/*"]
        Repos::PULLS.fetch(name, {}).each { |branch, number| refspecs << "refs/heads/#{branch}:refs/pull/#{number}/head" }
        world.git!(world.repo(name), "push", "--quiet", bare, *refspecs)
      end
      config << "[url \"#{File.join(world.root, "remote", GITHUB_OWNER)}/\"]\n\tinsteadOf = https://github.com/#{GITHUB_OWNER}/\n"
      File.write(File.join(world.home, ".gitconfig"), config, mode: "a")
    end

    def self.routes(world)
      routes = PRS.map do |pr|
        sha = pr_head(world, pr)
        view = { "number" => pr["number"], "url" => pr["url"], "title" => pr["title"], "state" => pr["state"],
                 "headRefName" => pr["head"], "baseRefName" => pr["base"], "isDraft" => pr["draft"],
                 "mergeCommit" => pr["state"] == "MERGED" ? { "oid" => sha } : nil }
        { "match" => ["^pr view (#{Regexp.escape(pr["head"])}|#{Regexp.escape(pr["url"])})( |$)"], "stdout" => view }
      end
      routes << { "match" => ["^pr view"], "stderr" => "no pull requests found for branch\n", "exit" => 1 }
      routes << { "match" => ["^api graphql", "user-review-requested"], "stdout" => { "data" => inbox(world) } }
      routes << { "match" => ["^api graphql", "reviewThreads"], "stdout" => threads_answer(world, []) }
      routes << { "match" => ["^api graphql", "reviewThreads", "number=38( |$)"], "stdout" => threads_answer(world, Threads.for_pr38(world)) }
      RELEASE.each do |repo, tag|
        routes << { "match" => ["^api repos/#{repo}/releases/latest"], "stdout" => "#{tag}\n" }
        routes << { "match" => ["^api repos/#{repo}/compare/"], "stdout" => "ahead\n" }
      end
      routes << { "match" => ["^api repos/#{SHOP}/compare/", deployed_sha(world)], "stdout" => "behind\n" }
      ISSUES.each do |number, (title, state)|
        routes << { "match" => ["^issue view #{number}( |$)"],
                    "stdout" => { "number" => number, "title" => title, "state" => state, "url" => "https://github.com/#{SHOP}/issues/#{number}" } }
      end
      routes << { "match" => ["^issue view"], "stderr" => "GraphQL: Could not resolve to an issue or pull request\n", "exit" => 1 }
      routes << { "match" => ["^repo view"], "stdout" => "main\n" }
      routes
    end

    def self.pr_head(world, pr)
      repo = world.repo(pr["repo"].split("/").last)
      world.git!(repo, "rev-parse", "--verify", "--quiet", "refs/heads/#{pr["head"]}").strip
    rescue RuntimeError
      Digest::SHA1.hexdigest(pr["url"])
    end

    # The main commit #38 requires deployed: already in the latest release.
    def self.deployed_sha(world) = world.git!(world.repo("bakery-shop"), "rev-parse", "main~1").strip

    def self.inbox(world)
      nodes = PRS.reject { |pr| pr["state"] == "MERGED" }.map { |pr| node(world, pr) }
      %w[author review assignee].to_h do |role|
        [role, { "nodes" => nodes.zip(PRS.reject { |pr| pr["state"] == "MERGED" }).select { |_, pr| pr["roles"].include?(role) }.map(&:first) }]
      end
    end

    def self.node(world, pr)
      updated = (world.now - (pr["days"] * 86_400)).utc.iso8601
      reviews = pr["decision"] ? [{ "state" => pr["decision"] }] : []
      { "number" => pr["number"], "title" => pr["title"], "url" => pr["url"], "isDraft" => pr["draft"], "updatedAt" => updated,
        "headRefName" => pr["head"], "baseRefName" => pr["base"], "reviewDecision" => pr["base"] == "main" ? pr["decision"] : nil,
        "latestReviews" => { "nodes" => reviews }, "author" => { "login" => pr["author"] },
        "repository" => { "nameWithOwner" => pr["repo"] },
        "commits" => { "nodes" => [{ "commit" => { "statusCheckRollup" => { "contexts" => { "nodes" => checks(world, pr, updated) } } } }] } }
    end

    def self.checks(_world, pr, updated)
      suite = { "databaseId" => 9000 + pr["number"], "createdAt" => updated, "app" => { "slug" => "github-actions" },
                "workflowRun" => { "workflow" => { "name" => "CI" } } }
      CHECKS.each_with_index.map do |name, i|
        conclusion = case pr["ci"]
                     when :red then name == "system-tests" ? "FAILURE" : "SUCCESS"
                     when :running then i < 5 ? "SUCCESS" : nil
                     else "SUCCESS"
                     end
        { "name" => name, "status" => conclusion ? "COMPLETED" : "IN_PROGRESS", "conclusion" => conclusion,
          "startedAt" => updated, "checkSuite" => suite }
      end
    end

    def self.threads_answer(_world, threads)
      { "data" => { "viewer" => { "login" => LOGIN },
                    "repository" => { "pullRequest" => { "id" => "PR_kwDOBakery38", "reviews" => { "nodes" => [] },
                                                         "reviewThreads" => { "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
                                                                              "nodes" => threads } } } } }
    end

    # qm's own stores, filled by asking the stub gh like the GUI does.
    FILL = <<~RUBY
      include Quartermaster
      DATA_IN["branches"].each do |slug, branches|
        item = WorkItem.find(slug)
        branches.each { |branch| PrStatus.new.state_for(item, branch) }
      end
      PrInbox.new.refresh
      store = PrPrerequisites.new
      DATA_IN["prerequisites"].each do |p|
        store.add(p["pr"], kind: p["kind"], ref: p["ref"], session: p["session"], note: p["note"])
      end
      PrDeployment.new.refresh
    RUBY
  end
end

DemoWorld.step("github") do |world|
  gh = DemoWorld::GitHub
  gh.mirror(world)
  world.write_json(File.join(world.gh_fixtures_dir, "30-github.json"), gh.routes(world))
  shop = ->(n) { "https://github.com/#{gh::SHOP}/pull/#{n}" }
  branches = { "gift-cards" => ["feature/gift-cards"], "checkout-flow" => DemoWorld::Repos::STACK,
               "cart-rounding" => ["fix/cart-rounding"], "button-variants" => ["feature/button-variants"],
               "delivery-slots" => ["feature/delivery-slots-v2"], "dark-mode-tokens" => ["feature/color-tokens"] }
  co = world.cast["co1"].id
  prerequisites = [
    { "pr" => shop.(42), "kind" => "pr", "ref" => shop.(36), "session" => co },
    { "pr" => shop.(43), "kind" => "pr", "ref" => shop.(41), "session" => co,
      "note" => "After #41 is deployed, run bin/rails checkout:backfill_addresses before merging." },
    { "pr" => shop.(38), "kind" => "commit", "ref" => gh.deployed_sha(world), "session" => world.cast["gc1"].id }
  ]
  world.qm_ruby!(gh::FILL, { "branches" => branches, "prerequisites" => prerequisites })
end

module DemoWorld
  module GitHub
    # Review threads on #38 (gift cards), on the lines they talk about at the
    # PR's head: open, replied to, resolved and outdated.
    module Threads
      def self.for_pr38(world)
        at = ->(days) { (world.now - (days * 86_400)).utc.iso8601 }
        [
          thread(world, "PRRT_kwDOBk38a", "app/models/gift_card.rb", 6, [
            ["tom-bakes", "An `ArgumentError` surfaces as a 500 at checkout. Could this be a `GiftCard::InsufficientBalance` the controller rescues?", at.(1.2)],
            ["mara-dev", "Good call — I'll add it in this PR.", at.(1.1)]
          ]),
          thread(world, "PRRT_kwDOBk38b", "app/controllers/checkouts_controller.rb", 7, [
            ["tom-bakes", "What happens when the card covers the whole order? We shouldn't send a €0 payment to Mollie.", at.(1.2)]
          ]),
          thread(world, "PRRT_kwDOBk38c", "app/mailers/gift_card_mailer.rb", 4, [
            ["anouk-ops", "The PDF prints fine on the shop's label printer too.", at.(0.9)]
          ], resolved: true),
          thread(world, "PRRT_kwDOBk38d", "app/models/gift_card.rb", 2, [
            ["tom-bakes", "Is 12 characters enough for a code people type in by hand?", at.(3)]
          ], outdated: true)
        ]
      end

      def self.thread(world, id, path, line, comments, resolved: false, outdated: false)
        text = world.git!(world.repo("bakery-shop"), "show", "feature/gift-cards:#{path}").lines.map(&:chomp)
        hunk = "@@ -0,0 +1,#{text.size} @@\n#{text.first(line).map { |l| "+#{l}" }.join("\n")}"
        { "id" => id, "path" => path, "line" => outdated ? nil : line, "originalLine" => line, "startLine" => nil,
          "originalStartLine" => nil, "diffSide" => "RIGHT", "subjectType" => "LINE", "isResolved" => resolved,
          "isOutdated" => outdated, "viewerCanResolve" => !resolved, "viewerCanUnresolve" => resolved, "viewerCanReply" => true,
          "resolvedBy" => resolved ? { "login" => LOGIN } : nil,
          "comments" => { "nodes" => comments.each_with_index.map do |(author, body, created), i|
            { "id" => "#{id}_c#{i}", "author" => { "login" => author }, "body" => body, "createdAt" => created,
              "url" => "https://github.com/#{SHOP}/pull/38#discussion_r#{1000 + i}", "state" => "SUBMITTED",
              "diffHunk" => hunk }
          end } }
      end
    end
  end
end
