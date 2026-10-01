module Krang
  module Blocks
    # Public: the interactive mode. Draws the Screen's cells straight onto the
    #         canvas, row by row, the way a full-screen app laid them out: no
    #         tokens, no wrapping, no scrollback. Input is handled by GridInput
    #         (see Terminal for the event wiring).
    class GridView < Hokusai::Block
      template <<-EOF
      [template]
        virtual
      EOF

      computed! :session
      computed :focused, default: false
      computed :font, default: nil
      computed :size, default: 20, convert: proc(&:to_i)
      computed :color, default: [222, 222, 222], convert: Hokusai::Color
      computed :padding, default: [0.0, 0.0, 0.0, 0.0], convert: Hokusai::Padding
      computed :selection_color, default: [183, 201, 229], convert: Hokusai::Color
      computed :selection_color_to, default: [183, 225, 229], convert: Hokusai::Color
      computed :animate_selection, default: true

      inject :tiling

      def initialize(**args)
        super

        @cw = nil
      end

      def user_font
        font ? Hokusai.fonts.get(font) : Hokusai.fonts.active
      end

      def render(canvas)
        @cw ||= user_font.measure_char("a", size)
        session.set_metrics(@cw, size)
        session.resize(
          [(canvas.width / @cw).floor, 1].max,
          [(canvas.height / size).floor, 1].max
        )
        session.advance(tiling ? tiling.budget : 0.008)

        draw(canvas) if session.alt_screen?

        yield canvas
      end

      private

      def draw(canvas)
        screen = session.screen
        theme = session.theme
        cw = @cw
        ch = size

        if screen.reverse_video
          rect(canvas.x, canvas.y, canvas.width, canvas.height) { |c| c.color = theme.color(theme.fg) }
        end

        selection = session.grid_input.selection

        screen.rows.times do |y|
          py = canvas.y + y * ch
          segs = Sessions::GridPlan.row(screen.cells[y])

          # backgrounds, neighbours of one colour as a single rectangle
          pending = nil
          segs.each do |col, n, _text, style|
            bg = session.look(style).bg
            if pending && bg && pending[2].equal?(bg) && pending[0] + pending[1] == col
              pending[1] += n
            else
              draw_bg(canvas, py, pending)
              pending = bg ? [col, n, bg] : nil
            end
          end
          draw_bg(canvas, py, pending)

          if selection && (span = selection.span(y, screen.cols))
            rect(canvas.x + span[0] * cw, py, (span[1] - span[0] + 1) * cw, ch) { |c| c.color = selection_color }
          end

          segs.each do |col, n, text, style|
            look = session.look(style)
            px = canvas.x + col * cw

            unless Sessions::GridPlan.blank?(text)
              text(text, px, py) do |command|
                command.color = look.fg
                command.size = size
                command.font = user_font if font
              end
            end

            if look.underline
              rect(px, py + ch - 2, n * cw, 1.0) { |c| c.color = look.fg }
            end
            if look.strike
              rect(px, py + (ch / 2.0).floor, n * cw, 1.0) { |c| c.color = look.fg }
            end
          end
        end

        draw_cursor(canvas) if screen.cursor_visible
      end

      def draw_bg(canvas, py, pending)
        return unless pending

        rect(canvas.x + pending[0] * @cw, py, pending[1] * @cw, size) { |c| c.color = pending[2] }
      end

      # block (default), underline or bar by DECSCUSR; an outline when the pane
      # isn't the one with focus
      def draw_cursor(canvas)
        screen = session.screen
        theme = session.theme
        px = canvas.x + screen.cx * @cw
        py = canvas.y + screen.cy * size
        color = theme.color(theme.fg)

        unless focused
          [[px, py, @cw, 1.0], [px, py + size - 1, @cw, 1.0], [px, py, 1.0, size], [px + @cw - 1, py, 1.0, size]].each do |x, y, w, h|
            rect(x, y, w, h) { |c| c.color = color }
          end
          return
        end

        case screen.cursor_style
        when 3, 4
          rect(px, py + size - 2, @cw, 2.0) { |c| c.color = color }
        when 5, 6
          rect(px, py, 2.0, size) { |c| c.color = color }
        else
          rect(px, py, @cw, size) { |c| c.color = color }

          cell = screen.cells[screen.cy][screen.cx]
          if cell[0] && !Sessions::GridPlan.blank?(cell[0])
            text(cell[0], px, py) do |command|
              command.color = theme.color(theme.bg)
              command.size = size
              command.font = user_font if font
            end
          end
        end
      end
    end
  end
end
