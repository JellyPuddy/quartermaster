# frozen_string_literal: true

module Quartermaster
  # Commands about how qm itself runs on this machine.
  module CliSetup
    COMMANDS = {
      "pin-ruby" => :cmd_pin_ruby,
      "doctor" => :cmd_doctor
    }.freeze

    private

    def cmd_doctor(_argv)
      doctor = Doctor.new
      doctor.checks.each { |check| puts check.line }
      exit(1) if doctor.failed?
    end

    def cmd_pin_ruby(argv)
      pin = RubyPin.new
      case argv.first
      when "--clear"
        pin.clear
        puts "qm is unpinned: it runs on whatever Ruby each session's directory resolves"
      when nil, /\A\d+(\.\d+)*\z/
        version = argv.first || RUBY_VERSION
        pin.pin(version)
        puts "qm runs on Ruby #{version} from now on, hooks included (qm pin-ruby --clear undoes it)"
      else
        abort("usage: qm pin-ruby [VERSION|--clear]")
      end
    end
  end
end
