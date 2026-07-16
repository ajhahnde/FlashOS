//! Allocation-free timer-backed entropy fallback.
//!
//! Timer-derived bits are deliberately weak at boot. The module preserves the
//! existing fallback until a separately hardware-qualified RNG driver exists.

use core::cell::UnsafeCell;

const GAMMA: u64 = 0x9E37_79B9_7F4A_7C15;

/// SplitMix64 finalizer.
pub const fn splitmix64(value: u64) -> u64 {
    let mut mixed = value;
    mixed = (mixed ^ (mixed >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    mixed = (mixed ^ (mixed >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    mixed ^ (mixed >> 31)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Mixer {
    state: u64,
}

impl Mixer {
    pub const fn from_seed(seed: u64) -> Self {
        Self {
            state: splitmix64(seed),
        }
    }

    pub fn next(&mut self, entropy: u64) -> u64 {
        self.state = self.state.wrapping_add(GAMMA);
        self.state ^= entropy;
        splitmix64(self.state)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Source {
    Fallback,
}

struct GlobalMixer(UnsafeCell<Mixer>);

// SAFETY: bring-up initializes the mixer before PID 1. Runtime mutation occurs
// only in serialized syscall context on the single active core; IRQ code never
// accesses the mixer.
unsafe impl Sync for GlobalMixer {}

static MIXER: GlobalMixer = GlobalMixer(UnsafeCell::new(Mixer { state: 0 }));

fn fill_from(mixer: &mut Mixer, buffer: &mut [u8], mut counter: impl FnMut() -> u64) -> Source {
    let mut offset = 0usize;
    while offset < buffer.len() {
        let mut word = mixer.next(counter());
        let mut byte = 0usize;
        while byte < 8 && offset < buffer.len() {
            buffer[offset] = word as u8;
            word >>= 8;
            offset += 1;
            byte += 1;
        }
    }
    Source::Fallback
}

/// Initialize and self-test the global fallback generator.
///
/// # Safety
/// Called once during single-core bring-up before any runtime consumer.
pub unsafe fn initialize(mut counter: impl FnMut() -> u64) -> i32 {
    // SAFETY: the caller grants exclusive boot-time access to the mixer.
    let mixer = unsafe { &mut *MIXER.0.get() };
    *mixer = Mixer::from_seed(counter());

    let mut first = [0; 16];
    let mut second = [0; 16];
    fill_from(mixer, &mut first, &mut counter);
    fill_from(mixer, &mut second, &mut counter);
    if first == second {
        -1
    } else {
        0
    }
}

/// Fill caller-owned bytes from the global fallback generator.
///
/// # Safety
/// Called only from serialized syscall context after [`initialize`].
pub unsafe fn fill(buffer: &mut [u8], counter: impl FnMut() -> u64) -> Source {
    // SAFETY: the syscall contract grants exclusive access to the mixer.
    let mixer = unsafe { &mut *MIXER.0.get() };
    fill_from(mixer, buffer, counter)
}

#[cfg(test)]
mod tests {
    use core::sync::atomic::{AtomicU64, Ordering};

    use super::{fill, fill_from, initialize, splitmix64, Mixer, Source, GAMMA};

    #[test]
    fn splitmix64_matches_the_reference_sequence_from_seed_zero() {
        let expected = [
            0xE220_A839_7B1D_CDAF,
            0x6E78_9E6A_A1B9_65F4,
            0x06C4_5D18_8009_454F,
        ];
        let mut state = 0u64;
        for wanted in expected {
            state = state.wrapping_add(GAMMA);
            assert_eq!(splitmix64(state), wanted);
        }
    }

    #[test]
    fn splitmix64_matches_a_second_independent_expression() {
        fn reference(value: u64) -> u64 {
            let first = (value ^ (value >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            let second = (first ^ (first >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            second ^ (second >> 31)
        }

        let mut state = 0u64;
        for _ in 0..1_000 {
            state = state.wrapping_add(GAMMA);
            assert_eq!(splitmix64(state), reference(state));
        }
    }

    #[test]
    fn outputs_differ_even_with_a_stuck_entropy_input() {
        let mut mixer = Mixer::from_seed(0);
        let first = mixer.next(0xDEAD_BEEF);
        let second = mixer.next(0xDEAD_BEEF);
        let third = mixer.next(0xDEAD_BEEF);
        assert_ne!(first, second);
        assert_ne!(second, third);
        assert_ne!(first, third);
    }

    #[test]
    fn equal_seed_and_entropy_sequence_reproduces_the_stream() {
        let mut first = Mixer::from_seed(42);
        let mut second = Mixer::from_seed(42);
        for input in 0u64..100 {
            let entropy = input.wrapping_mul(7_919);
            assert_eq!(first.next(entropy), second.next(entropy));
        }
    }

    #[test]
    fn different_seeds_diverge() {
        let mut first = Mixer::from_seed(1);
        let mut second = Mixer::from_seed(2);
        let mut collisions = 0u32;
        for _ in 0..64 {
            collisions += u32::from(first.next(0) == second.next(0));
        }
        assert_eq!(collisions, 0);
    }

    #[test]
    fn fill_and_initialize_cover_an_odd_length_end_to_end() {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let counter = || COUNTER.fetch_add(1, Ordering::Relaxed);

        // SAFETY: this is the only test that accesses the global mixer.
        assert_eq!(unsafe { initialize(counter) }, 0);
        let mut first = [0; 23];
        let mut second = [0; 23];
        // SAFETY: initialization completed and this test serializes all access.
        assert_eq!(unsafe { fill(&mut first, counter) }, Source::Fallback);
        // SAFETY: same serialized global-mixer access.
        assert_eq!(unsafe { fill(&mut second, counter) }, Source::Fallback);
        assert_ne!(first, second);

        let mut local = Mixer::from_seed(9);
        let mut partial = [0; 9];
        assert_eq!(fill_from(&mut local, &mut partial, || 7), Source::Fallback);
        assert_ne!(partial, [0; 9]);
    }
}
