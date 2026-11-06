# frozen_string_literal: true

module Quartermaster
  # `qm delete` and the GUI's Delete: removes a work item made by accident.
  # Without force it only removes one that holds nothing beyond what `qm new`
  # gives it, so a slip of the slug can't throw away real work. Its chats on
  # the qm socket are killed through the runner; the append-only logs keep
  # every line, and its sessions simply become unlinked (their ids lived in
  # the item file). Worktrees, branches, issue drafts and plans are left to
  # qm cleanup and qm sweep.
  class ItemDeletion
    # Raised when the guard refuses; an ArgumentError, so the CLI aborts with it.
    class NotEmpty < ArgumentError
      attr_reader :held

      def initialize(slug, held, branches:)
        @held = held
        cleanup = branches ? "; qm cleanup #{slug} first removes its worktrees and branches" : ""
        super("'#{slug}' holds #{held.join(", ")} — qm delete #{slug} --force deletes it anyway#{cleanup}")
      end
    end

    # The Description `qm new` writes when given none.
    PLACEHOLDER = "_TODO_"

    def initialize(runner: CommandRunner.new, tmux: Tmux.new)
      @runner = runner
      @tmux = tmux
    end

    # What the item holds that an accidental one wouldn't: empty means it is
    # safe to delete without force. One session is allowed — the one that
    # created it by mistake.
    def self.held(item)
      held = []
      held << counted(item.notes.size, "note", "notes") if item.notes.any?
      held << counted(item.branches.size, "branch", "branches") if item.branches.any?
      held << counted(item.sessions.size, "session", "sessions") if item.sessions.size > 1
      held << "board set" if item.board
      held << "a description" unless ["", PLACEHOLDER].include?(item.description)
      held
    end

    def self.counted(count, one, many) = "#{count} #{count == 1 ? one : many}"

    # Returns the tmux sessions it killed. Raises NotEmpty when the guard
    # refuses, ArgumentError for an unknown or unusable slug.
    def call(slug, force: false)
      raise ArgumentError, "'#{slug}' is not a work item slug" unless slug.is_a?(String) && slug.match?(Drafts::SLUG)

      WorkItem.with_lock do
        item = WorkItem.find(slug)
        held = self.class.held(item)
        raise NotEmpty.new(slug, held, branches: item.branches.any?) if held.any? && !force

        File.delete(WorkItem.path_for(item.slug))
        kill_chats(item.slug)
      end
    end

    # The GUI's reply: a refusal carries needs_force and what the item holds,
    # so the page can offer "Delete anyway".
    def gui_reply(slug, force:)
      killed = call(slug, force: force)
      { "ok" => true, "deleted" => slug, "killed" => killed }
    rescue NotEmpty => e
      { "ok" => false, "needs_force" => true, "held" => e.held, "error" => e.message }
    end

    private

    # The item's chat and its aside; a session that isn't running fails the
    # kill, which is no error.
    def kill_chats(slug)
      [slug, Aside.session_name(slug)].select do |name|
        @runner.call(@tmux.command("kill-session", "-t", "=#{name}")).success?
      end
    end
  end
end
