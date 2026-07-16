//! ARM generic-timer cadence and uptime accounting.
//!
//! The assembly layer owns the architectural register access. This module owns
//! only the deadline state and arithmetic, which keeps the policy host-testable.

use core::cell::UnsafeCell;

const TICK_PERIOD: u64 = 54_000_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Deadline {
    next: u64,
}

impl Deadline {
    const fn new() -> Self {
        Self { next: 0 }
    }

    fn initialize(&mut self, now: u64) -> u64 {
        self.next = now.wrapping_add(TICK_PERIOD);
        self.next
    }

    fn increment(&mut self) {
        self.next = self.next.wrapping_add(TICK_PERIOD);
    }

    fn rebase_if_late(&mut self, now: u64) -> u64 {
        // Interpreting the wrapping delta as signed matches the architectural
        // timer comparison window. A deadline at or behind `now` is rebased so
        // a late handler cannot cause an immediate interrupt burst.
        if self.next.wrapping_sub(now) as i64 <= 0 {
            self.next = now.wrapping_add(TICK_PERIOD);
        }
        self.next
    }
}

struct GlobalDeadline(UnsafeCell<Deadline>);

// SAFETY: FlashOS currently runs one active kernel core. Initialization occurs
// before IRQ enable; afterwards only the serialized timer IRQ mutates the cell.
unsafe impl Sync for GlobalDeadline {}

static DEADLINE: GlobalDeadline = GlobalDeadline(UnsafeCell::new(Deadline::new()));

/// Initialize the absolute timer deadline from the current architectural count.
///
/// # Safety
/// Called once during single-core bring-up before the timer IRQ can run.
pub unsafe fn initialize(mut counter: impl FnMut() -> u64) -> u64 {
    // SAFETY: the caller provides exclusive boot-time access to the cell.
    unsafe { (&mut *DEADLINE.0.get()).initialize(counter()) }
}

/// Advance the absolute timer deadline after one timer interrupt.
///
/// # Safety
/// Called only from the serialized timer IRQ on the active kernel core.
pub unsafe fn advance(mut counter: impl FnMut() -> u64) -> u64 {
    // SAFETY: the IRQ contract provides exclusive access to the cell.
    let deadline = unsafe { &mut *DEADLINE.0.get() };
    // Preserve the hardware path's order: advance the absolute deadline first,
    // then sample the counter to decide whether the handler arrived late.
    deadline.increment();
    deadline.rebase_if_late(counter())
}

/// Convert an architectural counter value to whole seconds since boot.
pub const fn uptime_seconds(count: u64, frequency: u64) -> u64 {
    if frequency == 0 {
        return 0;
    }
    count / frequency
}

#[cfg(test)]
mod tests {
    use super::{uptime_seconds, Deadline, TICK_PERIOD};

    #[test]
    fn uptime_uses_the_runtime_frequency() {
        assert_eq!(uptime_seconds(50_000_000, 10_000_000), 5);
        assert_eq!(uptime_seconds(59_999_999, 10_000_000), 5);
    }

    #[test]
    fn zero_frequency_reports_zero_instead_of_dividing() {
        assert_eq!(uptime_seconds(u64::MAX, 0), 0);
    }

    #[test]
    fn initialization_arms_one_absolute_period_ahead() {
        let mut deadline = Deadline::new();
        assert_eq!(deadline.initialize(123), 123 + TICK_PERIOD);
    }

    #[test]
    fn initialization_wraps_like_the_architectural_counter() {
        let mut deadline = Deadline::new();
        let now = u64::MAX - TICK_PERIOD + 7;
        assert_eq!(deadline.initialize(now), 6);
    }

    #[test]
    fn an_on_time_handler_advances_from_the_previous_deadline() {
        let mut deadline = Deadline::new();
        let first = deadline.initialize(1_000);
        deadline.increment();
        assert_eq!(deadline.rebase_if_late(first - 1), first + TICK_PERIOD);
    }

    #[test]
    fn a_late_or_exact_handler_rebases_from_now() {
        let mut late = Deadline::new();
        let first = late.initialize(1_000);
        let now = first + TICK_PERIOD + 9;
        late.increment();
        assert_eq!(late.rebase_if_late(now), now + TICK_PERIOD);

        let mut exact = Deadline::new();
        let first = exact.initialize(1_000);
        let next = first + TICK_PERIOD;
        exact.increment();
        assert_eq!(exact.rebase_if_late(next), next + TICK_PERIOD);
    }
}
