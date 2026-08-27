#!/usr/bin/env fsh
# Exercise the native target-matrix renderer through its public CLI. The same
# black-box root runs with the immutable bootstrap and candidate runtimes.

import { repository_root } from '../lib/repository.fsh'
import { require_jq, require_rg } from '../lib/tools.fsh'

def test_error(message) {
    ^printf 'FlashOS target matrix tests: FAILED: %s\n' $message 1>&2
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
let script = "$root/ci/flashos_target_matrix.fsh"
let matrix_source = "$root/components/flash/platforms/flashos-x86_64-target-matrix-v1.toml"
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flashos-target-matrix-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let boundary_result = run_renderer($runtime, $script, $temporary, 'boundary', ['--output', 'json-v1'])
let boundary = expect_success($boundary_result, 'tracked JSON boundary')
expect_projection($jq, $boundary, '.boundary_schema', '1', 'boundary schema')
expect_projection($jq, $boundary, '.consumers|@json', '["qemu","operator-observed-target"]', 'consumers')
expect_projection($jq, $boundary, '.max_interaction_bytes', '16', 'interaction boundary')
expect_projection($jq, $boundary, '.script_transport_chunk_bytes', '16', 'UART script chunk boundary')
expect_projection($jq, $boundary, '.cases|length', '13', 'case count')
expect_projection($jq, $boundary, '.cases[]|select(.id=="argv-environment-pipelines-and-redirections")|.steps[0]|(.payload.text|contains("argv ok")) and (.payload.text|contains("matrix.txt")) and (.expected|map(.text)|any(contains("<argv ok>"))) and (.expected|map(.text)|any(contains("onetwo")))', 'true', 'argv and redirection markers')
expect_projection($jq, $boundary, '.cases[]|select(.id=="dynamic-capture-error-and-status-language")|.steps[0]|(.payload.text|contains("dynamic-ok")) and (.expected|map(.text)|any(contains("dynamic-ok")))', 'true', 'dynamic output markers')
expect_projection($jq, $boundary, '.cases[]|select(.id=="directory-glob-and-grammar-completion")|.steps[0]|(.payload.text|contains("...$matches")) and (.expected|map(.text)|any(contains("a.fsh,"))) and (.expected|map(.text)|any(contains("b.fsh,")))', 'true', 'glob output markers')

let text_result = run_renderer($runtime, $script, $temporary, 'text', [])
let text_path = expect_success($text_result, 'tracked text rendering')
let rendered = "$(^cat $text_path)"
for marker in [
'startup-and-working-directory',
'config-options-and-capture-cleanup',
'argv-environment-pipelines-and-redirections',
'directory-glob-and-grammar-completion',
'history-completion-cancellation-and-unicode',
'v1-functions-modules-and-intrinsics',
'v1-language-server',
'<Ctrl-C>',
'<Tab>',
'<Up>',
'á界',
'     | echo config-created',
] {
    if !($marker in $rendered) { test_error("text rendering lacks '$marker'") }
}

let duplicate = "$temporary/duplicate.toml"
^sed 's/id = "config-options-and-capture-cleanup"/id = "startup-and-working-directory"/' $matrix_source > $duplicate
if !$status.ok { test_error('cannot create duplicate-id matrix mutation') }
let duplicate_result = run_renderer($runtime, $script, $temporary, 'duplicate', ['--matrix', $duplicate, '--output', 'json-v1'])
expect_failure($duplicate_result, 'case ids contain duplicates', 'duplicate case id')

let missing_rendered = "$temporary/missing-rendered.toml"
^env $rg --invert-match --fixed-strings 'rendered = ">> cd /home/user"' $matrix_source > $missing_rendered
if !$status.ok { test_error('cannot create missing-rendered matrix mutation') }
let missing_result = run_renderer($runtime, $script, $temporary, 'missing-rendered', ['--matrix', $missing_rendered, '--output', 'json-v1'])
expect_failure($missing_result, 'rendered is required for line input', 'line step without rendered row')

^rm -rf $temporary
^printf '%s\n' 'FlashOS target matrix tests: ok'
