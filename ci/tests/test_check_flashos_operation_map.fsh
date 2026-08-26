#!/usr/bin/env fsh
# Exercise the native FlashOS operation-map validator as a black box.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'FlashOS operation map tests: FAILED: %s\n' $message 1>&2
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
    let observation = {code: $result.code, stdout: "$stdout", stderr: "$stderr"}
    return $observation
}

def expect_success(result, label) {
    let stdout_path = $result.stdout
    let stderr_path = $result.stderr
    let observed_stdout = "$(^cat $stdout_path)"
    let observed_stderr = "$(^cat $stderr_path)"
    let expected = 'FlashOS operation map: mapping contract passed for x86_64-unknown-redox'
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
let temporary = "$(^mktemp -d "$temporary_parent/flashos-operation-map-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let tracked = run_validator($runtime, "$root/ci/check_flashos_operation_map.fsh", $root, $temporary, 'tracked')
expect_success($tracked, 'tracked operation map')

let classified = prepare_candidate($root, $temporary, 'classified-map')
let classified_source = "$classified/components/flash/platforms/flashos-x86_64-operation-map.toml"
rewrite($classified_source, '/^id = "environment-snapshot"$/,/^classification = "deferred"$/ s/classification = "deferred"/classification = "native"/', "$temporary/classified.toml", 'cannot classify mapped operation')
let classified_result = run_validator($runtime, "$classified/ci/check_flashos_operation_map.fsh", $classified, $temporary, 'classified-result')
expect_failure($classified_result, "classification must remain 'deferred'", 'classification in operation map')

let inferred = prepare_candidate($root, $temporary, 'inferred-symbol')
let inferred_source = "$inferred/components/flash/platforms/flashos-x86_64-operation-map.toml"
rewrite($inferred_source, '/^id = "rust-environment"$/,/^observation =/ s/symbols = \[\]/symbols = ["getenv"]/', "$temporary/inferred.toml", 'cannot infer Rust ABI symbol')
let inferred_result = run_validator($runtime, "$inferred/ci/check_flashos_operation_map.fsh", $inferred, $temporary, 'inferred-result')
expect_failure($inferred_result, 'must preserve the unknown Rust source boundary', 'inferred Rust ABI symbol')

let marker = prepare_candidate($root, $temporary, 'missing-marker')
let marker_source = "$marker/components/flash/platforms/flashos-x86_64-operation-map.toml"
rewrite($marker_source, '/^id = "rust-environment"$/,/^observation =/ s/tracked_markers = .*/tracked_markers = ["missing marker"]/', "$temporary/marker.toml", 'cannot mutate tracked seam marker')
let marker_result = run_validator($runtime, "$marker/ci/check_flashos_operation_map.fsh", $marker, $temporary, 'marker-result')
expect_failure($marker_result, 'marker is absent', 'missing tracked seam marker')

let unrouted = prepare_candidate($root, $temporary, 'unrouted-seam')
let unrouted_source = "$unrouted/components/flash/platforms/flashos-x86_64-operation-map.toml"
rewrite($unrouted_source, '/^id = "environment-snapshot"$/,/^mapping_observation =/ { s/abi_seams = .*/abi_seams = ["rust-filesystem"]/; s/boundary = "rust-std"/boundary = "unrouted"/; }', "$temporary/unrouted.toml", 'cannot attach seam to unrouted operation')
let unrouted_result = run_validator($runtime, "$unrouted/ci/check_flashos_operation_map.fsh", $unrouted, $temporary, 'unrouted-result')
expect_failure($unrouted_result, "boundary 'unrouted' must not name an ABI seam", 'unrouted operation with ABI seam')

^rm -rf $temporary
^printf '%s\n' 'FlashOS operation map tests: ok'
