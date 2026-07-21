//! Foreground execution of inspectable command plans.
//!
//! The executor handles external stages with inherited standard descriptors,
//! byte-pipeline assignments, and source-ordered redirections. It always runs
//! platform-independent preflight before touching the platform, starts every
//! stage before waiting, and never renders shell source.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::path::Path;

use flashshell_platform::{
    ChildDescriptor, ChildProcess, DescriptorEndpoint, FileOpenMode, FileOpenRequest, Platform,
    ProcessStatus, SpawnRequest,
};
use flashshell_syntax::{OutputMode, PipeOperator};

use crate::eval::{RuntimeError, RuntimeErrorKind};
use crate::plan::{
    ExecutionPlan, PlannedRedirection, PlannedResolution, RedirectionAction, preflight,
};

/// Execute one external foreground stage.
///
/// A nonzero exit or signal termination is a normal [`ProcessStatus`]. Spawn
/// and wait failures are source-anchored runtime errors. Internal commands
/// remain unsupported until built-in execution is added.
pub fn execute_foreground(
    plan: &ExecutionPlan,
    platform: &dyn Platform,
) -> Result<ProcessStatus, RuntimeError> {
    preflight(plan)?;

    if plan.stages().len() != 1 {
        return Err(RuntimeError::new(
            RuntimeErrorKind::Unsupported {
                feature: "a foreground pipeline with more than one stage",
            },
            plan.span(),
        ));
    }

    let mut statuses = execute_preflighted_pipeline(plan, platform)?;
    Ok(statuses
        .pop()
        .expect("a one-stage plan produces one process status"))
}

/// Execute an arbitrary-length external foreground byte pipeline.
///
/// Every edge receives one uniquely owned pipe. The final descriptor map for
/// each stage is passed to direct spawn, all parent endpoint owners are released
/// immediately after their stage starts, and no child is waited before every
/// stage has spawned. The returned low-level statuses remain in source order;
/// language-level aggregation and `pipefail` are a separate layer.
pub fn execute_foreground_pipeline(
    plan: &ExecutionPlan,
    platform: &dyn Platform,
) -> Result<Vec<ProcessStatus>, RuntimeError> {
    preflight(plan)?;
    execute_preflighted_pipeline(plan, platform)
}

fn execute_preflighted_pipeline(
    plan: &ExecutionPlan,
    platform: &dyn Platform,
) -> Result<Vec<ProcessStatus>, RuntimeError> {
    if plan.stages().is_empty() {
        return Err(RuntimeError::new(
            RuntimeErrorKind::Unsupported {
                feature: "an empty foreground pipeline",
            },
            plan.span(),
        ));
    }

    for stage in plan.stages() {
        validate_external_stage(stage)?;
    }

    let mut pipes = Vec::with_capacity(plan.edges().len());
    for edge in plan.edges() {
        let endpoints = platform.pipe().map_err(|error| {
            RuntimeError::new(RuntimeErrorKind::PipeCreate(error), edge.operator_span())
        })?;
        let (reader, writer) = endpoints.into_parts();
        pipes.push((Some(reader), Some(writer)));
    }

    let environment: Vec<(OsString, OsString)> = plan
        .environment()
        .iter()
        .map(|(name, value)| (OsString::from(name), value.to_os_string()))
        .collect();
    let mut children: Vec<Box<dyn ChildProcess>> = Vec::with_capacity(plan.stages().len());

    for (index, stage) in plan.stages().iter().enumerate() {
        let input = index.checked_sub(1).and_then(|edge| pipes[edge].0.take());
        let output = pipes.get_mut(index).and_then(|edge| edge.1.take());
        let merge_output =
            output.is_some() && plan.edges()[index].kind() == PipeOperator::StdoutAndStderr;
        let mut descriptor_map = StageDescriptorMap::new(input, output, merge_output);
        if let Err(error) =
            descriptor_map.apply_redirections(stage.redirections(), plan.cwd(), platform)
        {
            drop(descriptor_map);
            drop(pipes);
            terminate_and_reap(&mut children);
            return Err(error);
        }
        let descriptors = descriptor_map.child_descriptors();
        let closed_descriptors = descriptor_map.closed_descriptors();

        let PlannedResolution::External { path } = stage.resolution() else {
            unreachable!("external stages were validated before pipe creation");
        };
        let argv: Vec<OsString> = stage
            .argv()
            .iter()
            .map(|argument| argument.value().to_os_string())
            .collect();
        let request = SpawnRequest::new(path, &argv, &environment, plan.cwd())
            .expect("a planned command always carries argv zero")
            .with_descriptors(&descriptors)
            .expect("the final descriptor map has unique targets")
            .with_closed_descriptors(&closed_descriptors)
            .expect("a final descriptor cannot be both mapped and closed");
        let command_span = stage.argv()[0].span();
        let child = platform.spawn(&request).map_err(|error| {
            RuntimeError::new(RuntimeErrorKind::ProcessSpawn(error), command_span)
        });

        drop(descriptors);
        drop(closed_descriptors);
        drop(descriptor_map);

        match child {
            Ok(child) => children.push(child),
            Err(error) => {
                drop(pipes);
                terminate_and_reap(&mut children);
                return Err(error);
            }
        }
    }

    drop(pipes);
    wait_in_source_order(children, plan)
}

fn validate_external_stage(stage: &crate::plan::PlannedStage) -> Result<(), RuntimeError> {
    if !matches!(stage.resolution(), PlannedResolution::External { .. }) {
        return Err(RuntimeError::new(
            RuntimeErrorKind::Unsupported {
                feature: "foreground internal-command execution",
            },
            stage.span(),
        ));
    }
    Ok(())
}

fn terminate_and_reap(children: &mut [Box<dyn ChildProcess>]) {
    for child in &mut *children {
        let _ = child.terminate();
    }
    for child in children {
        let _ = child.wait();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DescriptorBinding {
    Inherited(u32),
    Owned(usize),
}

#[derive(Debug)]
struct StageDescriptorMap {
    bindings: BTreeMap<u32, DescriptorBinding>,
    resources: Vec<Option<Box<dyn DescriptorEndpoint>>>,
    touched: BTreeSet<u32>,
}

impl StageDescriptorMap {
    fn new(
        input: Option<Box<dyn DescriptorEndpoint>>,
        output: Option<Box<dyn DescriptorEndpoint>>,
        merge_output: bool,
    ) -> Self {
        let mut this = Self {
            bindings: BTreeMap::from([
                (0, DescriptorBinding::Inherited(0)),
                (1, DescriptorBinding::Inherited(1)),
                (2, DescriptorBinding::Inherited(2)),
            ]),
            resources: Vec::new(),
            touched: BTreeSet::new(),
        };
        if let Some(input) = input {
            this.assign_owned(0, input);
        }
        if let Some(output) = output {
            let resource = this.push_resource(output);
            this.assign(1, DescriptorBinding::Owned(resource));
            if merge_output {
                this.assign(2, DescriptorBinding::Owned(resource));
            }
        }
        this
    }

    fn apply_redirections(
        &mut self,
        redirections: &[PlannedRedirection],
        cwd: &Path,
        platform: &dyn Platform,
    ) -> Result<(), RuntimeError> {
        for redirection in redirections {
            match redirection.action() {
                RedirectionAction::Input {
                    descriptor, target, ..
                } => {
                    let endpoint = platform
                        .open_file(FileOpenRequest::new(
                            Path::new(target.value()),
                            cwd,
                            FileOpenMode::Read,
                        ))
                        .map_err(|error| {
                            RuntimeError::new(
                                RuntimeErrorKind::RedirectionSetup(error),
                                target.span(),
                            )
                        })?;
                    self.assign_owned(*descriptor, endpoint);
                }
                RedirectionAction::Output {
                    descriptor,
                    mode,
                    target,
                    ..
                } => {
                    let mode = match mode {
                        OutputMode::Truncate => FileOpenMode::WriteTruncate,
                        OutputMode::Append => FileOpenMode::WriteAppend,
                    };
                    let endpoint = platform
                        .open_file(FileOpenRequest::new(Path::new(target.value()), cwd, mode))
                        .map_err(|error| {
                            RuntimeError::new(
                                RuntimeErrorKind::RedirectionSetup(error),
                                target.span(),
                            )
                        })?;
                    self.assign_owned(*descriptor, endpoint);
                }
                RedirectionAction::Duplicate {
                    descriptor,
                    source,
                    target_span,
                    ..
                } => {
                    let binding = *self
                        .bindings
                        .get(source)
                        .expect("preflight established that the source descriptor is open");
                    let binding = match binding {
                        DescriptorBinding::Inherited(source) => {
                            let endpoint =
                                platform.inherit_descriptor(source).map_err(|error| {
                                    RuntimeError::new(
                                        RuntimeErrorKind::RedirectionSetup(error),
                                        *target_span,
                                    )
                                })?;
                            DescriptorBinding::Owned(self.push_resource(endpoint))
                        }
                        owned => owned,
                    };
                    self.assign(*descriptor, binding);
                }
                RedirectionAction::Close { descriptor, .. } => self.close(*descriptor),
            }
        }
        Ok(())
    }

    fn child_descriptors(&self) -> Vec<ChildDescriptor<'_>> {
        self.touched
            .iter()
            .filter_map(|target| match self.bindings.get(target) {
                Some(DescriptorBinding::Owned(resource)) => Some(ChildDescriptor::new(
                    *target,
                    self.resources[*resource]
                        .as_deref()
                        .expect("a mapped resource remains owned"),
                )),
                Some(DescriptorBinding::Inherited(source)) => {
                    debug_assert_eq!(target, source);
                    None
                }
                None => None,
            })
            .collect()
    }

    fn closed_descriptors(&self) -> Vec<u32> {
        self.touched
            .iter()
            .filter(|descriptor| !self.bindings.contains_key(descriptor))
            .copied()
            .collect()
    }

    fn assign_owned(&mut self, descriptor: u32, endpoint: Box<dyn DescriptorEndpoint>) {
        let resource = self.push_resource(endpoint);
        self.assign(descriptor, DescriptorBinding::Owned(resource));
    }

    fn push_resource(&mut self, endpoint: Box<dyn DescriptorEndpoint>) -> usize {
        let resource = self.resources.len();
        self.resources.push(Some(endpoint));
        resource
    }

    fn assign(&mut self, descriptor: u32, binding: DescriptorBinding) {
        let replaced = self.bindings.insert(descriptor, binding);
        self.touched.insert(descriptor);
        if let Some(DescriptorBinding::Owned(resource)) = replaced {
            self.release_if_unused(resource);
        }
    }

    fn close(&mut self, descriptor: u32) {
        let removed = self.bindings.remove(&descriptor);
        self.touched.insert(descriptor);
        if let Some(DescriptorBinding::Owned(resource)) = removed {
            self.release_if_unused(resource);
        }
    }

    fn release_if_unused(&mut self, resource: usize) {
        let still_used = self
            .bindings
            .values()
            .any(|binding| *binding == DescriptorBinding::Owned(resource));
        if !still_used {
            drop(self.resources[resource].take());
        }
    }
}

fn wait_in_source_order(
    children: Vec<Box<dyn ChildProcess>>,
    plan: &ExecutionPlan,
) -> Result<Vec<ProcessStatus>, RuntimeError> {
    let mut statuses = Vec::with_capacity(children.len());
    let mut first_error = None;
    for (mut child, stage) in children.into_iter().zip(plan.stages()) {
        match child.wait() {
            Ok(status) => statuses.push(status),
            Err(error) => {
                if first_error.is_none() {
                    first_error = Some(RuntimeError::new(
                        RuntimeErrorKind::ProcessWait(error),
                        stage.span(),
                    ));
                }
            }
        }
    }

    match first_error {
        Some(error) => Err(error),
        None => Ok(statuses),
    }
}
