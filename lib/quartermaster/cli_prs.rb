# frozen_string_literal: true

module Quartermaster
  # Pull requests: opening one, merge prerequisites, review drafts.
  module CliPrs
    COMMANDS = {
      "pr" => :cmd_pr,
      "pr-requires" => :cmd_pr_requires,
      "draft" => :cmd_draft
    }.freeze

    private

    def cmd_pr(argv)
      slug = argv.first
      abort("usage: qm pr SLUG") unless slug

      item = WorkItem.find(slug)
      branch = item.branches.size > 1 ? Viewer.pick(item.branches, prompt: "PR of #{item.slug} >") : nil
      return if item.branches.size > 1 && (branch.nil? || branch.empty?)

      begin
        PrStatus.new.open_web(item, branch: branch)
      rescue ArgumentError => e
        abort("qm: #{e.message}")
      end
    end

    PR_REQUIRES_USAGE = "usage: qm pr-requires PR-OR-SHA [--pr PR] [--note TEXT] | --remove PR-OR-SHA [--pr PR] | --list [--pr PR]"

    # Local only: records that a PR may merge only once an earlier PR or
    # commit is deployed. --pr defaults to the current branch's PR.
    def cmd_pr_requires(argv)
      options = {}
      parser = OptionParser.new do |o|
        o.on("--pr PR") { |v| options[:pr] = v }
        o.on("--remove") { options[:remove] = true }
        o.on("--list") { options[:list] = true }
        o.on("--session SESSION_ID") { |v| options[:session] = v }
        o.on("--note TEXT") { |v| options[:note] = v }
      end
      rest = parser.parse(argv)
      abort(PR_REQUIRES_USAGE) if options[:remove] && options[:list]
      abort(PR_REQUIRES_USAGE) if options.key?(:note) && (options[:remove] || options[:list])
      abort(PR_REQUIRES_USAGE) unless options[:list] ? rest.empty? : rest.size == 1

      store = @prerequisites || PrPrerequisites.new
      cwd = @cwd || Dir.pwd
      return pr_requires_list(store, options[:pr], cwd) if options[:list]

      pr = store.resolve_pr(options[:pr], cwd: cwd)
      repo = store.repo_of_pr_url(pr)
      if options[:remove]
        ref = store.stored_ref(pr, rest.first, cwd: cwd)
        store.remove(pr, ref)
        puts "#{pr_label(pr)} no longer requires #{prerequisite_label(ref)}"
      else
        prerequisite = store.resolve_prerequisite(rest.first, repo: repo, cwd: cwd)
        session = options[:session] || ENV["CLAUDE_CODE_SESSION_ID"]
        added = store.add(pr, kind: prerequisite["kind"], ref: prerequisite["ref"], session: session.to_s.empty? ? nil : session,
                              note: options[:note])
        label = prerequisite_label(prerequisite["ref"])
        if added || !options.key?(:note)
          puts "#{pr_label(pr)} #{added ? "now requires" : "already requires"} #{label} deployed before merging"
        else
          entry = store.set_note(pr, prerequisite["ref"], options[:note])
          abort("qm: #{pr_label(pr)} no longer requires #{label}") unless entry
          puts "#{pr_label(pr)}: #{entry.key?("note") ? "note on #{label} set" : "note on #{label} cleared"}"
        end
      end
    rescue OptionParser::ParseError => e
      abort("qm: #{e.message}\n#{PR_REQUIRES_USAGE}")
    end

    DRAFT_USAGE = "usage: qm draft add SLUG (--path P --line N [options] | --summary [--verdict V]) (--body TEXT | --body-file F) " \
                  "| qm draft list SLUG [--json]"

    def cmd_draft(argv)
      case argv.shift
      when "add" then cmd_draft_add(argv)
      when "list" then cmd_draft_list(argv)
      else abort(DRAFT_USAGE)
      end
    end

    # A chat's review finding as a GitHub draft on the item's PR (D14),
    # written straight into the item's drafts file (ChatReviewDrafts).
    def cmd_draft_add(argv)
      options = {}
      body_file = nil
      parser = OptionParser.new do |o|
        o.banner = "usage: qm draft add SLUG --path P --line N [options] (--body TEXT | --body-file F)\n" \
                   "       qm draft add SLUG --summary [--verdict V] [--pr URL | --branch B] (--body TEXT | --body-file F)\n\n" \
                   "Records a review comment as a draft on the item's pull request, marked 🤖 as Claude's,\n" \
                   "for the user to curate in the qm gui's diff pane and post as a pending review. Nothing goes\n" \
                   "to GitHub. Line numbers are the PR diff's: the new side's in the file at the PR head (or\n" \
                   "--commit), the old side's in the PR's base. GitHub only takes a comment on a line its PR\n" \
                   "diff shows (a change or 3 lines around one); anything else is refused — use --file for a\n" \
                   "comment on the whole file. The PR: --pr, else a Review item's own, else the open PR of the\n" \
                   "item's branch checked out here (or its only branch with one). --summary records instead\n" \
                   "your overall verdict and review summary, one per PR (a second replaces yours).\n\n"
        o.on("--path PATH", "file, relative to the repo root") { |v| options[:path] = v }
        o.on("--line N", Integer, "the (last) line commented on") { |v| options[:line] = v }
        o.on("--start-line M", Integer, "first line of a range of lines (same side, one hunk)") { |v| options[:start_line] = v }
        o.on("--side SIDE", %w[old new], "new (default: added or unchanged lines) or old (removed lines)") { |v| options[:side] = v }
        o.on("--commit SHA", "anchor to this PR commit instead of the head (lines numbered as base..SHA)") { |v| options[:commit] = v }
        o.on("--file", "a comment on the whole file, shown at --line and quoting it") { options[:file] = true }
        o.on("--reply-to THREAD_ID", "a reply to an existing review thread (its node id) instead") { |v| options[:reply_to] = v }
        o.on("--summary", "the review's summary and suggested verdict instead (no line flags)") { options[:summary] = true }
        o.on("--verdict VERDICT", "with --summary: approve, comment or request-changes") { |v| options[:verdict] = v }
        o.on("--pr URL", "the pull request, when the item's isn't the one") { |v| options[:pr] = v }
        o.on("--branch BRANCH", "the item's branch whose PR it is") { |v| options[:branch] = v }
        o.on("--body TEXT", "the comment (markdown; a ```suggestion block suggests a change)") { |v| options[:body] = v }
        o.on("--body-file FILE", "read the comment from FILE ('-': stdin)") { |v| body_file = v }
      end
      rest = parser.parse(argv)
      abort(parser.help) unless rest.size == 1
      abort("qm draft add: give the comment with --body or --body-file, not both") if body_file && options.key?(:body)

      options[:body] = body_file == "-" ? $stdin.read : File.read(body_file) if body_file
      item = WorkItem.find(rest.first)
      reviewer = ChatReviewDrafts.new(runner: @runner || CommandRunner.new, cwd: @cwd || Dir.pwd)
      entry, replaced = reviewer.add(item, **options)
      puts "🤖 #{draft_where(entry)} drafted (#{entry["id"]})#{" — replaced your earlier draft there" if replaced}"
    rescue OptionParser::ParseError, SystemCallError => e
      abort("qm draft add: #{e.message}\n#{DRAFT_USAGE}")
    rescue ArgumentError => e
      abort("qm draft add: #{e.message}")
    end

    # The item's drafts, so a chat sees what it and the user already wrote.
    def cmd_draft_list(argv)
      json = false
      rest = OptionParser.new { |o| o.on("--json") { json = true } }.parse(argv)
      abort(DRAFT_USAGE) unless rest.size == 1

      entries = Drafts.new(WorkItem.find(rest.first).slug).entries
      return puts(JSON.pretty_generate(entries)) if json

      puts "no drafts" if entries.empty?
      entries.each do |entry|
        author = { "claude" => "🤖 claude", "user" => "user" }.fetch(entry["author"].to_s, "user")
        first = entry["comment"].to_s.strip.lines.first.to_s.strip
        puts "#{entry["id"]}  #{draft_where(entry)}  #{author}: #{first[0, 100]}"
      end
    rescue ArgumentError, OptionParser::ParseError => e
      abort("qm draft list: #{e.message}")
    end

    def draft_where(entry)
      pr = "#{entry["repo"].to_s.split("/").last}##{entry["number"]}"
      at = entry["path"] ? "#{entry["path"]}#{DiffComments.lines_label(entry)}" : nil
      case entry["kind"]
      when "github-comment"
        "#{entry["subject"] == "file" ? "file comment" : "review comment"} on #{pr} #{at}#{" (removed)" if entry["side"] == "old"} " \
          "@#{entry["commit"].to_s[0, 7]}"
      when "review-summary" then "review summary on #{pr}#{" (#{entry["verdict"].tr("-", " ")})" if entry["verdict"]}"
      when "thread-reply" then "reply on #{pr} to thread #{entry["thread"]}#{" (#{at})" if at && entry["line"]}"
      when "diff-comment" then "chat comment on #{at}#{" of #{pr}" if entry["number"]}"
      when "annotation" then "page annotation on #{entry["page"] || entry["url"]}"
      when "issue-comment" then "issue comment on #{entry["file"]}"
      else entry["kind"].to_s
      end
    end

    # Without --pr: the current branch's PR, or every PR when there is none.
    def pr_requires_list(store, spec, cwd)
      pr = begin
        store.resolve_pr(spec, cwd: cwd)
      rescue ArgumentError
        raise if spec
      end
      entries = pr ? { pr => store.for_pr(pr) } : store.all
      entries = entries.reject { |_, list| list.empty? }
      return puts(pr ? "#{pr_label(pr)} has no prerequisites" : "no PR prerequisites recorded") if entries.empty?

      PrDeployment.new(store: store).states(entries, refresh: false).each do |url, list|
        puts "#{pr_label(url)} (#{url})"
        list.each do |entry|
          state = deployment_label(entry)
          puts "  needs #{prerequisite_label(entry["ref"])} deployed — added #{entry["addedAt"]}#{" — #{state}" if state}"
          entry["note"].to_s.each_line.with_index do |line, index|
            puts "#{index.zero? ? "    note: " : "          "}#{line.chomp}"
          end
        end
      end
    end

    # The deploy check's cached verdict; nil while it has none.
    def deployment_label(entry)
      case entry["state"]
      when "deployed" then "✓ deployed in #{entry["tag"]}"
      when "pending" then "not in #{entry["tag"]}"
      when "unmerged" then "not merged"
      when "closed" then "closed without merging"
      end
    end

    def pr_label(url)
      match = PrPrerequisites::PR_URL.match(url)
      match ? "#{match[1]}##{match[2]}" : url
    end

    def prerequisite_label(ref)
      match = PrPrerequisites::PR_URL.match(ref)
      match ? "##{match[2]}" : ref[0, 7]
    end
  end
end
