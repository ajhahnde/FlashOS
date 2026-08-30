#!/usr/bin/env fsh
# Exercise the native CI aggregate as a black box. The selected runtime is
# explicit so this same test root can qualify both bootstrap and candidate fsh.

import { repository_root } from '../lib/repository.fsh'
import { require_jq } from '../lib/tools.fsh'

def test_error(message) {
    ^printf 'CI aggregate tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_case(runtime, script, jq, temporary, label, event, draft, classification_lane, lane, image_required, target_required, image_result, scope_result, root_result, shell_result) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    let classification = "{\"schema\":1,\"lane\":\"$classification_lane\",\"image_required\":$image_required,\"target_required\":$target_required,\"reasons\":[\"test classification\"]}"
    ^env \
    "FLASH_AUTOMATION_JQ=$jq" \
    "EVENT_NAME=$event" \
    "PR_DRAFT=$draft" \
    "SCOPE_RESULT=$scope_result" \
    "LANE=$lane" \
    "IMAGE_REQUIRED=$image_required" \
    "TARGET_REQUIRED=$target_required" \
    "CLASSIFICATION=$classification" \
    "ROOT_RESULT=$root_result" \
    "SHELL_RESULT=$shell_result" \
    "IMAGE_RESULT=$image_result" \
    $runtime $script > $stdout 2> $stderr
    let result = $status
    let observed_stdout = "$(^cat $stdout)"
    let observed_stderr = "$(^cat $stderr)"
    let observation = {
        code: $result.code,
        stdout: $observed_stdout,
        stderr: $observed_stderr,
    }
    return $observation
}

def expect_success(result, label) {
    if $result.code != 0 || $result.stdout != 'CI aggregate: ok' || $result.stderr != '' {
        test_error("$label expected success, observed status ${$result.code}, stdout '${$result.stdout}', stderr '${$result.stderr}'")
    }
}

def expect_failure(result, marker, label) {
    if $result.code != 1 || !($marker in $result.stderr) {
        test_error("$label expected failure containing '$marker', observed status ${$result.code}, stderr '${$result.stderr}'")
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
let script = "$root/ci/aggregate_ci.fsh"
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flash-aggregate-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let product = run_case($runtime, $script, $jq, $temporary, 'product', 'pull_request', 'false', 'product', 'product', 'true', 'true', 'success', 'success', 'success', 'success')
expect_success($product, 'product lane')
for image in ['skipped', 'failure', 'cancelled'] {
    let rejected = run_case($runtime, $script, $jq, $temporary, "product-$image", 'pull_request', 'false', 'product', 'product', 'true', 'true', $image, 'success', 'success', 'success')
    expect_failure($rejected, 'requires successful product qualification', "product image $image")
}

let fast = run_case($runtime, $script, $jq, $temporary, 'fast', 'pull_request', 'false', 'fast', 'fast', 'false', 'false', 'skipped', 'success', 'success', 'success')
expect_success($fast, 'fast lane controlled image skip')
let source = run_case($runtime, $script, $jq, $temporary, 'source', 'pull_request', 'false', 'source', 'source', 'false', 'false', 'skipped', 'success', 'success', 'success')
expect_success($source, 'source lane controlled image skip')
let contrary = run_case($runtime, $script, $jq, $temporary, 'fast-contrary', 'pull_request', 'false', 'fast', 'fast', 'false', 'false', 'success', 'success', 'success', 'success')
expect_failure($contrary, 'ran contrary', 'fast lane image execution')

let draft = run_case($runtime, $script, $jq, $temporary, 'draft', 'pull_request', 'true', 'product', 'product', 'true', 'true', 'skipped', 'success', 'success', 'success')
expect_success($draft, 'draft product deferral')
let manual = run_case($runtime, $script, $jq, $temporary, 'manual', 'workflow_dispatch', 'true', 'product', 'product', 'true', 'true', 'skipped', 'success', 'success', 'success')
expect_failure($manual, 'requires successful product qualification', 'manual product image skip')

let scope_failed = run_case($runtime, $script, $jq, $temporary, 'scope-failed', 'pull_request', 'false', 'product', 'product', 'true', 'true', 'success', 'failure', 'success', 'success')
expect_failure($scope_failed, 'change classification failed', 'failed classification gate')
let root_failed = run_case($runtime, $script, $jq, $temporary, 'root-failed', 'pull_request', 'false', 'product', 'product', 'true', 'true', 'success', 'success', 'failure', 'success')
expect_failure($root_failed, 'required source gates failed', 'failed root gate')
let flash_failed = run_case($runtime, $script, $jq, $temporary, 'flash-failed', 'pull_request', 'false', 'product', 'product', 'true', 'true', 'success', 'success', 'success', 'failure')
expect_failure($flash_failed, 'required source gates failed', 'failed Flash gate')

let disagree = run_case($runtime, $script, $jq, $temporary, 'disagree', 'pull_request', 'false', 'product', 'fast', 'true', 'true', 'success', 'success', 'success', 'success')
expect_failure($disagree, 'disagree', 'payload and job output mismatch')

^rm -rf $temporary
^printf '%s\n' 'CI aggregate tests: ok'
