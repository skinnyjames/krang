
require_relative "../util/wcwidth"

module Krang
  module Sessions
    # Public: an interned set of text attributes. Cells hold a reference to one,
    #         so "same style" is an identity check (that's what makes merging cells
    #         into runs cheap).  Used as opaque payload in Hokusai::Util::WrapStream
    #
    #   fg / bg - nil (default), 0..255 (palette index) or [r, g, b]
    class Style
      BOLD = 1
      DIM = 2
      ITALIC = 4
      UNDERLINE = 8
      BLINK = 16
      INVERSE = 32
      HIDDEN = 64
      STRIKE = 128

      attr_reader :fg, :bg, :flags
      attr_accessor :extra # whatever the renderer wants to cache per style

      def self.get(fg, bg, flags)
        @cache ||= {}
        @cache = {} if @cache.size > 4096 # truecolor can mint a lot of them
        key = "#{fg.is_a?(Array) ? fg.join(',') : fg}/#{bg.is_a?(Array) ? bg.join(',') : bg}/#{flags}"
        @cache[key] ||= new(fg, bg, flags)
      end

      # Public: An empty style
      # 
      # Returns Style
      def self.default
        @default ||= get(nil, nil, 0)
      end

      def initialize(fg, bg, flags)
        @fg = fg
        @bg = bg
        @flags = flags
        @extra = nil
      end

      def with_fg(c)
        Style.get(c, @bg, @flags)
      end

      def with_bg(c)
        Style.get(@fg, c, @flags)
      end

      def set(flag)
        Style.get(@fg, @bg, @flags | flag)
      end

      def clear(flag)
        Style.get(@fg, @bg, @flags & ~flag)
      end

      def flag?(flag)
        @flags & flag != 0
      end

      def default?
        @fg.nil? && @bg.nil? && @flags == 0
      end
    end

    # Public: a terminal screen model. Pure Ruby with no UI dependency: feed it
    #         parser actions, read cells and history back.
    #
    #   A cell is [char, style]. A wide character takes two cells: [char, style]
    #   followed by [nil, style]. Rows are arrays of exactly `cols` cells.
    class Screen
      BLANK = [" ", Style.default].freeze
      HISTORY_LIMIT = 5000
      HISTORY_SLACK = 250 # trim in batches so a flood doesn't trim on every line
      MAX_WRAPPED_ROWS = 1000
      
      # Special Graphics Charset
      # see https://vt100.net/docs/vt100-ug/chapter3.html
      GRAPHICS = {
        "`" => "\u25c6", "a" => "\u2592", "b" => "\u2409", "c" => "\u240c", "d" => "\u240d",
        "e" => "\u240a", "f" => "\u00b0", "g" => "\u00b1", "h" => "\u2424", "i" => "\u240b",
        "j" => "\u2518", "k" => "\u2510", "l" => "\u250c", "m" => "\u2514", "n" => "\u253c",
        "o" => "\u23ba", "p" => "\u23bb", "q" => "\u2500", "r" => "\u23bc", "s" => "\u23bd",
        "t" => "\u251c", "u" => "\u2524", "v" => "\u2534", "w" => "\u252c", "x" => "\u2502",
        "y" => "\u2264", "z" => "\u2265", "{" => "\u03c0", "|" => "\u2260", "}" => "\u00a3",
        "~" => "\u00b7", "_" => "\u00a0"
      }.freeze

      attr_reader :cols, :rows, :cx, :cy, :alt, :title, :cwd, :lines, :pending, :history_gen, :trimmed,
                  :app_cursor, :app_keypad, :bracketed_paste, :focus_events, :mouse_mode,
                  :mouse_encoding, :alt_scroll, :cursor_visible, :cursor_style, :reverse_video,
                  :autowrap, :origin, :insert_mode, :newline_mode, :top, :bottom
      attr_accessor :on_response, :on_bell, :on_title, :on_osc, :on_history_row,
                    :default_fg, :default_bg

      # Public: Initialize a screen
      #  
      # cols - the number of colums for the screen
      # rows - the number of rows for the screen 
      # 
      def initialize(cols = 80, rows = 24)
        @cols = cols
        @rows = rows
        @primary = new_buffer # normal screen mode
        @alt_buf = new_buffer # alternate screen mode (see vim/less/etc)
        @buf = @primary
        @alt = false
        @lines = [] # history: logical lines (soft-wrapped rows joined), as [text, style] runs
        @pending = [] # runs of a soft-wrapped line whose first rows have scrolled off
        @pending_rows = 0
        @history_gen = 0 # bumped whenever existing history is rewritten or cleared
        @trimmed = 0 # how many of the oldest lines have been dropped for good
        @title = ""
        @cwd = nil
        @osc = nil
        @saved = [nil, nil]
        @last_char = nil
        @default_fg = nil
        @default_bg = nil
        reset_state
      end

      # ---- reading ------------------------------------------------------------

      def cells
        @buf.cells
      end

      def soft
        @buf.soft
      end

      def row_text(i)
        @buf.cells[i].map { |c| c[0] }.compact.join.rstrip
      end

      # [[text, style], ...] for one row of the screen, trailing default blanks cut
      def row_runs(y)
        runs_of(@buf.cells[y], true)
      end

      def text_rows
        (0...@rows).map { |i| row_text(i) }
      end

      # the whole history as plain text, one entry per logical line
      def history_text
        @lines.map { |runs| runs.map { |t, _| t }.join }
      end

      # ---- feeding ------------------------------------------------------------

      # Handles one VTParser action.
      def handle(a)
        case a.action_type
        when :print
          print(a.ch)
        when :execute
          execute(a.ch)
        when :csi_dispatch
          csi(a.private_mode_intermediate_char, a.intermediate_chars, a.params, a.ch)
        when :esc_dispatch
          esc(a.intermediate_chars, a.ch)
        when :osc_start
          @osc = +""
        when :osc_put
          (@osc ||= +"") << a.ch
        when :osc_end
          osc(@osc.to_s)
          @osc = nil
        end
      end

      # Printable ASCII only (0x20..0x7e), many characters at a time.
      def print_ascii(str)
        if @insert_mode || @charsets[@gl] != :ascii
          str.each_char { |c| print(c) }
          return
        end

        @last_char = str[-1]
        i = 0
        n = str.size
        while i < n
          if @pending_wrap
            if @autowrap
              wrap_line
            else
              @pending_wrap = false
            end
          end

          room = @cols - @cx
          take = n - i < room ? n - i : room
          row = @buf.cells[@cy]
          st = @style

          row[@cx - 1] = @blank if @cx > 0 && row[@cx][0].nil? # we're about to cut a wide char in half
          k = @cx
          str[i, take].each_char do |c|
            row[k] = [c, st]
            k += 1
          end
          row[k] = @blank if k < @cols && row[k][0].nil?

          i += take
          @cx += take
          if @cx >= @cols
            @cx = @cols - 1
            @pending_wrap = true if @autowrap
          end
        end
      end

      def print(ch)
        ch = GRAPHICS[ch] || ch if @charsets[@gl] == :graphics
        cp = ch.ord
        w = cp < 0x300 ? 1 : Util::Wcwidth.of(cp)
        return combine(ch) if w == 0

        @last_char = ch
        if @pending_wrap
          if @autowrap
            wrap_line
          else
            @pending_wrap = false
          end
        end

        if w == 2 && @cx == @cols - 1
          return unless @autowrap

          @buf.cells[@cy][@cx] = @blank
          wrap_line
        end

        row = @buf.cells[@cy]
        if @insert_mode
          w.times do
            row.insert(@cx, @blank)
            row.pop
          end
        end

        row[@cx - 1] = @blank if @cx > 0 && row[@cx][0].nil?
        if w == 2
          row[@cx + 2] = @blank if @cx + 2 < @cols && row[@cx + 1][0].nil?
          row[@cx] = [ch, @style]
          row[@cx + 1] = [nil, @style]
        else
          row[@cx + 1] = @blank if @cx + 1 < @cols && row[@cx + 1][0].nil?
          row[@cx] = [ch, @style]
        end

        @cx += w
        if @cx >= @cols
          @cx = @cols - 1
          @pending_wrap = true if @autowrap
        end
      end

      def execute(ch)
        case ch
        when "\n", "\v", "\f" then linefeed
        when "\r" then carriage_return
        when "\b" then backspace
        when "\t" then tab(1)
        when "\a" then @on_bell&.call
        when "\u000e" then @gl = 1
        when "\u000f" then @gl = 0
        when "\u0084" then index_down
        when "\u0085" then next_line
        when "\u0088" then @tabs[@cx] = true
        when "\u008d" then reverse_index
        end
      end

      # ---- escape sequences -----------------------------------------------------

      def esc(inter, final)
        case inter
        when ""
          case final
          when "7" then save_cursor
          when "8" then restore_cursor
          when "D" then index_down
          when "E" then next_line
          when "H" then @tabs[@cx] = true
          when "M" then reverse_index
          when "c" then full_reset
          when "=" then @app_keypad = true
          when ">" then @app_keypad = false
          when "Z" then respond("\e[?62;22c")
          when "n" then @gl = 2
          when "o" then @gl = 3
          end
        when "(", ")", "*", "+"
          slot = { "(" => 0, ")" => 1, "*" => 2, "+" => 3 }[inter]
          @charsets[slot] = final == "0" ? :graphics : :ascii
        when "#"
          screen_alignment if final == "8"
        end
      end

      def csi(priv, inter, params, final)
        return sgr(params) if final == "m" && priv.empty? && inter.empty?

        p = params.map { |x| x.is_a?(Array) ? x[0] : x }
        n = p[0].to_i
        n1 = n == 0 ? 1 : n

        if inter == " "
          @cursor_style = n if final == "q"
          return
        elsif inter == "!"
          soft_reset if final == "p"
          return
        elsif inter == "$"
          decrqm(priv, n) if final == "p"
          return
        elsif !inter.empty?
          return
        end

        case priv
        when ""
          csi_standard(final, p, n, n1)
        when "?"
          case final
          when "h" then set_modes(p, true, true)
          when "l" then set_modes(p, true, false)
          when "J" then erase_display(n)
          when "K" then erase_line(n)
          when "n" then respond("\e[?#{cursor_row_report};#{@cx + 1}R") if n == 6
          end
        when ">"
          case final
          when "c" then respond("\e[>41;354;0c")
          when "q" then respond("\eP>|krang\e\\")
          end
        end
      end

      def csi_standard(final, p, n, n1)
        case final
        when "@" then insert_chars(n1)
        when "A" then cursor_up(n1)
        when "B", "e" then cursor_down(n1)
        when "C", "a" then move_x(@cx + n1)
        when "D" then move_x(@cx - n1)
        when "E" then cursor_down(n1); @cx = 0
        when "F" then cursor_up(n1); @cx = 0
        when "G", "`" then move_x(n1 - 1)
        when "H", "f" then cursor_to((p[0].to_i == 0 ? 1 : p[0].to_i) - 1, (p[1].to_i == 0 ? 1 : p[1].to_i) - 1)
        when "I" then tab(n1)
        when "J" then erase_display(n)
        when "K" then erase_line(n)
        when "L" then insert_lines(n1)
        when "M" then delete_lines(n1)
        when "P" then delete_chars(n1)
        when "S" then scroll_up(n1) if p.size <= 1
        when "T" then scroll_down(n1) if p.size <= 1
        when "X" then erase_chars(n1)
        when "Z" then back_tab(n1)
        when "b" then repeat_char(n1)
        when "c" then respond("\e[?62;22c") if n == 0
        when "d" then cursor_to((n1 - 1), @cx, keep_x: true)
        when "g" then clear_tabs(n)
        when "h" then set_modes(p, false, true)
        when "l" then set_modes(p, false, false)
        when "n"
          if n == 5
            respond("\e[0n")
          elsif n == 6
            respond("\e[#{cursor_row_report};#{@cx + 1}R")
          end
        when "r" then set_margins(p[0].to_i, p[1].to_i)
        when "s" then save_cursor if p.empty?
        when "t"
          respond("\e[8;#{@rows};#{@cols}t") if n == 18 || n == 19
        when "u" then restore_cursor
        end
      end

      # ---- cursor -----------------------------------------------------------------

      def carriage_return
        @cx = 0
        @pending_wrap = false
      end

      def backspace
        @cx -= 1 if @cx > 0
        @pending_wrap = false
      end

      def linefeed
        @buf.soft[@cy] = false
        @cx = 0 if @newline_mode
        index_down
      end

      def next_line
        @buf.soft[@cy] = false
        @cx = 0
        index_down
      end

      def index_down
        @pending_wrap = false
        if @cy == @bottom
          scroll_up(1)
        elsif @cy < @rows - 1
          @cy += 1
        end
      end

      def reverse_index
        @pending_wrap = false
        if @cy == @top
          scroll_down(1)
        elsif @cy > 0
          @cy -= 1
        end
      end

      def wrap_line
        @buf.soft[@cy] = true
        @cx = 0
        @pending_wrap = false
        index_down
      end

      def cursor_up(n)
        limit = @cy >= @top ? @top : 0
        @cy = [@cy - n, limit].max
        @pending_wrap = false
      end

      def cursor_down(n)
        limit = @cy <= @bottom ? @bottom : @rows - 1
        @cy = [@cy + n, limit].min
        @pending_wrap = false
      end

      def move_x(x)
        @cx = [[x, 0].max, @cols - 1].min
        @pending_wrap = false
      end

      # absolute position, 0-based. With origin mode the row is relative to the
      # top margin and can't leave the scroll region.
      def cursor_to(y, x, keep_x: false)
        y = [[y + @top, @top].max, @bottom].min if @origin
        @cy = [[y, 0].max, @rows - 1].min
        @cx = [[x, 0].max, @cols - 1].min unless keep_x
        @pending_wrap = false
      end

      def cursor_row_report
        @origin ? @cy - @top + 1 : @cy + 1
      end

      def tab(n)
        n.times do
          x = @cx + 1
          x += 1 while x < @cols - 1 && !@tabs[x]
          @cx = [x, @cols - 1].min
        end
        @pending_wrap = false
      end

      def back_tab(n)
        n.times do
          x = @cx - 1
          x -= 1 while x > 0 && !@tabs[x]
          @cx = [x, 0].max
        end
        @pending_wrap = false
      end

      def clear_tabs(n)
        if n == 0
          @tabs[@cx] = false
        elsif n == 3
          @tabs = Array.new(@cols, false)
        end
      end

      def set_margins(top, bottom)
        top = top == 0 ? 1 : top
        bottom = bottom == 0 ? @rows : bottom
        return unless top < bottom && bottom <= @rows

        @top = top - 1
        @bottom = bottom - 1
        cursor_to(0, 0)
      end

      def save_cursor
        @saved[@alt ? 1 : 0] = [@cx, @cy, @style, @pending_wrap, @charsets.dup, @gl, @origin]
      end

      def restore_cursor
        s = @saved[@alt ? 1 : 0]
        if s
          @cx, @cy, @style, @pending_wrap, charsets, @gl, @origin = s
          @charsets = charsets.dup
          update_blank
          @cx = [@cx, @cols - 1].min
          @cy = [@cy, @rows - 1].min
        else
          @cx = 0
          @cy = 0
          @pending_wrap = false
          @origin = false
        end
      end

      # ---- scrolling and editing ----------------------------------------------------

      # Scrolls the margin region up. Rows leaving the top of a full-screen
      # primary buffer go to history.
      def scroll_up(n)
        n = [n, @bottom - @top + 1].min
        n.times do
          row = @buf.cells.delete_at(@top)
          soft = @buf.soft.delete_at(@top)
          stash(row, soft) if !@alt && @top == 0 && @bottom == @rows - 1
          @buf.cells.insert(@bottom, blank_row)
          @buf.soft.insert(@bottom, false)
        end
      end

      def scroll_down(n)
        n = [n, @bottom - @top + 1].min
        n.times do
          @buf.cells.delete_at(@bottom)
          @buf.soft.delete_at(@bottom)
          @buf.cells.insert(@top, blank_row)
          @buf.soft.insert(@top, false)
        end
      end

      def insert_lines(n)
        return unless @cy >= @top && @cy <= @bottom

        n = [n, @bottom - @cy + 1].min
        n.times do
          @buf.cells.delete_at(@bottom)
          @buf.soft.delete_at(@bottom)
          @buf.cells.insert(@cy, blank_row)
          @buf.soft.insert(@cy, false)
        end
        @cx = 0
        @pending_wrap = false
      end

      def delete_lines(n)
        return unless @cy >= @top && @cy <= @bottom

        n = [n, @bottom - @cy + 1].min
        n.times do
          @buf.cells.delete_at(@cy)
          @buf.soft.delete_at(@cy)
          @buf.cells.insert(@bottom, blank_row)
          @buf.soft.insert(@bottom, false)
        end
        @cx = 0
        @pending_wrap = false
      end

      def insert_chars(n)
        row = @buf.cells[@cy]
        n = [n, @cols - @cx].min
        n.times do
          row.insert(@cx, @blank)
          row.pop
        end
        fix_wide(row)
        @pending_wrap = false
      end

      def delete_chars(n)
        row = @buf.cells[@cy]
        n = [n, @cols - @cx].min
        n.times do
          row.delete_at(@cx)
          row << @blank
        end
        fix_wide(row)
        @pending_wrap = false
      end

      def erase_chars(n)
        row = @buf.cells[@cy]
        last = [@cx + n, @cols].min
        k = @cx
        while k < last
          row[k] = @blank
          k += 1
        end
        fix_wide(row)
        @pending_wrap = false
      end

      def erase_line(mode)
        row = @buf.cells[@cy]
        @pending_wrap = false # xterm: erasing ends the "wrap pending" state
        case mode
        when 0
          k = @cx
          while k < @cols
            row[k] = @blank
            k += 1
          end
          @buf.soft[@cy] = false
        when 1
          k = 0
          while k <= @cx
            row[k] = @blank
            k += 1
          end
        when 2
          @cols.times { |k| row[k] = @blank }
          @buf.soft[@cy] = false
        end
        fix_wide(row)
      end

      def erase_display(mode)
        @pending_wrap = false
        case mode
        when 0
          erase_line(0)
          (@cy + 1...@rows).each { |y| clear_row(y) }
        when 1
          (0...@cy).each { |y| clear_row(y) }
          erase_line(1)
        when 2
          (0...@rows).each { |y| clear_row(y) }
        when 3
          clear_history unless @alt
        end
      end

      def repeat_char(n)
        return unless @last_char

        n = [n, 65535].min
        n.times { print(@last_char) }
      end

      # ---- modes ---------------------------------------------------------------------

      def set_modes(modes, private_mode, on)
        modes.each do |m|
          m = m[0] if m.is_a?(Array)
          private_mode ? set_private_mode(m, on) : set_ansi_mode(m, on)
        end
      end

      def set_ansi_mode(m, on)
        case m
        when 4 then @insert_mode = on
        when 20 then @newline_mode = on
        end
      end

      def set_private_mode(m, on)
        case m
        when 1 then @app_cursor = on
        when 5 then @reverse_video = on
        when 6
          @origin = on
          cursor_to(0, 0)
        when 7 then @autowrap = on
        when 9 then @mouse_mode = on ? 9 : 0
        when 25 then @cursor_visible = on
        when 47, 1047 then on ? enter_alt(false) : leave_alt(m == 1047)
        when 1000, 1002, 1003
          if on
            @mouse_mode = m
          elsif @mouse_mode == m
            @mouse_mode = 0
          end
        when 1004 then @focus_events = on
        when 1005, 1006, 1015
          if on
            @mouse_encoding = m
          elsif @mouse_encoding == m
            @mouse_encoding = nil
          end
        when 1007 then @alt_scroll = on
        when 1048 then on ? save_cursor : restore_cursor
        when 1049
          if on
            save_cursor
            enter_alt(true)
          else
            leave_alt(false)
            restore_cursor
          end
        when 2004 then @bracketed_paste = on
        when 2026 then @sync = on
        end
      end

      def enter_alt(clear)
        return if @alt

        @alt = true
        @buf = @alt_buf
        (0...@rows).each { |y| clear_row(y) } if clear
        @top = 0
        @bottom = @rows - 1
        @pending_wrap = false
      end

      def leave_alt(clear)
        return unless @alt

        (0...@rows).each { |y| clear_row(y) } if clear
        @alt = false
        @buf = @primary
        @top = 0
        @bottom = @rows - 1
        @pending_wrap = false
      end

      def decrqm(priv, n)
        return unless priv == "?"

        state =
          case n
          when 1 then @app_cursor
          when 6 then @origin
          when 7 then @autowrap
          when 25 then @cursor_visible
          when 1049, 47, 1047 then @alt
          when 2004 then @bracketed_paste
          when 1000, 1002, 1003 then @mouse_mode == n
          when 1006 then @mouse_encoding == 1006
          else return respond("\e[?#{n};0$y")
          end
        respond("\e[?#{n};#{state ? 1 : 2}$y")
      end

      # ---- attributes ------------------------------------------------------------------

      def sgr(params)
        list = params.empty? ? [0] : params
        s = @style
        i = 0

        while i < list.size
          item = list[i]
          sub = item.is_a?(Array) ? item : nil
          code = sub ? sub[0] : item

          case code
          when 0 then s = Style.default
          when 1 then s = s.set(Style::BOLD)
          when 2 then s = s.set(Style::DIM)
          when 3 then s = s.set(Style::ITALIC)
          when 4
            s = (sub && sub[1] == 0) ? s.clear(Style::UNDERLINE) : s.set(Style::UNDERLINE)
          when 5, 6 then s = s.set(Style::BLINK)
          when 7 then s = s.set(Style::INVERSE)
          when 8 then s = s.set(Style::HIDDEN)
          when 9 then s = s.set(Style::STRIKE)
          when 21 then s = s.set(Style::UNDERLINE)
          when 22 then s = s.clear(Style::BOLD | Style::DIM)
          when 23 then s = s.clear(Style::ITALIC)
          when 24 then s = s.clear(Style::UNDERLINE)
          when 25 then s = s.clear(Style::BLINK)
          when 27 then s = s.clear(Style::INVERSE)
          when 28 then s = s.clear(Style::HIDDEN)
          when 29 then s = s.clear(Style::STRIKE)
          when 30..37 then s = s.with_fg(code - 30)
          when 39 then s = s.with_fg(nil)
          when 40..47 then s = s.with_bg(code - 40)
          when 49 then s = s.with_bg(nil)
          when 90..97 then s = s.with_fg(code - 90 + 8)
          when 100..107 then s = s.with_bg(code - 100 + 8)
          when 38, 48, 58
            color, used = extended_color(sub, list, i)
            i += used
            if color != :none
              s = s.with_fg(color) if code == 38
              s = s.with_bg(color) if code == 48
            end
          end
          i += 1
        end

        @style = s
        update_blank
      end

      # -> [color, extra params consumed]  (color is :none when malformed)
      def extended_color(sub, list, i)
        if sub
          kind = sub[1]
          if kind == 5 && sub.size >= 3
            return [clamp255(sub[2]), 0]
          elsif kind == 2 && sub.size >= 5
            rgb = sub.size >= 6 ? sub[3, 3] : sub[2, 3]
            return [rgb.map { |v| clamp255(v) }, 0]
          end
          return [:none, 0]
        end

        kind = list[i + 1]
        kind = kind[0] if kind.is_a?(Array)
        if kind == 5 && list[i + 2]
          [clamp255(list[i + 2]), 2]
        elsif kind == 2 && list[i + 4]
          [[clamp255(list[i + 2]), clamp255(list[i + 3]), clamp255(list[i + 4])], 4]
        else
          [:none, list.size - i - 1]
        end
      end

      def clamp255(v)
        v = v[0] if v.is_a?(Array)
        [[v.to_i, 0].max, 255].min
      end

      # ---- strings ------------------------------------------------------------------------

      def osc(str)
        i = str.index(";")
        code = i ? str[0, i] : str
        rest = i ? str[i + 1..] : ""

        case code
        when "0", "2"
          @title = rest
          @on_title&.call(rest)
        when "1"
          # icon name: ignored
        when "7"
          @cwd = rest
          @on_osc&.call(str)
        when "10", "11"
          if rest == "?"
            rgb = code == "10" ? @default_fg : @default_bg
            respond("\e]#{code};#{color_report(rgb)}\e\\") if rgb
          end
        else
          @on_osc&.call(str)
        end
      end

      def color_report(rgb)
        "rgb:" + rgb.map { |v| ("%02x" % v) * 2 }.join("/")
      end

      # ---- mouse and paste (what to send to the app) -----------------------------------

      # type   - :press, :release, :motion or :wheel
      # button - 0 left, 1 middle, 2 right; for :wheel 0 up / 1 down
      # col, row - 0-based cells
      # Returns the escape sequence to write to the pty, or nil if the app didn't ask.
      def mouse_report(type, button, col, row, shift: false, alt: false, ctrl: false)
        return nil if @mouse_mode == 0
        return nil if type == :release && @mouse_mode == 9
        return nil if type == :motion && @mouse_mode < 1002

        code =
          case type
          when :wheel then 64 + button
          when :release then @mouse_encoding == 1006 ? button : 3
          else button
          end
        code += 32 if type == :motion
        unless @mouse_mode == 9
          code += 4 if shift
          code += 8 if alt
          code += 16 if ctrl
        end

        if @mouse_encoding == 1006
          "\e[<#{code};#{col + 1};#{row + 1}#{type == :release ? 'm' : 'M'}"
        else
          return nil if col > 222 || row > 222

          "\e[M" + (32 + code).chr + (33 + col).chr + (33 + row).chr
        end
      end

      def paste_wrap(text)
        @bracketed_paste ? "\e[200~#{text}\e[201~" : text
      end

      # ---- resize ---------------------------------------------------------------------------

      def resize(cols, rows)
        cols = [cols, 1].max
        rows = [rows, 1].max
        return if cols == @cols && rows == @rows

        pending_before = @pending.size

        reflow_primary(cols) if cols != @cols
        resize_alt(cols, rows)
        @cols = cols

        fit_primary_rows(rows)

        @rows = rows
        @tabs = Array.new(cols) { |x| x % 8 == 0 }
        @top = 0
        @bottom = rows - 1
        @cx = [@cx, cols - 1].min
        @cy = [@cy, rows - 1].min
        @pending_wrap = false
        @history_gen += 1 if pending_before != @pending.size
      end

      # ---- housekeeping ---------------------------------------------------------------------

      def full_reset
        leave_alt(false)
        reset_state
        (0...@rows).each { |y| clear_row(y) }
      end

      def soft_reset
        @style = Style.default
        update_blank
        @insert_mode = false
        @origin = false
        @autowrap = true
        @app_cursor = false
        @app_keypad = false
        @cursor_visible = true
        @top = 0
        @bottom = @rows - 1
        @charsets = [:ascii, :ascii, :ascii, :ascii]
        @gl = 0
        @saved = [nil, nil]
      end

      def clear_history
        @lines.clear
        @pending.clear
        @history_gen += 1
      end

      private

      def new_buffer
        b = Buffer.new
        b.cells = Array.new(@rows) { Array.new(@cols, BLANK) }
        b.soft = Array.new(@rows, false)
        b
      end

      def reset_state
        @cx = 0
        @cy = 0
        @pending_wrap = false
        @style = Style.default
        @blank = BLANK
        @top = 0
        @bottom = @rows - 1
        @tabs = Array.new(@cols) { |x| x % 8 == 0 }
        @charsets = [:ascii, :ascii, :ascii, :ascii]
        @gl = 0
        @autowrap = true
        @insert_mode = false
        @newline_mode = false
        @origin = false
        @cursor_visible = true
        @cursor_style = 0
        @app_cursor = false
        @app_keypad = false
        @reverse_video = false
        @bracketed_paste = false
        @focus_events = false
        @mouse_mode = 0
        @mouse_encoding = nil
        @alt_scroll = true # wheel -> arrow keys in the alt screen, unless the app takes the mouse
        @sync = false
        @saved = [nil, nil]
      end

      def update_blank
        bg = @style.bg
        @blank = bg.nil? ? BLANK : [" ", Style.get(nil, bg, 0)]
      end

      def blank_row
        Array.new(@cols, @blank)
      end

      def clear_row(y)
        @buf.cells[y] = blank_row
        @buf.soft[y] = false
      end

      def respond(str)
        @on_response&.call(str)
      end

      # a combining character joins the cell before the cursor
      def combine(ch)
        x = @pending_wrap ? @cx : @cx - 1
        return if x < 0

        row = @buf.cells[@cy]
        x -= 1 if row[x][0].nil? && x > 0
        cell = row[x]
        row[x] = [cell[0] + ch, cell[1]] unless cell[0].nil?
      end

      def wide?(ch)
        cp = ch.ord
        cp >= 0x1100 && Util::Wcwidth.of(cp) == 2
      end

      # after editing a row, make sure no wide character was cut in half
      def fix_wide(row)
        k = 0
        while k < @cols
          ch = row[k][0]
          if ch.nil?
            prev = k > 0 ? row[k - 1][0] : nil
            row[k] = @blank unless prev && wide?(prev)
          elsif wide?(ch)
            row[k] = @blank unless k + 1 < @cols && row[k + 1][0].nil?
          end
          k += 1
        end
      end

      def screen_alignment
        @top = 0
        @bottom = @rows - 1
        @rows.times do |y|
          @buf.cells[y] = Array.new(@cols) { ["E", @style] }
          @buf.soft[y] = false
        end
        @cx = 0
        @cy = 0
        @pending_wrap = false
      end

      # ---- history ----------------------------------------------------------------------------

      # cells -> [[text, style], ...], merging neighbours that share a style.
      def runs_of(cells, trim)
        last = cells.size - 1
        if trim
          last -= 1 while last >= 0 && cells[last].equal?(BLANK)
        end
        return [] if last < 0

        runs = []
        text = +""
        style = nil
        k = 0
        while k <= last
          ch, st = cells[k]
          if !ch.nil?
            unless st.equal?(style)
              runs << [text, style] unless text.empty?
              text = +""
              style = st
            end
            text << ch
          end
          k += 1
        end
        runs << [text, style] unless text.empty?
        runs
      end

      # A row scrolled off the top: remember it as part of a logical line.
      def stash(cells, soft)
        soft = false if soft && (@pending_rows += 1) >= MAX_WRAPPED_ROWS
        @pending_rows = 0 unless soft

        runs = runs_of(cells, !soft)
        @on_history_row&.call(runs, soft)

        @pending.concat(runs)
        return if soft

        @lines << @pending
        @pending = []
        if @lines.size > HISTORY_LIMIT + HISTORY_SLACK
          extra = @lines.size - HISTORY_LIMIT
          @lines.slice!(0, extra)
          @trimmed += extra
        end
      end

      # ---- resize helpers -----------------------------------------------------------------------

      def resize_alt(cols, rows)
        @alt_buf.cells = @alt_buf.cells.map do |row|
          if row.size > cols
            r = row[0, cols]
            r[cols - 1] = BLANK if r[cols - 1][0] && wide?(r[cols - 1][0])
            r
          else
            row + Array.new(cols - row.size, BLANK)
          end
        end
        @alt_buf.soft = Array.new(@alt_buf.cells.size, false)
        while @alt_buf.cells.size > rows
          @alt_buf.cells.pop
          @alt_buf.soft.pop
        end
        while @alt_buf.cells.size < rows
          @alt_buf.cells << Array.new(cols, BLANK)
          @alt_buf.soft << false
        end
      end

      # [char, style] cells for a list of runs (wide characters get their tail cell)
      def cells_from_runs(runs)
        out = []
        runs.each do |text, style|
          text.each_char do |c|
            w = Util::Wcwidth.of(c.ord)
            if w == 0
              out[-1] = [out[-1][0] + c, out[-1][1]] unless out.empty? || out[-1][0].nil?
            else
              out << [c, style]
              out << [nil, style] if w == 2
            end
          end
        end
        out
      end

      # Joins soft-wrapped rows of the primary buffer back into logical lines and
      # cuts them again at the new width, moving the cursor with its text.
      def reflow_primary(cols)
        cells = @primary.cells
        soft = @primary.soft
        saved = @alt ? @saved[0] : nil
        cy = @alt ? (saved ? saved[1] : cells.size - 1) : @cy
        cx = @alt ? (saved ? saved[0] : 0) : @cx

        # a line that began in history and continues on screen: pull it back in
        unless @pending.empty?
          cells = [cells_from_runs(@pending)] + cells
          soft = [true] + soft
          @pending = []
          cy += 1
          @history_gen += 1
        end

        new_cells = []
        new_soft = []
        new_cy = 0
        new_cx = 0
        i = 0

        while i < cells.size
          j = i
          j += 1 while soft[j] && j < cells.size - 1

          line = []
          index = nil
          (i..j).each do |k|
            index = line.size + cx if k == cy
            line.concat(cells[k])
          end

          # blanks after the last character of the line (and the cursor) are not text
          keep = index ? index : 0
          line.pop while line.size > keep && line.last.equal?(BLANK)

          rows = split_cells(line, cols)

          if index
            r = 0
            left = index
            while r < rows.size - 1 && left >= rows[r].size
              left -= rows[r].size
              r += 1
            end
            rows << [] while rows.size <= r
            new_cy = new_cells.size + r
            new_cx = left
          end

          rows.each_with_index do |row, n|
            row = row + Array.new(cols - row.size, BLANK) if row.size < cols
            new_cells << row
            new_soft << (n < rows.size - 1)
          end
          i = j + 1
        end

        if new_cells.empty?
          new_cells = [Array.new(cols, BLANK)]
          new_soft = [false]
        end

        @primary.cells = new_cells
        @primary.soft = new_soft
        new_cx = [new_cx, cols - 1].min
        if @alt
          if saved
            saved[0] = new_cx
            saved[1] = new_cy
          end
        else
          @cx = new_cx
          @cy = new_cy
        end
      end

      # Cuts a logical line into rows of at most `cols` cells, never leaving a
      # wide character's tail at the start of a row.
      def split_cells(line, cols)
        rows = []
        k = 0
        while k < line.size
          take = [cols, line.size - k].min
          take -= 1 if take == cols && take > 1 && k + take < line.size && line[k + take][0].nil?
          rows << line[k, take]
          k += take
        end
        rows << [] if rows.empty?
        rows
      end

      def pad_row(row)
        row.size < @cols ? row + Array.new(@cols - row.size, BLANK) : row
      end

      # Takes up to `needed` rows from the end of the history, newest last. A line
      # that doesn't fit entirely is split: its first rows stay behind as the new
      # pending line. Returns [cell rows, soft flags].
      def pull_history(needed)
        got = []
        soft = []
        while got.size < needed && !@lines.empty?
          runs = @lines.pop
          rows = split_cells(cells_from_runs(runs), @cols)
          take = needed - got.size
          if rows.size > take
            head = rows[0, rows.size - take]
            rows = rows[rows.size - take, take]
            @pending = runs_of(head.flatten(1), false)
          end
          got = rows.map { |r| pad_row(r) } + got
          soft = Array.new(rows.size) { |i| i < rows.size - 1 } + soft
          @history_gen += 1
          break unless @pending.empty?
        end
        [got, soft]
      end

      # Brings the primary buffer to `rows` rows. Growing pulls history back in
      # above the screen; shrinking drops blank rows below the cursor first and
      # then scrolls the top into history.
      def fit_primary_rows(rows)
        cells = @primary.cells
        soft = @primary.soft
        saved = @alt ? @saved[0] : nil
        cy = @alt ? (saved ? saved[1] : 0) : @cy

        if cells.size < rows
          unless @pending.empty?
            lead = split_cells(cells_from_runs(@pending), @cols).map { |r| pad_row(r) }
            @pending = []
            cells = lead + cells
            soft = Array.new(lead.size, true) + soft
            cy += lead.size
            @history_gen += 1
          end
          if cells.size < rows
            got, got_soft = pull_history(rows - cells.size)
            cells = got + cells
            soft = got_soft + soft
            cy += got.size
          end
        end

        while cells.size > rows
          if cells.size - 1 > cy && cells.last.all? { |c| c.equal?(BLANK) }
            cells.pop
            soft.pop
          else
            row = cells.shift
            s = soft.shift
            stash(row, s)
            cy -= 1
          end
        end
        while cells.size < rows
          cells << Array.new(@cols, BLANK)
          soft << false
        end

        @primary.cells = cells
        @primary.soft = soft
        cy = 0 if cy < 0
        if @alt
          saved[1] = cy if saved
        else
          @cy = cy
        end
      end
    end

    class Buffer
      attr_accessor :cells, :soft
    end
  end
end
