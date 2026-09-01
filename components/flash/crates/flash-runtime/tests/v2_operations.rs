#![forbid(unsafe_code)]

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use flash_platform::FakePlatform;
use flash_runtime::Environment;
use flash_runtime::Value;
use flash_runtime::builtin::standard_registry;
use flash_runtime::eval::FakeClock;
use flash_runtime::help::{ModuleHelpCatalog, ModuleHelpKind};
use flash_runtime::module::{
    ModuleCanonicalizer, ModuleId, ModulePathError, ModuleProgramLoader, ModuleSourceError,
    ModuleSourceLoader, ValueType,
};
use flash_runtime::operation::{OperationInputType, OperationStreamOutcome};
use flash_runtime::plan::SessionOptions;
use flash_runtime::resolve::ExecutableProbe;
use flash_runtime::script::execute_module_program;
use flash_runtime::stream::ValueStream;
use flash_syntax::LanguageMajor;

struct FixtureModules;

struct NoExecutables;

impl ExecutableProbe for NoExecutables {
    fn is_executable(&self, _path: &OsStr) -> bool {
        false
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
fn operation_manifest_checks_and_executes_expression_and_pipeline_forms() {
    let root = operation_root();
    let manifest = fs::read_to_string(root.join("manifest.tsv")).unwrap();
    let modules = FixtureModules;

    for row in manifest.lines() {
        if row.is_empty() || row.starts_with('#') {
            continue;
        }
        let fields = row.split('\t').collect::<Vec<_>>();
        assert_eq!(fields.len(), 3, "malformed operation manifest row");
        let report = ModuleProgramLoader::for_language(&modules, &modules, LanguageMajor::V2)
            .analyze_with_commands(&root.join(fields[1]), &standard_registry());
        match fields[0] {
            "complete" => {
                let program = report.program().unwrap_or_else(|| {
                    panic!(
                        "{} must pass shared analysis: {:?}",
                        fields[1],
                        report.issues()
                    )
                });
                execute_module_program(
                    program,
                    &[],
                    &root,
                    &mut Environment::new(),
                    &standard_registry(),
                    &NoExecutables,
                    &SessionOptions::default(),
                    &FakePlatform::full(),
                    Arc::new(FakeClock::new()),
                    &mut Vec::new(),
                )
                .unwrap_or_else(|error| panic!("{} must execute: {}", fields[1], error.render()));
            }
            "invalid" => {
                let codes = report
                    .issues()
                    .iter()
                    .flat_map(|issue| issue.error().diagnostics())
                    .map(|diagnostic| diagnostic.code().to_owned())
                    .collect::<Vec<_>>();
                assert!(
                    report.program().is_none() && codes.iter().any(|code| code == fields[2]),
                    "{} must fail with {}: {codes:?}",
                    fields[1],
                    fields[2]
                );
            }
            class => panic!("unknown operation corpus class {class:?}"),
        }
    }
}

#[test]
fn operation_identity_overloads_help_and_budgeted_stream_share_one_descriptor() {
    let root = operation_root();
    let modules = FixtureModules;
    let program = ModuleProgramLoader::for_language(&modules, &modules, LanguageMajor::V2)
        .load(&root.join("complete/reference.fsh"))
        .expect("the operation reference fixture loads");
    let module = program.graph().root();
    let direct = program
        .resolve_operation(module, &["value", "length"])
        .expect("the direct standard alias resolves");
    let reexported = program
        .resolve_operation(module, &["api", "value", "length"])
        .expect("the explicit alias re-export resolves");

    assert_eq!(direct.id(), reexported.id());
    assert_eq!(direct.id().qualified_name(), "std::value::length");
    assert_eq!(direct.type_parameters(), &["T"]);
    assert_eq!(direct.validate(), Ok(()));
    assert_eq!(direct.overloads().len(), 2);
    assert!(matches!(
        direct.overloads()[0].input(),
        OperationInputType::Value(_)
    ));
    assert!(matches!(
        direct.overloads()[1].input(),
        OperationInputType::ValueStream(_)
    ));
    assert_eq!(
        direct.execute_value(Value::list(vec![Value::Int(1), Value::Int(2)])),
        Ok(Value::Int(2))
    );
    assert!(direct.execute_value(Value::Int(2)).is_err());
    assert!(
        direct
            .execute_value_with_types(Value::list(vec![Value::Int(1)]), &[ValueType::String],)
            .is_err()
    );

    let help = ModuleHelpCatalog::snapshot(&program)
        .query(module, "api::value::length")
        .expect("operation help follows the same alias path");
    assert_eq!(help.kind(), ModuleHelpKind::Operation);
    assert_eq!(help.operation().unwrap().id(), direct.id());
    assert!(
        help.operation()
            .unwrap()
            .documentation()
            .contains("bounded")
    );

    match direct.execute_value_stream(
        ValueStream::from_values(vec![Value::Int(1), Value::Int(2)]),
        2,
    ) {
        OperationStreamOutcome::Value(Value::Int(2)) => {}
        other => panic!("at-limit stream length must succeed: {other:?}"),
    }
    match direct.execute_value_stream(
        ValueStream::from_values(vec![Value::Int(1), Value::Int(2), Value::Int(3)]),
        2,
    ) {
        OperationStreamOutcome::LimitExceeded { limit: 2 } => {}
        other => panic!("first excess stream item must refuse: {other:?}"),
    }
}

fn operation_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("tests/v2-foundation/language/operations")
}
