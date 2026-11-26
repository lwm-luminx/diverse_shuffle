//! The engine in Rust: the same placements as the Ruby engine (lib/diverse_shuffle/ruby_engine.rb), bit for bit.
//! Every float is worked out in the same order as there, and every sum the Ruby engine takes with Array#sum is taken
//! here with the same Kahan-Babuska compensated sum.

/// Distance assumed when nothing is known, for the soft score.
const UNKNOWN: f64 = 0.5;

/// The seeded generator: SplitMix64, seeded by the 64-bit FNV-1a hash of the seed text.
pub struct Rng {
    state: u64,
}

impl Rng {
    pub fn new(seed: &[u8]) -> Self {
        let state = seed.iter().fold(0xcbf2_9ce4_8422_2325u64, |state, byte| {
            (state ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
        });
        Rng { state }
    }

    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// A float in [0, 1).
    pub fn float(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / 9_007_199_254_740_992.0
    }

    /// Fisher-Yates, from the last element down.
    pub fn shuffle<T: Copy>(&mut self, items: &[T]) -> Vec<T> {
        let mut result = items.to_vec();
        for i in (1..result.len()).rev() {
            let j = (self.next_u64() % (i as u64 + 1)) as usize;
            result.swap(i, j);
        }
        result
    }
}

/// Ruby's Array#sum over floats: Kahan-Babuska balancing compensated summation, starting from 0.
pub fn ruby_sum<I: IntoIterator<Item = f64>>(values: I) -> f64 {
    let mut f = 0.0f64;
    let mut c = 0.0f64;
    for x in values {
        if f.is_nan() {
            continue;
        }
        if x.is_nan() {
            f = x;
            continue;
        }
        if x.is_infinite() {
            f = if f.is_infinite() && x.is_sign_negative() != f.is_sign_negative() { f64::NAN } else { x };
            continue;
        }
        if f.is_infinite() {
            continue;
        }
        let t = f + x;
        if f.abs() >= x.abs() {
            c += (f - t) + x;
        } else {
            c += (x - t) + f;
        }
        f = t;
    }
    f + c
}

fn clamp01(value: f64) -> f64 {
    value.clamp(0.0, 1.0)
}

/// A rule as given: over measured vectors (distances between tracks) or over attributes (value ids per key).
pub enum RuleKind {
    /// Distances between tracks, track-major, None where unknown.
    Vector { matrix: Vec<Option<f64>> },
    /// Per track, one list of value ids per key, or None for a track with no attributes.
    Match { values: Vec<Option<Vec<Vec<i64>>>> },
}

pub struct Rule {
    pub weight: f64,
    pub min_distance: Option<f64>,
    pub max_same_in_window: Option<i64>,
    pub min_gap: Option<i64>,
    pub kind: RuleKind,
}

impl Rule {
    pub fn vector(weight: f64, min_distance: Option<f64>, tracks: usize, pairs: &[(usize, usize, f64)]) -> Self {
        let mut matrix = vec![None; tracks * tracks];
        for &(a, b, distance) in pairs {
            matrix[a * tracks + b] = Some(distance);
            matrix[b * tracks + a].get_or_insert(distance);
        }
        Rule { weight, min_distance, max_same_in_window: None, min_gap: None, kind: RuleKind::Vector { matrix } }
    }

    pub fn matching(
        weight: f64,
        max_same_in_window: Option<i64>,
        min_gap: Option<i64>,
        values: Vec<Option<Vec<Vec<i64>>>>,
    ) -> Self {
        Rule { weight, min_distance: None, max_same_in_window, min_gap, kind: RuleKind::Match { values } }
    }

    fn is_vector(&self) -> bool {
        matches!(self.kind, RuleKind::Vector { .. })
    }
}

/// A rule's hard limits at one loosening level.
#[derive(Clone, Copy)]
struct Limits {
    hard: bool,
    min_distance: Option<f64>,
    max_same_in_window: Option<i64>,
    min_gap: Option<i64>,
}

impl Limits {
    fn loosened(rule: &Rule, level: i64, factor: f64) -> Self {
        if rule.is_vector() {
            let min_distance = rule.min_distance.map(|d| if level == 0 { d } else { d * factor.powf(level as f64) });
            Limits { hard: min_distance.is_some(), min_distance, max_same_in_window: None, min_gap: None }
        } else {
            let hard = rule.max_same_in_window.is_some() || rule.min_gap.is_some();
            Limits {
                hard,
                min_distance: None,
                max_same_in_window: rule.max_same_in_window.map(|n| n + level),
                min_gap: rule.min_gap.map(|n| (n - level).max(0)),
            }
        }
    }
}

pub struct Settings {
    pub window: usize,
    pub compare_previous: bool,
    pub loosen_steps: usize,
    pub loosen_factor: f64,
    pub mmr_k: usize,
    pub mmr_jitter: f64,
    pub dpp_batch: usize,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Greedy,
    Mmr,
    Dpp,
}

/// Where one song went: its index, the loosening level it passed at, how many songs were looked at and how many of
/// those were ruled out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    pub song: usize,
    pub level: usize,
    pub considered: usize,
    pub rejected: usize,
}

const UNSET: u8 = 0;
const NO: u8 = 1;
const YES: u8 = 2;

pub struct Engine<'a> {
    settings: &'a Settings,
    rng: Rng,
    songs: &'a [Option<usize>],
    tracks: usize,
    rules: &'a [Rule],
    levels: Vec<Vec<Limits>>,
    /// Per attribute rule, per track: whether the track has the rule's attributes, every key with a value.
    attrs: Vec<Vec<bool>>,
    /// Per attribute rule, per pair of tracks: whether they are the same (UNSET until asked).
    same: Vec<Vec<u8>>,
}

impl<'a> Engine<'a> {
    pub fn new(
        songs: &'a [Option<usize>],
        tracks: usize,
        rules: &'a [Rule],
        settings: &'a Settings,
        seed: &[u8],
    ) -> Self {
        let levels = (0..=settings.loosen_steps)
            .map(|level| {
                rules.iter().map(|rule| Limits::loosened(rule, level as i64, settings.loosen_factor)).collect()
            })
            .collect();
        let attrs = rules
            .iter()
            .map(|rule| match &rule.kind {
                RuleKind::Vector { .. } => Vec::new(),
                RuleKind::Match { values } => values
                    .iter()
                    .map(|keys| keys.as_ref().is_some_and(|keys| keys.iter().all(|ids| !ids.is_empty())))
                    .collect(),
            })
            .collect();
        let same =
            rules.iter().map(|rule| if rule.is_vector() { Vec::new() } else { vec![UNSET; tracks * tracks] }).collect();
        Engine { settings, rng: Rng::new(seed), songs, tracks, rules, levels, attrs, same }
    }

    /// Placements for every song, in order.
    pub fn place(mut self, mode: Mode) -> Vec<Placement> {
        let all: Vec<usize> = (0..self.songs.len()).collect();
        let remaining = self.rng.shuffle(&all);
        let mut history = Vec::with_capacity(all.len());
        let mut placements = Vec::with_capacity(all.len());
        if mode == Mode::Dpp {
            self.batches(remaining, &mut history, &mut placements);
        } else {
            self.sequence(remaining, &mut history, mode, &mut placements);
        }
        placements
    }

    fn sequence(
        &mut self,
        mut remaining: Vec<usize>,
        history: &mut Vec<usize>,
        mode: Mode,
        placements: &mut Vec<Placement>,
    ) {
        while !remaining.is_empty() {
            let placement = self.place_one(&remaining, history, mode);
            let at = remaining.iter().position(|&song| song == placement.song).expect("placed song is remaining");
            remaining.remove(at);
            history.push(placement.song);
            placements.push(placement);
        }
    }

    fn place_one(&mut self, remaining: &[usize], history: &[usize], mode: Mode) -> Placement {
        for level in 0..=(self.settings.loosen_steps + 1) {
            let (passing, rejected) = self.candidates(remaining, history, level, mode);
            if passing.is_empty() {
                continue;
            }
            let considered = passing.len() + rejected;
            let song = self.pick(&passing, history, mode);
            return Placement { song, level, considered, rejected };
        }
        unreachable!("every song passes past the last loosening step")
    }

    fn window<'h>(&self, history: &'h [usize]) -> &'h [usize] {
        last(history, self.settings.window)
    }

    fn candidates(&mut self, remaining: &[usize], history: &[usize], level: usize, mode: Mode) -> (Vec<usize>, usize) {
        let limit = if mode == Mode::Mmr { self.settings.mmr_k } else { 1 };
        let mut passing = Vec::new();
        let mut rejected = 0;
        for &song in remaining {
            if level > self.settings.loosen_steps || self.passes(song, history, level) {
                passing.push(song);
            } else {
                rejected += 1;
            }
            if passing.len() >= limit {
                break;
            }
        }
        (passing, rejected)
    }

    fn pick(&mut self, passing: &[usize], history: &[usize], mode: Mode) -> usize {
        if mode != Mode::Mmr {
            return passing[0];
        }
        let window = self.window(history);
        let mut best = 0;
        let mut best_value = f64::NEG_INFINITY;
        for (index, &song) in passing.iter().enumerate() {
            let value = self.score(song, window) + (self.settings.mmr_jitter * self.rng.float());
            if index == 0 || value > best_value {
                best = song;
                best_value = value;
            }
        }
        best
    }

    fn passes(&mut self, song: usize, history: &[usize], level: usize) -> bool {
        let window = self.window(history);
        for index in 0..self.rules.len() {
            let limits = self.levels[level][index];
            if !limits.hard {
                continue;
            }
            let passed = if self.rules[index].is_vector() {
                self.distance_passes(index, limits, song, history, window)
            } else {
                self.match_passes(index, limits, song, history, window)
            };
            if !passed {
                return false;
            }
        }
        true
    }

    fn distance_passes(
        &mut self,
        index: usize,
        limits: Limits,
        song: usize,
        history: &[usize],
        window: &[usize],
    ) -> bool {
        let compared = if self.settings.compare_previous { last(history, 1) } else { window };
        let closest = compared.iter().filter_map(|&other| self.distance(index, song, other)).fold(None, min);
        match (closest, limits.min_distance) {
            (Some(closest), Some(min_distance)) => closest >= min_distance,
            _ => true,
        }
    }

    fn match_passes(&mut self, index: usize, limits: Limits, song: usize, history: &[usize], window: &[usize]) -> bool {
        if let Some(max_same) = limits.max_same_in_window {
            let same = window.iter().filter(|&&other| self.same(index, song, other)).count() as i64;
            if same >= max_same {
                return false;
            }
        }
        match limits.min_gap {
            None => true,
            Some(gap) => !last(history, gap.max(0) as usize).iter().any(|&other| self.same(index, song, other)),
        }
    }

    /// How far the song sits from the window before it, from 0 (alike) to 1, weighted per rule.
    fn score(&mut self, song: usize, window: &[usize]) -> f64 {
        if window.is_empty() {
            return 1.0;
        }
        let mut weighted = Vec::with_capacity(self.rules.len());
        for index in 0..self.rules.len() {
            let rule = &self.rules[index];
            if rule.weight == 0.0 {
                continue;
            }
            let weight = rule.weight;
            if let Some(distance) = self.window_distance(index, song, window) {
                weighted.push((weight, distance));
            }
        }
        blend(&weighted)
    }

    fn window_distance(&mut self, index: usize, song: usize, window: &[usize]) -> Option<f64> {
        if self.rules[index].is_vector() {
            window.iter().filter_map(|&other| self.distance(index, song, other)).fold(None, min).map(clamp01)
        } else if self.song_has_attrs(index, song) {
            Some(if window.iter().any(|&other| self.same(index, song, other)) { 0.0 } else { 1.0 })
        } else {
            None
        }
    }

    /// How far apart two songs are over every weighted rule (DPP's kernel).
    pub fn pair_distance(&mut self, first: usize, second: usize) -> f64 {
        let mut weighted = Vec::with_capacity(self.rules.len());
        for index in 0..self.rules.len() {
            let weight = self.rules[index].weight;
            if weight == 0.0 {
                continue;
            }
            if let Some(distance) = self.distance(index, first, second) {
                weighted.push((weight, distance));
            }
        }
        blend(&weighted)
    }

    fn song_has_attrs(&self, index: usize, song: usize) -> bool {
        self.songs[song].is_some_and(|track| self.attrs[index][track])
    }

    /// A rule's distance between two songs, 0 to 1, or None when unknown.
    fn distance(&mut self, index: usize, first: usize, second: usize) -> Option<f64> {
        match &self.rules[index].kind {
            RuleKind::Vector { matrix } => {
                let mine = self.songs[first]?;
                let theirs = self.songs[second]?;
                if mine == theirs {
                    return Some(0.0);
                }
                matrix[mine * self.tracks + theirs].map(clamp01)
            }
            RuleKind::Match { .. } => {
                if self.song_has_attrs(index, first) && self.song_has_attrs(index, second) {
                    Some(if self.same(index, first, second) { 0.0 } else { 1.0 })
                } else {
                    None
                }
            }
        }
    }

    /// Whether two songs share a value on every one of an attribute rule's keys.
    fn same(&mut self, index: usize, first: usize, second: usize) -> bool {
        let (Some(mine), Some(theirs)) = (self.songs[first], self.songs[second]) else {
            return false;
        };
        let slot = mine * self.tracks + theirs;
        match self.same[index][slot] {
            YES => return true,
            NO => return false,
            _ => {}
        }
        let answer = match &self.rules[index].kind {
            RuleKind::Match { values } => match (&values[mine], &values[theirs]) {
                (Some(a), Some(b)) => a.iter().zip(b.iter()).all(|(ids, other)| {
                    !ids.is_empty() && !other.is_empty() && ids.iter().any(|id| other.contains(id))
                }),
                _ => false,
            },
            RuleKind::Vector { .. } => false,
        };
        self.same[index][slot] = if answer { YES } else { NO };
        answer
    }

    fn batches(&mut self, mut remaining: Vec<usize>, history: &mut Vec<usize>, placements: &mut Vec<Placement>) {
        while !remaining.is_empty() {
            let size = self.settings.dpp_batch.min(remaining.len());
            let batch = self.dpp_pick(&remaining, size);
            remaining.retain(|song| !batch.contains(song));
            let order = self.rng.shuffle(&batch);
            self.sequence(order, history, Mode::Greedy, placements);
        }
    }

    /// Greedy MAP inference for a determinantal point process (Chen, Zhang & Zhou 2018, fast greedy with
    /// incremental Cholesky). Kernel L = q_i (1 - distance_ij) q_j, each song's quality a little random.
    fn dpp_pick(&mut self, pool: &[usize], size: usize) -> Vec<usize> {
        let jitter = self.settings.mmr_jitter;
        let quality: Vec<f64> = pool.iter().map(|_| 1.0 + (jitter * self.rng.float())).collect();
        let mut gains: Vec<f64> = quality.iter().map(|q| q * q).collect();
        let mut basis: Vec<Vec<f64>> = vec![Vec::new(); pool.len()];
        let mut taken = vec![false; pool.len()];
        let mut chosen = Vec::with_capacity(size);
        for _ in 0..size {
            let mut best: Option<usize> = None;
            for i in 0..pool.len() {
                if !taken[i] && best.is_none_or(|b| gains[i] > gains[b]) {
                    best = Some(i);
                }
            }
            let Some(best) = best else { break };
            if gains[best] <= 1e-9 {
                break;
            }
            chosen.push(best);
            taken[best] = true;
            let root = gains[best].sqrt();
            for i in 0..pool.len() {
                if taken[i] {
                    continue;
                }
                let kernel = quality[best] * quality[i] * (1.0 - self.pair_distance(pool[best], pool[i]));
                let dot = ruby_sum(basis[best].iter().zip(basis[i].iter()).map(|(a, b)| a * b));
                let e = (kernel - dot) / root;
                basis[i].push(e);
                gains[i] -= e * e;
            }
        }
        let mut picked: Vec<usize> = chosen.iter().map(|&i| pool[i]).collect();
        let fill: Vec<usize> =
            pool.iter().copied().filter(|song| !picked.contains(song)).take(size - picked.len()).collect();
        picked.extend(fill);
        picked
    }
}

fn blend(weighted: &[(f64, f64)]) -> f64 {
    if weighted.is_empty() {
        return UNKNOWN;
    }
    let total = ruby_sum(weighted.iter().map(|&(weight, _)| weight));
    if total == 0.0 {
        UNKNOWN
    } else {
        ruby_sum(weighted.iter().map(|&(weight, distance)| weight * distance)) / total
    }
}

/// The smaller of two, the first on a tie (Ruby's Array#min).
fn min(found: Option<f64>, value: f64) -> Option<f64> {
    match found {
        Some(current) if current <= value => Some(current),
        _ => Some(value),
    }
}

fn last(items: &[usize], count: usize) -> &[usize] {
    &items[items.len().saturating_sub(count)..]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draws_the_same_numbers_as_the_ruby_rng() {
        let mut rng = Rng::new(b"tuesday");
        // From DiverseShuffle::Engine::Rng.new('tuesday'): three next_u64 draws.
        let draws = [rng.next_u64(), rng.next_u64(), rng.next_u64()];
        assert_eq!(draws, [6_811_858_127_315_413_288, 90_594_298_792_728_333, 16_529_718_079_305_056_522]);
        assert_eq!(Rng::new(b"").next_u64(), 14_087_677_454_934_409_008);
    }

    #[test]
    fn sums_like_ruby() {
        assert_eq!(ruby_sum([0.1, 0.2, 0.3]), 0.6);
        assert_eq!(ruby_sum(std::iter::empty()), 0.0);
        assert_eq!(ruby_sum([3.0, 1e100, -1e100]), 3.0);
    }

    #[test]
    fn places_every_song_once() {
        let songs: Vec<Option<usize>> = (0..20).map(|i| if i % 7 == 0 { None } else { Some(i % 5) }).collect();
        let pairs: Vec<(usize, usize, f64)> =
            (0..5).flat_map(|a| (a + 1..5).map(move |b| (a, b, (a + b) as f64 / 10.0))).collect();
        let rules = vec![
            Rule::vector(1.0, Some(0.3), 5, &pairs),
            Rule::matching(0.5, Some(1), Some(2), (0..5).map(|t| Some(vec![vec![t as i64 % 2]])).collect()),
        ];
        let settings = Settings {
            window: 3,
            compare_previous: false,
            loosen_steps: 3,
            loosen_factor: 0.75,
            mmr_k: 8,
            mmr_jitter: 0.15,
            dpp_batch: 8,
        };
        for mode in [Mode::Greedy, Mode::Mmr, Mode::Dpp] {
            let placements = Engine::new(&songs, 5, &rules, &settings, b"seed").place(mode);
            let mut placed: Vec<usize> = placements.iter().map(|p| p.song).collect();
            placed.sort_unstable();
            assert_eq!(placed, (0..20).collect::<Vec<_>>());
        }
    }
}
