# frozen_string_literal: true

module Quartermaster
  # "Work on this item": point the dev server and the IDE at the item's
  # target worktree. The actions the CLI and the GUI share — switch the
  # project's dev server, open the configured IDE, both, or a Warp tab in it — each
  # returning a report the caller prints or serves; failures raise
  # ArgumentError with the tool's own message.
  class Workspace
    Report = Struct.new(:target, :mode, :steps, keyword_init: true) do
      def to_h = { "target" => target.to_h, "mode" => mode, "steps" => steps }
    end

    def initialize(project_map: ProjectMap.new, runner: CommandRunner.new)
      @runner = runner
      @project_map = project_map
      @targets = TargetWorktree.new(project_map: project_map, runner: runner)
      @warp = WarpTab.new(runner: runner)
    end

    def switch_pf(item, mode: nil, worktree: nil, branch: nil)
      server = server_for(item.project)
      mode = server.check_mode!(mode || item.pf_mode)
      target = @targets.materialize(item, worktree: worktree, branch: branch)
      report(target, mode) { |steps| steps << pf_step(server, target, mode) }
    end

    def open_ide(item, worktree: nil, branch: nil)
      ide = @project_map.ide!(item.project)
      target = @targets.materialize(item, worktree: worktree, branch: branch)
      report(target, nil) { |steps| steps << ide_step(ide, target) }
    end

    def open_terminal(item, worktree: nil, branch: nil)
      target = @targets.materialize(item, worktree: worktree, branch: branch)
      report(target, nil) { |steps| steps << @warp.open(target.path, "#{item.slug} · #{target.branch || File.basename(target.path)}") }
    end

    # Whichever of the dev server and the IDE are configured; refused with neither.
    def work_on(item, mode: nil, worktree: nil, branch: nil)
      settings = @project_map.settings_for(item.project)
      server = settings.dev_server
      ide = server ? @project_map.ide(item.project) : @project_map.ide!(item.project)
      mode = server&.check_mode!(mode || item.pf_mode)
      target = @targets.materialize(item, worktree: worktree, branch: branch)
      report(target, mode) do |steps|
        steps << (server ? pf_step(server, target, mode) : "dev server skipped: #{item.project} has none " \
                                                           "(#{settings.config_command("dev_server.command", "<command>")})")
        steps << (ide ? ide_step(ide, target) : "IDE skipped: none configured (#{Ide::CONFIG_COMMAND})")
      end
    end

    # The PRs view's buttons: the PR's own branch, not an item's target.
    # mode: nil means the project's default mode.
    def switch_pf_to_branch(project, branch, mode: nil)
      server = server_for(project)
      mode = server.check_mode!(mode || server.default_mode)
      target = @targets.materialize_branch(project, branch)
      report(target, mode) { |steps| steps << pf_step(server, target, mode) }
    end

    def open_ide_on_branch(project, branch)
      ide = @project_map.ide!(project)
      target = @targets.materialize_branch(project, branch)
      report(target, nil) { |steps| steps << ide_step(ide, target) }
    end

    # Stops the dev server, whichever checkout it serves.
    def stop_pf
      server = ProjectConfig.current.dev_server
      Pf.new(runner: @runner, server: server).stop
      "#{server.command} stopped"
    end

    private

    def server_for(project) = @project_map.settings_for(project).dev_server!

    def report(target, mode)
      steps = []
      steps << "created worktree #{Quartermaster.shorten_home(target.path)} for #{target.branch}" if target.create?
      begin
        yield steps
      rescue ArgumentError => e
        # Steps that already ran (a new worktree, a dev-server switch) must not vanish
        # behind the later failure, or a retry is blind to them.
        raise if steps.empty?

        raise ArgumentError, "#{steps.join("; ")}; then #{e.message}"
      end
      Report.new(target: target, mode: mode, steps: steps)
    end

    def pf_step(server, target, mode)
      Pf.new(runner: @runner, server: server).switch(target.path, mode)
      "#{server.command} #{mode} @ #{Quartermaster.shorten_home(target.path)}"
    end

    def ide_step(ide, target)
      result = @runner.call(ide.argv(target.path))
      unless result.success?
        raise ArgumentError, "opening #{ide.label} failed: #{(result.err.strip.empty? ? result.out : result.err).strip}"
      end

      "#{ide.label} opened #{Quartermaster.shorten_home(target.path)}"
    end
  end
end
