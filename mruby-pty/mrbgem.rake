MRuby::Gem::Specification.new('mruby-pty') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Developer'
  spec.summary = 'Cross-platform PTY functionality for mruby'

  # Depend on mruby-io for file descriptor handling
  spec.add_dependency('mruby-io')

  windows = spec.build.cc.command.to_s =~ /mingw|clang-cl|\bcl(\.exe)?\z/

  # Link utility library for openpty on Linux/BSD systems
  if !cc.defines.include?('_WIN32')
    spec.linker.libraries << 'util' unless windows
  end
end
