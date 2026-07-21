#![deny(unsafe_code)]

//! POSIX platform adapter for FlashShell.
//!
//! macOS and Linux provide every FlashShell platform capability. The concrete
//! descriptor and direct-spawn primitives are implemented here; pipeline,
//! redirection, process-group, and terminal behavior is built out as the
//! features that need it land. The adapter reports the full capability set so
//! the runtime resolves internal-vs-external and plan preflight against a
//! truthful host profile.

use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command};

use flashshell_platform::{
    Capabilities, Capability, ChildProcess, Platform, ProcessStatus, SpawnError, SpawnRequest,
    WaitError,
};

/// A uniquely owned POSIX descriptor with close-on-exec discipline.
///
/// The wrapper is intentionally not `Clone`: another owner requires the
/// fallible [`try_clone`](OwnedDescriptor::try_clone) operation. Normal release
/// happens only through `Drop` or an explicit transfer back into [`OwnedFd`].
#[derive(Debug)]
pub struct OwnedDescriptor {
    descriptor: OwnedFd,
}

impl OwnedDescriptor {
    /// Take ownership and atomically duplicate the descriptor with close-on-exec.
    ///
    /// The supplied owner is released whether duplication succeeds or fails.
    pub fn adopt(descriptor: OwnedFd) -> io::Result<Self> {
        let cloexec_descriptor = descriptor.try_clone()?;
        Ok(Self {
            descriptor: cloexec_descriptor,
        })
    }

    /// Create another close-on-exec owner of the same open file description.
    pub fn try_clone(&self) -> io::Result<Self> {
        self.descriptor
            .try_clone()
            .map(|descriptor| Self { descriptor })
    }

    /// Borrow the descriptor without transferring ownership.
    pub fn as_fd(&self) -> BorrowedFd<'_> {
        self.descriptor.as_fd()
    }

    /// Transfer ownership to a standard-library descriptor owner.
    pub fn into_owned_fd(self) -> OwnedFd {
        self.descriptor
    }
}

/// POSIX adapter for process and terminal capabilities.
#[derive(Debug, Default, Clone, Copy)]
pub struct PosixPlatform;

/// Owned POSIX child process handle.
#[derive(Debug)]
pub struct PosixChild {
    child: Child,
    completed: Option<ProcessStatus>,
}

impl ChildProcess for PosixChild {
    fn id(&self) -> u64 {
        u64::from(self.child.id())
    }

    fn wait(&mut self) -> Result<ProcessStatus, WaitError> {
        if let Some(status) = self.completed {
            return Ok(status);
        }

        let status = self
            .child
            .wait()
            .map_err(|error| WaitError::new(error.kind(), error.to_string()))?;
        let status = status
            .code()
            .map(ProcessStatus::Exited)
            .or_else(|| status.signal().map(ProcessStatus::Signaled))
            .expect("POSIX exit status has either a code or a signal");
        self.completed = Some(status);
        Ok(status)
    }
}

impl Platform for PosixPlatform {
    fn capabilities(&self) -> Capabilities {
        Capabilities::full()
    }

    fn spawn(&self, request: &SpawnRequest<'_>) -> Result<Box<dyn ChildProcess>, SpawnError> {
        self.require(Capability::ProcessSpawn)?;

        let cwd = std::path::absolute(request.cwd()).map_err(spawn_error)?;
        let executable = if request.executable().is_relative() {
            cwd.join(request.executable())
        } else {
            request.executable().to_owned()
        };
        let mut command = Command::new(executable);
        command
            .arg0(&request.argv()[0])
            .args(&request.argv()[1..])
            .env_clear()
            .envs(
                request
                    .environment()
                    .iter()
                    .map(|(name, value)| (name, value)),
            )
            .current_dir(cwd);

        command
            .spawn()
            .map(|child| {
                Box::new(PosixChild {
                    child,
                    completed: None,
                }) as Box<dyn ChildProcess>
            })
            .map_err(spawn_error)
    }
}

fn spawn_error(error: io::Error) -> SpawnError {
    SpawnError::Operation {
        kind: error.kind(),
        message: error.to_string(),
    }
}
