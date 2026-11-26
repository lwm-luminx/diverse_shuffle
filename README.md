# diverse_shuffle

A seeded shuffle where neighbouring songs aren't too alike. You give it songs, how far apart pairs of tracks are
(cosine distances from your vector store, say) and which attributes they share (voice, era, show), plus hard rules
over those: how far a song must be from the songs just before it, how many of the window may share an attribute,
how many songs must pass before an attribute comes back. It places every song, in an order that's the same for the
same seed.

The work runs in Rust (a native extension, precompiled for Linux and macOS on x86_64 and ARM). Where it isn't built,
a pure-Ruby engine places the songs instead, with exactly the same result: the specs hold the two engines to each
other on random pools, mode by mode, and every float is worked out in the same order on both sides.

On a 500-song pool with six rules, the Rust engine places every song in about 40 to 55 ms; the Ruby engine takes
about 1.1 s.

## Install

```ruby
gem 'diverse_shuffle'
```

## Use

```ruby
require 'diverse_shuffle'
E = DiverseShuffle::Engine

# Three tracks; four songs (two play the same track, one is a song nothing is known about).
sound = E::VectorRule.new(weight: 1.0, min_distance: 0.25, pairs: [[0, 1, 0.42], [0, 2, 0.07], [1, 2, 0.6]])
# Per track, one list of value ids per key (here one key, the show), or nil for a track with no attributes.
show = E::MatchRule.new(weight: 0.5, min_gap: 2, values: [[[7]], [[7]], [[3]]])
pool = E::Pool.new(songs: [0, 1, 2, nil], tracks: 3, rules: [sound, show])

E.place(pool, seed: 'tuesday', mode: :mmr)
# => [#<data DiverseShuffle::Engine::Placement song=1, level=0, considered=4, rejected=0>, ...]
```

`song` is an index into `pool.songs`; `level` is how far the rules had to loosen for the song to pass (0 when they
didn't); `considered` and `rejected` say how many songs were looked at for the slot and how many were ruled out.

### Modes

- `:greedy` takes, for each slot, the first song in shuffled order that passes every hard rule.
- `:mmr` takes the best of the first `mmr_k` passing songs by soft score (how far the song sits from the window
  before it, weighted per rule), plus up to `mmr_jitter` of randomness.
- `:dpp` picks spread-out sets of `dpp_batch` songs (greedy MAP inference for a determinantal point process, with
  incremental Cholesky), then places each set with the greedy rules.

### Rules

- `VectorRule.new(weight:, pairs:, min_distance: nil)`: `pairs` are `[track, track, distance]`. A song must be at
  least `min_distance` from the songs it's compared with. A pair with no distance is unknown and never rules a song
  out.
- `MatchRule.new(weight:, values:, max_same_in_window: nil, min_gap: nil)`: two songs are the same when they share a
  value on every key. Fewer than `max_same_in_window` songs of the window may be the same, and none of the last
  `min_gap`.

### Settings

`E::Settings.new(window: 3, compare: :window, loosen_steps: 3, loosen_factor: 0.75, mmr_k: 8, mmr_jitter: 0.15,
dpp_batch: 8)`, passed as `settings:`.

- `window`: how many songs back the hard rules and the soft score look.
- `compare`: `:window` compares distances against every song in the window, `:previous` against the one before
  only.
- `loosen_steps`, `loosen_factor`: when no song passes, the rules loosen a step at a time (distances times
  `loosen_factor` per step, one more same song allowed in the window, the gap one shorter); past the last step every
  song passes, so it never stalls.

### Engines

`DiverseShuffle::Engine.engine` says which engine `place` uses: `:native` where the extension is loaded, else
`:ruby`. Set `DIVERSE_SHUFFLE_ENGINE=ruby` to use Ruby anyway, or pass `engine: :ruby`.

## Develop

```sh
bundle install
bundle exec rake compile   # builds the Rust extension (needs a Rust toolchain)
bundle exec rspec          # specs, including the Rust engine against the Ruby one
cargo test --manifest-path ext/diverse_shuffle/Cargo.toml --no-default-features
```

## Release

Bump `DiverseShuffle::Engine::VERSION`, add a CHANGELOG entry, merge to main and run the Release workflow (or push
a `vX.Y.Z` tag). It builds the platform gems and the source gem and publishes them with RubyGems trusted publishing.

## License

MIT. Made by Love Wins Media, Inc.
