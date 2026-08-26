#!/usr/bin/env fsh
# Exercise the native Flash v1 conformance validator as a black box. The
# selected runtime is explicit so this root qualifies bootstrap and candidate.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'Flash conformance contract tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_validator(runtime, script, working, temporary, label) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    let previous = "$(pwd)"
    cd $working
    ^env "TMPDIR=$temporary" $runtime $script > $stdout 2> $stderr
    let result = $status
    cd $previous
    let observation = {
        code: $result.code,
        stdout: "$stdout",
        stderr: "$stderr",
    }
    return $observation
}

def expect_success(result, expected, label) {
    let stdout_path = $result.stdout
    let stderr_path = $result.stderr
    let observed_stdout = "$(^cat $stdout_path)"
    let observed_stderr = "$(^cat $stderr_path)"
    if $result.code != 0 || $observed_stdout != $expected || $observed_stderr != '' {
        test_error("$label expected success, observed status ${$result.code}, stdout '$observed_stdout', stderr '$observed_stderr'")
    }
}

def expect_failure(result, marker, label) {
    let stdout_path = $result.stdout
    let stderr_path = $result.stderr
    let observed_stdout = "$(^cat $stdout_path)"
    let observed_stderr = "$(^cat $stderr_path)"
    if $result.code != 1 || $observed_stdout != '' || !($marker in $observed_stderr) {
        test_error("$label expected failure containing '$marker', observed status ${$result.code}, stdout '$observed_stdout', stderr '$observed_stderr'")
    }
}

def prepare_candidate(root, temporary, label) {
    let candidate = "$temporary/$label"
    ^mkdir -p "$candidate/components/flash"
    if !$status.ok { test_error("cannot create $label candidate") }
    ^cp "$root/versions.env" "$candidate/"
    if !$status.ok { test_error("cannot copy $label version marker") }
    ^cp -R "$root/.github" "$candidate/"
    if !$status.ok { test_error("cannot copy $label workflow sources") }
    ^cp -R "$root/ci" "$candidate/"
    if !$status.ok { test_error("cannot copy $label CI sources") }
    ^cp -R "$root/components/flash/conformance" "$candidate/components/flash/"
    if !$status.ok { test_error("cannot copy $label conformance inventory") }
    ^cp -R "$root/components/flash/crates" "$candidate/components/flash/"
    if !$status.ok { test_error("cannot copy $label executable owners") }
    return $candidate
}

def rewrite(source, expression, temporary) {
    let rewritten = "$temporary/rewritten"
    ^sed $expression $source > $rewritten
    if !$status.ok { test_error("cannot mutate $source") }
    ^mv $rewritten $source
    if !$status.ok { test_error("cannot install mutation for $source") }
}

let root = repository_root('versions.env')
let runtime_value = env('FLASH_AUTOMATION_RUNTIME')
if $runtime_value == null || $runtime_value == '' {
    test_error('FLASH_AUTOMATION_RUNTIME is required')
}
let runtime = $runtime_value
if "$(^$runtime --version 2>/dev/null)" != 'fsh 1.0.0' {
    test_error('FLASH_AUTOMATION_RUNTIME must report fsh 1.0.0')
}
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flash-conformance-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let tracked = run_validator($runtime, "$root/ci/check_flash_conformance.fsh", $root, $temporary, 'tracked')
expect_success($tracked, 'Flash v1 conformance: ok', 'tracked conformance inventory')

let missing_family = prepare_candidate($root, $temporary, 'missing-family')
let missing_source = "$missing_family/components/flash/conformance/v1.toml"
let truncated = "$temporary/truncated-family"
^sed '/^id = "flashos-platform-routes"$/,$d' $missing_source > $truncated
if !$status.ok { test_error('cannot remove the final conformance family') }
^sed '$d' $truncated > "$temporary/without-family"
if !$status.ok { test_error('cannot remove the final conformance family header') }
^mv "$temporary/without-family" $missing_source
if !$status.ok { test_error('cannot install the missing-family mutation') }
let missing_result = run_validator($runtime, "$missing_family/ci/check_flash_conformance.fsh", $missing_family, $temporary, 'missing-family-result')
expect_failure($missing_result, 'family ids do not preserve the frozen order', 'missing required family')

let draft = prepare_candidate($root, $temporary, 'draft')
rewrite("$draft/components/flash/conformance/v1.toml", 's/contract_status = "frozen"/contract_status = "draft"/', $temporary)
let draft_result = run_validator($runtime, "$draft/ci/check_flash_conformance.fsh", $draft, $temporary, 'draft-result')
expect_failure($draft_result, "contract_status must be 'frozen'", 'draft contract status')

let missing_owner = prepare_candidate($root, $temporary, 'missing-owner')
rewrite("$missing_owner/components/flash/conformance/v1.toml", 's/parser.rs::structured_error_statements_retain_blocks_bindings_and_operands/parser.rs::not_a_real_test/', $temporary)
let owner_result = run_validator($runtime, "$missing_owner/ci/check_flash_conformance.fsh", $missing_owner, $temporary, 'missing-owner-result')
expect_failure($owner_result, 'does not resolve to an enabled #[test]', 'missing executable owner')

let expanded = prepare_candidate($root, $temporary, 'expanded-settings')
rewrite("$expanded/components/flash/conformance/v1.toml", '/  "continuation_prompt",/a\
  "theme",', $temporary)
let expanded_result = run_validator($runtime, "$expanded/ci/check_flash_conformance.fsh", $expanded, $temporary, 'expanded-settings-result')
expect_failure($expanded_result, 'config_settings do not preserve the frozen order', 'expanded config setting surface')

let unclassified = prepare_candidate($root, $temporary, 'unclassified-boundary')
^printf '\nfn hidden_gap() {\n    let _ = RuntimeErrorKind::Unsupported { feature: "a hidden gap" };\n}\n' >> "$unclassified/components/flash/crates/flash-runtime/src/eval.rs"
if !$status.ok { test_error('cannot create an unclassified runtime refusal') }
let unclassified_result = run_validator($runtime, "$unclassified/ci/check_flash_conformance.fsh", $unclassified, $temporary, 'unclassified-result')
expect_failure($unclassified_result, 'needs one nearby flash-v1-boundary annotation', 'unclassified runtime refusal')

let classified = prepare_candidate($root, $temporary, 'classified-boundary')
^printf '\nfn classified_gap() {\n    // flash-v1-boundary(embedding-refusal): This API cannot run jobs.\n    let _ = RuntimeErrorKind::Unsupported { feature: "effectful evaluation" };\n}\n' >> "$classified/components/flash/crates/flash-runtime/src/eval.rs"
if !$status.ok { test_error('cannot create a classified runtime refusal') }
let classified_result = run_validator($runtime, "$classified/ci/check_flash_conformance.fsh", $classified, $temporary, 'classified-result')
expect_success($classified_result, 'Flash v1 conformance: ok', 'classified runtime refusal')

^rm -rf $temporary
^printf '%s\n' 'Flash conformance contract tests: ok'
