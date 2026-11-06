# frozen_string_literal: true

module Quartermaster
  # A local automation's run as a chat of its own: tmux session
  # `<slug>--run-<run id>` on qm's socket, running claude as a chat does
  # (QM_ITEM is the automation, every CLAUDE* var unset by Tmux) with qm's
  # session id, the yml's flags and the prompt as claude's argument.
  class ChatFlow
    SEPARATOR = "--run-"

    def initialize(tmux:, project_map: nil)
      @tmux = tmux
      @project_map = project_map
    end

    def name = "chat"

    def needs = []

    def self.tmux_name(slug, run_id) = "#{slug}#{SEPARATOR}#{run_id}"

    # The prompt file, then the item as given under a final `## Item`.
    def self.prompt_with_item(prompt, item)
      return prompt.to_s if item.nil?

      "#{prompt.to_s.rstrip}\n\n## Item\n\n#{item_text(item)}".lstrip
    end

    # A guard's plain line comes back as that line; a JSON item pretty-printed.
    def self.item_text(item)
      item.is_a?(Hash) && item.keys.sort == %w[key line] ? item["line"].to_s : JSON.pretty_generate(item)
    end

    def start(automation, item, prompt, run_id:, session_id:)
      name = self.class.tmux_name(automation.slug, run_id)
      argv = [*launcher.chat_command, *AutomationFlows.flags(automation.record, session_id),
              self.class.prompt_with_item(prompt, item)]
      opened = @tmux.open(name, cwd: cwd(automation), argv: argv, env: { "QM_ITEM" => automation.slug })
      raise ArgumentError, "tmux session #{name} is already running" unless opened

      { item_slug: automation.slug, tmux: name }
    end

    private

    # The yml's cwd, else the automation's project root, else home.
    def cwd(automation)
      set = automation.record["cwd"].to_s
      return File.expand_path(set) unless set.empty?

      project = WorkItem.find(automation.slug).project if File.exist?(WorkItem.path_for(automation.slug))
      root = project && project_map.root_for(project)
      root && File.directory?(root) ? root : Dir.home
    end

    def project_map = @project_map || ProjectMap.new

    def launcher = Launcher.new(project_map: project_map)
  end
end
