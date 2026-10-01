module Krang
  module Sessions
    # Pure logic behind the interactive view (GridView): no Hokusai in here, so it
    # can be tested without a window.

    # Public: how to cut one row of cells into things to draw.
    module GridPlan
      # -> [[col, cells, text, style, ascii], ...]
      # Neighbouring ASCII cells with the same style become one string; every other
      # character gets a segment of its own so it can be put exactly on its column
      # (a font's advance for box drawing or CJK is not always one or two cells).
      # The tail cell of a wide character belongs to the segment before it.
      def self.row(cells)
        segs = []
        n = cells.size
        x = 0

        while x < n
          ch, style = cells[x]
          if ch.nil?
            x += 1
            next
          end

          wide = x + 1 < n && cells[x + 1][0].nil?
          w = wide ? 2 : 1
          ascii = ch.bytesize == 1
          last = segs.last

          if ascii && last && last[4] && last[3].equal?(style) && last[0] + last[1] == x
            last[1] += 1
            last[2] << ch
          else
            segs << [x, w, ch.dup, style, ascii] # dup: cells share their strings
          end
          x += w
        end

        segs
      end

      def self.blank?(text)
        text.strip.empty?
      end
    end

    # Public: a linear selection over the cell grid, from where the drag began to
    #         where it is now, in reading order.
    class CellSelection
      attr_reader :anchor, :head

      def initialize(col, row)
        @anchor = [col, row]
        @head = [col, row]
      end

      def extend_to(col, row)
        @head = [col, row]
      end

      def empty?
        @anchor == @head
      end

      # [[col, row], [col, row]] with the first one earlier in the grid
      def ordered
        a, b = @anchor, @head
        (a[1] < b[1] || (a[1] == b[1] && a[0] <= b[0])) ? [a, b] : [b, a]
      end

      # the first and last selected column of a row, or nil
      def span(row, cols)
        (c1, r1), (c2, r2) = ordered
        return nil if row < r1 || row > r2

        [row == r1 ? c1 : 0, row == r2 ? c2 : cols - 1]
      end

      # the selected text; rows are cut at their last character
      def text(screen)
        (c1, r1), (c2, r2) = ordered
        out = []

        (r1..r2).each do |y|
          from = y == r1 ? c1 : 0
          to = y == r2 ? c2 : screen.cols - 1
          line = screen.cells[y][from..to].map { |c| c[0] }.compact.join.rstrip
          out << line
        end

        out.join("\n")
      end
    end

    # Public: what the mouse does over the interactive view.
    #
    # * an app that asked for the mouse (?1000 and friends) gets reports, unless
    #   shift is held, which keeps selecting available
    # * otherwise a drag selects cells, and in the alternate screen the wheel
    #   sends arrow keys (so less and man scroll)
    class GridInput
      attr_reader :selection

      WHEEL_LINES = 3

      def initialize(session)
        @session = session
        @selection = nil
        @selecting = false
        @button = nil # the button an app is being told about
        @last = nil
      end

      def selection?
        !@selection.nil? && !@selection.empty?
      end

      def clear
        @selection = nil
        @selecting = false
      end

      def copy_text
        selection? ? @selection.text(@session.screen) : nil
      end

      # origin - [x, y] of the grid on the window
      def down(event, origin)
        button = event.left.down ? 0 : (event.middle.down ? 1 : (event.right.down ? 2 : nil))
        return unless button

        col, row = cell(event, origin)
        @last = [col, row]

        if reporting?(event)
          @button = button
          report(:press, button, col, row, event)
        elsif button == 0
          @selection = CellSelection.new(col, row)
          @selecting = true
        end
      end

      def move(event, origin)
        col, row = cell(event, origin)
        return if @last == [col, row]

        @last = [col, row]

        if @button
          report(:motion, @button, col, row, event)
        elsif @selecting
          @selection.extend_to(col, row)
        elsif reporting?(event)
          report(:motion, 3, col, row, event) # no button held (mode 1003 only)
        end
      end

      def up(event, origin)
        col, row = cell(event, origin)

        if @button
          report(:release, @button, col, row, event)
          @button = nil
        elsif @selecting
          @selection.extend_to(col, row)
          @selecting = false
          @selection = nil if @selection.empty?
        end
      end

      # event.scroll is 1.0 for down, -1.0 for up
      def wheel(event, origin)
        col, row = cell(event, origin)
        down = event.scroll > 0

        if reporting?(event)
          report(:wheel, down ? 1 : 0, col, row, event)
        elsif @session.screen.alt && @session.screen.alt_scroll
          s = @session.screen
          key = down ? "B" : "A"
          @session.write((s.app_cursor ? "\eO#{key}" : "\e[#{key}") * WHEEL_LINES)
        end
      end

      private

      def reporting?(event)
        @session.screen.mouse_mode != 0 && !mods(event)[0]
      end

      def report(type, button, col, row, event)
        shift, alt, ctrl = mods(event)
        bytes = @session.screen.mouse_report(type, button, col, row, shift: shift, alt: alt, ctrl: ctrl)
        @session.write(bytes) if bytes
      end

      # [shift, alt, ctrl]
      def mods(event)
        kb = event.input.keyboard
        [!!kb.shift, !!kb.alt, !!kb.control]
      end

      def cell(event, origin)
        s = @session.screen
        col = ((event.pos.x - origin[0]) / @session.cell_w).floor
        row = ((event.pos.y - origin[1]) / @session.cell_h).floor
        [[[col, 0].max, s.cols - 1].min, [[row, 0].max, s.rows - 1].min]
      end
    end
  end
end

