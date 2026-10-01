require_relative "krang/theme"
require_relative "krang/session"
require_relative "krang/patches/wrap_stream"
require_relative "krang/patches/panel"
require_relative "krang/blocks/root"
require_relative "./resolver"

def ruby_file(path)
  RubyResolver.new(path).code
end

PLUGIN_PATH = ENV["KRANG_PLUGIN_PATH"] || "assets/plugins"

module Krang
  def self.register_plugin(name, block)
    if plugins[name]
      puts "Krang Plugin: #{name} is already registered"
    else
      plugins[name] = block
    end
  end

  def self.plugins
    @plugins ||= {}
  end

  class App < Hokusai::Block
    template do 
      child(Krang::Blocks::Root) do
      end
    end

    provide :theme, :theme

    def theme
      @theme ||= Krang::Theme.init
    end
  end
end

Dir.glob("#{PLUGIN_PATH}/*").each do |dir|
  if File.exist?("#{dir}/manifest.rb")
    eval ruby_file("#{dir}/manifest.rb")
  else
    puts "Warning: Plugin #{dir} is not a krang plugin"
  end
end

Hokusai::Backend.run(Krang::App) do |config|
  config.width = 700
  config.height = 500
  config.title = "Krang"
  config.event_waiting = false
  EXTRA = "–—‘’“”…\r\n\t 0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%%^&*(),.?/\"\\[]-_=+|~`{}<>;:'✗➜"

  config.after_load do
    Hokusai.fonts.register "default", Hokusai::Backend::Font.from_ext("assets/DejaVu.ttf", 45, EXTRA)
    Hokusai.fonts.activate "default"
  end
end

