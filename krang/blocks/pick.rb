module Krang
  # Deprecated: idea for plugin system.
  module Blocks
    # Public: one visible row of the picker
    PickRow = Struct.new(:item_index, :label, :selected)

    # Public: the state of one widget request: `hk pick`, `hk confirm` or
    #         `hk input`. Plain Ruby, so keys can be routed to it from anywhere and
    #         it can be tested without a window.
    #
    #   :pick    filter a list, choose one (or several with multi)
    #   :confirm a pick between Yes and No, with y / n as shortcuts
    #   :input   a pick with no rows: the query is the answer
    class PickState
      ROW_H = 26.0

      attr_reader :id, :session, :title, :items, :multi, :query, :index, :max_rows, :kind, :secret

      def initialize(id, session, opts, items, kind = :pick)
        @id = id
        @session = session
        @kind = kind
        @title = opts["title"].to_s.empty? ? default_title : opts["title"]
        @multi = kind == :pick && opts["multi"] == "1"
        @secret = kind == :input && opts["secret"] == "1"
        @marked = {} # position in @items => true
        @filtered = nil
        @max_rows = 12
        @index = 0

        case kind
        when :confirm
          @items = ["Yes", "No"]
          @index = opts["default"] == "no" ? 1 : 0
          @query = +""
        when :input
          @items = []
          @query = (opts["default"] || "").dup
        else
          @items = items
          @query = (opts["query"] || "").dup
        end
      end

      def show_query?
        @kind != :confirm
      end

      def show_rows?
        @kind != :input
      end

      # positions in @items that match every space-separated term (case-insensitive)
      def filtered
        @filtered ||=
          if @kind == :pick
            terms = @query.downcase.split(" ")
            list = []
            @items.each_with_index do |item, i|
              d = item.downcase
              list << i if terms.all? { |t| d.include?(t) }
            end
            list
          else
            (0...@items.size).to_a
          end
      end

      def marked?(item_index)
        @marked[item_index] == true
      end

      def marked_count
        @marked.size
      end

      # title + hint (+ query line) + paddings
      def chrome
        (2 + (show_query? ? 1 : 0)) * ROW_H + 40.0
      end

      # -> [box_width, box_height, gap_above_box] for a pane of this size
      def layout(pane_w, pane_h)
        @max_rows = [[((pane_h * 0.8 - chrome) / ROW_H).floor, 3].max, 14].min
        box_h = chrome + rows_shown * ROW_H
        box_w = [pane_w * (@kind == :pick ? 0.8 : 0.6), @kind == :pick ? 760.0 : 520.0].min
        [box_w, box_h, [(pane_h - box_h) / 4.0, 0.0].max]
      end

      # a pick always shows at least one row so "no matches" has somewhere to live
      def rows_shown
        return 0 unless show_rows?

        [[filtered.size, 1].max, @max_rows].min
      end

      # the rows to show, scrolled so the cursor stays visible
      def window(max_chars)
        f = filtered
        count = rows_shown
        top = [[@index - count / 2, f.size - count].min, 0].max
        out = []
        k = top
        while k < f.size && out.size < count
          out << PickRow.new(f[k], label_for(f[k], max_chars), k == @index)
          k += 1
        end
        out
      end

      def result
        case @kind
        when :input
          @query
        when :confirm
          @items[filtered[@index]].downcase # "yes" / "no"
        else
          if @multi && !@marked.empty?
            @marked.keys.sort.map { |i| @items[i] }.join("\n")
          else
            i = filtered[@index]
            i && @items[i]
          end
        end
      end

      # -> :accept, :cancel or nil
      def handle_key(event)
        sym = event.symbol

        return :cancel if sym == :escape
        return :cancel if event.ctrl && (sym == :c || sym == :g)
        return (result.nil? ? nil : :accept) if sym == :enter

        case @kind
        when :confirm then confirm_key(event)
        when :input then input_key(event)
        else pick_key(event)
        end
      end

      # pasted text goes into the query (first line only)
      def type(text)
        return unless @kind != :confirm

        edit(@query + text.to_s.split("\n").first.to_s)
      end

      # mouse: move the cursor onto an item
      def select(item_index)
        pos = filtered.index(item_index)
        @index = pos if pos
      end

      def move(delta)
        n = filtered.size
        return if n.zero?

        @index = [[@index + delta, 0].max, n - 1].min
      end

      def toggle(advance)
        i = filtered[@index]
        return unless i

        if @marked[i]
          @marked.delete(i)
        else
          @marked[i] = true
        end
        move(1) if advance
      end

      private

      def default_title
        case @kind
        when :confirm then "Are you sure?"
        when :input then "Input"
        else "Select"
        end
      end

      def printable(event)
        c = event.char
        return nil unless c && c.size == 1 && c.ord >= 32 && c.ord != 127
        return nil if event.ctrl || event.super

        c
      end

      def pick_key(event)
        sym = event.symbol

        if sym == :up || (event.ctrl && sym == :p)
          move(-1)
        elsif sym == :down || (event.ctrl && sym == :n)
          move(1)
        elsif sym == :page_up
          move(-@max_rows)
        elsif sym == :page_down
          move(@max_rows)
        elsif sym == :tab
          toggle(true) if @multi
        elsif sym == :backspace
          edit(@query[0...-1].to_s)
        elsif event.ctrl && sym == :u
          edit("")
        elsif (c = printable(event))
          edit(@query + c)
        end

        nil
      end

      def confirm_key(event)
        sym = event.symbol
        c = printable(event).to_s.downcase

        if c == "y"
          @index = 0
          return :accept
        elsif c == "n"
          @index = 1
          return :accept
        elsif sym == :up || sym == :left
          @index = 0
        elsif sym == :down || sym == :right
          @index = 1
        elsif sym == :tab
          @index = 1 - @index
        end

        nil
      end

      def input_key(event)
        sym = event.symbol

        if sym == :backspace
          edit(@query[0...-1].to_s)
        elsif event.ctrl && sym == :u
          edit("")
        elsif event.ctrl && sym == :w
          q = @query.rstrip
          i = q.rindex(" ")
          edit(i ? q[0..i] : "")
        elsif (c = printable(event))
          edit(@query + c)
        end

        nil
      end

      def label_for(item_index, max_chars)
        item = @items[item_index]
        item = item[0, max_chars - 2] + ".." if item.size > max_chars
        @multi ? (marked?(item_index) ? "[x] " : "[ ] ") + item : item
      end

      def edit(query)
        @query = query
        @filtered = nil
        @index = 0
      end
    end

    # Public: one row. Same shape as Dropdown's item: an `empty` carrying the mouse
    #         events, drawn by hand.
    class PickItem < Hokusai::Block
      style <<~EOF
      [style]
        container {
          cursor: "pointer";
        }
      EOF

      template <<~EOF
      [template]
        empty.container { ...container @hover="on_hover" @mousedown="set_emit" @mouseup="emit_item" }
      EOF

      uses(empty: Hokusai::Blocks::Empty)

      computed! :row
      computed :size, default: 16, convert: proc(&:to_i)
      computed :color, default: [222, 222, 222], convert: Hokusai::Color
      computed :selected_color, default: [20, 20, 24, 22], convert: Hokusai::Color
      computed :selected_background, default: [44, 44, 44, 44], convert: Hokusai::Color
      computed :padding, default: [0.0, 8.0, 0.0, 10.0], convert: Hokusai::Padding

      def set_emit(_event)
        @emit_next = true
      end

      def emit_item(_event)
        emit("picked", row) if @emit_next
        @emit_next = false
      end
  
      # the pointer moved over us: make this row the cursor
      def on_hover(event)
        d = event.input.mouse.delta
        emit("hovered", row) if d.x != 0 || d.y != 0
      end

      def render(canvas)
        draw do
          if row.selected
            rect(canvas.x, canvas.y, canvas.width, canvas.height) do |command|
              command.color = selected_background
              command.round = 0.15
            end
          end

          text(row.label, canvas.x + padding.left, canvas.y + (canvas.height - size) / 2.0) do |command|
            command.size = size
            command.color = row.selected ? selected_color : color
          end
        end

        yield canvas
      end
    end

    class ConditionalShow < Hokusai::Block
      template <<-EOF
      [template]
        slot
      EOF

      computed :show, default: true
      computed :show_height, default: nil
      computed :padding, default: [0.0,0.0,0.0,0.0], convert: Hokusai::Padding

      def before_updated
        if show && show_height
          node.meta.set_prop(:height, show_height + padding.height)
        elsif show
          node.meta.set_prop(:height, nil)
        else
          node.meta.set_prop(:height, 0.0)
        end
      end

      def render(canvas)
        if show
          yield canvas
        end
      end
    end

    # Public: the picker box. Stops mouse events so nothing underneath sees them.
    #         Emits "resolved" with :accept when a row is clicked.
    class PickMenu < Hokusai::Block
      style <<~EOF
      [style]
      heading {
        color: rgb(140,140,158);
        padding: padding(10.0, 8.0, 4.0, 14.0);
      }
      queryLine {
        color: rgb(114, 90, 141);
        padding: padding(4.0, 8.0, 8.0, 14.0);
      }
      hint {
        color: rgb(140,140,158);
        padding: padding(6.0, 8.0, 4.0, 14.0);
      }
      box {
        z: 2;
        background: rgb(87, 34, 74);
        rounding: 0.03;
      }
      EOF

      template <<~EOF
      [template]
        vblock { ...box @click="prevent" @mousedown="prevent" @mouseup="prevent" @hover="prevent" @mousemove="prevent" @wheel="on_wheel" }
          text { ...heading :size="size" :content="heading_line" }
          vblock { :size="size"}
            cond { :show="show_query" :show_height="size" ...queryLine }
              text { ...queryLine :size="size" :content="query_line" }
            cond { :show="show_rows" }
              vblock { :height="rows_height" :padding="rows_padding" }
                cond { :show="no_matches"}
                  text { ...hint :size="size" :content="no_matches_line" }
                [for="row in rows"]
                  item {
                    :key="row_key(row, index)"
                    :row="row"
                    :size="size"
                    :height="row_height"
                    @picked="pick_row"
                    @hovered="hover_row"
                  }
            text { ...hint :size="small" :content="hint_line" }
      EOF

      uses(
        cond: ConditionalShow,
        vblock: Hokusai::Blocks::Vblock,
        text: Hokusai::Blocks::Text,
        item: PickItem
      )

      inject :theme

      computed! :state
      computed :size, default: 16, convert: proc(&:to_i)

      def small
        size - 2
      end

      def rows_height
        !show_rows ? 0.0 : nil
      end

      def row_height
        PickState::ROW_H
      end

      def rows_height
        state.rows_shown * PickState::ROW_H
      end

      def rows_padding
        Hokusai::Padding.new(0.0, 8.0, 0.0, 8.0)
      end

      def heading_line
        state.title
      end

      def show_query
        state.show_query?
      end

      def show_rows
        state.show_rows?
      end

      def query_line
        shown = state.secret ? "*" * state.query.size : state.query
        "> #{shown}_"
      end

      def hint_line
        case state.kind
        when :confirm
          "y yes  n no  enter select  esc cancel"
        when :input
          "enter accept  esc cancel"
        else
          count = "#{state.filtered.size}/#{state.items.size}"
          keys = state.multi ? "tab mark  enter accept  esc cancel" : "enter select  esc cancel"
          "#{keys}    #{count}"
        end
      end

      def no_matches
        state.kind == :pick && state.filtered.empty?
      end

      def no_matches_line
        "no matches"
      end

      def rows
        @cw ||= Hokusai.fonts.active.measure_char("a", size)
        state.window([((@box_w || 600.0) / @cw).floor - 6, 8].max)
      end

      def row_key(row, _index)
        row.item_index.to_s
      end

      def prevent(event)
        event.stop
      end

      def on_wheel(event)
        event.stop
        state.move(event.scroll > 0.0 ? 1 : -1)
      end

      def hover_row(row)
        state.select(row.item_index)
      end

      def pick_row(row)
        state.select(row.item_index)
        if state.multi
          state.toggle(false)
        else
          emit("resolved", :accept)
        end
      end

      def render(canvas)
        @box_w = canvas.width

        yield canvas
      end
    end
  end
end
