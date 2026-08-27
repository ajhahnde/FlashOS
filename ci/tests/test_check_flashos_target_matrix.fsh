#!/usr/bin/env fsh
# Exercise the native FlashOS target-matrix validator as a black box.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'FlashOS target matrix contract tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_validator(runtime, script, working, temporary, label) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    let previous = "$(pwd)"
    cd $working
    ^env "TMPDIR=$temporary" "FLASH_AUTOMATION_RUNTIME=$runtime" $runtime $script > $stdout 2> $stderr
    let result = $status
    cd $previous
    let observation = {code: $result.code, stdout: "$stdout", stderr: "$stderr"}
    return $observation
}

def expect_success(result, label) {
    let stdout_path = $result.stdout
    let stderr_path = $result.stderr
    let observed_stdout = "$(^cat $stdout_path)"
    let observed_stderr = "$(^cat $stderr_path)"
    if $result.code != 0 || $observed_stdout != 'FlashOS target matrix: advertised capability contract passed' || $observed_stderr != '' {
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
    ^cp -R "$root/.github" "$candidate/"
    ^cp -R "$root/ci" "$candidate/"
    ^cp -R "$root/components/flash/platforms" "$candidate/components/flash/"
    ^cp -R "$root/components/flash/crates" "$candidate/components/flash/"
    if !$status.ok { test_error("cannot copy $label contract sources") }
    return $candidate
}

def rewrite(source, expression, destination, message) {
    ^sed $expression $source > $destination
    if !$status.ok { test_error($message) }
    ^mv $destination $source
    if !$status.ok { test_error($message) }
}

let root = repository_root('versions.env')
let runtime_value = env('FLASH_AUTOMATION_RUNTIME')
if $runtime_value == null || $runtime_value == '' { test_error('FLASH_AUTOMATION_RUNTIME is required') }
let runtime = $runtime_value
if "$(^$runtime --version 2>/dev/null)" != 'fsh 1.0.0' { test_error('FLASH_AUTOMATION_RUNTIME must report fsh 1.0.0') }
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flashos-target-matrix-contract-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let tracked = run_validator($runtime, "$root/ci/check_flashos_target_matrix.fsh", $root, $temporary, 'tracked')
expect_success($tracked, 'tracked target matrix')

let withheld = prepare_candidate($root, $temporary, 'withheld')
let withheld_source = "$withheld/components/flash/platforms/flashos-x86_64-target-matrix-v1.toml"
rewrite($withheld_source, 's/capabilities = \["environment", "working-directory", "process-spawn", "foreground-terminal", "terminal-info", "standard-directories"\]/capabilities = ["environment", "working-directory", "process-spawn", "foreground-terminal", "terminal-info", "standard-directories", "signals"]/', "$temporary/withheld.toml", 'cannot add withheld capability to case')
let withheld_result = run_validator($runtime, "$withheld/ci/check_flashos_target_matrix.fsh", $withheld, $temporary, 'withheld-result')
expect_failure($withheld_result, 'has unadvertised capabilities', 'withheld capability in target case')

let ownerless = prepare_candidate($root, $temporary, 'ownerless')
let ownerless_source = "$ownerless/components/flash/platforms/flashos-x86_64-target-matrix-v1.toml"
rewrite($ownerless_source, '/  "cwd-startup-read",/d', "$temporary/ownerless.toml", 'cannot remove target operation owner')
let ownerless_result = run_validator($runtime, "$ownerless/ci/check_flashos_target_matrix.fsh", $ownerless, $temporary, 'ownerless-result')
expect_failure($ownerless_result, 'matrix operations must have complete single ownership', 'advertised operation without owner')

^rm -rf $temporary
^printf '%s\n' 'FlashOS target matrix contract tests: ok'
