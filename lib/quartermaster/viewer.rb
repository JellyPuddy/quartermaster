# frozen_string_literal: true

module Quartermaster
  class Viewer
    FILTER_FILE = File.join(ROOT, "viewer-filter")
    FILTER_CYCLE = %w[open in_progress fridge resolved all].freeze

    def self.fzf?
      system("command -v fzf >/dev/null 2>&1")
    end

    def self.pick(lines, prompt:)
      out, status = Open3.capture2("fzf", "--prompt=#{prompt} ", "--height=40%", "--reverse",
                                   stdin_data: lines.join("\n"))
      status.success? ? out.strip : nil
    end

    def open
      ensure_fzf!
      Quartermaster.ensure_setup
      File.write(FILTER_FILE, FILTER_CYCLE.first)
      bin = Shellwords.escape(EXECUTABLE)
      rows = "#{bin} viewer-rows"
      show_filter = "echo \"$(cat #{Shellwords.escape(FILTER_FILE)}) > \""
      header = "enter or double-click resume · ^N new session · ^X sessions · ^B inbox · ^R refresh\n" \
               "^S state · ^P project · ^O pr · ^F filter: #{FILTER_CYCLE.join("→")}\n" \
               "^T distill · ^A ack degradation · ^Z snooze"
      binds = [
        "ctrl-r:reload(#{rows})",
        "enter:execute-silent(#{bin} resume {1})",
        "double-click:execute-silent(#{bin} resume {1})",
        "ctrl-n:execute-silent(#{bin} start {1})",
        "ctrl-x:execute(#{bin} sessions-view {1})",
        "ctrl-s:execute(#{bin} choose-state {1})+reload(#{rows})",
        "ctrl-p:execute(#{bin} choose-project {1})+reload(#{rows})",
        "ctrl-o:execute-silent(#{bin} pr {1})",
        "ctrl-b:execute(#{bin} inbox-view)+reload(#{rows})",
        "ctrl-f:execute-silent(#{bin} cycle-filter)+transform-prompt(#{show_filter})+reload(#{rows})",
        "ctrl-t:execute(#{bin} distill {1} && printf '\\n[press enter] ' && read -r _)+reload(#{rows})",
        "ctrl-a:execute-silent(#{bin} ack {1})+reload(#{rows})",
        "ctrl-z:execute(#{bin} choose-snooze {1})+reload(#{rows})"
      ]
      run_fzf(rows, prompt: "#{FILTER_CYCLE.first} > ", header: header,
                    preview: "#{bin} show {1}", binds: binds)
    end

    def sessions_view(slug)
      ensure_fzf!
      item = WorkItem.find(slug)
      bin = Shellwords.escape(EXECUTABLE)
      rows = "#{bin} session-rows #{Shellwords.escape(item.slug)}"
      binds = [
        "enter:execute-silent(#{bin} resume #{Shellwords.escape(item.slug)} --session {1})",
        "ctrl-r:reload(#{rows})"
      ]
      run_fzf(rows, prompt: "#{item.slug} sessions > ",
                    header: "enter resume this session · ^R refresh · esc back",
                    preview: "#{bin} show-session {1}", binds: binds)
    end

    def inbox_view
      ensure_fzf!
      bin = Shellwords.escape(EXECUTABLE)
      rows = "#{bin} inbox-rows"
      binds = [
        "enter:execute(#{bin} attach-session {1})+reload(#{rows})",
        "ctrl-w:execute(#{bin} item-from-session {1})+reload(#{rows})",
        "ctrl-d:execute-silent(#{bin} dismiss {1})+reload(#{rows})",
        "ctrl-r:reload(#{rows})"
      ]
      run_fzf(rows, prompt: "inbox > ",
                    header: "enter attach to a work item · ^D dismiss · ^R refresh\n^W new item from session · esc back",
                    preview: "#{bin} show-session {1}", binds: binds)
    end

    private

    def ensure_fzf!
      abort("qm: the viewer needs fzf (brew install fzf)") unless self.class.fzf?
    end

    def run_fzf(rows_command, prompt:, header:, preview:, binds:)
      options = [
        "--ansi", "--reverse", "--delimiter='\t'", "--with-nth=2..",
        "--prompt=#{quote("#{prompt} ")}",
        "--header=#{quote(header)}",
        "--preview=#{quote(preview)}",
        "--preview-window=right:55%:wrap"
      ]
      options += binds.map { |b| "--bind=#{quote(b)}" }
      system("#{rows_command} | fzf #{options.join(" ")}")
    end

    # Single-quoted so embedded newlines survive (multi-line fzf headers);
    # Shellwords.escape would emit backslash-newline, which sh eats as a
    # line continuation.
    def quote(text)
      "'#{text.gsub("'", "'\\\\''")}'"
    end
  end
end
