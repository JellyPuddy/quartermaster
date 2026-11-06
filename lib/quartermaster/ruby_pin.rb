# frozen_string_literal: true

module Quartermaster
  # The Ruby qm runs on, whatever the session's cwd pins: a version in
  # ROOT/ruby-version that the launcher's sh half hands asdf (and mise) as
  # ASDF_RUBY_VERSION. Absent, qm runs on the Ruby the cwd resolves.
  class RubyPin
    FILE = File.join(ROOT, "ruby-version")
    PINNED_VARS = %w[ASDF_RUBY_VERSION MISE_RUBY_VERSION].freeze

    # qm already runs on the pinned Ruby; the processes it starts (chats, dev
    # servers, IDEs) get back the versions the launcher overrode, so they run
    # on the Ruby their own directory pins. Empty means it was unset.
    def self.hand_back_outer_env(env)
      PINNED_VARS.each do |var|
        next unless env.key?("QM_OUTER_#{var}")

        outer = env.delete("QM_OUTER_#{var}")
        outer.empty? ? env.delete(var) : env[var] = outer
      end
    end

    def initialize(path: FILE, asdf_dir: ENV.fetch("ASDF_DATA_DIR", File.expand_path("~/.asdf")))
      @path = path
      @installs = File.join(asdf_dir, "installs", "ruby")
    end

    def version
      text = File.exist?(@path) ? File.read(@path).strip : ""
      text.empty? ? nil : text
    end

    # Without asdf there is nothing to check against, so any version counts.
    def installed?(version)
      !File.directory?(@installs) || File.directory?(File.join(@installs, version))
    end

    def pin(version)
      unless RubyFloor.met?(version)
        raise ArgumentError, "qm needs Ruby >= #{RubyFloor::FLOOR}; #{version} is below that floor"
      end
      unless installed?(version)
        raise ArgumentError, "Ruby #{version} is not installed under asdf (#{@installs}); " \
                             "install it with `asdf install ruby #{version}` first"
      end

      Quartermaster.ensure_setup
      File.write(@path, "#{version}\n")
    end

    def clear
      FileUtils.rm_f(@path)
    end
  end
end
