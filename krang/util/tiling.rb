
# Public: a node in the layout tree.
#         A leaf holds one shell (its Session lives in Tiling, keyed by id).
#         A branch splits its space between two children.
module Krang
  module Util
    class Tile
      attr_accessor :dir, :ratio, :a, :b, :parent
      attr_reader :id

      def self.next_id
        @counter = (@counter || 0) + 1
      end

      # dir - :h (children side by side) or :v (stacked)
      def initialize(dir: nil, a: nil, b: nil, ratio: 0.5)
        @id = Tile.next_id
        @dir = dir
        @ratio = ratio
        @a = a
        @b = b
        @parent = nil
        a.parent = self if a
        b.parent = self if b
      end

      def leaf?
        @a.nil?
      end

      def leaves
        leaf? ? [self] : @a.leaves + @b.leaves
      end
    end

    # Public: shared state for the whole tiled terminal. Provided by the root block
    #         and injected by every Terminal / Ansi below it.
    class Tiling
      attr_reader :root, :focus_id, :token, :pick

      def initialize(theme)
        @root = Tile.new
        @focus_id = @root.id
        @sessions = {}
        @rects = {}

        # scripts prove they run inside this terminal by echoing this token back
        # (passed to every shell as $HOKUSAI_TOKEN). Anything else that prints
        # escape sequences, like `cat` on a hostile file, can't guess it.
        @token = make_token
        @pick = nil
        @pick_queue = []
      end

      def make_token
        hex = "0123456789abcdef"
        Array.new(32) { hex[(rand * 16).to_i % 16] }.join
      end

      # ---- lookup ------------------------------------------------------------

      def leaves
        @root.leaves
      end

      def focused_tile
        leaves.find { |t| t.id == @focus_id } || leaves.first
      end

      def focused?(tile)
        tile.id == @focus_id
      end

      def focus(id)
        @focus_id = id
      end

      def session(tile)
        @sessions[tile.id] ||= begin
          sess = Krang::Session.new(tile, "/bin/bash", @token)
          sess.on_osc = ->(str) { handle_osc(sess, str) }
          sess
        end
      end

      def rect_of(tile)
        @rects[tile.id]
      end

      # every session gets an equal slice of the frame's parse time
      def budget
        0.008 / [@sessions.size, 1].max
      end

      def report(tile, canvas)
        @rects[tile.id] = [canvas.x, canvas.y, canvas.width, canvas.height]
      end

      # ---- per frame ---------------------------------------------------------

      def tick
        @ending&.each { |s, req| end_plugin(s, req) }
        @ending = nil

        @sessions.values.each do |s|
          s.pump
          close(s.tile) if s.exited?
        end
      end

      # ---- layout ------------------------------------------------------------

      def split(dir)
        leaf = focused_tile
        fresh = Tile.new
        old_parent = leaf.parent

        branch = Tile.new(dir: dir, a: leaf, b: fresh) # re-parents leaf

        if old_parent.nil?
          @root = branch
        else
          if old_parent.a.equal?(leaf)
            old_parent.a = branch
          else
            old_parent.b = branch
          end
          branch.parent = old_parent
        end

        @focus_id = fresh.id
      end

      def close(tile)
        closing = @sessions.delete(tile.id)
        drop_picks(closing) if closing
        closing&.close
        @rects.delete(tile.id)

        parent = tile.parent
        if parent.nil?
          Hokusai.close_window # last pane
          return
        end

        sibling = parent.a.equal?(tile) ? parent.b : parent.a
        grand = parent.parent

        if grand.nil?
          @root = sibling
          sibling.parent = nil
        else
          if grand.a.equal?(parent)
            grand.a = sibling
          else
            grand.b = sibling
          end
          sibling.parent = grand
        end

        @focus_id = sibling.leaves.first.id if @focus_id == tile.id
      end

      def close_all
        @sessions.values.each(&:close)
      end

      # ---- focus -------------------------------------------------------------

      def focus_dir(dir)
        cur = @rects[@focus_id]
        return unless cur

        cx = cur[0] + cur[2] / 2.0
        cy = cur[1] + cur[3] / 2.0
        best = nil

        @rects.each do |id, (x, y, w, h)|
          next if id == @focus_id

          mx = x + w / 2.0
          my = y + h / 2.0
          ok =
            case dir
            when :left  then mx < cx
            when :right then mx > cx
            when :up    then my < cy
            when :down  then my > cy
            end
          next unless ok

          d = (mx - cx).abs + (my - cy).abs
          best = [id, d] if best.nil? || d < best[1]
        end

        @focus_id = best[0] if best
      end

      # ---- input -------------------------------------------------------------

      def send_key(event)
        return pick_key(event) if @pick

        s = @sessions[@focus_id]
        return unless s
        return if s.active_plugin

        bytes = Util::KeyMap.bytes(event, s.selection_active?, s.screen, interactive: s.alt_screen?)
        return unless bytes

        if s.selection_active?
          s.selection.clear
          s.grid_input.clear
        end
        s.stick = true
        s.write(bytes)
      end

      def paste
        text = Hokusai.paste
        return @pick.type(text) if @pick && text

        s = @sessions[@focus_id]
        return unless s && text

        s.stick = true
        s.paste(text)
      end

      # ---- widgets (hk pick / confirm / input) ---------------------------------------------
      def picking?
        !@pick.nil?
      end

      PluginRequest = Struct.new(:id, :done)

      # A request looks like "7777;<token>;<cmd>;<id>;<widget>;<base64 payload>".
      def handle_osc(session, str)
        parts = str.to_s.split(";", 6)
        return unless parts[0] == "7777" && parts[1] == @token

        cmd = parts[2]
        id = parts[3].to_s
        widget = parts[4]
        payload = parts[5].to_s

        case cmd
        when "part"
          # "7777;<token>;part;<id>;<b64 chunk>": the start of a long payload
          # @parts here is needed to buffer the string over mutiple frames for Windows/ConPTY
          buf = (@parts ||= {})[id] ||= +""
          buf << parts[4].to_s
          @parts.delete(id) if buf.bytesize > 4 * 1024 * 1024 # runaway: drop it

        when "open"
          payload = ((@parts ||= {}).delete(id) || "") + payload
          url, path = b64_decode(payload).split("\x1e", 2)
          if plugin_klass = Krang.plugins[widget]
            # give windows an ack
            reply(session, id, "opened") if windows?
            req = PluginRequest.new(id, false)
            plugin = plugin_klass.mount
            session.plugin_request = req
            session.active_plugin = plugin
            on_reply = ->(value) do
              return if req.done
              req.done = true

              if value.nil?
                reply(session, id, "cancel")
              else
                reply(session, id, "result", b64_encode(value.to_s))
              end

              (@ending ||= []) << [session, req]
            end
            begin
              plugin.on_ready(url, path, &on_reply) if plugin.respond_to?(:on_ready)
              plugin.node.meta.focus
            rescue => e
              puts "plugin #{widget}: #{e.class}: #{e.message}"
              on_reply.call(nil)
            end
          else 
            reply(session, id, "unsupported plugin")
          end
        when "cancel"
          @parts&.delete(id)
          req = session.plugin_request
          if req && req.id == id
            req.done = true
            end_plugin(session, req)
          end
        end
      end

      def end_plugin(session, req)
        return unless session.plugin_request.equal?(req)

        session.plugin_request = nil
        session.active_plugin = nil
      end

      def open_widget(session, id, payload, kind)
        opts, items = parse_request(b64_decode(payload))
        return reply(session, id, "cancel") if kind == :pick && items.empty?

        state = Blocks::PickState.new(id, session, opts, items, kind)
        if @pick
          @pick_queue << state
        else
          start_pick(state)
        end
      end

      def start_pick(state)
        @pick = state
        @focus_id = state.session.tile.id
      end

      def pick_key(event)
        result = @pick.handle_key(event)
        finish_pick(result) if result
      end

      # kind - :accept or :cancel
      def finish_pick(kind)
        state = @pick
        return unless state

        @pick = nil
        if kind == :accept && state.result
          reply(state.session, state.id, "result", b64_encode(state.result))
        else
          reply(state.session, state.id, "cancel")
        end

        nxt = @pick_queue.shift
        start_pick(nxt) if nxt
      end

      # the script gave up (killed): close its picker without replying
      def cancel_pick(id)
        if @pick && @pick.id == id
          @pick = nil
          nxt = @pick_queue.shift
          start_pick(nxt) if nxt
        else
          @pick_queue.reject! { |p| p.id == id }
        end
      end

      # a pane went away: its requests can never be answered
      def drop_picks(session)
        @pick_queue.reject! { |p| p.session.equal?(session) }
        return unless @pick && @pick.session.equal?(session)

        @pick = nil
        nxt = @pick_queue.shift
        start_pick(nxt) if nxt
      end

      def windows?
        ENV["OS"] == "Windows_NT"
      end

      # "ESC ] 7777 ; <id> ; <what> [; <payload>] BEL", typed into the pty
      def reply(session, id, what, payload = nil)
        body = "7777;#{id};#{what}"
        body += ";#{payload}" if payload

        out =  windows? ? body : "\e]#{body}"
        session.write(out + "\a")
      end

      # header lines "key: value", a blank line, then one item per line
      def parse_request(text)
        head, body = text.split("\n\n", 2)
        opts = {}
        head.to_s.split("\n").each do |line|
          k, v = line.split(": ", 2)
          opts[k] = v.to_s if k && !k.empty?
        end
        items = body.to_s.split("\n").reject { |l| l.empty? }
        [opts, items]
      end

      def b64_decode(str)
        str.unpack("m").first.to_s
      end

      def b64_encode(str)
        [str].pack("m").delete("\n")
      end
    end
  end
end
