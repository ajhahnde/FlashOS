#![forbid(unsafe_code)]

//! Platform-neutral capability contracts for FlashShell.
//!
//! Host adapters and the future FlashOS adapter implement [`Platform`] behind
//! this boundary. The engine never assumes a POSIX host: it asks a platform
//! which capabilities it supports and receives a precise [`PlatformError`] when
//! a capability is absent, rather than silently emulating unsafe behaviour.
//!
//! Platform calls are synchronous and blocking; concurrency (for example
//! draining a pipe while a child runs) is arranged by the caller with threads,
//! not by an async runtime. Byte-preserving data crosses the boundary as the
//! standard [`std::ffi::OsStr`] / [`std::path::Path`] family so native argv,
//! environment, and path bytes survive without lossy UTF-8 conversion.

use std::ffi::OsString;
use std::fmt;
use std::io;
use std::path::Path;

/// One platform capability group an adapter either supports or does not.
///
/// A platform that cannot honour a capability (for example a bare-metal target
/// without process groups) reports it as unsupported, and the runtime turns the
/// resulting [`PlatformError::Unsupported`] into a precise feature diagnostic.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Capability {
    /// Environment snapshot and per-child mutation.
    Environment,
    /// Working directory and path resolution.
    WorkingDirectory,
    /// File open, duplication, and close actions on child descriptors.
    FileActions,
    /// Anonymous pipe creation for pipeline plumbing.
    Pipes,
    /// Direct argv process spawn, exec, and wait.
    ProcessSpawn,
    /// Process-group creation and membership.
    ProcessGroups,
    /// Foreground terminal ownership handoff.
    ForegroundTerminal,
    /// Signal delivery and cancellation.
    Signals,
    /// Terminal size and TTY detection.
    TerminalInfo,
    /// A monotonic clock source.
    MonotonicClock,
    /// Home, config, and cache directory discovery.
    StandardDirectories,
}

impl Capability {
    /// Every capability, in declaration order.
    pub const ALL: [Capability; 11] = [
        Capability::Environment,
        Capability::WorkingDirectory,
        Capability::FileActions,
        Capability::Pipes,
        Capability::ProcessSpawn,
        Capability::ProcessGroups,
        Capability::ForegroundTerminal,
        Capability::Signals,
        Capability::TerminalInfo,
        Capability::MonotonicClock,
        Capability::StandardDirectories,
    ];

    /// The single set bit that represents this capability.
    const fn bit(self) -> u16 {
        1 << (self as u16)
    }
}

/// A set of supported [`Capability`] values.
///
/// Backed by a fixed-width bitset so it is `Copy`, allocation-free, and usable
/// in `const` contexts — the shape the future bare-metal FlashOS adapter needs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Capabilities {
    bits: u16,
}

impl Capabilities {
    /// The empty set — nothing supported.
    pub const fn empty() -> Self {
        Self { bits: 0 }
    }

    /// The full set — every capability supported.
    pub const fn full() -> Self {
        let mut bits = 0u16;
        let mut index = 0;
        while index < Capability::ALL.len() {
            bits |= Capability::ALL[index].bit();
            index += 1;
        }
        Self { bits }
    }

    /// This set with `capability` added; adding a present capability is a no-op.
    #[must_use]
    pub const fn with(self, capability: Capability) -> Self {
        Self {
            bits: self.bits | capability.bit(),
        }
    }

    /// Whether `capability` is in the set.
    pub const fn supports(self, capability: Capability) -> bool {
        self.bits & capability.bit() != 0
    }
}

/// A platform capability that failed to be satisfied.
///
/// [`Unsupported`](PlatformError::Unsupported) is a permanent gap: the platform
/// can never provide the capability, and the runtime reports a feature
/// diagnostic. [`Unavailable`](PlatformError::Unavailable) is transient: the
/// capability exists in principle but cannot be used right now (for example a
/// clock source that has not started), and carries a human-readable reason.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlatformError {
    /// The platform does not provide `capability` at all.
    Unsupported {
        /// The capability that is permanently absent.
        capability: Capability,
    },
    /// The platform provides `capability` but it cannot be used right now.
    Unavailable {
        /// The capability that is temporarily unusable.
        capability: Capability,
        /// A human-readable reason the capability is unavailable.
        reason: String,
    },
}

impl fmt::Display for PlatformError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlatformError::Unsupported { capability } => {
                write!(
                    formatter,
                    "platform capability {capability:?} is not supported"
                )
            }
            PlatformError::Unavailable { capability, reason } => write!(
                formatter,
                "platform capability {capability:?} is unavailable: {reason}",
            ),
        }
    }
}

impl std::error::Error for PlatformError {}

/// A structurally valid request to execute one program directly with argv.
///
/// The first argv entry is explicit rather than inferred from `executable`.
/// Environment entries describe the complete child environment, not a delta;
/// adapters clear their inherited environment before installing these entries.
#[derive(Clone, Copy, Debug)]
pub struct SpawnRequest<'a> {
    executable: &'a Path,
    argv: &'a [OsString],
    environment: &'a [(OsString, OsString)],
    cwd: &'a Path,
}

impl<'a> SpawnRequest<'a> {
    /// Build a direct-spawn request, rejecting an absent argv zero.
    pub fn new(
        executable: &'a Path,
        argv: &'a [OsString],
        environment: &'a [(OsString, OsString)],
        cwd: &'a Path,
    ) -> Result<Self, SpawnRequestError> {
        if argv.is_empty() {
            return Err(SpawnRequestError::EmptyArgv);
        }

        Ok(Self {
            executable,
            argv,
            environment,
            cwd,
        })
    }

    /// The resolved executable path passed directly to the host.
    pub const fn executable(self) -> &'a Path {
        self.executable
    }

    /// The complete native argv, including explicit argv zero.
    pub const fn argv(self) -> &'a [OsString] {
        self.argv
    }

    /// The complete native child environment.
    pub const fn environment(self) -> &'a [(OsString, OsString)] {
        self.environment
    }

    /// The child's working directory.
    pub const fn cwd(self) -> &'a Path {
        self.cwd
    }
}

/// A spawn request that cannot represent a process invocation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpawnRequestError {
    /// Direct process execution requires an explicit argv zero.
    EmptyArgv,
}

impl fmt::Display for SpawnRequestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyArgv => formatter.write_str("a spawn request requires argv zero"),
        }
    }
}

impl std::error::Error for SpawnRequestError {}

/// A direct process spawn failure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SpawnError {
    /// The platform cannot satisfy the process-spawn capability.
    Platform(PlatformError),
    /// The host rejected or could not complete the spawn operation.
    Operation {
        /// Stable I/O error category from the host adapter.
        kind: io::ErrorKind,
        /// Human-readable host error text.
        message: String,
    },
}

impl fmt::Display for SpawnError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Platform(error) => error.fmt(formatter),
            Self::Operation { message, .. } => write!(formatter, "process spawn failed: {message}"),
        }
    }
}

impl std::error::Error for SpawnError {}

impl From<PlatformError> for SpawnError {
    fn from(error: PlatformError) -> Self {
        Self::Platform(error)
    }
}

/// The low-level completion state of one child process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProcessStatus {
    /// The process called an exit path with this code.
    Exited(i32),
    /// The process was terminated by this platform signal number.
    Signaled(i32),
}

/// Failure while waiting for an already-spawned child.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WaitError {
    kind: io::ErrorKind,
    message: String,
}

impl WaitError {
    /// Build a wait error from a host I/O failure.
    pub fn new(kind: io::ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    /// Stable I/O error category from the host adapter.
    pub const fn kind(&self) -> io::ErrorKind {
        self.kind
    }
}

impl fmt::Display for WaitError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "process wait failed: {}", self.message)
    }
}

impl std::error::Error for WaitError {}

/// One owned child process returned by a platform adapter.
pub trait ChildProcess: Send + fmt::Debug {
    /// Adapter-native process identifier, widened for a portable boundary.
    fn id(&self) -> u64;

    /// Block until the child completes and return its low-level status.
    ///
    /// Calling this more than once returns the same completed status.
    fn wait(&mut self) -> Result<ProcessStatus, WaitError>;
}

/// Implemented by FlashShell platform adapters.
///
/// Capability methods (spawn, pipes, file actions, …) are added to this trait
/// as the features that need them are built; the foundation is the capability
/// query plus the [`require`](Platform::require) guard every capability method
/// calls before touching the host.
pub trait Platform: Send + Sync {
    /// The capabilities this platform supports.
    fn capabilities(&self) -> Capabilities;

    /// Return `Ok(())` when `capability` is supported, else
    /// [`PlatformError::Unsupported`] naming it.
    fn require(&self, capability: Capability) -> Result<(), PlatformError> {
        if self.capabilities().supports(capability) {
            Ok(())
        } else {
            Err(PlatformError::Unsupported { capability })
        }
    }

    /// Execute `request.executable` directly with its explicit native argv.
    fn spawn(&self, request: &SpawnRequest<'_>) -> Result<Box<dyn ChildProcess>, SpawnError>;
}

/// A deterministic in-process [`Platform`] for tests.
///
/// It performs no real host access; its capability set is scripted at
/// construction so runtime tests can drive both the supported and the
/// unsupported branches without a filesystem, process, or clock.
#[derive(Clone, Copy, Debug)]
pub struct FakePlatform {
    capabilities: Capabilities,
}

impl FakePlatform {
    /// A fake platform supporting exactly `capabilities`.
    pub const fn new(capabilities: Capabilities) -> Self {
        Self { capabilities }
    }

    /// A fake platform supporting every capability.
    pub const fn full() -> Self {
        Self::new(Capabilities::full())
    }

    /// A fake platform supporting no capability.
    pub const fn none() -> Self {
        Self::new(Capabilities::empty())
    }
}

impl Platform for FakePlatform {
    fn capabilities(&self) -> Capabilities {
        self.capabilities
    }

    fn spawn(&self, _request: &SpawnRequest<'_>) -> Result<Box<dyn ChildProcess>, SpawnError> {
        self.require(Capability::ProcessSpawn)?;
        Ok(Box::new(FakeChild))
    }
}

/// Deterministic host-free child returned by [`FakePlatform`].
#[derive(Clone, Copy, Debug, Default)]
pub struct FakeChild;

impl ChildProcess for FakeChild {
    fn id(&self) -> u64 {
        0
    }

    fn wait(&mut self) -> Result<ProcessStatus, WaitError> {
        Ok(ProcessStatus::Exited(0))
    }
}
