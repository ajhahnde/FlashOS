#!/usr/bin/env fsh
# Exercise the native release-candidate validator through exact temporary
# bundles, identity mutations, compression substitution, and selection data.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'release candidate tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_candidate(runtime, script, temporary, label, arguments, path) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    ^env "TMPDIR=$temporary" "PATH=$path" $runtime $script ...$arguments > $stdout 2> $stderr
    let result = $status
    let observation = {code: $result.code, stdout: "$stdout", stderr: "$stderr"}
    return $observation
}

def expect_success(result, expected, label) {
    let stdout_path = $result.stdout
    let stderr_path = $result.stderr
    let observed_stdout = "$(^cat $stdout_path)"
    let observed_stderr = "$(^cat $stderr_path)"
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

def sha256(path) {
    mut digest = "$(^shasum -a 256 $path | ^cut -d ' ' -f 1)"
    if !$status.ok || $digest == '' {
        $digest = "$(^sha256sum $path | ^cut -d ' ' -f 1)"
    }
    if !$status.ok || $digest == '' { test_error("cannot hash $path") }
    return $digest
}

def payload_names() {
    [
    'FlashOS-0.2.0-image.cdx.json',
    'FlashOS-0.2.0-release-notes.md',
    'FlashOS-0.2.0-source.cdx.json',
    'FlashOS-0.2.0-x86_64-harddrive.img.zst',
    'FlashOS-0.2.0-x86_64-live.iso.zst',
    'cookbook.lock',
    'qemu-harddrive-performance.json',
    'qemu-harddrive-smoke.log',
    'qemu-live-usb-smoke.log',
    'qemu-results.json',
    ]
}

def write_checksums(bundle) {
    let sums = "$bundle/SHA256SUMS"
    ^printf '%s' '' > $sums
    for name in payload_names() {
        let digest = sha256("$bundle/$name")
        ^printf '%s  %s\n' $digest $name >> $sums
        if !$status.ok { test_error('cannot write checksum fixture') }
    }
}

def prepare_bundle(temporary, label, attempt) {
    let bundle = "$temporary/$label"
    ^mkdir -p $bundle
    if !$status.ok { test_error("cannot create $label bundle") }
    ^printf '%s' '{}' > "$bundle/FlashOS-0.2.0-image.cdx.json"
    ^printf '%s' 'notes' > "$bundle/FlashOS-0.2.0-release-notes.md"
    ^printf '%s' '{}' > "$bundle/FlashOS-0.2.0-source.cdx.json"
    ^printf '%s' 'disk' > "$bundle/FlashOS-0.2.0-x86_64-harddrive.img.zst"
    ^printf '%s' 'live' > "$bundle/FlashOS-0.2.0-x86_64-live.iso.zst"
    ^printf '%s' '# generated build resolution' > "$bundle/cookbook.lock"
    ^printf '%s' '{}' > "$bundle/qemu-harddrive-performance.json"
    ^printf '%s' 'disk ok' > "$bundle/qemu-harddrive-smoke.log"
    ^printf '%s' 'live ok' > "$bundle/qemu-live-usb-smoke.log"
    let commit = '1111111111111111111111111111111111111111'
    let qemu = "{\"schema\":1,\"source_commit\":\"$commit\",\"harddrive\":{\"interface\":\"nvme\",\"result\":\"success\",\"attempt\":$attempt,\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"log\":\"qemu-harddrive-smoke.log\"},\"live\":{\"interface\":\"usb\",\"result\":\"success\",\"attempt\":1,\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"log\":\"qemu-live-usb-smoke.log\"}}"
    ^printf '%s\n' $qemu > "$bundle/qemu-results.json"
    if !$status.ok { test_error("cannot write $label bundle") }
    write_checksums($bundle)
    return $bundle
}

def create_arguments(source_root, bundle) {
    [
    'create', '--root', $source_root, '--bundle', $bundle, '--version', '0.2.0',
    '--repository', 'example/FlashOS',
    '--source-commit', '1111111111111111111111111111111111111111',
    '--source-tree', '2222222222222222222222222222222222222222',
    '--run-id', '123', '--run-attempt', '2',
    '--required-run-id', '120', '--security-run-id', '121',
    ]
}

def validate_arguments(source_root, bundle) {
    [
    'validate', '--root', $source_root, '--bundle', $bundle, '--repository', 'example/FlashOS',
    '--version', '0.2.0',
    '--source-commit', '1111111111111111111111111111111111111111',
    '--source-tree', '2222222222222222222222222222222222222222',
    '--run-id', '123', '--run-attempt', '2', '--tag', 'v0.2.0',
    ]
}

let root = repository_root('versions.env')
let runtime_value = env('FLASH_AUTOMATION_RUNTIME')
if $runtime_value == null || $runtime_value == '' { test_error('FLASH_AUTOMATION_RUNTIME is required') }
let runtime = $runtime_value
if "$(^$runtime --version 2>/dev/null)" != 'fsh 1.0.0' { test_error('FLASH_AUTOMATION_RUNTIME must report fsh 1.0.0') }
let path_value = env('PATH')
if $path_value == null { test_error('PATH is required') }
let host_path = $path_value
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/release-candidate-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }
let script = "$root/ci/release_candidate.fsh"
let source_root = $root

let bundle = prepare_bundle($temporary, 'bundle', 1)
let create_result = run_candidate($runtime, $script, $temporary, 'create-result', create_arguments($source_root, $bundle), $host_path)
expect_success($create_result, 'release candidate: ok', 'manifest creation')
let validate_result = run_candidate($runtime, $script, $temporary, 'validate-result', validate_arguments($source_root, $bundle), $host_path)
expect_success($validate_result, 'release candidate: ok', 'round-trip bundle validation')

let wrong_tree_result = run_candidate(
$runtime,
$script,
$temporary,
'wrong-tree-result',
[
'validate', '--root', $source_root, '--bundle', $bundle,
'--source-tree', '3333333333333333333333333333333333333333',
],
$host_path,
)
expect_failure($wrong_tree_result, 'candidate source tree mismatch', 'source-tree substitution')

let wrong_tag_result = run_candidate(
$runtime,
$script,
$temporary,
'wrong-tag-result',
['validate', '--root', $source_root, '--bundle', $bundle, '--tag', 'v0.2.1'],
$host_path,
)
expect_failure($wrong_tag_result, 'tag does not match the candidate version', 'tag substitution')

let tampered = "$temporary/tampered"
^cp -R $bundle $tampered
^printf '%s' 'substitute' > "$tampered/FlashOS-0.2.0-x86_64-live.iso.zst"
let tampered_result = run_candidate($runtime, $script, $temporary, 'tampered-result', ['validate', '--root', $source_root, '--bundle', $tampered], $host_path)
expect_failure($tampered_result, 'candidate file identity mismatch', 'tampered payload')

let unexpected = "$temporary/unexpected"
^cp -R $bundle $unexpected
^printf '%s' 'no' > "$unexpected/unexpected.txt"
let unexpected_result = run_candidate($runtime, $script, $temporary, 'unexpected-result', ['validate', '--root', $source_root, '--bundle', $unexpected], $host_path)
expect_failure($unexpected_result, 'candidate inventory mismatch', 'unexpected asset')

let missing_lock = prepare_bundle($temporary, 'missing-lock', 1)
^rm "$missing_lock/cookbook.lock"
let missing_lock_result = run_candidate($runtime, $script, $temporary, 'missing-lock-result', create_arguments($source_root, $missing_lock), $host_path)
expect_failure($missing_lock_result, 'candidate file is missing or not regular: cookbook.lock', 'missing generated cookbook lock')

let second_attempt = prepare_bundle($temporary, 'second-attempt', 2)
let second_attempt_result = run_candidate($runtime, $script, $temporary, 'second-attempt-result', create_arguments($source_root, $second_attempt), $host_path)
expect_failure($second_attempt_result, 'must succeed on the first attempt', 'second-attempt QEMU result')

let symlinked = "$temporary/symlinked"
^cp -R $bundle $symlinked
let symlink_name = 'FlashOS-0.2.0-source.cdx.json'
^cp "$symlinked/$symlink_name" "$temporary/source-copy"
^rm "$symlinked/$symlink_name"
^ln -s "$temporary/source-copy" "$symlinked/$symlink_name"
let symlink_result = run_candidate($runtime, $script, $temporary, 'symlink-result', ['validate', '--root', $source_root, '--bundle', $symlinked], $host_path)
expect_failure($symlink_result, 'candidate member is not a regular file', 'symlink substitution')

let fake_bin = "$temporary/fake-bin"
^mkdir -p $fake_bin
^printf '%s\n' '#!/bin/sh' 'printf "%s" "different decompressed bytes"' > "$fake_bin/zstd"
^chmod 755 "$fake_bin/zstd"
let compressed_result = run_candidate($runtime, $script, $temporary, 'compressed-result', ['validate', '--root', $source_root, '--bundle', $bundle, '--verify-compressed'], "$fake_bin:$host_path")
expect_failure($compressed_result, 'bytes differ from the QEMU-qualified raw image', 'compressed image substitution')

let run_path = "$temporary/run.json"
let artifacts_path = "$temporary/artifacts.json"
^printf '%s\n' '{"id":123,"head_repository":{"full_name":"example/FlashOS"},"path":".github/workflows/candidate.yml","event":"workflow_dispatch","status":"completed","conclusion":"success","run_attempt":2}' > $run_path
^printf '%s\n' '{"artifacts":[{"name":"flashos-release-candidate-123-2","expired":false}]}' > $artifacts_path
let select_result = run_candidate($runtime, $script, $temporary, 'select-result', ['select', '--run', $run_path, '--artifacts', $artifacts_path, '--repository', 'example/FlashOS', '--run-id', '123'], $host_path)
expect_success($select_result, '{"artifact_name":"flashos-release-candidate-123-2","run_attempt":2}', 'exact candidate artifact selection')

^printf '%s\n' '{"id":123,"head_repository":{"full_name":"attacker/FlashOS"},"path":".github/workflows/candidate.yml","event":"workflow_dispatch","status":"completed","conclusion":"success","run_attempt":2}' > $run_path
let repository_result = run_candidate($runtime, $script, $temporary, 'repository-result', ['select', '--run', $run_path, '--artifacts', $artifacts_path, '--repository', 'example/FlashOS', '--run-id', '123'], $host_path)
expect_failure($repository_result, 'candidate run belongs to another repository', 'repository substitution')

^printf '%s\n' '{"id":123,"head_repository":{"full_name":"example/FlashOS"},"path":".github/workflows/ci.yml","event":"workflow_dispatch","status":"completed","conclusion":"success","run_attempt":2}' > $run_path
let workflow_result = run_candidate($runtime, $script, $temporary, 'workflow-result', ['select', '--run', $run_path, '--artifacts', $artifacts_path, '--repository', 'example/FlashOS', '--run-id', '123'], $host_path)
expect_failure($workflow_result, 'selected run is not candidate.yml', 'workflow substitution')

^printf '%s\n' '{"id":123,"head_repository":{"full_name":"example/FlashOS"},"path":".github/workflows/candidate.yml","event":"workflow_dispatch","status":"completed","conclusion":"failure","run_attempt":2}' > $run_path
let unsuccessful_result = run_candidate($runtime, $script, $temporary, 'unsuccessful-result', ['select', '--run', $run_path, '--artifacts', $artifacts_path, '--repository', 'example/FlashOS', '--run-id', '123'], $host_path)
expect_failure($unsuccessful_result, 'selected candidate run is not successfully completed', 'unsuccessful producer')

^printf '%s\n' '{"id":123,"head_repository":{"full_name":"example/FlashOS"},"path":".github/workflows/candidate.yml","event":"workflow_dispatch","status":"completed","conclusion":"success","run_attempt":2}' > $run_path
^printf '%s\n' '{"artifacts":[{"name":"flashos-release-candidate-123-2","expired":true}]}' > $artifacts_path
let expired_result = run_candidate($runtime, $script, $temporary, 'expired-result', ['select', '--run', $run_path, '--artifacts', $artifacts_path, '--repository', 'example/FlashOS', '--run-id', '123'], $host_path)
expect_failure($expired_result, 'candidate artifact is missing, ambiguous, or expired', 'expired candidate artifact')

^printf '%s\n' '{"artifacts":[{"name":"flashos-release-candidate-123-2","expired":false},{"name":"flashos-release-candidate-123-2","expired":false}]}' > $artifacts_path
let ambiguous_result = run_candidate($runtime, $script, $temporary, 'ambiguous-result', ['select', '--run', $run_path, '--artifacts', $artifacts_path, '--repository', 'example/FlashOS', '--run-id', '123'], $host_path)
expect_failure($ambiguous_result, 'candidate artifact is missing, ambiguous, or expired', 'ambiguous candidate artifact')

^rm -rf $temporary
^printf '%s\n' 'release candidate tests: ok'
