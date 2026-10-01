require_relative "./vtparser/keymap"

# VTParser adapted from https://github.com/coezbek/vtparser/blob/main/lib/vtparser/parser.rb
# To work with MRuby/Krang
module Krang
  module Sessions
    class Action
      attr_reader :action_type, :ch, :private_mode_intermediate_char, :intermediate_chars, :params

      def initialize(action_type, ch, private_mode_intermediate_char, intermediate_chars, params)
        @action_type = action_type
        @ch = ch
        @intermediate_chars = intermediate_chars
        @private_mode_intermediate_char = private_mode_intermediate_char
        @params = params
      end
    end

    class VTParser
      attr_reader :private_mode_intermediate_char, :intermediate_chars, :params, :state

      include Keymap

      # FIX 1: characters above 0x9f used to fall through to :ignore in every
      # state, so any non-ASCII text (accents, box drawing, CJK, emoji) vanished.
      # They can't live in the transition tables (expanding a range up to 0x10ffff
      # would be a million entries per state), so they're looked up here instead.
      HIGH = {
        GROUND: :print,
        OSC_STRING: :osc_put,
        DCS_PASSTHROUGH: :put
      }.freeze

      def initialize(&block)
        @callback = block
        @state = :GROUND
        @intermediate_chars = ''
        @private_mode_intermediate_char = ''
        @params = []
        @ignore_flagged = false
        initialize_states
        build_state_transitions
      end

      def parse(data)
        data.each_char do |ch|
          do_state_change(ch)
        end
      end

      def initialize_states
        @states = {
          :GROUND => {
            (0x00..0x17) => :execute,
            0x19 => :execute,
            (0x1c..0x1f) => :execute,
            (0x20..0x7e) => :print,
            0x7f => :ignore, # FIX 2: DEL is ignored, it used to be printed
          },
          :ESCAPE => {
            :on_entry => :clear,
            (0x00..0x17) => :execute,
            0x19 => :execute,
            (0x1c..0x1f) => :execute,
            0x7f => :ignore,
            (0x20..0x2f) => [:collect, :ESCAPE_INTERMEDIATE],
            (0x30..0x4f) => [:esc_dispatch, :GROUND],
            (0x51..0x57) => [:esc_dispatch, :GROUND],
            0x59 => [:esc_dispatch, :GROUND],
            0x5a => [:esc_dispatch, :GROUND],
            0x5c => [:esc_dispatch, :GROUND],
            (0x60..0x7e) => [:esc_dispatch, :GROUND],
            0x5b => :CSI_ENTRY,
            0x5d => :OSC_STRING,
            0x50 => :DCS_ENTRY,
            0x58 => :SOS_PM_APC_STRING,
            0x5e => :SOS_PM_APC_STRING,
            0x5f => :SOS_PM_APC_STRING,
          },
          :ESCAPE_INTERMEDIATE => {
            (0x00..0x17) => :execute,
            0x19 => :execute,
            (0x1c..0x1f) => :execute,
            (0x20..0x2f) => :collect,
            0x7f => :ignore,
            (0x30..0x7e) => [:esc_dispatch, :GROUND],
          },
          :CSI_ENTRY => {
            :on_entry => :clear,
            (0x00..0x17) => :execute,
            0x19 => :execute,
            (0x1c..0x1f) => :execute,
            0x7f => :ignore,
            (0x20..0x2f) => [:collect, :CSI_INTERMEDIATE],
            0x3a => [:param, :CSI_PARAM], # FIX 3: ':' sub-parameters (38:2::r:g:b, 4:3)
            (0x30..0x39) => [:param, :CSI_PARAM],
            0x3b => [:param, :CSI_PARAM],
            (0x3c..0x3f) => [:private_mode_collect, :CSI_PARAM],
            (0x40..0x7e) => [:csi_dispatch, :GROUND],
          },
          :CSI_PARAM => {
            (0x00..0x17) => :execute,
            0x19 => :execute,
            (0x1c..0x1f) => :execute,
            (0x30..0x39) => :param,
            0x3b => :param,
            0x3a => :param,
            0x7f => :ignore,
            (0x3c..0x3f) => :CSI_IGNORE,
            (0x20..0x2f) => [:collect, :CSI_INTERMEDIATE],
            (0x40..0x7e) => [:csi_dispatch, :GROUND],
          },
          :CSI_INTERMEDIATE => {
            (0x00..0x17) => :execute,
            0x19 => :execute,
            (0x1c..0x1f) => :execute,
            (0x20..0x2f) => :collect,
            0x7f => :ignore,
            (0x30..0x3f) => :CSI_IGNORE,
            (0x40..0x7e) => [:csi_dispatch, :GROUND],
          },
          :CSI_IGNORE => {
            (0x00..0x17) => :execute,
            0x19 => :execute,
            (0x1c..0x1f) => :execute,
            (0x20..0x3f) => :ignore,
            (0x40..0x7e) => :GROUND, # FIX 4: a malformed CSI ends at its final byte (it used to swallow the rest of the stream)
            0x7f => :ignore,
          },
          :DCS_ENTRY => {
            :on_entry => :clear,
            (0x00..0x17) => :ignore,
            0x19 => :ignore,
            (0x1c..0x1f) => :ignore,
            0x7f => :ignore,
            0x3a => :DCS_IGNORE,
            (0x20..0x2f) => [:collect, :DCS_INTERMEDIATE],
            (0x30..0x39) => [:param, :DCS_PARAM],
            0x3b => [:param, :DCS_PARAM],
            (0x3c..0x3f) => [:collect, :DCS_PARAM],
            (0x40..0x7e) => [:collect, :DCS_PASSTHROUGH],
          },
          :DCS_PARAM => {
            (0x00..0x17) => :ignore,
            0x19 => :ignore,
            (0x1c..0x1f) => :ignore,
            (0x30..0x39) => :param,
            0x3b => :param,
            0x7f => :ignore,
            0x3a => :DCS_IGNORE,
            (0x3c..0x3f) => :DCS_IGNORE,
            (0x20..0x2f) => [:collect, :DCS_INTERMEDIATE],
            (0x40..0x7e) => [:collect, :DCS_PASSTHROUGH],
          },
          :DCS_INTERMEDIATE => {
            (0x00..0x17) => :ignore,
            0x19 => :ignore,
            (0x1c..0x1f) => :ignore,
            (0x20..0x2f) => :collect,
            0x7f => :ignore,
            (0x30..0x3f) => :DCS_IGNORE,
            (0x40..0x7e) => [:collect, :DCS_PASSTHROUGH],
          },
          :DCS_PASSTHROUGH => {
            :on_entry => :hook,
            (0x00..0x17) => :put,
            0x19 => :put,
            (0x1c..0x1f) => :put,
            (0x20..0x7e) => :put,
            0x7f => :ignore,
            :on_exit => :unhook,
          },
          :DCS_IGNORE => {
            (0x00..0x17) => :ignore,
            0x19 => :ignore,
            (0x1c..0x1f) => :ignore,
            (0x20..0x7f) => :ignore,
          },
          :OSC_STRING => {
            :on_entry => :osc_start,
            (0x00..0x06) => :ignore,
            (0x07) => [:ignore, :GROUND], # FIX 5: BEL ends the string. It used to be passed to osc_put *after* osc_end
            (0x08..0x17) => :ignore,
            0x19 => :ignore,
            (0x1c..0x1f) => :ignore,
            (0x20..0x7f) => :osc_put,
            :on_exit => :osc_end,
          },
          :SOS_PM_APC_STRING => {
            (0x00..0x17) => :ignore,
            0x19 => :ignore,
            (0x1c..0x1f) => :ignore,
            (0x20..0x7f) => :ignore,
          },
        }

        @anywhere_transitions = {
          0x18 => [:execute, :GROUND],
          0x1a => [:execute, :GROUND],
          (0x80..0x8f) => [:execute, :GROUND],
          (0x91..0x97) => [:execute, :GROUND],
          0x99 => [:execute, :GROUND],
          0x9a => [:execute, :GROUND],
          0x9c => :GROUND,
          0x1b => :ESCAPE,
          0x98 => :SOS_PM_APC_STRING,
          0x9e => :SOS_PM_APC_STRING,
          0x9f => :SOS_PM_APC_STRING,
          0x90 => :DCS_ENTRY,
          0x9d => :OSC_STRING,
          0x9b => :CSI_ENTRY,
        }
      end

      def build_state_transitions
        @state_transitions = {}
        @states.each do |state, transitions|
          expanded_transitions = expand_transitions(transitions)
          anywhere_transitions = expand_transitions(@anywhere_transitions)
          merged_transitions = anywhere_transitions.merge(expanded_transitions) { |_, _, newval| newval }
          on_entry = merged_transitions.delete(:on_entry)
          on_exit = merged_transitions.delete(:on_exit)
          @state_transitions[state] = {
            transitions: merged_transitions,
            on_entry: on_entry,
            on_exit: on_exit,
          }
        end
      end

      def expand_transitions(transitions)
        expanded = {}
        transitions.each do |key, value|
          if key.is_a?(Range)
            key.each do |k|
              expanded[k] = value
            end
          else
            expanded[key] = value
          end
        end
        expanded
      end

      def do_state_change(ch)
        state_info = @state_transitions[@state]
        transitions = state_info[:transitions]
        o = ch.ord
        action_state = transitions[o]
        action_state = HIGH[@state] if action_state.nil? && o > 0x9f # FIX 1

        action, new_state = nil, nil

        if action_state
          if action_state.is_a?(Array)
            action = action_state[0]
            new_state = action_state[1]
          else
            if @states.key?(action_state)
              new_state = action_state
            else
              action = action_state
            end
          end
        else
          action = :ignore
        end

        if new_state
          on_exit = state_info[:on_exit]
          handle_action(on_exit, nil) if on_exit
        end

        handle_action(action, ch) if action

        if new_state
          @state = new_state
          new_state_info = @state_transitions[@state]
          on_entry = new_state_info[:on_entry]
          handle_action(on_entry, nil) if on_entry
        end
      end

      def handle_action(action, ch)
        case action
        when :private_mode_collect
          @private_mode_intermediate_char = ch
          return
        when :collect
          unless @ignore_flagged
            @intermediate_chars << ch
          end
          return
        when :param
          if ch == ';'
            # FIX 6: a leading ';' means the first parameter was empty. ";5H" is
            # [0, 5], it used to come out as [5].
            @params << 0 if @params.empty?
            @params << 0 if @params.size < 32
          elsif ch == ':'
            @params << 0 if @params.empty?
            cur = @params[-1]
            cur = (@params[-1] = [cur]) unless cur.is_a?(Array)
            cur << 0 if cur.size < 8
          else
            @params << 0 if @params.empty?
            d = ch.ord - 48
            cur = @params[-1]
            if cur.is_a?(Array)
              cur[-1] = [cur[-1] * 10 + d, 65535].min
            else
              @params[-1] = [cur * 10 + d, 65535].min # FIX 7: no runaway integers
            end
          end
          return
        when :clear
          @intermediate_chars = ''
          @private_mode_intermediate_char = ''
          @params = []
          @ignore_flagged = false
        else
          @callback.call(Action.new(action, ch, private_mode_intermediate_char, intermediate_chars, params)) if @callback

          # FIX 8: parameters are only dropped once a sequence is dispatched (or
          # on entry to a new one). A control character in the middle of a sequence
          # (:execute) or an ignored byte used to wipe what had been collected.
          if RESET_AFTER.include?(action)
            @intermediate_chars = ''
            @private_mode_intermediate_char = ''
            @params = []
            @ignore_flagged = false
          end
        end
      end

      RESET_AFTER = [:csi_dispatch, :esc_dispatch, :hook, :unhook, :osc_end].freeze
    end
  end
end
