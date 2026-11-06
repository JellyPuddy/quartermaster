# frozen_string_literal: true

module Quartermaster
  # The Ruby qm runs on, whatever the session's cwd pins: a version in
  # ROOT/ruby-version that the launcher's sh half hands asdf (and mise) as
  # ASDF_RUBY_VERSION. Absent, qm runs on the Ruby the cwd resolves.
  class RubyPin
    FILE = File.join(ROOT, "ruby-version")

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
