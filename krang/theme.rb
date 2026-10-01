module Krang
  # Public: The theme for the application
  class Theme
    # Public: creates an ostruct-like object from a theme.json file
    # 
    # path - a theme.json (default assets/theme.json)
    # 
    # Returns a Krang::Theme
    def self.init(from = "assets/theme.json")
      theme = JSON.parse(File.read(from))
      obj = new

      theme.each do |k, v|
        set_attr(obj, k, v)
      end
      
      obj
    end

    def self.set_attr(obj, k, v)
      if v.is_a?(Hash)
        other = new
        v.each do |ok, ov|
          set_attr(other, ok, ov)
        end

        obj.define_singleton_method(k) do
          other
        end
      elsif k.end_with?("color")
        obj.define_singleton_method(k) do
          Hokusai::Color.convert(v)
        end
      elsif k.end_with?("padding")
        obj.define_singleton_method(k) do
          Hokusai::Padding.convert(v)
        end
      else
        obj.define_singleton_method(k) do
          v
        end
      end
    end
  end
end