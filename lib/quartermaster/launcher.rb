# frozen_string_literal: true

module Quartermaster
  class Launcher
    def initialize(project_map: ProjectMap.new, session_log: SessionLog.new)
      @project_map = project_map
      @session_log = session_log
    end

    def resume(item, session_id: nil, here: false)
      plan = resume_plan(item, session_id: session_id)
      case plan[:mode]
      when :live
        abort("qm: session #{plan[:session_id][0, 8]} is running right now — switch to its Warp tab instead")
      when :resume
        open_session(plan[:cwd], ["claude", "--resume", plan[:session_id]], {}, "resume #{item.slug}", here)
      when :rehydrate
        open_session(plan[:cwd], ["claude"], { "QM_ITEM" => item.slug }, "qm #{item.slug}", here)
      end
    end

    def start(item, here: false)
      open_session(start_cwd(item), ["claude"], { "QM_ITEM" => item.slug }, "qm #{item.slug}", here)
    end

    # Resume lands on the newest attached session whose transcript and cwd both
    # still exist. Live sessions are never resumed (that would fork them). With
    # nothing resumable, fall back to rehydration: a fresh session at the item's
    # best-known location, seeded through QM_ITEM with the work item file.
    def resume_plan(item, session_id: nil, exclude_session_ids: [])
      ids = item.sessions.map { |s| s["id"] } - exclude_session_ids.to_a
      ids &= [session_id] if session_id
      sessions = @session_log.sessions
                             .select { |s| ids.include?(s.id) }
                             .sort_by(&:last_ts)
                             .reverse
      live = sessions.find(&:live?)
      resumable = sessions.find { |s| s.tier == "resumable" && resume_cwd(s) }

      if resumable
        { mode: :resume, session_id: resumable.id, cwd: resume_cwd(resumable) }
      elsif live
        { mode: :live, session_id: live.id }
      else
        { mode: :rehydrate, cwd: start_cwd(item) }
      end
    end

    # An unlinked (inbox) session has no work item to rehydrate from, so its
    # plan is simpler than resume_plan: resume the surviving transcript in the
    # session's own recorded cwd, or nothing.
    def session_resume_plan(session_id)
      session = @session_log.session_for(session_id)
      return { mode: :gone } unless session
      return { mode: :live } if session.live?

      cwd = resume_cwd(session)
      if session.tier == "resumable" && cwd
        { mode: :resume, cwd: cwd }
      else
        { mode: :gone }
      end
    end

    def resume_session(session_id, here: false)
      plan = session_resume_plan(session_id)
      case plan[:mode]
      when :live then abort("qm: session #{session_id[0, 8]} is running right now — switch to its Warp tab instead")
      when :gone then abort("qm: session #{session_id[0, 8]} has no surviving transcript to resume")
      else open_session(plan[:cwd], ["claude", "--resume", session_id], {}, "resume #{session_id[0, 8]}", here)
      end
    end

    # A new session starts in the worktree checked out on the item's branch,
    # else the project root, else wherever its last session ran, else home.
    def start_cwd(item)
      root = @project_map.root_for(item.project)
      if root
        item.branches.reverse_each do |branch|
          worktree = worktree_for(root, branch)
          return worktree if worktree
        end
      end
      return root if root && File.directory?(root)

      last_cwd = item.sessions.filter_map { |s| @session_log.last_start_for(s["id"])&.fetch("cwd", nil) }.last
      last_cwd && File.directory?(last_cwd) ? last_cwd : Dir.home
    end

    # What the GUI's chat pane runs for an item, as { mode:, cwd:, argv:, env: }.
    # Start is always a fresh QM_ITEM session at start_cwd; Resume follows
    # resume_plan (newest resumable session in its own cwd, else rehydrate).
    # :live means the newest session runs outside the pane (a Warp tab): it
    # can be taken over only once it has ended — resuming now would fork it.
    # One live chat per item, so any live session refuses — resume_plan alone
    # would happily resume an older transcript beside it.
    # prompt: a fresh chat's first prompt, passed as claude's argument (the
    # issue kickoff) rather than typed into the pane.
    # exclude_session_ids: attached sessions that are not the item's chat (a
    # local automation's runs), never live-checked or resumed.
    def chat_plan(item, fresh: false, session_id: nil, prompt: nil, exclude_session_ids: [])
      ids = item.sessions.map { |s| s["id"] } - exclude_session_ids.to_a
      live = @session_log.sessions.find { |s| ids.include?(s.id) && s.live? }
      return { mode: :live, session_id: live.id } if live
      return fresh_chat_plan(item, prompt: prompt) if fresh

      plan = resume_plan(item, session_id: session_id, exclude_session_ids: exclude_session_ids)
      case plan[:mode]
      when :resume then plan.merge(argv: [*chat_command, "--resume", plan[:session_id]], env: {})
      when :rehydrate then fresh_chat_plan(item)
      else plan
      end
    end

    # An aside next to the item's chat: same cwd, the chosen model, and
    # QM_ASIDE instead of QM_ITEM — the hook injects the digest without
    # linking it. QM_ITEM is blanked in case the GUI itself inherited one.
    def aside_plan(item, model:)
      { cwd: start_cwd(item), argv: [*chat_command, "--model", model],
        env: { Aside::ENV_VAR => item.slug, "QM_ITEM" => "" } }
    end

    # An earlier aside resumed under its marker, on the model it ran on (claude
    # --resume alone falls back to the default); nil when its transcript is gone.
    def aside_resume_plan(item, session, model: nil)
      cwd = session.tier == "resumable" && resume_cwd(session)
      return nil unless cwd

      { cwd: cwd, argv: [*chat_command, *(model ? ["--model", model] : []), "--resume", session.id],
        env: { Aside::ENV_VAR => item.slug, "QM_ITEM" => "" } }
    end

    # A loose chat belongs to no item: it starts in the project's main
    # checkout (home without one), marked QM_LOOSE so the hook never links
    # it, with the first prompt as claude's argument rather than typed.
    def loose_plan(id, project:, model: nil, prompt: nil)
      root = @project_map.root_for(project)
      { cwd: root && File.directory?(root) ? root : Dir.home,
        argv: [*chat_command, *(model ? ["--model", model] : []), *(prompt.to_s.strip.empty? ? [] : [prompt])],
        env: { LooseChat::ENV_VAR => id, "QM_ITEM" => "" } }
    end

    # The pane's secondary door: a Warp tab attached to the same tmux session.
    def attach_in_warp(name, tmux)
      open_warp_tab(Dir.home, Shellwords.join(tmux.attach_command(name)), "qm #{name}")
    end

    # A fresh QM_ITEM chat, with no live-session check: Start, and a context
    # rotation once it has ended the old chat itself.
    def fresh_chat_plan(item, prompt: nil)
      { mode: :start, cwd: start_cwd(item), argv: [*chat_command, *prompt], env: { "QM_ITEM" => item.slug } }
    end

    # QM_CHAT_COMMAND swaps the program a pane runs (`claude --model haiku`
    # for an end-to-end check, a stand-in in tests); the user's chats run claude.
    def chat_command
      Shellwords.split(ENV.fetch("QM_CHAT_COMMAND", "claude"))
    end

    private

    # Where `claude --resume ID` can actually find the session. Claude Code
    # files a transcript under the project directory for the cwd it was
    # started in, and looks it up the same way — but the two can diverge: a
    # worktree session's transcript lands under the main checkout's directory,
    # and the worktree itself may be gone (adopt-worktree) by the time we
    # resume. So prefer the nearest existing ancestor of the recorded cwd that
    # maps to the directory the transcript is really filed under, and fall
    # back to the recorded cwd when nothing maps (test fixtures, transcripts
    # outside TRANSCRIPTS_DIR). nil means there is nowhere to resume from.
    def resume_cwd(session)
      cwd = session.cwd.to_s
      dir = session.transcript && File.dirname(session.transcript)
      if dir
        path = Pathname.new(cwd).ascend.find { |c| File.directory?(c) && project_dir(c.to_s) == dir }
        return path.to_s if path
      end
      cwd if File.directory?(cwd)
    end

    # Claude Code's project directory for a cwd: the path with every
    # non-alphanumeric character replaced by a dash.
    def project_dir(path)
      File.join(Quartermaster::TRANSCRIPTS_DIR, path.gsub(/[^A-Za-z0-9]/, "-"))
    end

    def worktree_for(root, branch)
      path = Quartermaster.branch_worktrees(root)[branch]
      path if path && File.directory?(path)
    end

    def open_session(cwd, argv, env, title, here)
      cwd = Dir.home unless cwd && File.directory?(cwd)
      if here
        Dir.chdir(cwd)
        exec(env, *argv)
      else
        command = (env.map { |k, v| "#{k}=#{Shellwords.escape(v)}" } + [Shellwords.join(argv)]).join(" ")
        open_warp_tab(cwd, command, title)
      end
    end

    def open_warp_tab(cwd, command, title)
      puts WarpTab.new.open(cwd, title, command: command)
    rescue ArgumentError => e
      abort("qm: #{e.message}")
    end
  end
end
