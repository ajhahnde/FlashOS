#!/usr/bin/env fsh
# Exercise the native FlashOS capability-evidence validator as a black box.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'FlashOS capability evidence tests: FAILED: %s\n' $message 1>&2
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

def expect_success(result, label) {
    let stdout_path = $result.stdout
    let stderr_path = $result.stderr
    let observed_stdout = "$(^cat $stdout_path)"
    let observed_stderr = "$(^cat $stderr_path)"
    let expected = 'FlashOS capability evidence: source/runtime comparison contract passed for x86_64-unknown-redox'
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
    ^cp -R "$root/.github" "$candidate/"
    ^cp -R "$root/ci" "$candidate/"
    ^cp -R "$root/components/flash/platforms" "$candidate/components/flash/"
    ^cp -R "$root/components/flash/crates" "$candidate/components/flash/"
    if !$status.ok { test_error("cannot copy $label contract sources") }
    return $candidate
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
let temporary = "$(^mktemp -d "$temporary_parent/flashos-capability-evidence-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let tracked = run_validator($runtime, "$root/ci/check_flashos_capabilities.fsh", $root, $temporary, 'tracked')
expect_success($tracked, 'tracked capability evidence')

let classified = prepare_candidate($root, $temporary, 'classified-evidence')
let source = "$classified/components/flash/platforms/flashos-x86_64-capability-evidence.toml"
let rewritten = "$temporary/classified-evidence.toml"
^sed '/^\[\[capability\]\]$/,/^classification = "deferred"$/ s/classification = "deferred"/classification = "native"/' $source > $rewritten
if !$status.ok { test_error('cannot mutate capability evidence') }
^mv $rewritten $source
if !$status.ok { test_error('cannot install capability-evidence mutation') }
let classified_result = run_validator($runtime, "$classified/ci/check_flashos_capabilities.fsh", $classified, $temporary, 'classified-result')
expect_failure($classified_result, "classification must remain 'deferred'", 'classification in evidence inventory')

^rm -rf $temporary
^printf '%s\n' 'FlashOS capability evidence tests: ok'
