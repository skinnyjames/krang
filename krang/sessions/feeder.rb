require_relative "./vtparser"

module Krang
  module Sessions
    # Public: the hot path between raw output and a Screen.
    #
    # The VT parser costs a few microseconds per character, so while it is idle
    # (GROUND) plain text never goes through it: printable ASCII is gathered into
    # runs, other printable characters are drawn directly, and only control
    # characters and escape sequences reach the parser.
    class Feeder
      attr_reader :parser, :screen

      def initialize(screen)
        @screen = screen
        @parser = VTParser.new { |action| @screen.handle(action) }
      end

      PASCII_START = 0x20
      PASCII_END = 0x7f
      EXT_START = 0xa0

      def feed(str)
        run = nil
        parser = @parser
        screen = @screen

        str.each_char do |ch|
          o = ch.ord

          if parser.state == :GROUND
            # add to run instead of parsing if we can
            if o >= PASCII_START && o < PASCII_END
              (run ||= +"") << ch
              next
            end

            if run
              screen.print_ascii(run)
              run = nil
            end

            if o >= EXT_START
              # extended character, print directly to screen model
              screen.print(ch)
              next
            elsif o == 10
              screen.execute(ch)
              next
            elsif o == 13
              screen.execute(ch)
              next
            end
          elsif run
            screen.print_ascii(run)
            run = nil
          end

          parser.parse(ch)
        end

        screen.print_ascii(run) if run
      end
    end
  end
end
