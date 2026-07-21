//! Foreground execution of inspectable command plans.
//!
//! The initial executor handles exactly one external stage with inherited
//! standard descriptors. It always runs platform-independent preflight before
//! touching the platform, then passes the plan's native argv, exact environment,
//! and cwd to the direct-spawn capability without rendering shell source.

use std::ffi::OsString;

use flashshell_platform::{Platform, ProcessStatus, SpawnRequest};

use crate::eval::{RuntimeError, RuntimeErrorKind};
use crate::plan::{ExecutionPlan, PlannedResolution, preflight};

/// Execute one external foreground stage with inherited standard descriptors.
///
/// A nonzero exit or signal termination is a normal [`ProcessStatus`]. Spawn
/// and wait failures are source-anchored runtime errors. Multi-stage pipelines,
/// internal commands, and redirections remain explicit unsupported errors until
/// their execution support is added.
pub fn execute_foreground(
    plan: &ExecutionPlan,
    platform: &dyn Platform,
) -> Result<ProcessStatus, RuntimeError> {
    preflight(plan)?;

    let [stage] = plan.stages() else {
        return Err(RuntimeError::new(
            RuntimeErrorKind::Unsupported {
                feature: "a foreground pipeline with more than one stage",
            },
            plan.span(),
        ));
    };

    if let Some(redirection) = stage.redirections().first() {
        return Err(RuntimeError::new(
            RuntimeErrorKind::Unsupported {
                feature: "foreground redirection",
            },
            redirection.span(),
        ));
    }

    let PlannedResolution::External { path } = stage.resolution() else {
        return Err(RuntimeError::new(
            RuntimeErrorKind::Unsupported {
                feature: "foreground internal-command execution",
            },
            stage.span(),
        ));
    };

    let argv: Vec<OsString> = stage
        .argv()
        .iter()
        .map(|argument| argument.value().to_os_string())
        .collect();
    let environment: Vec<(OsString, OsString)> = plan
        .environment()
        .iter()
        .map(|(name, value)| (OsString::from(name), value.to_os_string()))
        .collect();
    let request = SpawnRequest::new(path, &argv, &environment, plan.cwd())
        .expect("a planned command always carries argv zero");
    let command_span = stage.argv()[0].span();
    let mut child = platform
        .spawn(&request)
        .map_err(|error| RuntimeError::new(RuntimeErrorKind::ProcessSpawn(error), command_span))?;

    child
        .wait()
        .map_err(|error| RuntimeError::new(RuntimeErrorKind::ProcessWait(error), stage.span()))
}
