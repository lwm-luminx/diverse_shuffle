//! The Ruby glue: DiverseShuffle::Engine::Native.place.

use crate::engine::{Engine, Mode, Rule, Settings};
use magnus::{function, prelude::*, Error, RArray, RString, Ruby};

type Pairs = Vec<(i64, i64, f64)>;
type Values = Vec<Option<Vec<Vec<i64>>>>;
/// [kind (0 vector, 1 match), weight, min_distance (NaN for none), max_same_in_window (-1), min_gap (-1), pairs, values]
type RuleRow = (i64, f64, f64, i64, i64, Pairs, Values);
/// [window, compare previous?, loosen_steps, loosen_factor, mmr_k, mmr_jitter, dpp_batch]
type SettingsRow = (usize, bool, usize, f64, usize, f64, usize);

fn argument_error(ruby: &Ruby, message: impl Into<String>) -> Error {
    Error::new(ruby.exception_arg_error(), message.into())
}

fn track(ruby: &Ruby, index: i64, tracks: usize) -> Result<usize, Error> {
    usize::try_from(index)
        .ok()
        .filter(|&index| index < tracks)
        .ok_or_else(|| argument_error(ruby, format!("track {index} out of range")))
}

fn rule(ruby: &Ruby, row: RuleRow, tracks: usize) -> Result<Rule, Error> {
    let (kind, weight, min_distance, max_same, min_gap, pairs, values) = row;
    let optional = |value: i64| (value >= 0).then_some(value);
    if kind == 0 {
        let pairs = pairs
            .into_iter()
            .map(|(a, b, distance)| Ok((track(ruby, a, tracks)?, track(ruby, b, tracks)?, distance)))
            .collect::<Result<Vec<_>, Error>>()?;
        let min_distance = (!min_distance.is_nan()).then_some(min_distance);
        Ok(Rule::vector(weight, min_distance, tracks, &pairs))
    } else {
        if values.len() != tracks {
            return Err(argument_error(ruby, "a MatchRule needs values for every track"));
        }
        Ok(Rule::matching(weight, optional(max_same), optional(min_gap), values))
    }
}

fn place(
    ruby: &Ruby,
    songs: Vec<i64>,
    tracks: usize,
    rules: RArray,
    settings: SettingsRow,
    seed: RString,
    mode: usize,
) -> Result<Vec<(usize, usize, usize, usize)>, Error> {
    let songs = songs
        .into_iter()
        .map(|index| if index < 0 { Ok(None) } else { track(ruby, index, tracks).map(Some) })
        .collect::<Result<Vec<_>, Error>>()?;
    let rules = rules
        .into_iter()
        .map(|row| rule(ruby, RuleRow::try_convert(row)?, tracks))
        .collect::<Result<Vec<_>, Error>>()?;
    let (window, compare_previous, loosen_steps, loosen_factor, mmr_k, mmr_jitter, dpp_batch) = settings;
    let settings = Settings { window, compare_previous, loosen_steps, loosen_factor, mmr_k, mmr_jitter, dpp_batch };
    let mode = match mode {
        0 => Mode::Greedy,
        1 => Mode::Mmr,
        2 => Mode::Dpp,
        _ => return Err(argument_error(ruby, "mode must be 0, 1 or 2")),
    };
    // SAFETY: the seed's bytes are copied before any Ruby code can run again.
    let seed = unsafe { seed.as_slice() }.to_vec();
    let placements = Engine::new(&songs, tracks, &rules, &settings, &seed).place(mode);
    Ok(placements.into_iter().map(|p| (p.song, p.level, p.considered, p.rejected)).collect())
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let engine = ruby.define_module("DiverseShuffle")?.define_module("Engine")?;
    let native = engine.define_module("Native")?;
    native.define_module_function("place", function!(place, 6))?;
    Ok(())
}
