#![forbid(unsafe_code)]

//! Acceptance coverage for the closure-free terminal structured commands —
//! `first`, `last`, `collect`, and `length` — over a `ValueStream`. Each drains
//! (or bounded-drains) the stream and reshapes it: `first n` takes the leading
//! items without pulling the source more than `n` times, `last n` keeps the
//! trailing items, `collect` materializes a `List` value, and `length` counts.
//!
//! The layer is host-free and span-independent, matching `stream` and `convert`:
//! no process, terminal, or clock participates. Every terminal state a drain can
//! reach — exhaustion, a materialization bound, a producer failure, or a
//! cancellation — is a first-class `DrainOutcome` arm.

use std::cell::Cell;
use std::rc::Rc;

use flashshell_runtime::Value;
use flashshell_runtime::eval::{CancelReason, CancellationToken};
use flashshell_runtime::stream::ValueStream;
use flashshell_runtime::structured::{DrainOutcome, collect, first, last, length};

/// A stream of the given integer values.
fn ints(values: &[i64]) -> ValueStream {
    ValueStream::from_values(values.iter().copied().map(Value::Int).collect())
}

#[test]
fn first_takes_the_leading_items_without_overdraining() {
    // The source counts every pull. `first 3` must advance it exactly three times,
    // so an unbounded producer is safe.
    let pulls = Rc::new(Cell::new(0_i64));
    let stream = ValueStream::from_fn({
        let pulls = Rc::clone(&pulls);
        move || {
            let n = pulls.get();
            pulls.set(n + 1);
            Some(Ok(Value::Int(n)))
        }
    });
    match first(stream, 3) {
        DrainOutcome::Done(items) => {
            assert_eq!(items, vec![Value::Int(0), Value::Int(1), Value::Int(2)]);
        }
        other => panic!("expected the leading items, got {other:?}"),
    }
    assert_eq!(pulls.get(), 3, "source advanced exactly `count` times");
}

#[test]
fn first_stops_at_end_when_the_source_is_shorter_than_count() {
    match first(ints(&[1, 2]), 5) {
        DrainOutcome::Done(items) => assert_eq!(items, vec![Value::Int(1), Value::Int(2)]),
        other => panic!("expected the whole short stream, got {other:?}"),
    }
}

#[test]
fn first_propagates_cancellation() {
    let stream = ints(&[1, 2, 3]).with_cancellation(CancellationToken::from_fn(|| true));
    assert!(matches!(
        first(stream, 2),
        DrainOutcome::Cancelled(CancelReason::Requested)
    ));
}

#[test]
fn last_keeps_the_trailing_items() {
    match last(ints(&[1, 2, 3, 4, 5]), 2, 1000) {
        DrainOutcome::Done(items) => assert_eq!(items, vec![Value::Int(4), Value::Int(5)]),
        other => panic!("expected the trailing items, got {other:?}"),
    }
}

#[test]
fn last_keeps_the_whole_stream_when_count_exceeds_length() {
    match last(ints(&[1, 2]), 5, 1000) {
        DrainOutcome::Done(items) => assert_eq!(items, vec![Value::Int(1), Value::Int(2)]),
        other => panic!("expected the whole stream, got {other:?}"),
    }
}

#[test]
fn last_reports_limit_exceeded_on_an_oversized_stream() {
    // `last` must read the whole stream to find its tail, so an oversized stream
    // is refused rather than drained without bound.
    assert!(matches!(
        last(ints(&[1, 2, 3, 4]), 2, 3),
        DrainOutcome::LimitExceeded { limit: 3 }
    ));
}

#[test]
fn collect_materializes_a_list_value_within_the_limit() {
    match collect(ints(&[1, 2, 3]), 1000) {
        DrainOutcome::Done(Value::List(items)) => {
            assert_eq!(&*items, &[Value::Int(1), Value::Int(2), Value::Int(3)]);
        }
        other => panic!("expected a list value, got {other:?}"),
    }
}

#[test]
fn collect_reports_limit_exceeded() {
    assert!(matches!(
        collect(ints(&[1, 2, 3, 4]), 3),
        DrainOutcome::LimitExceeded { limit: 3 }
    ));
}

#[test]
fn collect_within_exactly_the_limit_succeeds() {
    match collect(ints(&[1, 2, 3]), 3) {
        DrainOutcome::Done(Value::List(items)) => assert_eq!(items.len(), 3),
        other => panic!("expected a list value at the bound, got {other:?}"),
    }
}

#[test]
fn length_counts_the_items() {
    match length(ints(&[1, 2, 3, 4]), 1000) {
        DrainOutcome::Done(Value::Int(count)) => assert_eq!(count, 4),
        other => panic!("expected an int count, got {other:?}"),
    }
}

#[test]
fn length_reports_limit_exceeded() {
    assert!(matches!(
        length(ints(&[1, 2, 3, 4]), 3),
        DrainOutcome::LimitExceeded { limit: 3 }
    ));
}

#[test]
fn collect_propagates_a_producer_failure() {
    let mut pulls = 0_i64;
    let stream = ValueStream::from_fn(move || {
        pulls += 1;
        match pulls {
            1 => Some(Ok(Value::Int(1))),
            2 => Some(Err(flashshell_runtime::eval::RuntimeError::new(
                flashshell_runtime::eval::RuntimeErrorKind::ExecutionUnsupported,
                {
                    let file = flashshell_syntax::SourceFile::new(
                        flashshell_syntax::SourceId::new(1),
                        "t",
                        "x",
                    );
                    file.span(0..1).unwrap()
                },
            ))),
            _ => None,
        }
    });
    assert!(matches!(collect(stream, 1000), DrainOutcome::Failed(_)));
}
