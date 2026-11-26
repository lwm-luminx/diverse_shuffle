# frozen_string_literal: true

module DiverseShuffle
  module Engine
    # The engine in plain Ruby (Engine::Ruby): the reference the Rust engine is held to, and the one used where the
    # native extension isn't built. Songs are indexes into the pool; every pair answer is worked out once and kept.
    class Ruby
      # Distance assumed when nothing is known, for the soft score.
      UNKNOWN = 0.5
      UNSET = Object.new.freeze

      def initialize(pool, settings, seed)
        @pool = pool
        @settings = settings
        @rng = Rng.new(seed)
        @size = pool.size
        @songs = pool.songs
        @rules = pool.rules
        @matrices = @rules.map { |rule| rule.vector? ? matrix(rule) : nil }
        @attrs = @rules.map { |rule| rule.vector? ? nil : attrs_flags(rule) }
        @cache = @rules.map { Array.new(@size * @size, UNSET) }
        @levels = (0..settings.loosen_steps).map do |level|
          @rules.map { |rule| rule.loosened(level, settings.loosen_factor) }
        end
      end

      # Placements for every song, in order.
      def place(mode)
        remaining = @rng.shuffle((0...@size).to_a)
        mode == :dpp ? batches(remaining) : sequence(remaining, [], mode, [])
      end

      private

      def sequence(remaining, history, mode, placements)
        remaining = remaining.dup
        until remaining.empty?
          placement = place_one(remaining, history, mode)
          remaining.delete_at(remaining.index(placement.song))
          history << placement.song
          placements << placement
        end
        placements
      end

      def place_one(remaining, history, mode)
        (0..(@settings.loosen_steps + 1)).each do |level|
          rules = @levels[level]
          passing, rejected = candidates(remaining, history, rules, mode)
          next if passing.empty?

          return Placement.new(song: pick(passing, history, mode), level:, considered: passing.size + rejected,
                               rejected:)
        end
      end

      def candidates(remaining, history, rules, mode)
        limit = mode == :mmr ? @settings.mmr_k : 1
        passing = []
        rejected = 0
        window = history.last(@settings.window)
        remaining.each do |song|
          rules.nil? || passes?(song, history, window, rules) ? passing << song : rejected += 1
          break if passing.size >= limit
        end
        [passing, rejected]
      end

      def pick(passing, history, mode)
        return passing.first unless mode == :mmr

        window = history.last(@settings.window)
        passing.each_with_index.max_by do |song, index|
          [score(song, window) + (@settings.mmr_jitter * @rng.float), -index]
        end.first
      end

      def passes?(song, history, window, rules)
        rules.each_with_index.all? do |rule, index|
          next true unless rule.hard?

          if rule.vector?
            distance_passes?(index, rule, song, history,
                             window)
          else
            match_passes?(index, rule, song, history, window)
          end
        end
      end

      def distance_passes?(index, rule, song, history, window)
        compared = @settings.compare == :previous ? history.last(1) : window
        closest = compared.filter_map { distance(index, song, it) }.min
        closest.nil? || closest >= rule.min_distance
      end

      def match_passes?(index, rule, song, history, window)
        return false if rule.max_same_in_window && window.count { same?(index, song, it) } >= rule.max_same_in_window

        rule.min_gap.nil? || history.last(rule.min_gap).none? { same?(index, song, it) }
      end

      # How far the song sits from the window before it, from 0 (alike) to 1, weighted per rule.
      def score(song, window)
        return 1.0 if window.empty?

        weighted = @rules.each_with_index.filter_map do |rule, index|
          next if rule.weight.zero?

          distance = window_distance(index, rule, song, window)
          [rule.weight, distance] unless distance.nil?
        end
        blend(weighted)
      end

      def window_distance(index, rule, song, window)
        if rule.vector?
          window.filter_map { distance(index, song, it) }.min&.clamp(0.0, 1.0)
        elsif @attrs[index][song]
          window.any? { same?(index, song, it) } ? 0.0 : 1.0
        end
      end

      # How far apart two songs are over every weighted rule (DPP's kernel).
      def pair_distance(first, second)
        weighted = @rules.each_with_index.filter_map do |rule, index|
          next if rule.weight.zero?

          distance = distance(index, first, second)
          [rule.weight, distance] unless distance.nil?
        end
        blend(weighted)
      end

      def blend(weighted)
        return UNKNOWN if weighted.empty?

        total = weighted.sum(&:first)
        total.zero? ? UNKNOWN : weighted.sum { |weight, distance| weight * distance } / total
      end

      # A rule's distance between two songs, 0 to 1, or nil when unknown. For an attribute rule, 0 when the same and
      # 1 when not, when both songs have the rule's attributes.
      def distance(index, first, second)
        slot = (first * @size) + second
        cached = @cache[index][slot]
        return cached unless cached.equal?(UNSET)

        @cache[index][slot] = compute_distance(index, first, second)
      end

      def compute_distance(index, first, second)
        if @rules[index].vector?
          mine = @songs[first]
          theirs = @songs[second]
          return nil unless mine && theirs
          return 0.0 if mine == theirs

          @matrices[index][(mine * @pool.tracks) + theirs]&.clamp(0.0, 1.0)
        elsif @attrs[index][first] && @attrs[index][second]
          same?(index, first, second) ? 0.0 : 1.0
        end
      end

      # Whether two songs share a value on every one of an attribute rule's keys.
      def same?(index, first, second)
        mine = @songs[first]
        theirs = @songs[second]
        return false unless mine && theirs

        values = @rules[index].values
        a = values[mine]
        b = values[theirs]
        return false unless a && b

        a.each_with_index.all? { |ids, key| !ids.empty? && !b[key].empty? && ids.intersect?(b[key]) }
      end

      # Per song, whether it has attributes and every one of the rule's keys.
      def attrs_flags(rule)
        @songs.map do |track|
          values = track && rule.values[track]
          values ? values.all? { !it.empty? } : false
        end
      end

      # Distances between tracks, track-major, nil where unknown. A pair given one way counts both ways.
      def matrix(rule)
        tracks = @pool.tracks
        found = Array.new(tracks * tracks)
        rule.pairs.each do |a, b, distance|
          found[(a * tracks) + b] = Float(distance)
          found[(b * tracks) + a] ||= Float(distance)
        end
        found
      end

      def dpp = @dpp ||= Dpp.new(self, @rng, @settings.mmr_jitter)

      def batches(remaining)
        history = []
        placements = []
        until remaining.empty?
          batch = dpp.pick(remaining, [@settings.dpp_batch, remaining.size].min)
          remaining -= batch
          sequence(@rng.shuffle(batch), history, :greedy, placements)
        end
        placements
      end

      # Greedy MAP inference for a determinantal point process (Chen, Zhang & Zhou 2018, fast greedy with incremental
      # Cholesky). Kernel L = q_i (1 - distance_ij) q_j, each song's quality q a little random so equal sets don't
      # always win. Fills from the pool's order once the kernel can't tell songs apart.
      class Dpp
        def initialize(engine, rng, jitter)
          @engine = engine
          @rng = rng
          @jitter = jitter
        end

        def pick(pool, size)
          @pool = pool
          @quality = pool.map { 1.0 + (@jitter * @rng.float) }
          @gains = @quality.map { it * it }
          @basis = Array.new(pool.size) { [] }
          @chosen = []
          @taken = Array.new(pool.size, false)
          size.times { break unless added_best? }
          picked = @chosen.map { pool[it] }
          picked + (pool - picked).first(size - picked.size)
        end

        private

        def added_best?
          best = @gains.each_index.reject { @taken[it] }.max_by { [@gains[it], -it] }
          return false if best.nil? || @gains[best] <= 1e-9

          @chosen << best
          @taken[best] = true
          project(best)
          true
        end

        def project(best)
          root = Math.sqrt(@gains[best])
          @pool.each_index do |i|
            next if @taken[i]

            e = (kernel(best, i) - @basis[best].zip(@basis[i]).sum { |a, b| a * b }) / root
            @basis[i] << e
            @gains[i] -= e * e
          end
        end

        def kernel(first, second)
          @quality[first] * @quality[second] * (1.0 - @engine.send(:pair_distance, @pool[first], @pool[second]))
        end
      end
    end
  end
end
