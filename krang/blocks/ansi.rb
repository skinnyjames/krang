module Krang
  module Blocks
    # Public: renders one Session's tokens inside a Panel/Selectable.
    #         All terminal state lives in the Session; this block only draws.
    class Ansi < Hokusai::Block
      template <<-EOF
      [template]
        virtual
      EOF

      computed! :session
      computed :inset, default: 0.0, convert: proc(&:to_f)
      computed :focused, default: false
      computed :font, default: nil
      computed :size, default: 20, convert: proc(&:to_i)
      computed :color, default: [22, 22, 22], convert: Hokusai::Color
      computed :padding, default: [0.0, 0.0, 0.0, 0.0], convert: Hokusai::Padding
      computed :selection_color, default: [183, 201, 229], convert: Hokusai::Color
      computed :selection_color_to, default: [183, 225, 229], convert: Hokusai::Color
      computed :animate_selection, default: true
      computed :copy_text, default: false

      inject :panel_offset
      inject :panel_height
      inject :selection
      inject :tiling

      def initialize(**args)
        super

        @progress = 0
        @back = false
        @last_height = nil
        @cw = nil
      end

      def user_font
        font ? Hokusai.fonts.get(font) : Hokusai.fonts.active
      end

      def offset
        panel_offset || 0.0
      end

      def top
        offset + padding.top
      end

      def height(canvas)
        panel_height || canvas.height
      end

      def fshader
        <<-EOF
        #version 330
        in vec4 fragColor;
        in vec2 fragTexCoord;
        out vec4 finalColor;
        uniform sampler2D texture0;
        uniform vec4 from;
        uniform vec4 to;
        uniform float progress;

        void main() {
          vec4 texelColor = texture(texture0, fragTexCoord) * fragColor;

          finalColor.a = texelColor.a;
          finalColor.rgb = mix(from, to, progress).rgb;
        }
        EOF
      end

      def update_height
        h = (session.content_height + padding.height).ceil
        return if h == @last_height

        @last_height = h
        node.meta.set_prop(:height, h)
        emit("height_updated", h)
      end

      def render(canvas)
        # -- keep the session in step with what we can show
        @cw ||= user_font.measure_char("a", size)
        session.set_metrics(@cw, size)
        session.ensure_stream(canvas.x, canvas.y + padding.top)
        session.rebase_x(canvas.x)

        viewport = panel_height ? panel_height - inset : canvas.height
        session.resize(
          [((canvas.width - padding.width) / @cw).floor, 1].max,
          [(viewport / size).floor, 1].max
        )

        session.advance(tiling ? tiling.budget : 0.008)
        update_height

        token_cache = session.cache
        return if token_cache.tokens.empty?

        diff = canvas.y.round(2) + offset.round(2) - token_cache.tokens.first.y.round(2)
        token_cache.diff_y = diff
        panel_top = canvas.y + offset # where the content starts, unscrolled
        tokens = token_cache.tokens_for(Hokusai::Canvas.new(canvas.width, height(canvas), canvas.x, panel_top + top))

        # -- backgrounds the program asked for, under everything else
        tokens.each do |wrapped|
          bg = wrapped.extra.bg
          next unless bg

          rect(wrapped.x + padding.left, wrapped.y + diff + padding.top - offset, wrapped.width, wrapped.height) do |command|
            command.color = bg
          end
        end

        # -- selection + cursor (only the focused pane owns them)
        if selection && (focused || node.uuid == selection.focus_id)
          selection.clear if selection.focus_id != node.uuid && !focused

          selection.cursor = nil unless focused
          selection.focus_id = node.uuid
          selection.offset_y = offset

          if animate_selection && selection.geom?
            shader_begin do |command|
              command.fragment_shader = fshader
              command.uniforms = {
                "from" => [selection_color.to_shader_value, HP_SHADER_UNIFORM_VEC4],
                "to" => [selection_color_to.to_shader_value, HP_SHADER_UNIFORM_VEC4],
                "progress" => [@progress, HP_SHADER_UNIFORM_FLOAT]
              }
            end
          end

          token_cache.selected_area_for_tokens(tokens, selection, padding: padding) do |rect|
            rect(rect.x, rect.y, rect.width, rect.height) do |command|
              command.color = selection_color
            end
          end

          if focused && !session.selection_active?
            if session.screen.cursor_visible
              cx, cy = session.terminal_cursor
              selection.geom.modified = true # lets the setter through in geom mode
              selection.cursor = [cx + padding.left, cy + padding.top + diff, 0.5, size]
            else
              selection.cursor = nil # the program hid it (ESC [ ? 25 l)
            end
          end

          if copy_text
            full = session.full_text # padded: token positions are absolute
            copystuff = token_cache.selected_text(full, selection)
            Hokusai.copy(copystuff)
            emit("copy", copystuff)
          end

          shader_end if animate_selection && selection.geom?
        end

        # -- text
        tokens.each do |wrapped|
          look = wrapped.extra
          tx = wrapped.x + padding.left
          ty = wrapped.y + diff + padding.top - offset

          text(wrapped.text, tx, ty) do |command|
            command.color = look.fg
            command.size = size
            command.font = user_font if font
          end

          if look.underline
            rect(tx, ty + wrapped.height - 2, wrapped.width, 1.0) { |command| command.color = look.fg }
          end
          if look.strike
            rect(tx, ty + (wrapped.height / 2.0).floor, wrapped.width, 1.0) { |command| command.color = look.fg }
          end
        end

        # -- selection shimmer
        @progress += (@back ? -0.02 : 0.02)
        if @progress >= 1 && !@back
          @back = true
        elsif @progress <= 0 && @back
          @progress = 0
          @back = false
        end

        yield canvas
      end
    end
  end
end

