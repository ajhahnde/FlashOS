#!/usr/bin/env fsh
# Taplo and jq decode tracked platform/package records. ripgrep exposes exact
# source and compiler-fingerprint markers. A version-pinned readelf supplies
# ELF structure; Flash owns every identity, ABI, package, and artifact decision.

import { require_jq, require_rg, selected_tool, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def platform_error(message) {
    ^printf 'FlashOS platform baseline: %s\n' $message 1>&2
    exit 1
}

def validate_source(bundle) {
    let baseline = $bundle.baseline
    if $baseline.schema_version != 2 {
        throw 'schema_version must be 2'
    }
    if $baseline.platform != 'flashos' {
        throw 'platform must be flashos'
    }
    if $baseline.architecture != 'x86_64' {
        throw 'architecture must be x86_64'
    }
    if $baseline.image_profiles != ['flashos', 'flashos-release'] {
        throw 'image_profiles must preserve development and release order'
    }
    if $baseline.target.triple != 'x86_64-unknown-redox' {
        throw 'target.triple must be x86_64-unknown-redox'
    }
    if !('flash' in $bundle.development_packages) {
        throw 'the flashos image profile no longer includes Flash'
    }
    if !('flash' in $bundle.release_packages) {
        throw 'the flashos-release image profile no longer includes Flash'
    }
    if !('relibc' in $bundle.base_packages) {
        throw 'the FlashOS base profile no longer includes relibc'
    }
    if $baseline.build.image_package_rule != 'source' {
        throw 'build.image_package_rule must be source'
    }
    if $bundle.root_toolchain.toolchain.channel != $baseline.build.root_toolchain {
        throw 'build.root_toolchain does not match rust-toolchain.toml'
    }
    if $bundle.rust_recipe.source.git != $baseline.compiler.source {
        throw 'compiler.source does not match the Rust recipe'
    }
    if $baseline.compiler.source_selector_kind != 'branch' {
        throw 'compiler.source_selector_kind must be branch'
    }
    if $bundle.rust_recipe.source.branch != $baseline.compiler.source_selector {
        throw 'compiler.source_selector does not match the Rust recipe'
    }
    if $bundle.relibc_recipe.source.git != $baseline.libc.source {
        throw 'libc.source does not match the relibc recipe'
    }
    if $bundle.relibc_recipe.source.rev != $baseline.libc.configured_revision {
        throw 'libc.configured_revision does not match the relibc recipe'
    }
    return true
}

def require_marker(path, marker, message, rg) {
    if ^env $rg --multiline --fixed-strings --quiet -- $marker $path {
    } else {
        platform_error($message)
    }
}

def require_readelf_pattern(path, pattern, message, rg) {
    if ^env $rg --quiet --regexp $pattern $path {
    } else {
        platform_error($message)
    }
}

def require_readelf() {
    mut program = selected_tool('FLASH_AUTOMATION_READELF', 'llvm-readelf')
    mut version = "$(^env $program --version 2>/dev/null | ^sed -n '1p')"
    if !$status.ok || $version == '' {
        $program = 'readelf'
        $version = "$(^env $program --version 2>/dev/null | ^sed -n '1p')"
    }
    let accepted = [
    'Homebrew LLVM version 22.1.8',
    'Ubuntu LLVM version 18.1.3',
    'GNU readelf (GNU Binutils for Ubuntu) 2.42',
    ]
    if !$status.ok || !($version in $accepted) {
        platform_error("readelf version differs: observed $version")
    }
    return $program
}

let root = repository_root('versions.env')
mut artifacts = false
for argument in $args {
    if $argument == '--artifacts' {
        $artifacts = true
    } else if $argument in ['-h', '--help'] {
        ^printf 'usage: check_flashos_platform.fsh [-h] [--artifacts]\n'
        exit 0
    } else {
        ^printf 'usage: check_flashos_platform.fsh [-h] [--artifacts]\n' 1>&2
        ^printf 'check_flashos_platform.fsh: error: unrecognized arguments: %s\n' $argument 1>&2
        exit 2
    }
}
let jq = require_jq()
let rg = require_rg()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flashos-platform.XXXXXX")"
if !$status.ok {
    platform_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
let baseline = "$temporary/baseline.json"
let development = "$temporary/development.json"
let release = "$temporary/release.json"
let base = "$temporary/base.json"
let root_toolchain = "$temporary/root-toolchain.json"
let rust_recipe = "$temporary/rust-recipe.json"
let relibc_recipe = "$temporary/relibc-recipe.json"
let bundle = "$temporary/bundle.json"
let baseline_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64.toml",
$errors,
)
^printf '%s\n' $baseline_document > $baseline
let development_document = toml_to_json("$root/config/x86_64/flashos.toml", $errors)
^printf '%s\n' $development_document > $development
let release_document = toml_to_json(
"$root/config/x86_64/flashos-release.toml",
$errors,
)
^printf '%s\n' $release_document > $release
let base_document = toml_to_json("$root/config/flashos-base.toml", $errors)
^printf '%s\n' $base_document > $base
let root_toolchain_document = toml_to_json("$root/rust-toolchain.toml", $errors)
^printf '%s\n' $root_toolchain_document > $root_toolchain
let rust_recipe_document = toml_to_json("$root/recipes/dev/rust/recipe.toml", $errors)
^printf '%s\n' $rust_recipe_document > $rust_recipe
let relibc_recipe_document = toml_to_json(
"$root/recipes/core/relibc/recipe.toml",
$errors,
)
^printf '%s\n' $relibc_recipe_document > $relibc_recipe
^env $jq \
--slurpfile development $development \
--slurpfile release $release \
--slurpfile base $base \
--slurpfile root_toolchain $root_toolchain \
--slurpfile rust_recipe $rust_recipe \
--slurpfile relibc_recipe $relibc_recipe \
'{baseline:., development_packages:($development[0].packages|keys), release_packages:($release[0].packages|keys), base_packages:($base[0].packages|keys), root_toolchain:$root_toolchain[0], rust_recipe:$rust_recipe[0], relibc_recipe:$relibc_recipe[0]}' \
$baseline > $bundle 2> $errors
if !$status.ok {
    platform_error('cannot project the platform source contract')
}
try {
    open $bundle | from json | each {|document| validate_source($document)} | to json > /dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    platform_error($message)
}
let root_toolchain_value = "$(^env $jq --raw-output '.build.root_toolchain' $baseline)"
let cbindgen_version = "$(^env $jq --raw-output '.build.cbindgen_version' $baseline)"
let compiler_selector = "$(^env $jq --raw-output '.compiler.source_selector' $baseline)"
let selector_date = "$(^printf '%s' $compiler_selector | ^sed 's/^redox-//')"
require_marker(
"$root/mk/config.mk",
'export TARGET=$(ARCH)-unknown-redox',
'mk/config.mk no longer derives the recorded target triple',
$rg,
)
require_marker(
"$root/ci/container/Dockerfile",
"ARG RUST_TOOLCHAIN=$root_toolchain_value",
'the hosted image builder does not use build.root_toolchain',
$rg,
)
require_marker(
"$root/ci/container/Dockerfile",
"ARG CBINDGEN_VERSION=$cbindgen_version",
'the hosted image builder does not use build.cbindgen_version',
$rg,
)
require_marker(
"$root/ci/container/Dockerfile",
"/root/.cargo/bin/cargo install --locked \\\n       --version \"\${CBINDGEN_VERSION}\" cbindgen",
'the hosted image builder does not install its pinned cbindgen',
$rg,
)
require_marker(
"$root/ci/container/Dockerfile",
'ENV REPO_BINARY=0',
'the hosted image container does not default to source packages',
$rg,
)
if ^env $rg --fixed-strings --quiet -- 'ENV REPO_BINARY=1' "$root/ci/container/Dockerfile" {
    platform_error('the hosted image container does not default to source packages')
}
require_marker(
"$root/mk/prefix.mk",
"UPSTREAM_RUSTC_VERSION=$selector_date",
'mk/prefix.mk does not match compiler.source_selector',
$rg,
)
require_marker(
"$root/.github/workflows/ci.yml",
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_platform.fsh',
'standard CI does not validate the source platform baseline',
$rg,
)
require_marker(
"$root/.github/workflows/_image.yml",
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_platform.fsh --artifacts',
'image CI does not validate platform build artifacts',
$rg,
)
require_marker(
"$root/.github/workflows/_image.yml",
'REPO_BINARY=0',
'image CI does not require source packages',
$rg,
)
if ^env $rg --fixed-strings --quiet -- 'REPO_BINARY=1' "$root/.github/workflows/_image.yml" {
    platform_error('image CI does not require source packages')
}

if $artifacts {
    let flash_target = "$root/recipes/terminal/flash/target/x86_64-unknown-redox"
    let relibc_target = "$root/recipes/core/relibc/target/x86_64-unknown-redox"
    let fingerprint = "$flash_target/build/target/.rustc_info.json"
    let version_output = "$temporary/rustc-version"
    let cfg_output = "$temporary/rustc-cfg"
    ^env $jq --raw-output '[.outputs[]|select(.success == true and (.stdout|contains("binary: rustc")) and (.stdout|contains("release:")))][0].stdout // ""' $fingerprint > $version_output 2> $errors
    if !$status.ok {
        platform_error('compiler fingerprint has no successful rustc version query')
    }
    if ^test -s $version_output {
    } else {
        platform_error('compiler fingerprint has no successful rustc version query')
    }
    ^env $jq --raw-output '[.outputs[]|select(.success == true and (.stdout|contains("target_os=\"redox\"")) and (.stdout|contains("target_arch=\"x86_64\"")))][0].stdout // ""' $fingerprint > $cfg_output 2> $errors
    if !$status.ok {
        platform_error('compiler fingerprint has no successful FlashOS target query')
    }
    if ^test -s $cfg_output {
    } else {
        platform_error('compiler fingerprint has no successful FlashOS target query')
    }
    let compiler_release = "$(^env $jq --raw-output '.compiler.release' $baseline)"
    let compiler_commit = "$(^env $jq --raw-output '.compiler.commit' $baseline)"
    let compiler_llvm = "$(^env $jq --raw-output '.compiler.llvm_version' $baseline)"
    for marker in [
    "release: $compiler_release",
    "commit-hash: $compiler_commit",
    "LLVM version: $compiler_llvm",
    ] {
        if ^env $rg --fixed-strings --quiet -- $marker $version_output {
        } else {
            platform_error('compiler fingerprint version identity differs')
        }
    }
    let target_fields = ['os', 'environment', 'family', 'pointer_width', 'endianness', 'object_format']
    let cfg_fields = ['target_os', 'target_env', 'target_family', 'target_pointer_width', 'target_endian', 'target_object_format']
    mut target_index = 0
    for field in $target_fields {
        let cfg_field = $cfg_fields[$target_index]
        let expected = "$(^env $jq --raw-output --arg field $field '.target[$field]|tostring' $baseline)"
        if ^env $rg --fixed-strings --quiet -- "$cfg_field=\"$expected\"" $cfg_output {
        } else {
            platform_error("target.$field does not match the compiler fingerprint: expected $cfg_field=\"$expected\"")
        }
        $target_index = $target_index + 1
    }
    if ^env $rg --fixed-strings --quiet -- 'target_arch="x86_64"' $cfg_output {
    } else {
        platform_error('architecture does not match the compiler fingerprint')
    }
    let stage = "$temporary/relibc-stage.json"
    let stage_document = toml_to_json("$relibc_target/stage.toml", $errors)
    ^printf '%s\n' $stage_document > $stage
    let stage_name = "$(^env $jq --raw-output '.name // ""' $stage)"
    let stage_target = "$(^env $jq --raw-output '.target // ""' $stage)"
    let stage_source = "$(^env $jq --raw-output '.source_identifier // ""' $stage)"
    let stage_commit = "$(^env $jq --raw-output '.commit_identifier // ""' $stage)"
    let libc_name = "$(^env $jq --raw-output '.libc.name' $baseline)"
    let target_triple = "$(^env $jq --raw-output '.target.triple' $baseline)"
    let libc_revision = "$(^env $jq --raw-output '.libc.configured_revision' $baseline)"
    if $stage_name != $libc_name {
        platform_error('libc.name artifact identity differs')
    }
    if $stage_target != $target_triple {
        platform_error('libc target artifact identity differs')
    }
    if $stage_source != $libc_revision {
        platform_error('libc.configured_revision artifact source differs')
    }
    if $stage_commit == '' {
        platform_error('libc package has no build-tree commit identifier')
    }
    let readelf = require_readelf()
    let fsh_elf = "$temporary/fsh-elf"
    let libc_elf = "$temporary/libc-elf"
    ^env $readelf -h -l -d "$flash_target/stage/usr/bin/fsh" > $fsh_elf 2> $errors
    if !$status.ok {
        platform_error('cannot read ELF artifact recipes/terminal/flash/target/x86_64-unknown-redox/stage/usr/bin/fsh')
    }
    ^env $readelf -h -d "$relibc_target/stage/usr/lib/libc.so" > $libc_elf 2> $errors
    if !$status.ok {
        platform_error('cannot read ELF artifact recipes/core/relibc/target/x86_64-unknown-redox/stage/usr/lib/libc.so')
    }
    require_readelf_pattern($fsh_elf, '^[[:space:]]*Class:[[:space:]]+ELF64[[:space:]]*$', 'fsh ELF identity differs: Class: ELF64', $rg)
    require_readelf_pattern($fsh_elf, "^[[:space:]]*Data:[[:space:]]+2's complement, little endian[[:space:]]*$", "fsh ELF identity differs: Data: 2's complement, little endian", $rg)
    require_readelf_pattern($fsh_elf, '^[[:space:]]*Type:[[:space:]]+DYN([[:space:]]|$)', 'fsh ELF identity differs: Type: DYN', $rg)
    require_readelf_pattern($fsh_elf, '^[[:space:]]*Machine:[[:space:]]+Advanced Micro Devices X86-64[[:space:]]*$', 'fsh ELF identity differs: Machine: Advanced Micro Devices X86-64', $rg)
    require_readelf_pattern($fsh_elf, 'Requesting program interpreter:[[:space:]]*/lib/ld64\.so\.1', 'fsh ELF identity differs: Requesting program interpreter: /lib/ld64.so.1', $rg)
    require_readelf_pattern($fsh_elf, '\(FLAGS_1\).*([[:space:]]|:)PIE([[:space:]]|$)', 'executable.position_independent artifact identity differs', $rg)
    let needed = "$(^env $rg --only-matching --replace '$1' '\(NEEDED\).*\[([^]]+)\]' $fsh_elf | ^env LC_ALL=C sort)"
    if $needed != "libc.so.6\nlibgcc_s.so.1" {
        platform_error('executable.required_libraries artifact identity differs')
    }
    require_readelf_pattern($libc_elf, '^[[:space:]]*Class:[[:space:]]+ELF64[[:space:]]*$', 'libc ELF identity differs: Class: ELF64', $rg)
    require_readelf_pattern($libc_elf, '^[[:space:]]*Machine:[[:space:]]+Advanced Micro Devices X86-64[[:space:]]*$', 'libc ELF identity differs: Machine: Advanced Micro Devices X86-64', $rg)
    require_readelf_pattern($libc_elf, '\(SONAME\).*Library soname:[[:space:]]*\[libc\.so\.6\]', 'libc.soname artifact identity differs', $rg)
}

^rm -rf $temporary
mut mode = 'source'
if $artifacts {
    $mode = 'source and artifact'
}
^printf 'FlashOS platform baseline: %s contract passed for x86_64-unknown-redox\n' $mode
