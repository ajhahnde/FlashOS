//! Acceptance tests for the platform capability foundation.

use std::ffi::OsString;
use std::path::Path;

use flashshell_platform::{
    Capabilities, Capability, FakePlatform, Platform, PlatformError, ProcessStatus, SpawnError,
    SpawnRequest, SpawnRequestError,
};

#[test]
fn fake_platform_reports_its_scripted_capability_set() {
    let caps = Capabilities::empty()
        .with(Capability::ProcessSpawn)
        .with(Capability::Pipes);
    let platform = FakePlatform::new(caps);

    assert_eq!(platform.capabilities(), caps);
    assert!(platform.capabilities().supports(Capability::ProcessSpawn));
    assert!(platform.capabilities().supports(Capability::Pipes));
    assert!(
        !platform
            .capabilities()
            .supports(Capability::ForegroundTerminal)
    );
}

#[test]
fn require_accepts_a_supported_capability() {
    let platform = FakePlatform::new(Capabilities::empty().with(Capability::Environment));

    assert_eq!(platform.require(Capability::Environment), Ok(()));
}

#[test]
fn require_rejects_an_unsupported_capability_naming_it() {
    let platform = FakePlatform::new(Capabilities::empty());

    assert_eq!(
        platform.require(Capability::ProcessSpawn),
        Err(PlatformError::Unsupported {
            capability: Capability::ProcessSpawn,
        }),
    );
}

#[test]
fn full_supports_every_capability_and_empty_supports_none() {
    let full = FakePlatform::full();
    let none = FakePlatform::none();

    for capability in Capability::ALL {
        assert!(
            full.capabilities().supports(capability),
            "full is missing {capability:?}",
        );
        assert!(
            !none.capabilities().supports(capability),
            "empty unexpectedly has {capability:?}",
        );
    }
}

#[test]
fn capability_construction_is_additive_and_order_independent() {
    let a = Capabilities::empty()
        .with(Capability::Pipes)
        .with(Capability::ProcessSpawn);
    let b = Capabilities::empty()
        .with(Capability::ProcessSpawn)
        .with(Capability::Pipes);

    assert_eq!(a, b);
    // Adding a capability already present is idempotent.
    assert_eq!(a.with(Capability::Pipes), a);
}

#[test]
fn unavailable_carries_the_capability_and_a_reason() {
    let error = PlatformError::Unavailable {
        capability: Capability::MonotonicClock,
        reason: "clock source not yet started".to_string(),
    };

    match error {
        PlatformError::Unavailable { capability, reason } => {
            assert_eq!(capability, Capability::MonotonicClock);
            assert!(reason.contains("clock source"));
        }
        other => panic!("expected Unavailable, got {other:?}"),
    }
}

#[test]
fn spawn_requests_require_an_explicit_argv_zero() {
    let environment = [];
    let error = SpawnRequest::new(Path::new("/fixture"), &[], &environment, Path::new("/work"))
        .expect_err("an empty argv must be rejected");

    assert_eq!(error, SpawnRequestError::EmptyArgv);
}

#[test]
fn fake_spawn_is_host_free_and_returns_an_owned_waitable_child() {
    let platform = FakePlatform::full();
    let argv = [
        OsString::from("fixture"),
        OsString::from("literal argument"),
    ];
    let environment = [(OsString::from("FLASH"), OsString::from("shell"))];
    let request = SpawnRequest::new(
        Path::new("/does/not/need/to/exist"),
        &argv,
        &environment,
        Path::new("/also/not/read"),
    )
    .expect("the request is valid");

    let mut child = platform.spawn(&request).expect("the fake spawn succeeds");

    assert_eq!(child.id(), 0);
    assert_eq!(child.wait(), Ok(ProcessStatus::Exited(0)));
    assert_eq!(child.wait(), Ok(ProcessStatus::Exited(0)));
}

#[test]
fn spawn_rejects_an_absent_capability_before_host_access() {
    let platform = FakePlatform::none();
    let argv = [OsString::from("fixture")];
    let environment = [];
    let request = SpawnRequest::new(
        Path::new("/does/not/exist"),
        &argv,
        &environment,
        Path::new("/does/not/exist"),
    )
    .expect("the request is structurally valid");

    assert_eq!(
        platform
            .spawn(&request)
            .expect_err("spawn must be rejected"),
        SpawnError::Platform(PlatformError::Unsupported {
            capability: Capability::ProcessSpawn,
        }),
    );
}
