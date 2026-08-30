#![cfg(unix)]

use std::{
    env, fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Output},
    time::{SystemTime, UNIX_EPOCH},
};

const SUCCESS_JSON: &str = "{\"api\":{\"name\":\"flashos.system\",\"schema\":1,\"maturity\":\"experimental\"},\"result\":{\"action\":\"system.describe\",\"system\":{\"name\":\"FlashOS\",\"release\":\"0.3.0\",\"architecture\":\"x86_64\"},\"actions\":[{\"name\":\"system.describe\",\"kind\":\"query\",\"available\":true}]}}";
const ERROR_JSON: &str = "{\"api\":{\"name\":\"flashos.system\",\"schema\":1,\"maturity\":\"experimental\"},\"error\":{\"code\":\"unavailable\",\"message\":\"system description is unavailable\"}}";

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new(label: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should follow the Unix epoch")
            .as_nanos();
        let path = env::temp_dir().join(format!(
            "flashos-system-api-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&path).expect("test directory should be created");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn repository_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("system/api should have a repository parent")
        .to_owned()
}

fn flash_runtime() -> PathBuf {
    if let Some(runtime) = env::var_os("FLASH_AUTOMATION_RUNTIME") {
        return PathBuf::from(runtime);
    }
    repository_root().join("build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh")
}

fn run_flash(arguments: &[&Path]) -> Output {
    let runtime = flash_runtime();
    assert!(runtime.is_file(), "Flash 1.0 automation runtime is missing");
    Command::new(runtime)
        .args(arguments)
        .current_dir(repository_root())
        .output()
        .expect("Flash should execute")
}

fn assert_success(output: &Output, label: &str) {
    assert!(
        output.status.success(),
        "{label} failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn write_transport(directory: &Path, payload: &str, code: u8) {
    let path = directory.join("flashos-system");
    let source = format!("#!/bin/sh\nprintf '%s\\n' '{payload}'\nexit {code}\n");
    fs::write(&path, source).expect("transport fixture should be written");
    let mut permissions = fs::metadata(&path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn installed_example(directory: &Path) -> PathBuf {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let module = manifest.join("flash/system.fsh");
    let source = fs::read_to_string(manifest.join("examples/system-description.fsh"))
        .expect("example should be readable")
        .replace(
            "/usr/share/flashos/flash/system.fsh",
            module.to_str().expect("module path should be UTF-8"),
        );
    let path = directory.join("system-description.fsh");
    fs::write(&path, source).expect("host example should be written");
    path
}

fn run_example(directory: &Path, payload: &str, code: u8) -> Output {
    write_transport(directory, payload, code);
    let example = installed_example(directory);
    let runtime = flash_runtime();
    let inherited_path = env::var_os("PATH").unwrap_or_default();
    let joined = env::join_paths(
        std::iter::once(directory.to_path_buf()).chain(env::split_paths(&inherited_path)),
    )
    .expect("test PATH should be joinable");
    Command::new(runtime)
        .arg(example)
        .env("PATH", joined)
        .current_dir(repository_root())
        .output()
        .expect("public example should execute")
}

#[test]
fn module_formats_checks_and_exercises_all_envelope_outcomes() {
    let root = repository_root();
    let runtime = flash_runtime();
    let module = root.join("system/api/flash/system.fsh");
    let module_tests = root.join("system/api/flash/tests/module.fsh");

    let format = Command::new(&runtime)
        .args(["format", "--check"])
        .arg(&module)
        .arg(&module_tests)
        .current_dir(&root)
        .output()
        .expect("Flash formatter should execute");
    assert_success(&format, "Flash module formatting");
    assert_success(
        &run_flash(&[Path::new("check"), &module]),
        "Flash module check",
    );
    let exercised = run_flash(&[&module_tests]);
    assert_success(&exercised, "Flash module tests");
    assert_eq!(
        String::from_utf8(exercised.stdout).unwrap(),
        "FlashOS system API module tests: ok\n"
    );
}

#[test]
fn public_pipeline_preserves_success_and_transport_failure_separately() {
    let success_directory = TestDirectory::new("success");
    let success = run_example(success_directory.path(), SUCCESS_JSON, 0);
    assert_success(&success, "successful public pipeline");
    let success_document: serde_json::Value =
        serde_json::from_slice(&success.stdout).expect("success output should be JSON");
    assert_eq!(success_document["ok"], true);
    assert_eq!(success_document["result"]["system"]["name"], "FlashOS");

    let error_directory = TestDirectory::new("error");
    let error = run_example(error_directory.path(), ERROR_JSON, 1);
    assert_eq!(error.status.code(), Some(1));
    let error_document: serde_json::Value =
        serde_json::from_slice(&error.stdout).expect("error outcome should remain JSON");
    assert_eq!(error_document["ok"], false);
    assert_eq!(error_document["error"]["code"], "unavailable");
}

#[test]
fn json_boundary_owns_malformed_truncated_and_oversized_documents() {
    let directory = TestDirectory::new("json-boundary");
    let script = directory.path().join("decode.fsh");
    fs::write(
        &script,
        "let input = $args[0]\nopen $input | from json | to json | ^cat\n",
    )
    .unwrap();

    for (name, contents) in [
        ("malformed", b"not-json".as_slice()),
        ("truncated", b"{\"api\":".as_slice()),
    ] {
        let input = directory.path().join(name);
        fs::write(&input, contents).unwrap();
        let output = run_flash(&[&script, &input]);
        assert!(!output.status.success(), "{name} JSON should fail");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("malformed JSON"),
            "{name} stderr differed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let oversized = directory.path().join("oversized");
    let mut document = String::from("{\"padding\":\"");
    document.push_str(&"x".repeat(8 * 1024 * 1024));
    document.push_str("\"}");
    fs::write(&oversized, document).unwrap();
    let output = run_flash(&[&script, &oversized]);
    assert!(!output.status.success(), "oversized JSON should fail");
    assert!(String::from_utf8_lossy(&output.stderr).contains("materialization limit"));
}
