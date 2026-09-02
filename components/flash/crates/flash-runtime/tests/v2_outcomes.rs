#![forbid(unsafe_code)]

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use flash_platform::{
    Capabilities, ChildProcess, DescriptorEndpoint, FakePlatform, FileActionError, FileOpenRequest,
    PipeEndpoints, PipeError, Platform, ProcessGroup, ProcessGroupId, ProcessStatus, SpawnError,
    SpawnRequest, TerminateError, WaitError,
};
use flash_runtime::builtin::standard_registry;
use flash_runtime::eval::FakeClock;
use flash_runtime::module::{
    ModuleCanonicalizer, ModuleId, ModuleOrigin, ModulePathError, ModuleProgram,
    ModuleProgramLoader, ModuleSourceError, ModuleSourceLoader, ValueType,
};
use flash_runtime::plan::SessionOptions;
use flash_runtime::resolve::ExecutableProbe;
use flash_runtime::script::{ScriptCompletion, execute_module_program};
use flash_runtime::{Environment, Value};
use flash_syntax::LanguageMajor;

struct FixtureModules;

struct NoExecutables;

struct ToolExecutable;

#[derive(Debug)]
struct StatusChild {
    code: i32,
    group: Option<ProcessGroupId>,
}

impl ChildProcess for StatusChild {
    fn id(&self) -> u64 {
        70_006
    }

    fn process_group(&self) -> Option<ProcessGroupId> {
        self.group
    }

    fn wait(&mut self) -> Result<ProcessStatus, WaitError> {
        Ok(ProcessStatus::Exited(self.code))
    }

    fn terminate(&mut self) -> Result<(), TerminateError> {
        Ok(())
    }
}

struct StatusPlatform {
    inner: FakePlatform,
    code: i32,
}

impl StatusPlatform {
    const fn new(code: i32) -> Self {
        Self {
            inner: FakePlatform::full(),
            code,
        }
    }
}

impl Platform for StatusPlatform {
    fn capabilities(&self) -> Capabilities {
        self.inner.capabilities()
    }

    fn pipe(&self) -> Result<PipeEndpoints, PipeError> {
        self.inner.pipe()
    }

    fn open_file(
        &self,
        request: FileOpenRequest<'_>,
    ) -> Result<Box<dyn DescriptorEndpoint>, FileActionError> {
        self.inner.open_file(request)
    }

    fn inherit_descriptor(
        &self,
        descriptor: u32,
    ) -> Result<Box<dyn DescriptorEndpoint>, FileActionError> {
        self.inner.inherit_descriptor(descriptor)
    }

    fn spawn(&self, request: &SpawnRequest<'_>) -> Result<Box<dyn ChildProcess>, SpawnError> {
        let group = match request.process_group() {
            ProcessGroup::Inherit => None,
            ProcessGroup::New => ProcessGroupId::new(70_006),
            ProcessGroup::Join(group) => Some(group),
        };
        Ok(Box::new(StatusChild {
            code: self.code,
            group,
        }))
    }
}

impl ExecutableProbe for NoExecutables {
    fn is_executable(&self, _path: &OsStr) -> bool {
        false
    }
}

impl ExecutableProbe for ToolExecutable {
    fn is_executable(&self, path: &OsStr) -> bool {
        path == OsStr::new("/bin/tool")
    }
}

impl ModuleCanonicalizer for FixtureModules {
    fn canonicalize(&self, candidate: &Path) -> Result<PathBuf, ModulePathError> {
        Ok(candidate.to_path_buf())
    }
}

impl ModuleSourceLoader for FixtureModules {
    fn load(&self, module: &ModuleId) -> Result<Vec<u8>, ModuleSourceError> {
        fs::read(module.path()).map_err(|error| ModuleSourceError::new(error.to_string()))
    }
}

#[test]
fn outcome_manifest_checks_compiled_variants_and_conversion_boundaries() {
    let root = outcome_root();
    let manifest = fs::read_to_string(root.join("manifest.tsv")).unwrap();
    let modules = FixtureModules;

    for (index, row) in manifest.lines().enumerate() {
        if row.is_empty() || row.starts_with('#') {
            continue;
        }
        let fields = row.split('\t').collect::<Vec<_>>();
        assert_eq!(fields.len(), 3, "malformed outcome row {}", index + 1);
        let report = ModuleProgramLoader::for_language(&modules, &modules, LanguageMajor::V2)
            .analyze(&root.join(fields[1]));
        match fields[0] {
            "complete" => assert!(
                report.issues().is_empty() && report.program().is_some(),
                "{} must pass shared analysis: {:?}",
                fields[1],
                report.issues()
            ),
            "invalid" => {
                let codes = report
                    .issues()
                    .iter()
                    .flat_map(|issue| issue.error().diagnostics())
                    .map(|diagnostic| diagnostic.code().to_owned())
                    .collect::<Vec<_>>();
                assert!(
                    report.program().is_none() && codes.iter().any(|code| code == fields[2]),
                    "{} must fail with {}: {codes:?}; {:?}",
                    fields[1],
                    fields[2],
                    report.issues()
                );
            }
            class => panic!("unknown outcome corpus class {class:?}"),
        }
    }
}

#[test]
fn standard_result_and_option_share_canonical_nominal_identity() {
    let program = load("complete/reference.fsh");
    let root = program.graph().root();
    let result = program
        .resolve_nominal_type(root, &["outcome", "Result"])
        .expect("std::outcome::Result resolves through its alias");
    let option = program
        .resolve_nominal_type(root, &["api", "outcome", "Option"])
        .expect("std::outcome::Option resolves through its deep re-export");
    let direct_option = program
        .resolve_nominal_type(root, &["outcome", "Option"])
        .expect("std::outcome::Option resolves through its direct alias");

    assert_eq!(result.id().name(), "Result");
    assert_eq!(result.type_parameters().len(), 2);
    assert_eq!(
        result
            .variants()
            .iter()
            .map(|variant| variant.name())
            .collect::<Vec<_>>(),
        ["Ok", "Err"]
    );
    assert_eq!(option.id().name(), "Option");
    assert_eq!(option.type_parameters().len(), 1);
    assert_eq!(
        option
            .variants()
            .iter()
            .map(|variant| variant.name())
            .collect::<Vec<_>>(),
        ["Some", "None"]
    );
    assert!(matches!(
        result.id().module().origin(),
        ModuleOrigin::Standard { namespace, module }
            if namespace == "std" && module == "outcome"
    ));
    assert_eq!(result.id().module(), option.id().module());
    assert_eq!(option.id(), direct_option.id());
}

#[test]
fn completed_values_domain_errors_and_statuses_remain_distinct() {
    let reference = execute(
        &load("complete/reference.fsh"),
        &NoExecutables,
        Environment::new(),
    );
    assert_eq!(reference.value(), &Value::Int(2));
    assert!(reference.status().is_none());

    let domain_result = execute(
        &load("complete/domain-error.fsh"),
        &NoExecutables,
        Environment::new(),
    );
    let Value::Variant(result) = domain_result.value() else {
        panic!("a domain Err must remain an ordinary variant value");
    };
    assert_eq!(result.id().name(), "Result");
    assert_eq!(
        result.type_arguments(),
        &[ValueType::Int, ValueType::String]
    );
    assert_eq!(result.constructor(), "Err");
    assert_eq!(result.payload(), &[Value::string("domain")]);
    assert!(domain_result.status().is_none());

    let option = execute(
        &load("complete/option-none.fsh"),
        &NoExecutables,
        Environment::new(),
    );
    let Value::Variant(option_value) = option.value() else {
        panic!("None must remain an ordinary variant value");
    };
    assert_eq!(option_value.id().name(), "Option");
    assert_eq!(option_value.type_arguments(), &[ValueType::Int]);
    assert_eq!(option_value.constructor(), "None");
    assert!(option_value.payload().is_empty());
    assert!(option.status().is_none());

    let status = execute_on(
        &load("complete/status-success.fsh"),
        &ToolExecutable,
        Environment::from_snapshot([("PATH", "/bin")]),
        &StatusPlatform::new(7),
    );
    let Value::Status(value_status) = status.value() else {
        panic!("a completed process status must remain a Status value");
    };
    assert_eq!(value_status.code(), Some(7));
    assert_eq!(status.status(), Some(value_status));
}

fn execute(
    program: &ModuleProgram,
    probe: &dyn ExecutableProbe,
    environment: Environment,
) -> ScriptCompletion {
    execute_on(program, probe, environment, &FakePlatform::full())
}

fn execute_on(
    program: &ModuleProgram,
    probe: &dyn ExecutableProbe,
    mut environment: Environment,
    platform: &dyn Platform,
) -> ScriptCompletion {
    let mut output = Vec::new();
    let completion = execute_module_program(
        program,
        &[],
        &outcome_root(),
        &mut environment,
        &standard_registry(),
        probe,
        &SessionOptions::default(),
        platform,
        Arc::new(FakeClock::new()),
        &mut output,
    )
    .unwrap_or_else(|error| panic!("outcome fixture must execute: {}", error.render()));
    assert!(
        output.is_empty(),
        "non-interactive outcomes do not print implicitly"
    );
    completion
}

fn load(path: &str) -> ModuleProgram {
    let modules = FixtureModules;
    ModuleProgramLoader::for_language(&modules, &modules, LanguageMajor::V2)
        .load(&outcome_root().join(path))
        .unwrap_or_else(|error| panic!("{path} must load: {error:?}"))
}

fn outcome_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("tests/v2-foundation/language/outcomes")
}
