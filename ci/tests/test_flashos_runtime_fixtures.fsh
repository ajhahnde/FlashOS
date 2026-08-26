#!/usr/bin/env fsh
# Exercise the native runtime-fixture renderer through its public CLI. The
# selected runtime is explicit so this root qualifies bootstrap and candidate.

import { repository_root } from '../lib/repository.fsh'
import { require_jq, require_rg } from '../lib/tools.fsh'

def test_error(message) {
    ^printf 'FlashOS runtime fixture tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_renderer(runtime, script, temporary, label, arguments) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    ^$runtime $script ...$arguments > $stdout 2> $stderr
    let result = $status
    let observation = {
        code: $result.code,
        stdout: "$stdout",
        stderr: "$stderr",
    }
    return $observation
}

def expect_success(result, label) {
    let stderr_path = $result.stderr
    let observed_stderr = "$(^cat $stderr_path)"
    if $result.code != 0 || $observed_stderr != '' {
        test_error("$label expected success, observed status ${$result.code}, stderr '$observed_stderr'")
    }
    return $result.stdout
}

def expect_projection(jq, document, query, expected, label) {
    let observed = "$(^env $jq --compact-output --raw-output $query $document 2>/dev/null)"
    if !$status.ok || $observed != $expected {
        test_error("$label differs: observed '$observed', expected '$expected'")
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
let rg = require_rg()
let script = "$root/ci/flashos_runtime_fixtures.fsh"
let fixture_source = "$root/components/flash/platforms/flashos-x86_64-runtime-fixtures-v1.toml"
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flashos-runtime-fixture-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let boundary_result = run_renderer($runtime, $script, $temporary, 'boundary', ['--output', 'json-v1'])
let boundary = expect_success($boundary_result, 'tracked JSON boundary')
expect_projection($jq, $boundary, '.boundary_schema', '1', 'boundary schema')
expect_projection($jq, $boundary, '.consumers|@json', '["qemu","real-system"]', 'consumers')
expect_projection($jq, $boundary, '.max_interaction_bytes', '16', 'interaction boundary')
expect_projection($jq, $boundary, '.fixtures|length', '6', 'fixture count')
expect_projection($jq, $boundary, '.fixtures[]|select(.id=="background-child")|[.steps[0].payload.text,.steps[1].payload.text]|@json', '["^sleep 9&","wait %4"]', 'background child wait window')
expect_projection($jq, $boundary, '.fixtures[]|select(.id=="background-supervisor")|[.steps[0].payload.text,.steps[1].payload.text]|@json', '["^sleep 9&&true&","wait %5"]', 'background supervisor wait window')

let text_result = run_renderer($runtime, $script, $temporary, 'text', [])
let text_path = expect_success($text_result, 'tracked text rendering')
let rendered = "$(^cat $text_path)"
for marker in [
'interactive-editing',
'working-directory-script',
'external-pipeline',
'structured-directory',
'background-child',
'background-supervisor',
'Enter: pwz<Backspace>d',
] {
    if !($marker in $rendered) { test_error("text rendering lacks '$marker'") }
}

let oversized = "$temporary/oversized.toml"
^sed 's/input_hex = "70777a7f64"/input_hex = "61616161616161616161616161616161"/' $fixture_source > $oversized
if !$status.ok { test_error('cannot create oversized fixture mutation') }
let oversized_result = run_renderer($runtime, $script, $temporary, 'oversized', ['--fixtures', $oversized, '--output', 'json-v1'])
expect_failure($oversized_result, 'exceeds the 16-byte interaction limit', 'oversized interaction')

let duplicate = "$temporary/duplicate.toml"
^sed 's/id = "working-directory-script"/id = "interactive-editing"/' $fixture_source > $duplicate
if !$status.ok { test_error('cannot create duplicate-id fixture mutation') }
let duplicate_result = run_renderer($runtime, $script, $temporary, 'duplicate', ['--fixtures', $duplicate, '--output', 'json-v1'])
expect_failure($duplicate_result, 'fixture ids contain duplicates', 'duplicate fixture id')

^rm -rf $temporary
^printf '%s\n' 'FlashOS runtime fixture tests: ok'
