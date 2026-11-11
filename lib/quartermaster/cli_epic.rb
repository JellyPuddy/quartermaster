# frozen_string_literal: true

module Quartermaster
  # `qm epic` and `qm link`, and the epic parts of `qm show`: an item's place in
  # an epic, an epic's children and any item's links (WorkItemEpic).
  module CliEpic
    COMMANDS = { "epic" => :cmd_epic, "link" => :cmd_link }.freeze

    private

    def cmd_epic(argv)
      slug, target = argv
      abort("usage: qm epic ITEM_SLUG EPIC_SLUG|--clear | qm epic SLUG --make|--unmake") unless slug && target

      item = WorkItem.find(slug)
      case target
      when "--clear"
        item.leave_epic
        puts "#{slug} → (no epic)"
      when "--make"
        item.make_epic!
        puts "#{slug} → epic"
      when "--unmake"
        item.unmake_epic!
        puts "#{slug} → work item"
      else
        item.join_epic(target)
        puts "#{slug} → epic #{target}"
      end
    end

    def cmd_link(argv)
      slug, label, url = argv
      abort('usage: qm link SLUG "LABEL" URL | qm link SLUG "LABEL" --remove') unless slug && label && url

      item = WorkItem.find(slug)
      url == "--remove" ? item.remove_link(label) : item.set_link(label, url)
      labels = WorkItem.find(slug).links.map { |link| link["label"] }
      puts "#{slug} → #{labels.empty? ? "(no links)" : labels.join(", ")}"
    end

    def epic_line(item)
      found = item.epic_item
      found ? "Epic: #{found.title} (#{found.slug})" : "Epic: #{item.epic} (missing)"
    end

    # An epic's children (slug, state, title), then the item's links.
    def epic_sections(item)
      lines = []
      if item.epic?
        children = item.children
        lines += ["", paint("Children", 1)]
        lines += children.empty? ? ["(none)"] : aligned(children.map { |c| [c.slug, c.state.to_s, c.title.to_s] })
      end
      return lines if item.links.empty?

      lines + ["", paint("Links", 1)] + aligned(item.links.map { |link| [link["label"].to_s, link["url"].to_s] })
    end

    def aligned(rows)
      widths = rows.transpose.map { |col| col.map(&:length).max }
      rows.map { |row| row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
    end
  end
end
