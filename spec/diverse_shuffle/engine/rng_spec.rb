# frozen_string_literal: true

RSpec.describe DiverseShuffle::Engine::Rng do
  it 'draws the same numbers for the same seed (and the Rust engine draws the same ones)' do
    rng = described_class.new('tuesday')

    expect(Array.new(3) { rng.next_u64 }).to eq([6_811_858_127_315_413_288, 90_594_298_792_728_333,
                                                 16_529_718_079_305_056_522])
    expect(described_class.new('').next_u64).to eq(14_087_677_454_934_409_008)
  end

  it 'draws floats in [0, 1) and shuffles without losing anything' do
    rng = described_class.new('x')

    expect(Array.new(1000) { rng.float }).to all(be >= 0.0).and all(be < 1.0)
    expect(rng.shuffle((1..50).to_a).sort).to eq((1..50).to_a)
  end
end
