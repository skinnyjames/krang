module Krang
  module Util
    # Public: turns Hokusai key events into the bytes a terminal app expects.
    #
    # The encoding follows xterm: arrows and Home/End switch between CSI and SS3
    # with DECCKM, modifiers become a "1;<mod>" parameter, F-keys and the editing
    # keys use the "~" forms.
    module KeyMap
      CURSOR = { up: "A", down: "B", right: "C", left: "D", home: "H", end: "F" }.freeze
      SS3_FKEYS = { f1: "P", f2: "Q", f3: "R", f4: "S" }.freeze
      TILDE = {
        insert: 2, delete: 3, page_up: 5, page_down: 6,
        f5: 15, f6: 17, f7: 18, f8: 19, f9: 20, f10: 21, f11: 23, f12: 24
      }.freeze

      # keys a terminal sends as control characters when ctrl is held
      CTRL = {
        space: "\x00", two: "\x00", left_bracket: "\e", backslash: "\x1c",
        right_bracket: "\x1d", six: "\x1e", minus: "\x1f", slash: "\x1f"
      }.freeze

      KEYPAD = {
        kp_0: "p", kp_1: "q", kp_2: "r", kp_3: "s", kp_4: "t", kp_5: "u", kp_6: "v",
        kp_7: "w", kp_8: "x", kp_9: "y", kp_decimal: "n", kp_add: "k", kp_subtract: "m",
        kp_multiply: "j", kp_divide: "o", kp_enter: "M", kp_equal: "X"
      }.freeze

      KEYPAD_PLAIN = {
        kp_0: "0", kp_1: "1", kp_2: "2", kp_3: "3", kp_4: "4", kp_5: "5", kp_6: "6",
        kp_7: "7", kp_8: "8", kp_9: "9", kp_decimal: ".", kp_add: "+", kp_subtract: "-",
        kp_multiply: "*", kp_divide: "/", kp_enter: "\r", kp_equal: "="
      }.freeze

      # event       - a Hokusai::KeyboardEvent
      # selecting   - there is a selection, so ctrl+c belongs to the copy
      # screen      - the Screen, for DECCKM / keypad mode (nil: defaults)
      # interactive - a full-screen app is in charge: the navigation keys
      #               (Home, End, Page Up/Down, Insert) are its, not the scrollback's
      #
      # Returns a String, or nil if the key means nothing to the terminal.
      def self.bytes(event, selecting, screen = nil, interactive: false)
        sym = event.symbol

        return selecting ? nil : "\x03" if event.ctrl && !event.alt && sym == :c

        app_cursor = screen ? screen.app_cursor : false
        app_keypad = screen ? screen.app_keypad : false
        mod = modifier(event)

        if (c = CURSOR[sym])
          return nil if !interactive && (sym == :home || sym == :end)

          return mod > 1 ? "\e[1;#{mod}#{c}" : (app_cursor ? "\eO#{c}" : "\e[#{c}")
        end

        if (c = SS3_FKEYS[sym])
          return mod > 1 ? "\e[1;#{mod}#{c}" : "\eO#{c}"
        end

        if (n = TILDE[sym])
          return nil if !interactive && (sym == :page_up || sym == :page_down || sym == :insert)

          return mod > 1 ? "\e[#{n};#{mod}~" : "\e[#{n}~"
        end

        if KEYPAD.key?(sym)
          return app_keypad && mod == 1 ? "\eO#{KEYPAD[sym]}" : KEYPAD_PLAIN[sym]
        end

        case sym
        when :enter then return event.alt ? "\e\r" : "\r"
        when :tab then return event.shift ? "\e[Z" : (event.alt ? "\e\t" : "\t")
        when :escape then return "\e"
        when :backspace then return event.alt ? "\e\x7f" : (event.ctrl ? "\x08" : "\x7f")
        end

        return nil if event.super

        if event.ctrl
          code = CTRL[sym]
          s = sym.to_s
          code ||= (s.ord & 0x1f).chr if s.size == 1 && s =~ /[a-z]/
          return nil unless code

          return event.alt ? "\e" + code : code
        end

        # Alt/Meta sends ESC first. The pressed key is used (the typed character
        # may be a composed one, like Option+e on a Mac).
        if event.alt
          s = sym.to_s
          return "\e" + (event.shift ? s.upcase : s) if s.size == 1 && s =~ /[a-z]/

          c = event.char
          return "\e" + c if c && c.size == 1 && c.ord >= 32 && c.ord < 127
        end

        c = event.char
        return c if c && c.size == 1 && c.ord >= 32 && c.ord != 127

        nil
      end

      # xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4)
      def self.modifier(event)
        1 + (event.shift ? 1 : 0) + (event.alt ? 2 : 0) + (event.ctrl ? 4 : 0)
      end
    end
  end
end

