# frozen_string_literal: true

module DiverseShuffle
  module Engine
    # A rule over measured vectors: how far apart two tracks are, from the distances you give for pairs of tracks
    # (cosine distance from your vector store, say). A pair with no distance is unknown.
    #
    #   VectorRule.new(weight: 1.0, min_distance: 0.25, pairs: [[0, 1, 0.42], [0, 2, 0.07]])
    #
    # - weight: how much the rule counts in the soft score (0 leaves it out of the score).
    # - min_distance: the hard rule: a song must be at least this far from the songs it's compared with; nil for none.
    # - pairs: [track, track, distance] triples, track indexes into Pool#tracks. A pair given one way counts both ways;
    #   given both ways, each way keeps its own distance. A track is 0.0 from itself.
    class VectorRule
      attr_reader :weight, :min_distance, :pairs

      def initialize(weight:, pairs:, min_distance: nil)
        @weight = Float(weight)
        @min_distance = min_distance && Float(min_distance)
        @pairs = pairs
      end

      def vector? = true

      # Whether the rule can rule a song out.
      def hard? = !min_distance.nil?

      # This rule loosened `level` steps: min_distance times factor**level.
      def loosened(level, factor)
        return self if level.zero? || min_distance.nil?

        VectorRule.new(weight:, pairs:, min_distance: min_distance * (factor**level))
      end
    end

    # A rule over attributes: two songs are the same when, on every one of the rule's keys, they share a value.
    #
    #   MatchRule.new(weight: 0.5, max_same_in_window: 1, values: [[[3], [7]], [[3], []], nil])
    #
    # - weight: how much the rule counts in the soft score.
    # - max_same_in_window: the hard rule: fewer than this many of the window's songs may be the same; nil for none.
    # - min_gap: the hard rule: none of the last min_gap songs may be the same; nil for none.
    # - values: per track, one list of value ids per key (values you number yourself: equal ids are equal values), or
    #   nil for a track with no attributes at all. A key with no values never matches.
    class MatchRule
      attr_reader :weight, :max_same_in_window, :min_gap, :values

      def initialize(weight:, values:, max_same_in_window: nil, min_gap: nil)
        @weight = Float(weight)
        @max_same_in_window = max_same_in_window && Integer(max_same_in_window)
        @min_gap = min_gap && Integer(min_gap)
        raise ArgumentError, 'max_same_in_window must not be negative' if @max_same_in_window&.negative?
        raise ArgumentError, 'min_gap must not be negative' if @min_gap&.negative?

        @values = values
      end

      def vector? = false

      def hard? = !max_same_in_window.nil? || !min_gap.nil?

      # This rule loosened `level` steps: max_same_in_window plus level, min_gap minus level (not below 0).
      def loosened(level, _factor)
        return self if level.zero? || !hard?

        MatchRule.new(weight:, values:, max_same_in_window: max_same_in_window && (max_same_in_window + level),
                      min_gap: min_gap && [min_gap - level, 0].max)
      end
    end

    # How the shuffle places songs.
    #
    # - window: how many songs back the hard rules (and the soft score) look.
    # - compare: :window (min_distance against every song in the window) or :previous (against the one before only).
    # - loosen_steps, loosen_factor: when no song passes, the rules loosen a step at a time, this many steps (see
    #   VectorRule#loosened and MatchRule#loosened); past the last step every song passes.
    # - mmr_k, mmr_jitter: :mmr takes the best of the first mmr_k passing songs by soft score plus up to mmr_jitter of
    #   randomness.
    # - dpp_batch: :dpp picks spread-out sets of this many songs.
    Settings = Data.define(:window, :compare, :loosen_steps, :loosen_factor, :mmr_k, :mmr_jitter, :dpp_batch) do
      def initialize(window: 3, compare: :window, loosen_steps: 3, loosen_factor: 0.75, mmr_k: 8, mmr_jitter: 0.15,
                     dpp_batch: 8)
        compare = compare.to_sym
        raise ArgumentError, 'compare must be :window or :previous' unless %i[window previous].include?(compare)

        super(window: at_least(window, 0, 'window'), compare:, loosen_steps: at_least(loosen_steps, 0, 'loosen_steps'),
              loosen_factor: Float(loosen_factor), mmr_k: at_least(mmr_k, 1, 'mmr_k'), mmr_jitter: Float(mmr_jitter),
              dpp_batch: at_least(dpp_batch, 1, 'dpp_batch'))
      end

      private

      def at_least(value, floor, name)
        value = Integer(value)
        raise ArgumentError, "#{name} must be at least #{floor}" if value < floor

        value
      end
    end

    # The songs to place and what's known about them.
    #
    # - songs: per song, the index of its track, or nil for a song nothing is known about. Several songs may share a
    #   track.
    # - tracks: how many tracks the rules' pairs and values index.
    # - rules: VectorRule and MatchRule, in order (the soft score adds them up in this order).
    class Pool
      attr_reader :songs, :tracks, :rules

      def initialize(songs:, tracks:, rules:)
        @songs = songs.map { |track| track && Integer(track) }
        @tracks = Integer(tracks)
        @rules = rules
        check!
      end

      def size = songs.size

      private

      def check!
        songs.each { check_track!(it) if it }
        rules.each { it.vector? ? check_pairs!(it) : check_values!(it) }
      end

      def check_track!(track)
        raise ArgumentError, "track #{track} out of range" unless track.is_a?(Integer) && track.between?(0, tracks - 1)
      end

      def check_pairs!(rule)
        rule.pairs.each do |a, b, _distance|
          check_track!(a)
          check_track!(b)
        end
      end

      def check_values!(rule)
        raise ArgumentError, 'a MatchRule needs values for every track' unless rule.values.size == tracks

        keys = rule.values.compact.map(&:size).uniq
        raise ArgumentError, 'every track of a MatchRule needs the same keys' if keys.size > 1
      end
    end

    # Where one song went: the song (its index in Pool#songs), the loosening level it passed at, how many songs were
    # looked at for the slot and how many of those were ruled out.
    Placement = Data.define(:song, :level, :considered, :rejected)
  end
end
