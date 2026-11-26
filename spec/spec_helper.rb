# frozen_string_literal: true

require 'diverse_shuffle'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { it.syntax = :expect }
end

# Random pools for the specs: tracks with distances and attributes, songs that share tracks and songs with none.
module PoolMaker
  E = DiverseShuffle::Engine

  def self.pool(random, songs: 40, tracks: 25)
    rules = [vector_rule(random, tracks, 0.25), vector_rule(random, tracks, nil),
             match_rule(random, tracks, max_same_in_window: 1), match_rule(random, tracks, min_gap: 3),
             match_rule(random, tracks, max_same_in_window: 2, min_gap: 2)]
    E::Pool.new(songs: Array.new(songs) { random.rand < 0.9 ? random.rand(tracks) : nil }, tracks:,
                rules:)
  end

  def self.vector_rule(random, tracks, min_distance)
    pairs = (0...tracks).to_a.combination(2).filter_map { |a, b| [a, b, random.rand * 1.1] if random.rand < 0.85 }
    E::VectorRule.new(weight: random.rand.round(2), min_distance:, pairs:)
  end

  def self.match_rule(random, tracks, **limits)
    keys = random.rand(1..2)
    values = Array.new(tracks) do
      next if random.rand < 0.1

      Array.new(keys) { random.rand < 0.1 ? [] : Array.new(random.rand(1..2)) { random.rand(4) } }
    end
    E::MatchRule.new(weight: [0.0, 0.5, 1.0].sample(random:), values:, **limits)
  end
end
