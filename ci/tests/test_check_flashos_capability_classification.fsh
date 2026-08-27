#!/usr/bin/env fsh
# Exercise the native FlashOS capability-classification validator as a black box.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'FlashOS capability classification tests: FAILED: %s\n' $message 1>&2
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
    let expected = 'FlashOS capability classification: contract passed for x86_64-unknown-redox'
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
let temporary = "$(^mktemp -d "$temporary_parent/flashos-capability-classification-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }

let tracked = run_validator($runtime, "$root/ci/check_flashos_capability_classification.fsh", $root, $temporary, 'tracked')
expect_success($tracked, 'tracked capability classification')

let unrouted = prepare_candidate($root, $temporary, 'unrouted-native')
let unrouted_source = "$unrouted/components/flash/platforms/flashos-x86_64-capability-classification.toml"
rewrite($unrouted_source, '/^id = "directories-discover"$/,/^rationale =/ { s/classification = "shimmed"/classification = "native"/; s/basis = "flashos-policy-shim"/basis = "existing-rust-std-route"/; }', "$temporary/unrouted.toml", 'cannot mutate unrouted operation')
let unrouted_map = "$unrouted/components/flash/platforms/flashos-x86_64-operation-map.toml"
rewrite($unrouted_map, '/^id = "directories-discover"$/,/^mapping_observation =/ s/boundary = "flash-internal"/boundary = "unrouted"/', "$temporary/unrouted-map.toml", 'cannot mutate operation-map boundary')
let unrouted_result = run_validator($runtime, "$unrouted/ci/check_flashos_capability_classification.fsh", $unrouted, $temporary, 'unrouted-result')
expect_failure($unrouted_result, 'cannot classify an unrouted operation as native', 'unrouted native operation')

let aggregate = prepare_candidate($root, $temporary, 'aggregate')
let aggregate_source = "$aggregate/components/flash/platforms/flashos-x86_64-capability-classification.toml"
rewrite($aggregate_source, '/^name = "standard-directories"$/,/^rationale =/ s/classification = "shimmed"/classification = "native"/', "$temporary/aggregate.toml", 'cannot mutate capability aggregate')
let aggregate_result = run_validator($runtime, "$aggregate/ci/check_flashos_capability_classification.fsh", $aggregate, $temporary, 'aggregate-result')
expect_failure($aggregate_result, 'classification does not match its operation aggregate', 'capability aggregate')

let qualified = prepare_candidate($root, $temporary, 'qualified')
let qualified_source = "$qualified/components/flash/platforms/flashos-x86_64-capability-classification.toml"
rewrite($qualified_source, '/^\[\[capability\]\]$/,/^rationale =/ s/target_qualification = "pending"/target_qualification = "qualified"/', "$temporary/qualified.toml", 'cannot mutate target qualification')
let qualified_result = run_validator($runtime, "$qualified/ci/check_flashos_capability_classification.fsh", $qualified, $temporary, 'qualified-result')
expect_failure($qualified_result, "target_qualification must remain 'pending'", 'advanced target qualification')

let completed_map = prepare_candidate($root, $temporary, 'completed-map')
let map_source = "$completed_map/components/flash/platforms/flashos-x86_64-operation-map.toml"
rewrite($map_source, 's/classification = "deferred"/classification = "complete"/g', "$temporary/completed-map.toml", 'cannot mutate operation-map classification')
let map_result = run_validator($runtime, "$completed_map/ci/check_flashos_capability_classification.fsh", $completed_map, $temporary, 'completed-map-result')
expect_failure($map_result, 'operation map classification must remain deferred', 'completed operation map')

^rm -rf $temporary
^printf '%s\n' 'FlashOS capability classification tests: ok'
