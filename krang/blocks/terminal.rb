require_relative "./ansi"
require_relative "./grid_view"

module Krang
  module Blocks
    class PluginContainer < Hokusai::Block
      template <<~EOF
      [template]
        empty { @close="close" }
      EOF

      uses(empty: Hokusai::Blocks::Empty)

      computed! :plugin
      computed! :session

      def close
        emit("close")
      end

      def on_mounted
        node.meta.set_child(0, plugin)
      end
    end

    # Public: one tile's view, bound to a Session kept in the shared Tiling service.
    #
    # Two modes, swapped as a whole by [if="interactive"]:
    #
    # * regular: Panel + Selectable + Ansi - history and the screen rows as one
    #   scrolling stream, with text selection
    # * interactive (the alternate screen: vim, less, htop): GridView draws the
    #   cell grid; the mouse belongs to the app (or selects cells)
    #
    # The blocks hold no terminal state, so a swap loses nothing.
    class Terminal < Hokusai::Block
      style <<~EOF
      [style]
      text {
        animate_selection: true;
        color: rgb(222,222,222);
        text_color: rgb(222,222,222);
        padding: padding(0.0, 0.0, 0.0, 0.0);
      }
      cursor {
        cursor_color: rgb(222,222,222);
      }
      panel {
        align: "bottom";
      }
      EOF

      template <<-EOF
      [template]
        vblock { :background="background" }
          [if="interactive"]
            vblock { @mousedown="grid_down" @mouseup="grid_up" @mousemove="grid_move" @wheel="grid_wheel" @keypress="on_keypress" :padding="theme.display.window_padding" }
              gridview { ...text :size="theme.display.font_size" :session="session" :focused="focused" :selection_color="theme.display.selection_color" :selection_color_to="theme.display.selection_to_color" }
          [else]
            panel { 
              ...panel 
              @keypress="on_keypress"
              @content_height="handle_height"
              @scroll="clear_scroll"
              :scroll_goto="scroll" 
              :content_padding="theme.display.window_padding"
              :scroll_background="theme.display.scrollbar_color"
              :scroll_color="theme.display.scrollbar_wheel_color"
            }
              vblock { :padding="theme.display.window_padding" :height="ansi_height" }
                selectable { :selection_override="selection" :vertical="true" :cursor_color="theme.display.cursor_color" }
                  ansi { 
                    ...text 
                    :size="theme.display.font_size" 
                    :session="session" 
                    :focused="focused" 
                    :copy_text="copy" 
                    @copy="on_copy"
                    @height_updated="ansi_height_update" 
                    :selection_color="theme.display.selection_color" 
                    :selection_color_to="theme.display.selection_to_color"
                    :inset="theme.display.window_padding.height"
                  }
      EOF

      uses(
        ansi: Ansi,
        gridview: GridView,
        container: PluginContainer,
        vblock: Hokusai::Blocks::Vblock,
        selectable: Hokusai::Blocks::Selectable,
        panel: Hokusai::Blocks::Panel
      )

      computed! :tile
      inject :tiling
      inject :theme

      attr_accessor :scroll, :copy, :ansi_height

      def initialize(**args)
        super

        @copy = false
        @scroll = nil
        @last_height = nil
        @was_focused = nil
        @was_blocked = false
        @was_interactive = false
        @ansi_height = 0.0
      end

      def close_plugin
        session.active_plugin = nil
      end

      # -- bindings ------------------------------------------------------------

      def session
        tiling.session(tile)
      end

      def selection
        session.selection
      end

      def focused
        tiling.focused?(tile)
      end

      def plugin
        session.active_plugin
      end

      # the program switched to the alternate screen
      def interactive
        session.alt_screen?
      end

      def background
        focused ? theme.display.background_focus_color : theme.display.background_blur_color
      end

      # -- events --------------------------------------------------------------

      def ansi_height_update(height)
        self.ansi_height = height + theme.display.window_padding.height
      end

      # The pane Tiling considers active, and not blurred by a z-layer above us
      # (the painter blurs everything under a z-indexed block when it is clicked).
      def active?
        focused && node.meta.focused
      end

      def on_keypress(event)
        return unless active?

        if interactive
          copy_cells if event.symbol == :c && (event.super || (event.ctrl && event.shift))
        elsif event.symbol == :c && (event.super || event.ctrl)
          self.copy = true
        end
      end

      def copy_cells
        text = session.grid_input.copy_text
        return unless text

        Hokusai.copy(text)
        session.grid_input.clear
      end

      def on_copy(_text)
        self.copy = false
      end

      # -- interactive mode: the mouse -------------------------------------------

      # where the grid starts on the window
      def origin
        r = tiling.rect_of(tile)
        r ? [r[0], r[1]] : [0.0, 0.0]
      end

      def grid_down(event)
        return if tiling.picking?

        tiling.focus(tile.id)
        session.grid_input.down(event, origin)
      end

      def grid_up(event)
        return if tiling.picking?

        session.grid_input.up(event, origin)
      end

      def grid_move(event)
        return if tiling.picking?

        session.grid_input.move(event, origin)
      end

      def grid_wheel(event)
        return if tiling.picking?

        session.grid_input.wheel(event, origin)
      end

      # -- regular mode: following the output ---------------------------------------

      # follow the output while it grows
      def handle_height(height)
        return if height == @last_height

        self.scroll = height
        @last_height = height
      end

      def clear_scroll(_y, percent: nil)
        self.scroll = nil
      end

      def before_updated
        sync_focus
        sync_mode

        # typing snaps back to the bottom
        if session.take_stick && @last_height
          self.scroll = @last_height 
        end
      end

      # Coming back from interactive mode mounts a fresh Panel, which starts at
      # the top. Forgetting the height we knew makes its first height report count
      # as new, and that scrolls it to the bottom.
      def sync_mode
        return if interactive == @was_interactive

        @was_interactive = interactive
        return if interactive

        @last_height = nil
        self.scroll = nil
      end

      # Tiling and the painter each know part of who is focused:
      #
      # * a click: the painter focuses the node under the pointer, so we tell Tiling
      # * Cmd+arrows, split, close: only Tiling knows, so we focus / blur the node
      # * an overlay closing: the painter blurred everything under it and never
      #   undoes that, so the active pane takes its focus back
      #
      # While an overlay is open nothing is touched: whatever changed meanwhile is
      # picked up on the first frame after it closes.
      def sync_focus
        if tiling.picking?
          @was_blocked = true
          return
        end

        if focused != @was_focused
          focused ? node.meta.focus : node.meta.blur
          # apps that asked for focus reports (?1004), once we know it's a change
          session.write(focused ? "\e[I" : "\e[O") if !@was_focused.nil? && session.screen.focus_events
        elsif node.meta.focused && !focused
          tiling.focus(tile.id)
        end

        node.meta.focus if @was_blocked && focused

        @was_focused = focused
        @was_blocked = false
      end

      def render(canvas)
        tiling.report(tile, canvas)

        yield canvas
      end
    end

    class TerminalSwitcher < Hokusai::Block
      template <<~EOF
      [template]
        vblock { @keypress="switch_plugin_view" }
          [if="plugin"]
            container { @close="close_plugin" :plugin="plugin" }
          [else]
            terminal { :tile="tile" }
      EOF

      uses(container: PluginContainer, terminal: Terminal, vblock: Hokusai::Blocks::Vblock)

      computed! :tile
      inject :tiling

      def session
        tiling.session(tile)
      end

      def plugin
        session.active_plugin
      end

      def close_plugin
        session.active_plugin = nil
        @active_plugin = nil
      end

      def switch_plugin_view(event)
        return unless event.ctrl || event.super

        if event.symbol == :s && session.active_plugin
          @active_plugin = session.active_plugin
          session.active_plugin = nil
        elsif event.symbol == :s && @active_plugin
          session.active_plugin = @active_plugin
        end
      end
    end
  end
end



