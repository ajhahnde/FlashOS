#!/usr/bin/env fsh
# Exercise the native benchmark policy through its public CLI. The same
# black-box root runs with the immutable bootstrap and candidate runtimes.

import { repository_root } from '../lib/repository.fsh'
import { require_jq } from '../lib/tools.fsh'

def test_error(message) {
    ^printf 'Flash benchmark contract tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_checker(runtime, script, temporary, label, arguments) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    ^$runtime $script ...$arguments > $stdout 2> $stderr
    let result = $status
    let observation = {
        code: $result.code,
        stdout: "$(^cat $stdout)",
        stderr: "$(^cat $stderr)",
    }
    return $observation
}

def expect_success(result, expected_stdout, label) {
    if $result.code != 0 || $result.stdout != $expected_stdout || $result.stderr != '' {
        test_error("$label expected success, observed status ${$result.code}, stdout '${$result.stdout}', stderr '${$result.stderr}'")
    }
}

def expect_failure(result, code, marker, label) {
    if $result.code != $code || !($marker in $result.stderr) {
        test_error("$label expected status $code containing '$marker', observed status ${$result.code}, stdout '${$result.stdout}', stderr '${$result.stderr}'")
    }
}

def expect_projection(jq, document, query, expected, label) {
    let observed = "$(^env $jq --raw-output $query $document 2>/dev/null)"
    if !$status.ok || $observed != $expected {
        test_error("$label differs: observed '$observed', expected '$expected'")
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
let script = "$root/ci/flash_benchmarks.fsh"
let evidence = "$root/components/flash/benchmarks/evidence"
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flash-benchmark-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let tracked = run_checker($runtime, $script, $temporary, 'tracked', [])
expect_success($tracked, 'Flash benchmark contract: ok', 'tracked contract, results, and budgets')
for result in [
"$evidence/host-darwin-arm64-v1.json",
"$evidence/flashos-qemu-tcg-v1.json",
] {
    let label = "result-${$(^basename $result)}"
    let validated = run_checker($runtime, $script, $temporary, $label, ['--result', $result])
    expect_success($validated, 'Flash benchmark contract: ok', "tracked result ${$(^basename $result)}")
}

let boundary_result = run_checker($runtime, $script, $temporary, 'boundary', ['--contract-json-v1'])
if $boundary_result.code != 0 || $boundary_result.stderr != '' {
    test_error("contract boundary expected success, observed status ${$boundary_result.code}, stderr '${$boundary_result.stderr}'")
}
let boundary = "$temporary/boundary.stdout"
expect_projection($jq, $boundary, '.boundary_schema', '1', 'boundary schema')
expect_projection($jq, $boundary, '.kind', 'flash-benchmark-contract', 'boundary kind')
expect_projection($jq, $boundary, '.result_schema', 'flash-performance-result-v1', 'result schema')
expect_projection($jq, $boundary, '.contract_sha256 | length', '64', 'contract digest length')

let host = "$evidence/host-darwin-arm64-v1.json"
let drifted = "$temporary/summary-drift.json"
^env $jq '.measurements[0].summary.p95 += 1' $host > $drifted
if !$status.ok { test_error('cannot create summary-drift result') }
let drift = run_checker($runtime, $script, $temporary, 'summary-drift', ['--result', $drifted])
expect_failure($drift, 1, 'summary drifted', 'summary drift')

let regression = "$temporary/regression.json"
^env $jq '.measurements[0].samples = [1000000000000] | .measurements[0].summary = {minimum:1000000000000, median:1000000000000, p95:1000000000000, maximum:1000000000000}' $host > $regression
if !$status.ok { test_error('cannot create benchmark regression result') }
let regressed = run_checker($runtime, $script, $temporary, 'regression', ['--evaluate', $regression, '--environment', 'host-darwin-arm64'])
expect_failure($regressed, 1, 'performance regressions', 'budget regression')

let missing = run_checker($runtime, $script, $temporary, 'missing-result', ['--result'])
expect_failure($missing, 2, 'argument --result: expected one argument', 'missing result argument')

^rm -rf $temporary
^printf '%s\n' 'Flash benchmark contract tests: ok'
