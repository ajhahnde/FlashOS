//! Acceptance tests for the POSIX adapter's capability profile and spawn seam.

use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::Read;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::symlink;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use flashshell_platform::{Capability, Platform, ProcessStatus, SpawnError, SpawnRequest};
use flashshell_platform_posix::{OwnedDescriptor, PosixPlatform};

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

#[test]
fn owned_descriptors_close_on_drop_and_clones_keep_the_resource_alive() {
    let (owned_end, mut peer) = UnixStream::pair().expect("socket pair should open");
    let descriptor = OwnedDescriptor::adopt(OwnedFd::from(owned_end))
        .expect("descriptor adoption should duplicate with close-on-exec");
    let clone = descriptor
        .try_clone()
        .expect("descriptor cloning should succeed");

    drop(descriptor);
    clone
        .as_fd()
        .try_clone_to_owned()
        .expect("the clone should still be open");
    drop(clone);

    let mut byte = [0_u8; 1];
    assert_eq!(peer.read(&mut byte).expect("peer read should succeed"), 0);
}

#[test]
fn posix_spawn_preserves_native_argv_and_never_invokes_a_shell() {
    let temp = TempDir::new("direct-argv");
    let report = temp.path().join("report.bin");
    let fixture = Path::new(env!("CARGO_BIN_EXE_flashshell-argv-probe-fixture"));
    symlink(fixture, temp.path().join("argv-probe")).expect("fixture symlink should be created");
    let argv = [
        OsString::from("deliberate-argv-zero"),
        OsString::from("two words"),
        OsString::from("$(must-not-run) ; *"),
        OsString::new(),
        OsString::from_vec(vec![b'n', b'a', 0x80, b't', b'i', b'v', b'e']),
    ];
    let environment = [
        (
            OsString::from("FLASH_PROBE_REPORT"),
            report.clone().into_os_string(),
        ),
        (
            OsString::from("FLASH_PROBE_VALUE"),
            OsString::from("exact value"),
        ),
    ];
    let request = SpawnRequest::new(Path::new("./argv-probe"), &argv, &environment, temp.path())
        .expect("the spawn request is valid");

    let mut child = PosixPlatform
        .spawn(&request)
        .expect("the fixture should spawn directly");

    assert!(child.id() > 0);
    assert_eq!(child.wait(), Ok(ProcessStatus::Exited(0)));
    assert_eq!(child.wait(), Ok(ProcessStatus::Exited(0)));

    let bytes = fs::read(&report).expect("the fixture should write its report");
    let child_cwd = fs::canonicalize(temp.path()).expect("temporary cwd should canonicalize");
    let expected = encode_report(
        &argv,
        &child_cwd,
        OsStr::new("exact value"),
        OsStr::new(""),
        false,
    );
    assert_eq!(bytes, expected);
}

#[test]
fn owned_descriptors_are_not_inherited_across_exec() {
    let temp = TempDir::new("close-on-exec");
    let report = temp.path().join("report.bin");
    let fixture = Path::new(env!("CARGO_BIN_EXE_flashshell-argv-probe-fixture"));
    let (owned_end, _peer) = UnixStream::pair().expect("socket pair should open");
    let descriptor = OwnedDescriptor::adopt(OwnedFd::from(owned_end))
        .expect("descriptor adoption should succeed");
    let descriptor_number = descriptor.as_fd().as_raw_fd();
    let argv = [OsString::from("probe")];
    let environment = [
        (
            OsString::from("FLASH_PROBE_REPORT"),
            report.clone().into_os_string(),
        ),
        (
            OsString::from("FLASH_PROBE_FD"),
            OsString::from(descriptor_number.to_string()),
        ),
    ];
    let request = SpawnRequest::new(fixture, &argv, &environment, temp.path())
        .expect("the spawn request is valid");

    let mut child = PosixPlatform
        .spawn(&request)
        .expect("the fixture should spawn");
    assert_eq!(child.wait(), Ok(ProcessStatus::Exited(0)));

    let bytes = fs::read(&report).expect("the fixture should write its report");
    let child_cwd = fs::canonicalize(temp.path()).expect("temporary cwd should canonicalize");
    assert_eq!(
        bytes,
        encode_report(&argv, &child_cwd, OsStr::new(""), OsStr::new(""), false,)
    );
    drop(descriptor);
}

#[test]
fn posix_spawn_surfaces_a_structured_host_error() {
    let temp = TempDir::new("spawn-error");
    let argv = [OsString::from("missing")];
    let environment = [];
    let request = SpawnRequest::new(
        Path::new("./definitely-missing"),
        &argv,
        &environment,
        temp.path(),
    )
    .expect("the spawn request is valid");

    let error = PosixPlatform
        .spawn(&request)
        .expect_err("the missing executable must not spawn");

    assert!(matches!(
        error,
        SpawnError::Operation {
            kind: std::io::ErrorKind::NotFound,
            ..
        }
    ));
}

fn encode_report(
    argv: &[OsString],
    cwd: &Path,
    value: &OsStr,
    path: &OsStr,
    fd_open: bool,
) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;

    let mut report = Vec::new();
    write_field(&mut report, cwd.as_os_str().as_bytes());
    write_field(&mut report, value.as_bytes());
    write_field(&mut report, path.as_bytes());
    report.push(u8::from(fd_open));
    report.extend_from_slice(&(argv.len() as u32).to_le_bytes());
    for argument in argv {
        write_field(&mut report, argument.as_os_str().as_bytes());
    }
    report
}

fn write_field(output: &mut Vec<u8>, value: &[u8]) {
    output.extend_from_slice(&(value.len() as u32).to_le_bytes());
    output.extend_from_slice(value);
}

struct TempDir {
    path: PathBuf,
}

impl TempDir {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let nonce = NEXT.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("flashshell-{label}-{}-{nonce}", std::process::id()));
        fs::create_dir(&path).expect("temporary directory should be created");
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.path).expect("temporary directory should be removed");
    }
}
