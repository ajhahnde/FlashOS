#!/usr/bin/env fsh
# Exercise the native exhaustive Flash v1 exercise validator as a black box.
# The selected runtime is explicit so this root qualifies bootstrap and candidate.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'Flash v1 exercise contract tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_validator(runtime, script, working, temporary, label) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    let previous = "$(pwd)"
    cd $working
    ^env "TMPDIR=$temporary" "FLASH_V1_BOOTSTRAP_FSH=$runtime" $runtime $script > $stdout 2> $stderr
    let result = $status
    cd $previous
    let observation = {
        code: $result.code,
        stdout: "$stdout",
        stderr: "$stderr",
    }
    return $observation
}

def expect_success(result, label) {
    let stdout_path = $result.stdout
    let stderr_path = $result.stderr
    let observed_stdout = "$(^cat $stdout_path)"
    let observed_stderr = "$(^cat $stderr_path)"
    if $result.code != 0 || $observed_stdout != 'Flash v1 exercises: exhaustive contract passed' || $observed_stderr != '' {
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
    ^cp "$root/components/flash/README.md" "$candidate/components/flash/"
    if !$status.ok { test_error("cannot copy $label component overview") }
    for directory in ['docs', 'exercises', 'platforms'] {
        ^cp -R "$root/components/flash/$directory" "$candidate/components/flash/"
        if !$status.ok { test_error("cannot copy $label Flash $directory") }
    }
    return $candidate
}

def mutate(candidate, expression, temporary) {
    let source = "$candidate/components/flash/exercises/v1.toml"
    let rewritten = "$temporary/rewritten-exercises"
    ^sed $expression $source > $rewritten
    if !$status.ok { test_error('cannot mutate the exercise contract') }
    ^mv $rewritten $source
    if !$status.ok { test_error('cannot install the exercise mutation') }
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
let temporary = "$(^mktemp -d "$temporary_parent/flash-v1-exercise-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let tracked = run_validator($runtime, "$root/ci/check_flash_v1_exercises.fsh", $root, $temporary, 'tracked')
expect_success($tracked, 'tracked exercise contract')

let builtin = prepare_candidate($root, $temporary, 'missing-builtin')
mutate($builtin, 's/, "where", "which"/, "which"/', $temporary)
let builtin_result = run_validator($runtime, "$builtin/ci/check_flash_v1_exercises.fsh", $builtin, $temporary, 'missing-builtin-result')
expect_failure($builtin_result, 'standard-builtins does not match the standard registry', 'missing standard built-in')

let documentation = prepare_candidate($root, $temporary, 'documentation-gap')
mutate($documentation, 's/last_block = 66/last_block = 65/', $temporary)
let documentation_result = run_validator($runtime, "$documentation/ci/check_flash_v1_exercises.fsh", $documentation, $temporary, 'documentation-gap-result')
expect_failure($documentation_result, 'documentation ownership is incomplete', 'documentation ownership gap')

let compatibility = prepare_candidate($root, $temporary, 'compatibility-gap')
mutate($compatibility, 's/id = "namespace-evolution-machinery"/id = "removed-classification"/', $temporary)
let compatibility_result = run_validator($runtime, "$compatibility/ci/check_flash_v1_exercises.fsh", $compatibility, $temporary, 'compatibility-gap-result')
expect_failure($compatibility_result, 'compatibility ownership does not preserve the classified records', 'missing compatibility classification')

let host_owner = prepare_candidate($root, $temporary, 'host-owner-gap')
mutate($host_owner, 's/exercise_case = "language-values"/exercise_case = "missing-owner"/', $temporary)
let host_owner_result = run_validator($runtime, "$host_owner/ci/check_flash_v1_exercises.fsh", $host_owner, $temporary, 'host-owner-gap-result')
expect_failure($host_owner_result, 'host case ownership does not match the contract', 'missing executable host owner')

let flashos_owner = prepare_candidate($root, $temporary, 'flashos-owner-gap')
mutate($flashos_owner, 's/target-matrix:v1-language-values-and-control/target-matrix:not-a-case/', $temporary)
let flashos_owner_result = run_validator($runtime, "$flashos_owner/ci/check_flash_v1_exercises.fsh", $flashos_owner, $temporary, 'flashos-owner-gap-result')
expect_failure($flashos_owner_result, 'has unknown FlashOS owner', 'unknown FlashOS owner')

let stale_evidence = prepare_candidate($root, $temporary, 'stale-evidence')
mutate($stale_evidence, 's/suite_version = 1/suite_version = 2/', $temporary)
let stale_result = run_validator($runtime, "$stale_evidence/ci/check_flash_v1_exercises.fsh", $stale_evidence, $temporary, 'stale-evidence-result')
expect_failure($stale_result, 'suite_version is 2, expected 1', 'stale candidate identity')

^rm -rf $temporary
^printf '%s\n' 'Flash v1 exercise contract tests: ok'
