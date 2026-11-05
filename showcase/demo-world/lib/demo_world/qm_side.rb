# frozen_string_literal: true

module DemoWorld
  QM_LIB = File.expand_path("../../../../lib/quartermaster", __dir__)

  # Seeding through qm's own code: a `qm` command, or a Ruby snippet with
  # qm's lib loaded, run in a child process with only the world's env, so
  # QM_ROOT and friends are the world's when qm's constants are computed —
  # never the seeding process's (a test's, or the user's).
  class World
    # Loaded before a snippet: `DATA_IN` is the JSON handed over on stdin;
    # `on_day(date) { ... }` makes qm's writers stamp that day (notes,
    # snapshots, `created`) so the world's history spreads over the past days.
    QM_PRELUDE = <<~RUBY
      require #{QM_LIB.inspect}
      module DemoToday
        def today(*args) = Thread.current[:demo_today] || super
      end
      Date.singleton_class.prepend(DemoToday)
      def on_day(date)
        Thread.current[:demo_today] = Date.parse(date.to_s)
        yield
      ensure
        Thread.current[:demo_today] = nil
      end
      DATA_IN = JSON.parse($stdin.read)
    RUBY

    def qm!(*args, chdir: home, extra_env: {})
      run!(RbConfig.ruby, QM_EXECUTABLE, *args, chdir: chdir, extra_env: extra_env)
    end

    # Runs source with qm loaded; returns its stdout parsed as JSON when it
    # printed any.
    def qm_ruby!(source, data = {}, chdir: home)
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", "#{QM_PRELUDE}#{source}",
                                        stdin_data: JSON.generate(data), chdir: chdir, unsetenv_others: true)
      raise "qm snippet failed: #{err}#{out}" unless status.success?

      out.strip.empty? ? nil : JSON.parse(out)
    end

    # Who said what when: shared by every seeding step.
    def cast = @cast ||= Cast.new(self)

    def git!(repo, *args, extra_env: {}) = run!("git", *args, chdir: repo, extra_env: extra_env)

    # A worktree of one of the repos: .claude/worktrees/<dir>.
    def worktree(repo_name, dir) = File.join(repo(repo_name), ".claude", "worktrees", dir)

    def append_jsonl(path, rows)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| rows.each { |row| f.puts(JSON.generate(row)) } }
    end
  end
end
