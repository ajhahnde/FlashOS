#!/usr/bin/env fsh
# Exercise the native change classifier through its public CLI. The same root
# runs with the immutable bootstrap and the workspace candidate runtimes.

import { repository_root } from '../lib/repository.fsh'
import { require_jq } from '../lib/tools.fsh'

def test_error(message) {
    ^printf 'change classification tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_success(runtime, script, jq, temporary, label, arguments) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    ^env "FLASH_AUTOMATION_JQ=$jq" $runtime $script --json ...$arguments > $stdout 2> $stderr
    let result = $status
    let observed_stderr = "$(^cat $stderr)"
    if $result.code != 0 || $observed_stderr != '' {
        test_error("$label expected success, observed status ${$result.code}, stderr '$observed_stderr'")
    }
    return $stdout
}

def expect_projection(jq, document, query, expected, label) {
    let observed = "$(^env $jq --compact-output --raw-output $query $document 2>/dev/null)"
    if !$status.ok || $observed != $expected {
        test_error("$label differs: observed '$observed', expected '$expected'")
    }
}

def expect_failure(runtime, script, jq, temporary, label, argument) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    ^env "FLASH_AUTOMATION_JQ=$jq" $runtime $script --json $argument > $stdout 2> $stderr
    let result = $status
    let observed_stdout = "$(^cat $stdout)"
    let observed_stderr = "$(^cat $stderr)"
    if $result.code != 2 || $observed_stdout != '' || !('invalid repository-relative path' in $observed_stderr) {
        test_error("$label did not reject '$argument': status ${$result.code}, stdout '$observed_stdout', stderr '$observed_stderr'")
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
let script = "$root/ci/classify_changes.fsh"
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flash-classify-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let fast = run_success($runtime, $script, $jq, $temporary, 'fast', [
'docs/verification.md',
'CHANGELOG.md',
'.github/SECURITY.md',
'.github/dependabot.yml',
'flashos.sh',
'flashos.zsh',
'components/flash/docs/reference.md',
])
expect_projection($jq, $fast, '.lane', 'fast', 'fast lane')
expect_projection($jq, $fast, '.image_required', 'false', 'fast image decision')
expect_projection($jq, $fast, '.target_required', 'false', 'fast target decision')
expect_projection($jq, $fast, '.security_required', 'true', 'fast security decision')

let adjacent = run_success($runtime, $script, $jq, $temporary, 'adjacent', ['components/flash/docs/generated.json'])
expect_projection($jq, $adjacent, '.lane', 'product', 'source-adjacent lane')
expect_projection($jq, $adjacent, '.image_required', 'true', 'source-adjacent image decision')

for path in ['components/flash/crates/flash-cli/src/main.rs', 'recipes/groups/auto-test/auto-test.fsh'] {
    let target = run_success($runtime, $script, $jq, $temporary, 'target', [$path])
    expect_projection($jq, $target, '.lane', 'product', "target lane for $path")
    expect_projection($jq, $target, '.target_required', 'true', "target decision for $path")
}
for path in ['.github/workflows/ci.yml', 'ci/classify_changes.fsh', 'future/subsystem/input.bin'] {
    let product = run_success($runtime, $script, $jq, $temporary, 'product', [$path])
    expect_projection($jq, $product, '.lane', 'product', "product lane for $path")
    expect_projection($jq, $product, '.image_required', 'true', "product image decision for $path")
}

let empty_stdout = "$temporary/empty.stdout"
let empty_stderr = "$temporary/empty.stderr"
^env "FLASH_AUTOMATION_JQ=$jq" $runtime $script --json < /dev/null > $empty_stdout 2> $empty_stderr
let empty_status = $status
if $empty_status.code != 0 || "$(^cat $empty_stderr)" != '' { test_error('empty input was not classified successfully') }
expect_projection($jq, $empty_stdout, '.lane', 'product', 'empty input lane')
expect_projection($jq, $empty_stdout, '.image_required', 'true', 'empty input image decision')
expect_projection($jq, $empty_stdout, '.target_required', 'true', 'empty input target decision')

let mixed = run_success($runtime, $script, $jq, $temporary, 'mixed', ['docs/verification.md', 'recipes/core/kernel/recipe.toml'])
expect_projection($jq, $mixed, '.lane', 'product', 'mixed lane')
expect_projection($jq, $mixed, '.image_required', 'true', 'mixed image decision')

for path in ['Cargo.lock', 'components/flash/crates/flash-cli/Cargo.toml', '.github/workflows/security.yml'] {
    let security = run_success($runtime, $script, $jq, $temporary, 'security', [$path])
    expect_projection($jq, $security, '.security_required', 'true', "security decision for $path")
}
let documentation = run_success($runtime, $script, $jq, $temporary, 'documentation', ['docs/verification.md'])
expect_projection($jq, $documentation, '.security_required', 'false', 'documentation security decision')

let normalized = run_success($runtime, $script, $jq, $temporary, 'normalized', ['./docs/z.md', 'docs/a.md', 'docs/a.md'])
expect_projection($jq, $normalized, '.paths', '["docs/a.md","docs/z.md"]', 'normalized paths')

let large_input = "$temporary/large.input"
let large_stdout = "$temporary/large.stdout"
let large_stderr = "$temporary/large.stderr"
mut large_index = 0
while $large_index < 192 {
    ^printf 'future/generated-%03d.bin\0' $large_index >> $large_input
    $large_index = $large_index + 1
}
^env "FLASH_AUTOMATION_JQ=$jq" $runtime $script --json --null < $large_input > $large_stdout 2> $large_stderr
let large_status = $status
if $large_status.code != 0 || "$(^cat $large_stderr)" != '' {
    test_error("large path set exceeded bounded classification: status ${$large_status.code}, stderr '$(^cat $large_stderr)'")
}
expect_projection($jq, $large_stdout, '.paths | length', '192', 'large path count')
expect_projection($jq, $large_stdout, '.lane', 'product', 'large path lane')

expect_failure($runtime, $script, $jq, $temporary, 'parent', '../outside')
expect_failure($runtime, $script, $jq, $temporary, 'absolute', '/absolute')

let github_output = "$temporary/github-output"
let github_summary = "$temporary/github-summary"
let github_stdout = "$temporary/github.stdout"
let github_stderr = "$temporary/github.stderr"
^env \
"FLASH_AUTOMATION_JQ=$jq" \
"GITHUB_OUTPUT=$github_output" \
"GITHUB_STEP_SUMMARY=$github_summary" \
$runtime $script 'docs/verification.md' > $github_stdout 2> $github_stderr
let github_status = $status
let output_text = "$(^cat $github_output)"
let summary_text = "$(^cat $github_summary)"
if $github_status.code != 0 || "$(^cat $github_stdout)" != '' || "$(^cat $github_stderr)" != '' {
    test_error('GitHub output mode did not complete silently')
}
for marker in ['lane=fast', 'image_required=false', 'classification=', '"schema":1'] {
    if !($marker in $output_text) { test_error("GitHub output lacks '$marker'") }
}
if !('lane: `fast`' in $summary_text) { test_error('GitHub summary lacks the fast lane') }

^rm -rf $temporary
^printf '%s\n' 'change classification tests: ok'
