# frozen_string_literal: true

module Quartermaster
  # Option parsing for commands that take free text (new, note, retitle,
  # describe, board-answer): an argument that starts with `-` and holds
  # whitespace ("- a bullet") is text, not an option, and `--` ends options.
  module FreeTextArgs
    module_function

    # The positional arguments left after `parser` takes its options, in order.
    # Text never reaches the parser on its own, so it can't be taken for an
    # abbreviated option ("-d does stuff" as --description); right after an
    # option that wants a value, it is that value.
    def parse(parser, argv)
      rest = argv.dup
      positional = []
      until rest.empty?
        segment = rest.shift(rest.index { |arg| arg == "--" || text?(arg) } || rest.size)
        begin
          parser.order!(segment) { |arg| positional << arg }
        rescue OptionParser::MissingArgument => e
          raise unless rest.first && text?(rest.first)

          parser.order!([e.args.first, rest.shift])
          next
        end
        next if rest.empty?

        arg = rest.shift
        next positional << arg unless arg == "--"

        positional.concat(rest)
        break
      end
      positional
    end

    # Commands without options: only a leading `--` needs dropping.
    def words(argv)
      argv.first == "--" ? argv.drop(1) : argv
    end

    def text?(arg)
      arg.start_with?("-") && arg.match?(/\s/) && !arg.match?(/\A--[^\s=]+=/)
    end
  end
end
