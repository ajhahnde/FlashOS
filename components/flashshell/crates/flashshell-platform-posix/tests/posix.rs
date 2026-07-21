//! Acceptance tests for the POSIX adapter's capability profile.

use flashshell_platform::{Capability, Platform};
use flashshell_platform_posix::PosixPlatform;

#[test]
fn posix_platform_supports_every_capability() {
    let platform = PosixPlatform;

    for capability in Capability::ALL {
        assert!(
            platform.capabilities().supports(capability),
            "POSIX adapter should support {capability:?}",
        );
        assert_eq!(platform.require(capability), Ok(()));
    }
}
