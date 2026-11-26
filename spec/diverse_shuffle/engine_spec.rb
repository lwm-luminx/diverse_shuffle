# frozen_string_literal: true

RSpec.describe DiverseShuffle::Engine do
  let(:engine) { described_class }

  def placements(pool, engine:, **options)
    described_class.place(pool, seed: options.fetch(:seed, 's'), mode: options.fetch(:mode, :greedy),
                                settings: options.fetch(:settings, DiverseShuffle::Engine::Settings.new), engine:)
  end

  it 'places every song exactly once, in every mode' do
    pool = PoolMaker.pool(Random.new(1))

    described_class::MODES.each do |mode|
      expect(placements(pool, engine: :ruby, mode:).map(&:song).sort).to eq((0...pool.size).to_a)
    end
  end

  it 'gives the same order for the same seed and another for another seed' do
    pool = PoolMaker.pool(Random.new(2))

    first = placements(pool, engine: :ruby, seed: 'a')

    expect(placements(pool, engine: :ruby, seed: 'a')).to eq(first)
    expect(placements(pool, engine: :ruby, seed: 'b')).not_to eq(first)
  end

  it 'keeps songs apart by distance before it loosens the rules' do
    pairs = [[0, 1, 0.1], [0, 2, 0.9], [1, 2, 0.9]]
    rule = described_class::VectorRule.new(weight: 1.0, min_distance: 0.5, pairs:)
    pool = described_class::Pool.new(songs: [0, 1, 2], tracks: 3, rules: [rule])
    settings = described_class::Settings.new(window: 1)

    order = placements(pool, engine: :ruby, settings:)

    expect(order.map(&:level)).to all(eq(0))
    expect(order.map(&:song).each_cons(2).map(&:sort)).not_to include([0, 1])
  end

  it 'loosens a step at a time when no song passes, and never stalls' do
    values = [[[1]], [[1]], [[1]]]
    rule = described_class::MatchRule.new(weight: 1.0, max_same_in_window: 1, values:)
    pool = described_class::Pool.new(songs: [0, 1, 2], tracks: 3, rules: [rule])

    expect(placements(pool, engine: :ruby).map(&:level)).to eq([0, 1, 2])
  end

  it 'refuses tracks out of range, uneven attributes and bad settings' do
    vector = described_class::VectorRule.new(weight: 1, pairs: [[0, 5, 0.1]])
    uneven = described_class::MatchRule.new(weight: 1, values: [[[1]], [[1], [2]]])

    expect { described_class::Pool.new(songs: [3], tracks: 2, rules: []) }.to raise_error(ArgumentError)
    expect { described_class::Pool.new(songs: [0], tracks: 2, rules: [vector]) }.to raise_error(ArgumentError)
    expect { described_class::Pool.new(songs: [0], tracks: 2, rules: [uneven]) }.to raise_error(ArgumentError)
    expect { described_class::Settings.new(dpp_batch: 0) }.to raise_error(ArgumentError)
    expect { described_class::Settings.new(compare: :sideways) }.to raise_error(ArgumentError)
    expect { described_class.place(described_class::Pool.new(songs: [], tracks: 0, rules: []), seed: 1, mode: :x) }
      .to raise_error(described_class::Error)
  end

  it 'uses Ruby when DIVERSE_SHUFFLE_ENGINE=ruby' do
    ENV['DIVERSE_SHUFFLE_ENGINE'] = 'ruby'
    expect(described_class.engine).to eq(:ruby)
  ensure
    ENV.delete('DIVERSE_SHUFFLE_ENGINE')
  end

  context 'with the Rust engine', if: described_class.native? do
    it 'places exactly as the Ruby engine does, over random pools, settings, modes and seeds' do
      random = Random.new(42)
      30.times do |round|
        pool = PoolMaker.pool(random, songs: random.rand(0..60), tracks: random.rand(1..30))
        compare = %i[window previous].sample(random:)
        settings = described_class::Settings.new(window: random.rand(0..5), compare:,
                                                 loosen_steps: random.rand(0..4), loosen_factor: random.rand,
                                                 mmr_k: random.rand(1..10), mmr_jitter: random.rand * 0.5,
                                                 dpp_batch: random.rand(1..10))
        described_class::MODES.each do |mode|
          options = { seed: "round #{round}", mode:, settings: }
          expect(placements(pool, engine: :native, **options)).to eq(placements(pool, engine: :ruby, **options)),
                                                                  "round #{round}, #{mode}"
        end
      end
    end

    it 'refuses a track out of range like the Ruby side does' do
      expect { DiverseShuffle::Engine::Native.place([5], 2, [], [3, false, 3, 0.75, 8, 0.15, 8], 's', 0) }
        .to raise_error(ArgumentError, /out of range/)
    end
  end
end
