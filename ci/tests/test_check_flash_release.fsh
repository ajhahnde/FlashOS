#!/usr/bin/env fsh
# Exercise the native Flash v1 release validator as a black box. The selected
# runtime is explicit so this root qualifies bootstrap and candidate.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'Flash release contract tests: FAILED: %s\n' $message 1>&2
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
    if $result.code != 0 || $observed_stdout != 'Flash release: 1.0.0 contract passed' || $observed_stderr != '' {
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
    ^mkdir -p "$candidate/components/flash/fuzz"
    if !$status.ok { test_error("cannot create $label candidate") }
    ^cp "$root/versions.env" "$candidate/"
    if !$status.ok { test_error("cannot copy $label version marker") }
    ^cp -R "$root/.github" "$candidate/"
    if !$status.ok { test_error("cannot copy $label workflow sources") }
    ^cp -R "$root/ci" "$candidate/"
    if !$status.ok { test_error("cannot copy $label CI sources") }
    ^cp -R "$root/docs" "$candidate/"
    if !$status.ok { test_error("cannot copy $label product claims") }
    for source in ['Cargo.toml', 'Cargo.lock', 'CHANGELOG.md', 'README.md'] {
        ^cp "$root/components/flash/$source" "$candidate/components/flash/"
        if !$status.ok { test_error("cannot copy $label Flash $source") }
    }
    for directory in ['conformance', 'docs', 'exercises', 'platforms', 'release'] {
        ^cp -R "$root/components/flash/$directory" "$candidate/components/flash/"
        if !$status.ok { test_error("cannot copy $label Flash $directory") }
    }
    ^cp "$root/components/flash/fuzz/Cargo.lock" "$candidate/components/flash/fuzz/"
    if !$status.ok { test_error("cannot copy $label fuzz lock") }
    return $candidate
}

def mutate(candidate, expression, temporary) {
    let source = "$candidate/components/flash/release/v1.toml"
    let rewritten = "$temporary/rewritten-release"
    ^sed $expression $source > $rewritten
    if !$status.ok { test_error('cannot mutate the release record') }
    ^mv $rewritten $source
    if !$status.ok { test_error('cannot install the release mutation') }
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
let temporary = "$(^mktemp -d "$temporary_parent/flash-release-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let tracked = run_validator($runtime, "$root/ci/check_flash_release.fsh", $root, $temporary, 'tracked')
expect_success($tracked, 'tracked release record')

let candidate_status = prepare_candidate($root, $temporary, 'candidate-status')
mutate($candidate_status, 's/status = "released"/status = "candidate"/', $temporary)
let status_result = run_validator($runtime, "$candidate_status/ci/check_flash_release.fsh", $candidate_status, $temporary, 'candidate-status-result')
expect_failure($status_result, "status must be 'released'", 'candidate release status')

let finding = prepare_candidate($root, $temporary, 'release-finding')
mutate($finding, 's/release_findings = \[\]/release_findings = ["critical-runtime-finding"]/', $temporary)
let finding_result = run_validator($runtime, "$finding/ci/check_flash_release.fsh", $finding, $temporary, 'release-finding-result')
expect_failure($finding_result, 'release_findings must be empty', 'release finding')

let unexamined = prepare_candidate($root, $temporary, 'unexamined-item')
mutate($unexamined, 's/unexamined_inventory_items = \[\]/unexamined_inventory_items = ["missing-user-path"]/', $temporary)
let unexamined_result = run_validator($runtime, "$unexamined/ci/check_flash_release.fsh", $unexamined, $temporary, 'unexamined-item-result')
expect_failure($unexamined_result, 'unexamined_inventory_items must be empty', 'unexamined inventory item')

let product_claim = prepare_candidate($root, $temporary, 'product-claim')
mutate($product_claim, 's/FlashOS product versions, images, tags, and publication remain separate release boundaries\./FlashOS is also released./', $temporary)
let product_result = run_validator($runtime, "$product_claim/ci/check_flash_release.fsh", $product_claim, $temporary, 'product-claim-result')
expect_failure($product_result, 'limitations must preserve exact product-release and physical boundaries', 'FlashOS product release claim')

^rm -rf $temporary
^printf '%s\n' 'Flash release contract tests: ok'
