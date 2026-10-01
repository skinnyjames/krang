require_relative "./pick"
require_relative "./pane"

module Krang
  module Blocks
    # Public: Current entry point for the application
    #         Manages the tiling service, which handles the tile tree and the 
    #         PTY Sessions
    #         
    #         pane is our recursive tile
    #         vblock.backdrop is a modal for plugins
    class Root < Hokusai::Block
      template <<~EOF
        [template]
          vblock { :background="[14,14,14]" @keypress="on_keypress" }
            pane { :tile="root_tile" }
      EOF

      uses(
        vblock: Hokusai::Blocks::Vblock,
        hblock: Hokusai::Blocks::Hblock,
        empty: Hokusai::Blocks::Empty,
        pane: Krang::Blocks::Pane,
        pickmenu: Krang::Blocks::PickMenu
      )

      inject :theme
      provide :tiling, :tiling

      DIM = Hokusai::Color.convert([0, 0, 0, 150])

      def initialize(**args)
        super

        @root_rect = [0.0, 0.0, 900.0, 600.0]
        Hokusai.on_exit { tiling.close_all }
      end

      def tiling
        @tiling ||= Util::Tiling.new(theme)
      end

      def root_tile
        tiling.root
      end

      def before_updated
        tiling.tick
      end

      def render(canvas)
        @root_rect = [canvas.x, canvas.y, canvas.width, canvas.height]

        yield canvas
      end

      # -- picker overlay ------------------------------------------------------

      def picking
        tiling.picking?
      end

      def pick_state
        tiling.pick
      end

      def dim
        DIM
      end

      # the pane that asked, or the whole window until it has been drawn once
      def pick_rect
        tile = pick_state.session.tile
        tiling.rect_of(tile) || @root_rect
      end

      # Boundary is (top, right, bottom, left) relative to the root rect
      def pick_bounds
        px, py, pw, ph = pick_rect
        rx, ry, rw, rh = @root_rect
        Hokusai::Boundary.new(py - ry, pw - rw, ph - rh, px - rx)
      end

      def pick_layout
        _x, _y, w, h = pick_rect
        pick_state.layout(w, h)
      end

      def pick_box_width
        pick_layout[0]
      end

      def pick_box_height
        pick_layout[1]
      end

      def pick_top_gap
        pick_layout[2]
      end

      def stop_event(event)
        event.stop
      end

      # clicking outside the box cancels
      def on_backdrop(event)
        event.stop
        tiling.finish_pick(:cancel) if event.left.clicked
      end

      def on_pick_resolved(kind)
        tiling.finish_pick(kind)
      end

      # -- keys ----------------------------------------------------------------

      def on_keypress(event)
        if tiling.picking?
          tiling.paste if (event.super || event.ctrl) && event.symbol == :v
          tiling.send_key(event) unless (event.super || event.ctrl)
          return
        end

        if event.super || (event.ctrl && event.alt)
          case event.symbol
          when :d
            tiling.split(event.shift ? :v : :h)
            return
          when :w
            tiling.close(tiling.focused_tile)
            return
          when :v
            tiling.paste
            return
          when :left, :right, :up, :down
            tiling.focus_dir(event.symbol)
            return
          end
        end

        tiling.send_key(event)
      end
    end
  end
end