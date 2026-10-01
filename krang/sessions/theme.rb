module Krang
  module Sessions
    # Public: turns the Screen's styles (palette indexes, rgb, flags) into things
    #         that can be drawn. The result is cached on the interned Style, so a
    #         frame only does a lookup per run.
    class Theme
      # What a style looks like on screen.
      #   fg / bg   - Hokusai::Color; bg is nil when it is the default background
      #   stored as an opaque payload on the WrapCache token
      Look = Struct.new(:fg, :bg, :underline, :strike, :italic, :bold)

      SIMPLE = [
        [0, 0, 0], [226, 81, 144], [102, 206, 99], [206, 202, 99],
        [131, 207, 234], [198, 93, 191], [133, 220, 252], [233, 233, 233]
      ].freeze

      BRIGHT = [
        [102, 102, 102], [255, 110, 168], [140, 240, 138], [240, 236, 140],
        [170, 225, 250], [230, 140, 225], [170, 240, 255], [255, 255, 255]
      ].freeze

      attr_reader :fg, :bg, :gen

      # fg / bg - [r, g, b] of the default text and background colours
      def initialize(style, fg: style.display.text_focus_color, bg: style.display.background_focus_color)
        @fg = [fg.r, fg.g, fg.b]
        @bg = [bg.r, bg.g, bg.b]
        @gen = 0
        @colors = {}
        @palette = build_palette
      end

      def fg=(rgb)
        @fg = rgb
        @gen += 1
      end

      def bg=(rgb)
        @bg = rgb
        @gen += 1
      end

      # -> Look
      def look(style, reverse = false)
        cached = style.extra
        return cached[1] if cached && cached[0] == @gen && cached[2] == reverse

        look = resolve(style, reverse)
        style.extra = [@gen, look, reverse]
        look
      end

      # [r, g, b] for a palette index (0..255)
      def rgb(index)
        @palette[index]
      end

      # a Hokusai::Color for [r, g, b], shared between calls
      def color(rgb)
        @colors[rgb[0] << 16 | rgb[1] << 8 | rgb[2]] ||= Hokusai::Color.convert(rgb)
      end

      private

      def resolve(style, reverse)
        flags = style.flags
        default_fg = reverse ? @bg : @fg
        default_bg = reverse ? @fg : @bg

        fg = rgb_of(style.fg, flags & Style::BOLD != 0)
        bg = rgb_of(style.bg, false)

        if flags & Style::INVERSE != 0
          fg, bg = (bg || default_bg), (fg || default_fg)
        end

        fg ||= default_fg
        fg = blend(fg, bg || default_bg, 0.55) if flags & Style::DIM != 0
        fg = bg || default_bg if flags & Style::HIDDEN != 0

        Look.new(
          color(fg),
          bg && color(bg),
          flags & Style::UNDERLINE != 0,
          flags & Style::STRIKE != 0,
          flags & Style::ITALIC != 0,
          flags & Style::BOLD != 0
        )
      end

      # bold text in one of the first 8 colours uses the bright variant (xterm's default)
      def rgb_of(spec, bold)
        return nil if spec.nil?
        return spec if spec.is_a?(Array)

        spec += 8 if bold && spec < 8
        @palette[spec]
      end

      def blend(a, b, amount)
        [0, 1, 2].map { |i| (a[i] * amount + b[i] * (1 - amount)).round }
      end

      def build_palette
        palette = SIMPLE + BRIGHT
        (0..5).each do |r|
          (0..5).each do |g|
            (0..5).each do |b|
              palette << [r > 0 ? r * 40 + 55 : 0, g > 0 ? g * 40 + 55 : 0, b > 0 ? b * 40 + 55 : 0]
            end
          end
        end
        24.times { |i| v = 8 + i * 10; palette << [v, v, v] }
        palette
      end
    end
  end
end

