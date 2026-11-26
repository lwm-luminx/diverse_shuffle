# frozen_string_literal: true

require_relative 'diverse_shuffle/version'
require_relative 'diverse_shuffle/rng'
require_relative 'diverse_shuffle/pool'
require_relative 'diverse_shuffle/ruby_engine'

# Songs in a random order where neighbouring songs aren't too alike: a seeded shuffle under hard rules (how far apart
# songs must be, how often the same attribute may come up in a window) with a soft score for how spread out the
# order is. Three modes:
#
# - :greedy takes, for each slot, the first song in shuffled order that passes every hard rule.
# - :mmr takes the best of the first few passing songs by soft score, with a little randomness.
# - :dpp picks spread-out sets of songs (a determinantal point process), then places each set with the greedy rules.
#
# When no song passes, the rules loosen a step at a time, so it never stalls. The same seed always gives the same
# order, from the Rust engine or the Ruby one.
#
# Everything lives under DiverseShuffle::Engine, so an app can keep its own DiverseShuffle namespace around it.
#
#   pool = DiverseShuffle::Engine::Pool.new(songs: [0, 1, 2, nil], tracks: 3, rules: [...])
#   DiverseShuffle::Engine.place(pool, seed: 'tuesday', mode: :mmr) # => [Placement, ...]
module DiverseShuffle
  # The shuffle: Engine.place, the pool and rules it places (Pool, VectorRule, MatchRule, Settings) and its two
  # engines, Native (Rust) and Ruby.
  module Engine
    class Error < StandardError; end

    MODES = %i[greedy mmr dpp].freeze

    begin
      require_relative "diverse_shuffle/#{RUBY_VERSION[/\d+\.\d+/]}/diverse_shuffle"
    rescue LoadError
      begin
        require_relative 'diverse_shuffle/diverse_shuffle'
      rescue LoadError
        nil # No native extension built for this platform: the Ruby engine places songs.
      end
    end

    # Whether the Rust engine is loaded.
    def self.native? = defined?(Native) ? true : false

    # :native or :ruby: the engine #place uses. DIVERSE_SHUFFLE_ENGINE=ruby picks Ruby even where Rust is built.
    def self.engine
      return :ruby if ENV['DIVERSE_SHUFFLE_ENGINE'] == 'ruby' || !native?

      :native
    end

    # Every song of the pool, placed: an Array of Placement in play order.
    def self.place(pool, seed:, mode: :greedy, settings: Settings.new, engine: self.engine)
      mode = mode.to_sym
      raise Error, "mode must be one of #{MODES.join(', ')}" unless MODES.include?(mode)

      case engine
      when :ruby then Ruby.new(pool, settings, seed.to_s).place(mode)
      when :native then native_place(pool, settings, seed.to_s, mode)
      else raise Error, "engine must be :native or :ruby, not #{engine.inspect}"
      end
    end

    def self.native_place(pool, settings, seed, mode)
      raise Error, 'the native engine is not built for this platform' unless native?

      rows = Native.place(pool.songs.map { it || -1 }, pool.tracks, pool.rules.map { native_rule(it) },
                          native_settings(settings), seed, MODES.index(mode))
      rows.map { |song, level, considered, rejected| Placement.new(song:, level:, considered:, rejected:) }
    end

    def self.native_rule(rule)
      if rule.vector?
        [0, rule.weight, rule.min_distance || Float::NAN, -1, -1, rule.pairs.map { |a, b, d| [a, b, Float(d)] }, []]
      else
        [1, rule.weight, Float::NAN, rule.max_same_in_window || -1, rule.min_gap || -1, [],
         rule.values]
      end
    end

    def self.native_settings(settings)
      [settings.window, settings.compare == :previous, settings.loosen_steps, settings.loosen_factor,
       settings.mmr_k, settings.mmr_jitter, settings.dpp_batch]
    end
    private_class_method :native_place, :native_rule, :native_settings
  end
end
