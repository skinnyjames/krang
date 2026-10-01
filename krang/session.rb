require_relative "./util/wcwidth"
require_relative "./util/keys"
require_relative "./sessions/screen"
require_relative "./sessions/feeder"
require_relative "./sessions/theme"
require_relative "./sessions/grid"
require_relative "./patches/wrap_stream"

module Krang
  # Public: everything about one shell that must outlive the blocks rendering it.
  #
  # Owns the pty, the Screen (the terminal model: cells, cursor, modes, history),
  # the WrapCache of history tokens and the selection. Blocks only draw it:
  #
  # * Ansi draws the regular mode: history tokens followed by the screen rows,
  #   inside a Panel, with text selection.
  # * GridView draws the interactive mode (the alternate screen: vim, less, htop)
  #   straight from the screen's cells.
  #
  # so if Hokusai remounts blocks when the tree changes (a split, or the swap
  # between those two), the shell and its scrollback survive.
  class Session
    # how long the size has to hold still before history is re-wrapped
    REFLOW_DELAY = 0.15

    attr_reader :tile, :cache, :stream, :selection, :cols, :max_rows, :screen, :theme, :cell_w, :cell_h
    attr_accessor :on_osc, :stick, :active_plugin, :plugin_request

    # A widget request from a script: ESC ] 7777 ; <token> ; open ; ... BEL
    HK_OPEN = "\e]7777;"
    KRANG_SHELL_DIR = File.expand_path ENV.fetch("KRAN_SHELL_DIR", "assets/shell")
    INBOX_MAX = 1 << 20

    def initialize(tile, shell = "/bin/bash", token = nil, theme: Krang::Theme.init)
      @tile = tile

      if ENV["OS"] == "Windows_NT"
        sep = ";"
        default_shell = "Powershell"
      else
        sep = ":"
        default_shell = shell
      end

      # The shell inherits the parent's environment, so set the token here, just
      # before fork().
      if token
        ENV["HOKUSAI_TOKEN"] = token
        ENV["HOKUSAI_TERM"] = "1"
        paths = ENV["PATH"].to_s.split(sep)
        ENV["PATH"] = (paths + [KRANG_SHELL_DIR]).join(sep) unless paths.include?(KRANG_SHELL_DIR)
      end

      curshell = ENV.fetch("KRANG_SHELL", default_shell)
      @pty, @pid = PTY.spawn(curshell)
      @inbox = +""
      @carry = +"" # the start of a multi-byte character the read ended in the middle of
      @hk_at = nil   # index of the first widget request in @inbox
      @hk_wait = nil # when we started waiting for an unfinished one
      @hk_hold = nil # when we started holding back a possible start of one

      @cols = 80
      @max_rows = 24
      @screen = Sessions::Screen.new(@cols, @max_rows)
      @screen.on_response = ->(bytes) { write(bytes) }
      @screen.on_history_row = ->(runs, soft) { commit_row(runs, soft) }
      @screen.on_osc = ->(str) { @on_osc&.call(str) }
      @screen.on_title = ->(str) { Hokusai.set_title(str) }
      @feeder = Sessions::Feeder.new(@screen)
      @theme = Sessions::Theme.new(theme)

      @cache = Hokusai::Util::WrapCache.new
      @selection = Hokusai::Util::Selection.new
      @budget = Hokusai::Util::Timer.new
      @stream = nil
      @region_start = nil
      @origin_y = 0.0
      @active_plugin = nil

      # for every finished logical line in the history tokens: [tokens, rows],
      # so the oldest ones can be dropped without rebuilding anything
      @line_ends = []
      @open_tokens = 0 # tokens / rows of the line still being written
      @open_rows = 0
      @seen_trim = 0
      @gen = @screen.history_gen
      @reflow_at = nil
      @rw = nil
      @quiet = false # the screen is resizing itself: its history rows aren't ours to emit
      @dirty = false # region tokens are stale and need re-emitting
      @was_alt = false

      @cell_w = 10.0
      @cell_h = 18
      @stick = false
      @closed = false
      @on_osc = nil
    end

    # ---- lifecycle ---------------------------------------------------------

    # Moves whatever the reader thread has collected into our inbox.
    def pump
      return if @closed
      return if @inbox.bytesize > INBOX_MAX # let the reader fill up and block the writer

      chunk = @pty.drain
      return if chunk.empty?

      chunk = @carry + chunk unless @carry.empty?
      chunk, @carry = split_incomplete(chunk)
      return if chunk.empty?

      scan_from = [@inbox.size - HK_OPEN.size + 1, 0].max
      @inbox << chunk
      @hk_at ||= @inbox.index(HK_OPEN, scan_from)
    end

    def exited?
      !@closed && @pty.eof? && @inbox.empty?
    end

    def write(bytes)
      @pty.io.print(bytes) unless @closed
    end

    # Pasted text, wrapped for apps that asked for bracketed paste.
    def paste(text)
      text = text.split("\e[201~").join if @screen.bracketed_paste # can't be allowed to end the paste early
      write(@screen.paste_wrap(text))
    end

    def close
      return if @closed

      @closed = true
      @pty.close
    end

    # The joined text of every token, padded so that the tokens' absolute
    # positions index into it (WrapCache#selected_text relies on that, and the
    # oldest tokens get dropped).
    def full_text
      return "" if @cache.tokens.empty?

      (" " * @cache.tokens.first.positions.first) + @cache.tokens.map(&:text).join
    end

    def alt_screen?
      @screen.alt
    end

    def title
      @screen.title
    end

    def selection_active?
      @selection.geom.state == :selecting || !@selection.pos.positions.nil? || grid_input.selection?
    end

    # mouse and cell selection for the interactive view
    def grid_input
      @grid_input ||= Sessions::GridInput.new(self)
    end

    # Terminal apps typing should snap the view to the bottom.
    def take_stick
      s = @stick
      @stick = false
      s
    end

    # ---- geometry ----------------------------------------------------------

    def set_metrics(cell_w, cell_h, _default_color = nil)
      @cell_w = cell_w
      @cell_h = cell_h
    end

    # The pane moved sideways (a sibling closed, a divider dragged):
    # token x is absolute, so shift everything already emitted.
    def rebase_x(x)
      return unless @stream
      dx = x - @stream.origin_x
      return if dx.zero?

      @cache.tokens.each { |t| t.x += dx }
      @stream.origin_x = x
      @stream.x += dx

      # a reflow in flight was built at the old origin
      if @rw
        @rw = nil
        @reflow_at = Hokusai.monotonic
      end
    end

    def ensure_stream(x, y)
      return if @stream

      @origin_y = y
      @stream = Hokusai::Util::WrapStream.new(1_000_000_000.0, x, y) do |string, _extra|
        measure(string)
      end
      @stream.on_text { |wrapped| @cache << wrapped }
      @region_start = { token: 0, y: y, pos: 0 }
    end

    def resize(cols, rows)
      return if cols == @cols && rows == @max_rows

      @cols = cols
      @max_rows = rows
      @pty.set_size(rows, cols, 0, 0)

      @quiet = true
      @screen.resize(cols, rows)
      @quiet = false

      @gen = @screen.history_gen
      @rw = nil # a rebuild in flight was for the old size
      @reflow_at = Hokusai.monotonic + REFLOW_DELAY
      @dirty = true
    end

    def content_height
      return @cell_h unless @stream

      (@region_start[:y] - @origin_y) + @screen.rows * @cell_h
    end

    # cursor in stream coordinates (same space as the tokens)
    def terminal_cursor
      [@stream.origin_x + @screen.cx * @cell_w, @region_start[:y] + @screen.cy * @cell_h]
    end

    # how to draw a style right now (honours reverse video)
    def look(style)
      @theme.look(style, @screen.reverse_video)
    end

    # ---- per frame ---------------------------------------------------------

    # Parses as much of the inbox as fits in the budget, then re-emits the
    # screen rows. Returns true if anything changed.
    def advance(budget)
      return false unless @stream

      start_reflow if @reflow_at && !@rw && Hokusai.monotonic >= @reflow_at
      return step_reflow(budget) if @rw # output waits in the inbox meanwhile

      fed = false
      until @inbox.empty?
        @budget.reset if !fed
        break if fed && @budget.elapsed(budget)

        chunk = next_chunk
        break if chunk.nil?

        unless chunk.empty?
          @feeder.feed(chunk)
          fed = true
        end
      end

      changed = fed || @dirty
      changed = true if track_mode_change
      track_history

      return false unless changed

      emit_region unless @screen.alt
      @dirty = false
      true
    end

    private

    # ---- mode changes -------------------------------------------------------

    # Leaving the alternate screen: the regular view comes back, snapped to the
    # bottom, and its row tokens were not kept up to date meanwhile.
    def track_mode_change
      return false if @screen.alt == @was_alt

      @was_alt = @screen.alt
      @selection.clear
      @stick = true unless @was_alt
      @dirty = true
      true
    end

    # The screen dropped its oldest lines or rewrote its history (ED 3).
    def track_history
      if @screen.history_gen != @gen
        @gen = @screen.history_gen
        @rw = nil
        @reflow_at = Hokusai.monotonic
      end

      return if @screen.trimmed == @seen_trim || @rw

      drop_oldest(@screen.trimmed - @seen_trim)
      @seen_trim = @screen.trimmed
    end

    # Forgets the tokens of the n oldest logical lines.
    def drop_oldest(n)
      n = [n, @line_ends.size].min
      return if n == 0

      tokens = 0
      rows = 0
      @line_ends.slice!(0, n).each do |t, r|
        tokens += t
        rows += r
      end

      @cache.tokens.slice!(0, tokens)
      @region_start[:token] -= tokens
      @origin_y += rows * @cell_h
    end

    # ---- input chunks -------------------------------------------------------

    # Removes n characters from the front of the inbox.
    def take(n)
      @hk_at -= n if @hk_at
      @inbox.slice!(0, n)
    end

    # The next piece of the stream to parse. A widget request never goes through
    # the VT parser: it can be large (a list of items) and the parser is slow per
    # byte. Returns "" after handling one, nil while one is still arriving.
    def next_chunk
      if @hk_at.nil?
        # the read may have ended inside the marker ("\e]77"): don't hand those
        # bytes to the parser yet, but only wait a moment for the rest
        hold = partial_marker_length
        if hold > 0
          @hk_hold ||= Hokusai.monotonic
          if Hokusai.monotonic - @hk_hold < 0.05
            avail = @inbox.size - hold
            return avail > 0 ? take([avail, 128].min) : nil
          end
        else
          @hk_hold = nil
        end
        return take(128)
      end

      return take([@hk_at, 128].min) if @hk_at > 0

      q = @inbox.index("\a")
      # another escape sequence before the BEL: this request was cut off (conhost
      # drops long ones). Let it through as text instead of waiting for a BEL that
      # belongs to something else.
      broken = @inbox.index("\e", 1)
      if broken && (q.nil? || broken < q)
        @hk_wait = nil
        chunk = take(broken)
        @hk_at = @inbox.index(HK_OPEN)
        return chunk
      end

      if q.nil?
        @hk_wait ||= Hokusai.monotonic
        return nil if Hokusai.monotonic - @hk_wait < 2.0

        # the client died mid-write: stop waiting and treat it as text
        @hk_wait = nil
        chunk = take(1)
        @hk_at = @inbox.index(HK_OPEN)
        return chunk
      end

      @hk_wait = nil
      seq = take(q + 1)
      @hk_at = @inbox.index(HK_OPEN)
      @on_osc&.call(seq[2...-1]) # "7777;<token>;open;..."
      ""
    end

    # how many characters at the end of the inbox could be the start of a marker
    def partial_marker_length
      (HK_OPEN.size - 1).downto(1) do |n|
        return n if @inbox.end_with?(HK_OPEN[0, n])
      end
      0
    end

    # [complete, tail]: a read can end in the middle of a multi-byte character.
    def split_incomplete(str)
      n = str.bytesize
      return [str, +""] if n == 0

      i = n - 1
      back = 0
      while i > 0 && back < 3 && (str.getbyte(i) & 0xC0) == 0x80
        i -= 1
        back += 1
      end

      lead = str.getbyte(i)
      need = lead >= 0xF0 ? 4 : (lead >= 0xE0 ? 3 : (lead >= 0xC0 ? 2 : 1))
      have = n - i
      return [str, +""] if have >= need || lead < 0xC0

      [str.byteslice(0, i), str.byteslice(i, have)]
    end

    # The stream asks for one character at a time; "\n" takes no room.
    def measure(string)
      if string.size == 1
        o = string.ord
        w = o == 10 ? 0 : (o < 0x300 ? 1 : Util::Wcwidth.of(o))
        return [@cell_w * w, @cell_h]
      end

      n = string.end_with?("\n") ? string[0, string.size - 1] : string
      [@cell_w * Util::Wcwidth.width(n), @cell_h]
    end

    # ---- emitting tokens ---------------------------------------------------

    # A row scrolled off the top of the screen: it becomes history tokens, right
    # before the screen rows.
    def commit_row(runs, soft)
      return if @quiet || @stream.nil? || @rw

      @cache.tokens.slice!(@region_start[:token]..)
      reset_stream
      before = @cache.tokens.size
      emit_runs(@stream, runs, true)
      @region_start = { token: @cache.tokens.size, y: @stream.y, pos: @stream.offset_pos }

      @open_tokens += @cache.tokens.size - before
      @open_rows += 1
      return if soft

      @line_ends << [@open_tokens, @open_rows]
      @open_tokens = 0
      @open_rows = 0
    end

    # The screen rows, from the top down to the cursor or the last row with
    # anything on it.
    def emit_region
      @cache.tokens.slice!(@region_start[:token]..)
      reset_stream

      last = @screen.rows - 1
      last -= 1 while last > @screen.cy && blank_row?(last)

      (0..last).each { |y| emit_runs(@stream, @screen.row_runs(y), y < last) }
    end

    def blank_row?(y)
      @screen.cells[y].all? { |cell| cell.equal?(Sessions::Screen::BLANK) }
    end

    def reset_stream
      @stream.x = @stream.origin_x
      @stream.y = @region_start[:y]
      @stream.offset_pos = @region_start[:pos]
      @stream.current_width = 0.0
    end

    # runs -> tokens. Wide characters get a token of their own: the font's
    # advance for them is not two cells, so they would push the rest of the run
    # out of its columns.
    def emit_runs(stream, runs, newline)
      if runs.empty?
        stream.wrap("\n", look(Sessions::Style.default)) if newline
        stream.flush(false)
        return
      end

      last = runs.size - 1
      runs.each_with_index do |(text, style), i|
        extra = look(style)
        str = newline && i == last ? text + "\n" : text

        if text.bytesize == text.size
          stream.wrap(str, extra)
          stream.flush(false)
        else
          emit_unicode(stream, str, extra)
        end
      end
    end

    def emit_unicode(stream, str, extra)
      piece = +""
      str.each_char do |c|
        if c.ord >= 0x1100 && Util::Wcwidth.of(c.ord) == 2
          unless piece.empty?
            stream.wrap(piece, extra)
            stream.flush(false)
            piece = +""
          end
          stream.wrap(c, extra)
          stream.flush(false)
        else
          piece << c
        end
      end
      return if piece.empty?

      stream.wrap(piece, extra)
      stream.flush(false)
    end

    # ---- history rebuild ------------------------------------------------------

    # Cuts a logical line (runs) into rows of at most `cols` cells, the same way
    # the screen does it.
    def split_runs(runs, cols)
      rows = []
      cur = []
      room = cols

      runs.each do |text, style|
        if text.bytesize == text.size
          t = text
          until t.empty?
            take = t[0, room]
            t = t[take.size..]
            cur << [take, style]
            room -= take.size
            if room == 0
              rows << cur
              cur = []
              room = cols
            end
          end
        else
          piece = +""
          text.each_char do |c|
            w = Util::Wcwidth.of(c.ord)
            if w > room
              cur << [piece, style] unless piece.empty?
              piece = +""
              rows << cur
              cur = []
              room = cols
            end
            piece << c
            room -= w
          end
          cur << [piece, style] unless piece.empty?
          if room == 0
            rows << cur
            cur = []
            room = cols
          end
        end
      end

      rows << cur unless cur.empty?
      rows << [] if rows.empty?
      rows
    end

    # Rebuilds the history tokens at the current size, a few lines per frame,
    # into a separate list that replaces the old one when it's done. The old
    # tokens keep being drawn until then.
    def start_reflow
      @reflow_at = nil

      s = Hokusai::Util::WrapStream.new(1_000_000_000.0, @stream.origin_x, @origin_y) do |string, _extra|
        measure(string)
      end
      tokens = []
      s.on_text { |w| tokens << w unless w.positions.empty? }

      @rw = { s: s, tokens: tokens, i: 0, cols: @cols, lines: @screen.lines.dup, ends: [], pending: @screen.pending.dup, trimmed: @screen.trimmed }
    end

    def step_reflow(budget)
      s = @rw[:s]
      @budget.reset

      while @rw[:i] < @rw[:lines].size
        break if @budget.elapsed(budget)

        before = @rw[:tokens].size
        rows = split_runs(@rw[:lines][@rw[:i]], @rw[:cols])
        rows.each { |runs| emit_runs(s, runs, true) }
        @rw[:ends] << [@rw[:tokens].size - before, rows.size]
        @rw[:i] += 1
      end

      finish_reflow if @rw[:i] >= @rw[:lines].size
      true
    end

    def finish_reflow
      s = @rw[:s]

      # the first rows of a line that continues on the screen
      before = @rw[:tokens].size
      rows = @rw[:pending].empty? ? [] : split_runs(@rw[:pending], @rw[:cols])
      rows.each { |runs| emit_runs(s, runs, true) }
      @open_tokens = @rw[:tokens].size - before
      @open_rows = rows.size

      @cache.tokens = @rw[:tokens]
      @line_ends = @rw[:ends]
      @seen_trim = @rw[:trimmed]
      @stream.x = @stream.origin_x
      @stream.y = s.y
      @stream.offset_pos = s.offset_pos
      @stream.current_width = 0.0
      @region_start = { token: @cache.tokens.size, y: s.y, pos: s.offset_pos }
      @selection.clear # old positions point into the old tokens
      @rw = nil

      emit_region unless @screen.alt
      @dirty = false
    end
  end
end
