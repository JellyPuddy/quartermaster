# frozen_string_literal: true

module Quartermaster
  # The one door to external tools that change things outside qm's own files
  # (the dev server, the IDE, `git worktree add`, the test-DB command). Everything that
  # shells out to them takes a runner, so tests pass a stub and never touch a
  # real dev server, IDE or repo.
  class CommandRunner
    Result = Struct.new(:out, :err, :success, keyword_init: true) do
      def success? = success
    end

    # The user's personal tools live in ~/bin, which a GUI started from a
    # launcher (or a hook) may not have on PATH.
    PERSONAL_BIN = File.expand_path("~/bin")

    # out/err: file paths the command's stdout/stderr are appended to as it
    # runs (a long run read live by someone else); the Result then holds
    # neither.
    def call(argv, chdir: nil, out: nil, err: nil)
      argv = [resolve(argv.first), *argv.drop(1)]
      options = chdir ? { chdir: chdir } : {}
      return stream(argv, options, out, err) if out || err

      stdout, stderr, status = Open3.capture3(*argv, **options)
      Result.new(out: stdout, err: stderr, success: status.success?)
    rescue SystemCallError => e
      Result.new(out: "", err: e.message, success: false)
    end

    private

    def stream(argv, options, out, err)
      pid = Process.spawn(*argv, in: File::NULL, out: [out || File::NULL, "a"], err: [err || File::NULL, "a"], **options)
      _, status = Process.wait2(pid)
      Result.new(out: "", err: "", success: status.success?)
    end

    def resolve(name)
      return name if name.include?("/")

      personal = File.join(PERSONAL_BIN, name)
      File.executable?(personal) ? personal : name
    end
  end
end
