
require_relative "./terminal"
require_relative "../util/tiling"

# Handles presentation of a single plane used
# in a recursive window tiling block
# with drag-to-resize
module Krang
  module Blocks
    class Dragger < Hokusai::Block
      template <<-EOF
      [template]
        empty { 
          cursor="pointer"
          @click="drag_start"
          @mousemove="drag_update"
        }
      EOF

      uses(empty: Hokusai::Blocks::Empty)

      computed :vertical, default: false
      computed :size, default: 5.0, convert: proc(&:to_f)
      computed :color, default: [222,222,222], convert: Hokusai::Color

      def drag_start(event)
        return unless event.left.clicked

        @dragging = true
        @start = vertical ? event.pos.y : event.pos.x
        emit("grab")
      end

      def drag_update(event)
        if @dragging && event.left.down
          now = vertical ? event.pos.y : event.pos.x
          emit("update", now - @start) # positive = toward the far edge
        else
          emit("done")
          @dragging = false
        end
      end
      
      def render(canvas)
        if vertical
          @last = canvas.height
        else
          @last = canvas.width
        end

        draw do
          rect(canvas.x, canvas.y, canvas.width, canvas.height) do |command|
            command.color = color
          end
        end

        yield canvas
      end
    end

    # Public: renders one Tile. A leaf becomes a Terminal; a branch becomes an
    #         hblock / vblock holding two more Panes (the block uses itself).
    class Pane < Hokusai::Block
      template <<~EOF
        [template]
          vblock
            [if="leaf"]
              terminal { :tile="tile" }
            [else]
              vblock
                [if="side_by_side"]
                  hblock
                    pane { :tile="first_tile" :width="first_size" }
                    dragger { :width="dragger_size" :color="dragging_color" :vertical="false" @done="done" @grab="begin_drag" @update="update_first_size" }
                    pane { :tile="second_tile" }
                [else]
                  vblock
                    pane { :tile="first_tile" :height="first_size" }
                    dragger { :height="dragger_size" :color="dragging_color" :vertical="true" @done="done" @grab="begin_drag" @update="update_first_size" }
                    pane { :tile="second_tile" }
      EOF

      uses(
        pane: Pane,
        terminal: TerminalSwitcher,
        dragger: Dragger,
        hblock: Hokusai::Blocks::Hblock,
        vblock: Hokusai::Blocks::Vblock
      )

      computed! :tile
      inject :theme
      
      attr_accessor :dragging_color

      MIN_SIZE = 60.0

      def dragger_size
        5.0
      end

      def leaf
        tile.leaf?
      end

      def side_by_side
        tile.dir == :h
      end

      def side_by_side?
        tile.dir == :h
      end

      def first_tile
        tile.a
      end

      def second_tile
        tile.b
      end

      def dragging_color
        @dragging ? theme.display.dragger_focus_color : theme.display.dragger_blur_color
      end

      def begin_drag(*)
        @drag_base = @total * tile.ratio
        @dragging = true
      end

      def done
        @dragging = false
      end

      def update_first_size(delta)
        return unless @drag_base && @total && @total > MIN_SIZE * 2

        size = [[@drag_base + delta, MIN_SIZE].max, @total - MIN_SIZE].min
        tile.ratio = size / @total
      end

      def render(canvas)
        unless tile.leaf?
          @total = side_by_side? ? canvas.width : canvas.height
          @first_size = (@total * tile.ratio).floor - dragger_size
        end

        yield canvas
      end

      # pixel size for the first child, the second one flexes into the rest.
      # nil (before the first frame) means "share equally".
      def first_size
        @first_size
      end
    end
  end
end

