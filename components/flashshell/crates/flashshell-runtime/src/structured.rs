//! Closure-free terminal commands over a value stream.
//!
//! `first`, `last`, `collect`, and `length` are the reshaping and terminal
//! commands that consume a [`ValueStream`] without evaluating a closure. They are
//! the first real runtime users of the stream payload: `first n` takes the
//! leading items while pulling the source no more than `n` times (so an unbounded
//! producer is safe), `last n` keeps the trailing items, `collect` materializes a
//! `List` value, and `length` counts the items.
//!
//! Every terminal state a drain can reach is a first-class [`DrainOutcome`] arm,
//! so exhaustion, a materialization bound, a producer failure, and a cancellation
//! never fold into one another. `last`, `collect`, and `length` must read the
//! whole stream, so each takes a `limit` and refuses an oversized source rather
//! than draining without bound; `first` is bounded by its own `count` and needs
//! no limit.
//!
//! The layer is host-free and span-independent, matching [`crate::stream`] and
//! [`crate::convert`]: nothing here touches a process, terminal, or clock. The
//! closure-driven commands (`each`, `where`, …) and the record commands
//! (`select`, `get`, `update`, `sort`) build on this foundation in later work.

use std::collections::VecDeque;
use std::sync::Arc;

use crate::Value;
use crate::eval::{CancelReason, RuntimeError};
use crate::stream::{StreamPull, ValueStream};

/// The terminal outcome of draining a value stream, generic over the produced
/// result.
///
/// It mirrors [`crate::stream::StreamPull`] with a `Done` success arm and a
/// `LimitExceeded` bound arm, so a terminal drain reports every state it can
/// reach.
#[derive(Debug)]
pub enum DrainOutcome<T> {
    /// The drain finished within any bound; `T` is the produced result.
    Done(T),
    /// Reading the stream would have exceeded `limit` items; it is not drained
    /// further and nothing past the bound is materialized.
    LimitExceeded {
        /// The item bound that was reached.
        limit: usize,
    },
    /// The producer raised a runtime error mid-drain, carrying its own span.
    Failed(RuntimeError),
    /// The carried cancellation token tripped mid-drain.
    Cancelled(CancelReason),
}

/// `first n`: the leading `count` items.
///
/// The source is pulled at most `count` times, so a `first` of a small count over
/// an unbounded producer returns promptly. A shorter stream yields all of it.
#[must_use]
pub fn first(mut stream: ValueStream, count: usize) -> DrainOutcome<Vec<Value>> {
    let mut items = Vec::new();
    while items.len() < count {
        match stream.pull() {
            StreamPull::Item(value) => items.push(value),
            StreamPull::End => break,
            StreamPull::Failed(error) => return DrainOutcome::Failed(error),
            StreamPull::Cancelled(reason) => return DrainOutcome::Cancelled(reason),
        }
    }
    DrainOutcome::Done(items)
}

/// `last n`: the trailing `count` items.
///
/// Finding the tail requires reading the whole stream, so `limit` caps the total
/// items read; a stream longer than `limit` is refused. A ring buffer keeps only
/// the last `count` items, so memory is bounded by `count`, not by the stream.
#[must_use]
pub fn last(mut stream: ValueStream, count: usize, limit: usize) -> DrainOutcome<Vec<Value>> {
    let mut tail: VecDeque<Value> = VecDeque::new();
    let mut seen = 0;
    loop {
        match stream.pull() {
            StreamPull::Item(value) => {
                seen += 1;
                if seen > limit {
                    return DrainOutcome::LimitExceeded { limit };
                }
                if count > 0 {
                    if tail.len() == count {
                        tail.pop_front();
                    }
                    tail.push_back(value);
                }
            }
            StreamPull::End => return DrainOutcome::Done(tail.into()),
            StreamPull::Failed(error) => return DrainOutcome::Failed(error),
            StreamPull::Cancelled(reason) => return DrainOutcome::Cancelled(reason),
        }
    }
}

/// `collect`: the whole stream materialized as one `List` value.
///
/// Bounded by `limit`: a stream of more than `limit` items is refused rather than
/// materialized without bound. A stream of exactly `limit` items succeeds.
#[must_use]
pub fn collect(mut stream: ValueStream, limit: usize) -> DrainOutcome<Value> {
    let mut items: Vec<Value> = Vec::new();
    loop {
        match stream.pull() {
            StreamPull::Item(value) => {
                if items.len() == limit {
                    return DrainOutcome::LimitExceeded { limit };
                }
                items.push(value);
            }
            StreamPull::End => return DrainOutcome::Done(Value::List(Arc::from(items))),
            StreamPull::Failed(error) => return DrainOutcome::Failed(error),
            StreamPull::Cancelled(reason) => return DrainOutcome::Cancelled(reason),
        }
    }
}

/// `length`: the number of items as an `Int` value.
///
/// Counting requires reading the whole stream, so `limit` caps the total items
/// read; a stream longer than `limit` is refused.
#[must_use]
pub fn length(mut stream: ValueStream, limit: usize) -> DrainOutcome<Value> {
    let mut count = 0_i64;
    loop {
        match stream.pull() {
            StreamPull::Item(_) => {
                count += 1;
                if count as usize > limit {
                    return DrainOutcome::LimitExceeded { limit };
                }
            }
            StreamPull::End => return DrainOutcome::Done(Value::Int(count)),
            StreamPull::Failed(error) => return DrainOutcome::Failed(error),
            StreamPull::Cancelled(reason) => return DrainOutcome::Cancelled(reason),
        }
    }
}
