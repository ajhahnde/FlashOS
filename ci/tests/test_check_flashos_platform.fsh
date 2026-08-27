#!/usr/bin/env fsh
# Exercise the native FlashOS platform validator as a black box, including a
# complete synthetic artifact identity boundary.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'FlashOS platform contract tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def run_validator(runtime, script, working, temporary, label, arguments, readelf) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    let previous = "$(pwd)"
    cd $working
    ^env "TMPDIR=$temporary" "FLASH_AUTOMATION_READELF=$readelf" $runtime $script ...$arguments > $stdout 2> $stderr
    let result = $status
    cd $previous
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

def prepare_candidate(root, temporary, label) {
    let candidate = "$temporary/$label"
    ^mkdir -p \
    "$candidate/components/flash" \
    "$candidate/config/x86_64" \
    "$candidate/mk" \
    "$candidate/recipes/dev/rust" \
    "$candidate/recipes/core/relibc"
    if !$status.ok { test_error("cannot create $label candidate") }
    ^cp "$root/versions.env" "$root/rust-toolchain.toml" "$candidate/"
    ^cp -R "$root/.github" "$candidate/"
    ^cp -R "$root/ci" "$candidate/"
    ^cp "$root/mk/config.mk" "$root/mk/prefix.mk" "$candidate/mk/"
    ^cp "$root/config/flashos-base.toml" "$candidate/config/"
    ^cp "$root/config/x86_64/flashos.toml" "$root/config/x86_64/flashos-release.toml" "$candidate/config/x86_64/"
    ^cp "$root/recipes/dev/rust/recipe.toml" "$candidate/recipes/dev/rust/"
    ^cp "$root/recipes/core/relibc/recipe.toml" "$candidate/recipes/core/relibc/"
    ^cp -R "$root/components/flash/platforms" "$candidate/components/flash/"
    if !$status.ok { test_error("cannot copy $label platform sources") }
    return $candidate
}

def install_artifacts(candidate, temporary) {
    ^mkdir -p $temporary
    if !$status.ok { test_error('cannot create synthetic artifact tool directory') }
    let flash_target = "$candidate/recipes/terminal/flash/target/x86_64-unknown-redox"
    let relibc_target = "$candidate/recipes/core/relibc/target/x86_64-unknown-redox"
    ^mkdir -p "$flash_target/build/target" "$flash_target/stage/usr/bin" "$relibc_target/stage/usr/lib"
    if !$status.ok { test_error('cannot create synthetic artifact layout') }
    let version = 'rustc 1.98.0-dev\nbinary: rustc\ncommit-hash: unknown\nrelease: 1.98.0-dev\nLLVM version: 21.1.2\n'
    let cfg = 'target_arch="x86_64"\ntarget_endian="little"\ntarget_env="relibc"\ntarget_family="unix"\ntarget_os="redox"\ntarget_pointer_width="64"\ntarget_object_format="elf"\n'
    let jq_value = env('FLASH_AUTOMATION_JQ')
    if $jq_value == null || $jq_value == '' { test_error('FLASH_AUTOMATION_JQ is required') }
    let jq = $jq_value
    ^env $jq -n --arg version $version --arg cfg $cfg '{outputs:[{success:true,stdout:$version},{success:true,stdout:$cfg}]}' > "$flash_target/build/target/.rustc_info.json"
    if !$status.ok { test_error('cannot create compiler fingerprint fixture') }
    ^printf '%s\n' \
    'name = "relibc"' \
    'target = "x86_64-unknown-redox"' \
    'source_identifier = "5f6afb52692e62dae79154f4dbec2d0e79a07602"' \
    'commit_identifier = "image-builder-commit"' > "$relibc_target/stage.toml"
    ^printf '%s\n' 'synthetic fsh ELF' > "$flash_target/stage/usr/bin/fsh"
    ^printf '%s\n' 'synthetic relibc ELF' > "$relibc_target/stage/usr/lib/libc.so"
    if !$status.ok { test_error('cannot create synthetic package artifacts') }
    let readelf = "$temporary/readelf"
    ^printf '%s\n' \
    '#!/bin/sh' \
    'if [ "$1" = "--version" ]; then printf "%s\\n" "GNU readelf (GNU Binutils for Ubuntu) 2.42"; exit 0; fi' \
    'last=""; for argument in "$@"; do last="$argument"; done' \
    'if [ "${last##*/}" = "libc.so" ]; then' \
    '  printf "%s\\n" "  Class:                             ELF64" "  Machine:                           Advanced Micro Devices X86-64" " 0x000000000000000e (SONAME)             Library soname: [libc.so.6]"' \
    'else' \
    '  printf "%s\\n" "  Class:                             ELF64"; printf "  Data:                              2\\047s complement, little endian\\n"; printf "%s\\n" "  Type:                              DYN (Position-Independent Executable file)" "  Machine:                           Advanced Micro Devices X86-64" "      [Requesting program interpreter: /lib/ld64.so.1]" " 0x000000006ffffffb (FLAGS_1)            Flags: NOW PIE" " 0x0000000000000001 (NEEDED)             Shared library: [libgcc_s.so.1]" " 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]"' \
    'fi' > $readelf
    ^chmod 755 $readelf
    if !$status.ok { test_error('cannot create readelf fixture') }
    return $readelf
}

let root = repository_root('versions.env')
let runtime_value = env('FLASH_AUTOMATION_RUNTIME')
if $runtime_value == null || $runtime_value == '' { test_error('FLASH_AUTOMATION_RUNTIME is required') }
let runtime = $runtime_value
if "$(^$runtime --version 2>/dev/null)" != 'fsh 1.0.0' { test_error('FLASH_AUTOMATION_RUNTIME must report fsh 1.0.0') }
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flashos-platform-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }
let placeholder_readelf = "$temporary/not-used"

let tracked = run_validator($runtime, "$root/ci/check_flashos_platform.fsh", $root, $temporary, 'tracked', [], $placeholder_readelf)
expect_success($tracked, 'FlashOS platform baseline: source contract passed for x86_64-unknown-redox', 'tracked source platform baseline')

let artifacts = prepare_candidate($root, $temporary, 'artifacts')
let readelf = install_artifacts($artifacts, $temporary)
let artifact_result = run_validator($runtime, "$artifacts/ci/check_flashos_platform.fsh", $artifacts, $temporary, 'artifacts-result', ['--artifacts'], $readelf)
expect_success($artifact_result, 'FlashOS platform baseline: source and artifact contract passed for x86_64-unknown-redox', 'synthetic compiler and ELF identity')

let invalid_type = prepare_candidate($root, $temporary, 'invalid-elf-type')
let invalid_type_readelf = install_artifacts($invalid_type, "$temporary/invalid-elf-type-tools")
let rewritten_readelf = "$temporary/invalid-elf-type-readelf"
^sed 's/DYN (Position-Independent Executable file)/EXEC (Executable file)/' $invalid_type_readelf > $rewritten_readelf
^chmod 755 $rewritten_readelf
if !$status.ok { test_error('cannot mutate ELF type fixture') }
let invalid_type_result = run_validator($runtime, "$invalid_type/ci/check_flashos_platform.fsh", $invalid_type, $temporary, 'invalid-elf-type-result', ['--artifacts'], $rewritten_readelf)
expect_failure($invalid_type_result, 'fsh ELF identity differs: Type: DYN', 'fsh ELF type mismatch')

let invalid_pie = prepare_candidate($root, $temporary, 'invalid-pie-flag')
let invalid_pie_readelf = install_artifacts($invalid_pie, "$temporary/invalid-pie-tools")
let rewritten_pie_readelf = "$temporary/invalid-pie-readelf"
^sed 's/Flags: NOW PIE/Flags: NOW NODELETE/' $invalid_pie_readelf > $rewritten_pie_readelf
^chmod 755 $rewritten_pie_readelf
if !$status.ok { test_error('cannot mutate ELF PIE fixture') }
let invalid_pie_result = run_validator($runtime, "$invalid_pie/ci/check_flashos_platform.fsh", $invalid_pie, $temporary, 'invalid-pie-result', ['--artifacts'], $rewritten_pie_readelf)
expect_failure($invalid_pie_result, 'executable.position_independent artifact identity differs', 'fsh ELF PIE flag mismatch')

let mismatch = prepare_candidate($root, $temporary, 'relibc-mismatch')
let mismatch_readelf = install_artifacts($mismatch, "$temporary/mismatch-tools")
let stage = "$mismatch/recipes/core/relibc/target/x86_64-unknown-redox/stage.toml"
let rewritten = "$temporary/mismatched-stage.toml"
^sed 's/source_identifier = .*/source_identifier = "moving-binary-feed-revision"/' $stage > $rewritten
if !$status.ok { test_error('cannot mutate relibc stage identity') }
^mv $rewritten $stage
let mismatch_result = run_validator($runtime, "$mismatch/ci/check_flashos_platform.fsh", $mismatch, $temporary, 'mismatch-result', ['--artifacts'], $mismatch_readelf)
expect_failure($mismatch_result, 'libc.configured_revision artifact source differs', 'relibc artifact source mismatch')

^rm -rf $temporary
^printf '%s\n' 'FlashOS platform contract tests: ok'
