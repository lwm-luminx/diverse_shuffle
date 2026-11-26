//! DiverseShuffle::Engine::Native: the Rust engine behind DiverseShuffle::Engine.place (lib/diverse_shuffle.rb
//! marshals the pool into plain arrays for it).

mod engine;

pub use engine::{Engine, Mode, Placement, Rng, Rule, Settings};

#[cfg(feature = "ruby")]
mod ruby;
