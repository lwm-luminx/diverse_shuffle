# frozen_string_literal: true

module DiverseShuffle
  module Engine
    # The seeded generator: SplitMix64, seeded by the 64-bit FNV-1a hash of the seed text, so the same seed always gives
    # the same draws (and the Rust engine draws exactly the same numbers).
    class Rng
      MASK = 0xFFFF_FFFF_FFFF_FFFF
      GOLDEN = 0x9e37_79b9_7f4a_7c15

      # FNV-1a over the text's bytes.
      def self.fnv(text)
        text.to_s.each_byte.reduce(0xcbf2_9ce4_8422_2325) do |state, byte|
          ((state ^ byte) * 0x0000_0100_0000_01b3) & MASK
        end
      end

      # SplitMix64's output function.
      def self.mix(state)
        z = ((state ^ (state >> 30)) * 0xbf58_476d_1ce4_e5b9) & MASK
        z = ((z ^ (z >> 27)) * 0x94d0_49bb_1331_11eb) & MASK
        z ^ (z >> 31)
      end

      def initialize(seed)
        @state = self.class.fnv(seed)
      end

      def next_u64
        @state = (@state + GOLDEN) & MASK
        self.class.mix(@state)
      end

      # A float in [0, 1).
      def float = (next_u64 >> 11) / 9_007_199_254_740_992.0

      # Fisher-Yates, from the last element down.
      def shuffle(items)
        result = items.dup
        (result.size - 1).downto(1) do |i|
          j = next_u64 % (i + 1)
          result[i], result[j] = result[j], result[i]
        end
        result
      end
    end
  end
end
