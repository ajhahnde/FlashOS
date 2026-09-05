#!/usr/bin/env fsh
# Exercise the native LCOV validator through its public CLI. The selected
# runtime is explicit so the same root qualifies bootstrap and candidate fsh.

import { repository_root } from '../lib/repository.fsh'
import { require_jq, toml_to_json } from '../lib/tools.fsh'

def test_error(message) {
    ^printf 'coverage contract tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_validator(runtime, script, temporary, label, report) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    ^$runtime $script $report > $stdout 2> $stderr
    let result = $status
    let observation = {
        code: $result.code,
        stdout: "$(^cat $stdout)",
        stderr: "$(^cat $stderr)",
    }
    return $observation
}

def expect_success(result, label) {
    if $result.code != 0 || !('coverage contract: ok' in $result.stdout) || !('workspace members: 8' in $result.stdout) || $result.stderr != '' {
        test_error("$label expected success, observed status ${$result.code}, stdout '${$result.stdout}', stderr '${$result.stderr}'")
    }
}

def expect_failure(result, marker, label) {
    if $result.code != 1 || $result.stdout != '' || !($marker in $result.stderr) {
        test_error("$label expected failure containing '$marker', observed status ${$result.code}, stdout '${$result.stdout}', stderr '${$result.stderr}'")
    }
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
let jq = require_jq()
let script = "$root/ci/check_coverage.fsh"
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flash-coverage-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let workspace_json = "$temporary/workspace.json"
let workspace_text = toml_to_json("$root/components/flash/Cargo.toml", "$temporary/taplo.stderr")
^printf '%s\n' $workspace_text > $workspace_json
if !$status.ok { test_error('cannot decode Flash workspace membership') }

let complete = "$temporary/complete.lcov"
^printf '%s' '' > $complete
mut index = 0
mut remaining = true
while $remaining {
    let exists = "$(^env $jq --raw-output --argjson index $index '.workspace.members | has($index)' $workspace_json)"
    if !$status.ok { test_error('cannot inspect Flash workspace membership') }
    if $exists != 'true' {
        $remaining = false
        continue
    }
    let member = "$(^env $jq --raw-output --argjson index $index '.workspace.members[$index]' $workspace_json)"
    if !$status.ok { test_error('cannot inspect Flash workspace membership') }
    ^printf 'SF:%s/components/flash/%s/src/lib.rs\nDA:1,1\nend_of_record\n' $root $member >> $complete
    if !$status.ok { test_error('cannot create complete coverage report') }
    $index = $index + 1
}
if $index != 8 { test_error("expected eight Flash workspace members, observed $index") }

let accepted = run_validator($runtime, $script, $temporary, 'complete', $complete)
expect_success($accepted, 'complete workspace report')

let omitted_once = "$temporary/omitted-once.lcov"
let omitted_twice = "$temporary/omitted-twice.lcov"
let omitted = "$temporary/omitted.lcov"
^sed '$d' $complete > $omitted_once
^sed '$d' $omitted_once > $omitted_twice
^sed '$d' $omitted_twice > $omitted
if !$status.ok { test_error('cannot create omitted-member coverage report') }
let missing = run_validator($runtime, $script, $temporary, 'omitted', $omitted)
expect_failure($missing, 'omitted Flash workspace members', 'omitted workspace member')

let zero = "$temporary/zero.lcov"
^sed 's/DA:1,1/DA:1,0/g' $complete > $zero
if !$status.ok { test_error('cannot create zero-execution coverage report') }
let unexecuted = run_validator($runtime, $script, $temporary, 'zero', $zero)
expect_failure($unexecuted, 'no executed first-party Rust lines', 'unexecuted workspace report')

^rm -rf $temporary
^printf '%s\n' 'coverage contract tests: ok'
