module ImagePlugin
  class Manifest < Hokusai::Block
    template <<-EOF
    [template]
      empty { 
        @keypress="on_keypress"
      }
    EOF

    uses(
      vblock: Hokusai::Blocks::Vblock,
      empty: Hokusai::Blocks::Empty
    )

    HELP_TEXT = "Shift + left/right arrow to move"
    IMAGE_EXT = /\.(jpe?g|png|tga|bmp|psd|gif|hdr|pic|pnm)$/i

    attr_reader :images
    attr_accessor :count, :cursor

    def initialize(**args)
      super

      @images = {}
      @paths = []
      @cursor = 0
      @count = 0
    end

    def on_ready(cwd, payload, &reply)
      @reply = reply
      parse_payload(cwd, payload)
    end

    def on_keypress(event)
      if event.symbol == :enter
        @reply.call(images.keys[cursor])
        return
      end

      if event.symbol == :escape
        @reply.call(nil)
        return
      end

      return unless event.shift

      case event.symbol
      when :right
        self.cursor += 1 if cursor < count - 1
      when :left
        self.cursor -= 1 if cursor > 0
      end
    end

    def image_by_index(index)
      key = images.keys[index]
      
      [key, images[key]]  
    end

    def absolute?(path)
      path.start_with?("/") || path.start_with?("\\") ||                  # POSIX, UNC
        (path.size > 2 && path[1] == ":" && (path[2] == "\\" || path[2] == "/")) # C:\ or C:/
    end

    def parse_payload(cwd, payload)
      payload.to_s.split("\n").each do |line|
        path = line.strip
        next unless path =~ IMAGE_EXT
        key = absolute?(path) ? path : File.join(cwd, path)

        images[key] ||= begin
          self.count += 1
          Hokusai::Image.from_file(key)
        end
      end

      @reply.call(nil) if count.zero? # nothing to show: give the shell back
    end

    def render(canvas)
      x = canvas.x.to_f
      y = canvas.y.to_f
      w = canvas.width.to_f
      h = canvas.height.to_f

      if count > 0
        path, obj = image_by_index(cursor)

        draw do
          image(obj, x, y, w, h - 20.0) do
          end

          rect(x, y + h - 30.0, w, 30.0) do |command|
            command.color = Hokusai::Color.new(22,22,22)
          end
          
          text(HELP_TEXT, x, y + h - 30) do |command|
            command.size = 15
            command.color = Hokusai::Color.new(222,222,222)
          end

          text(path, x, y + h - 15.0) do |command|
            command.size = 15
            command.color = Hokusai::Color.new(222,222,222)
          end
        end
      else
        draw do
          text("No images found", x, y) do |command|
            command.size = 15
            command.color = Hokusai::Color.new(0,0,0)
          end
        end
      end

      yield canvas

    end
  end
end

Krang.register_plugin "img", ImagePlugin::Manifest