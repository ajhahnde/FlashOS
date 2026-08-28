#!/usr/bin/env fsh
# Taplo decodes product/profile records, jq exposes field names and bounded
# selections, and ripgrep exposes public workflow/source markers. Flash owns
# package and credential closure, product identity, TUI-only policy, immutable
# dependency routing, candidate/release ordering, and diagnostics.

import { require_jq, require_rg, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

mut artifact_mode = false
if $args == ['--artifacts'] {
    $artifact_mode = true
} else if $args != [] {
    ^printf '%s\n' 'usage: ci/check_profile.fsh [--artifacts]' 1>&2
    exit 2
}

def profile_error(message) {
    ^printf 'profile contract: %s\n' $message 1>&2
    exit 1
}

def validate(bundle) {
    let version = $bundle.version
    if $bundle.root.package.version != $version {
        throw 'root Cargo package version drifted from versions.env'
    }
    let flash_version = $bundle.flash.workspace.package.version
    if !$bundle.flash_version_semantic {
        throw 'Flash workspace version is not semantic'
    }
    if $bundle.flash_release.release_version != $flash_version {
        throw 'Flash workspace version drifted from its component release record'
    }
    if $bundle.profile.include != ['../flashos-base.toml'] {
        throw 'the x86_64 profile must include only ../flashos-base.toml'
    }
    if $bundle.profile.general.create_xdg_user_dirs != false {
        throw 'graphical XDG home directories must remain disabled'
    }
    let expected_packages = [
    'base',
    'coreutils',
    'flash',
    'flash.lsp',
    'kernel',
    'libgcc',
    'netdb',
    'netutils',
    'relibc',
    'userutils',
    'uutils',
    ]
    if $bundle.packages != $expected_packages {
        throw 'package closure drifted'
    }
    if $bundle.gui_packages != [] {
        throw "GUI package selected: ${$bundle.gui_packages[0]}"
    }
    if $bundle.dead_runtime_paths != [] {
        throw "dead runtime compatibility path returned: ${$bundle.dead_runtime_paths[0]}"
    }
    for account in ['root', 'user'] {
        if $bundle.profile.users[$account].shell != '/usr/bin/fsh' {
            throw "$account shell must be /usr/bin/fsh"
        }
    }
    for section in ['general', 'packages', 'files'] {
        if $bundle.profile[$section] != $bundle.release[$section] {
            throw "release profile drifted from the development profile: [$section]"
        }
    }
    if $bundle.profile_users != $bundle.release_users {
        throw 'release profile defines a different account set'
    }
    if $bundle.release.users.root.locked != true {
        throw 'the release profile must lock the root account'
    }
    if $bundle.release_root_has_password {
        throw 'a locked account must not also carry a password'
    }
    if $bundle.release.users.user.password != '' {
        throw 'the release user must remain passwordless'
    }
    let expected_console_init = "inputd -A 2\nnowait getty 2\nnowait getty /scheme/debug/no-preserve -J\n"
    if $bundle.console_init_count != 1 || $bundle.console_init_data != $expected_console_init {
        throw 'console initialization must contain only input and local getty processes'
    }
    let well_known = [
    '123456',
    'admin',
    'flashos',
    'password',
    'redox',
    'root',
    'toor',
    'user',
    ]
    for account in $bundle.release_user_records {
        if $account.password != null && $account.password_lower in $well_known {
            throw "release account ${$account.name} uses a well-known password"
        }
    }
    if $bundle.login_file_count != 1 {
        throw '/etc/login_schemes.toml is missing'
    }
    for required in ['audio', 'display*', 'event', 'pty'] {
        if !($required in $bundle.login.user_schemes.user.schemes) {
            throw "required TUI/runtime scheme is missing: $required"
        }
    }
    if 'orbital' in $bundle.login.user_schemes.user.schemes {
        throw 'Orbital scheme access must not be present'
    }
    if $bundle.legacy_ui_paths != [] {
        throw 'legacy /ui compatibility path returned'
    }
    if $bundle.os_release_count != 1 {
        throw '/usr/lib/os-release is missing'
    }
    for expected in [
    "PRETTY_NAME=\"FlashOS $version\"",
    "VERSION_ID=\"$version\"",
    "VERSION=\"$version\"",
    ] {
        if !($expected in $bundle.os_release_data) {
            throw "os-release version drifted from versions.env: $expected"
        }
    }
    if $bundle.issue_count != 1 || $bundle.issue_data != "FlashOS $version\n" {
        throw '/etc/issue version drifted from versions.env'
    }
    let identity_paths = [
    '/etc/hostname',
    '/etc/issue',
    '/etc/motd',
    '/etc/os-release',
    '/usr/lib/os-release',
    ]
    mut identity_index = 0
    for postinstall in $bundle.identity_postinstall {
        if $postinstall != true {
            throw "${$identity_paths[$identity_index]} must be installed after packages"
        }
        $identity_index = $identity_index + 1
    }
    if $bundle.flash_recipe.source != {workspace: 'components/flash'} {
        throw 'Flash recipe must use the in-tree components/flash workspace source'
    }
    if $bundle.flash_recipe.build.template != 'custom' || !('DYNAMIC_INIT' in $bundle.flash_recipe.build.script) {
        throw 'Flash workspace recipe must initialize the Cargo build template'
    }
    return true
}

def require_markers(path, markers, label, rg) {
    for marker in $markers {
        if ^env $rg --multiline --fixed-strings --quiet -- $marker $path {
        } else {
            profile_error("$label is missing: $marker")
        }
    }
}

def reject_markers(path, markers, label, rg) {
    for marker in $markers {
        if ^env $rg --multiline --fixed-strings --quiet -- $marker $path {
            profile_error("$label: $marker")
        }
    }
}

def require_marker_count(path, marker, expected, label, rg) {
    let observed = "$(^env $rg --fixed-strings --count-matches -- $marker $path)"
    if !$status.ok || $observed != $expected {
        profile_error("$label expected $expected occurrences of '$marker', observed '$observed'")
    }
}

let root = repository_root('versions.env')
let jq = require_jq()
let rg = require_rg()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flashos-profile.XXXXXX")"
if !$status.ok {
    profile_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
let profile = "$temporary/profile.json"
let release = "$temporary/release.json"
let base = "$temporary/base.json"
let root_manifest = "$temporary/root.json"
let flash_manifest = "$temporary/flash.json"
let flash_release = "$temporary/flash-release.json"
let flash_recipe = "$temporary/flash-recipe.json"
let login = "$temporary/login.json"
let bundle = "$temporary/bundle.json"
let profile_document = toml_to_json("$root/config/x86_64/flashos.toml", $errors)
^printf '%s\n' $profile_document > $profile
let release_document = toml_to_json(
"$root/config/x86_64/flashos-release.toml",
$errors,
)
^printf '%s\n' $release_document > $release
let base_document = toml_to_json("$root/config/flashos-base.toml", $errors)
^printf '%s\n' $base_document > $base
let root_document = toml_to_json("$root/Cargo.toml", $errors)
^printf '%s\n' $root_document > $root_manifest
let flash_document = toml_to_json("$root/components/flash/Cargo.toml", $errors)
^printf '%s\n' $flash_document > $flash_manifest
let flash_release_document = toml_to_json(
"$root/components/flash/release/v1.toml",
$errors,
)
^printf '%s\n' $flash_release_document > $flash_release
let flash_recipe_document = toml_to_json(
"$root/recipes/terminal/flash/recipe.toml",
$errors,
)
^printf '%s\n' $flash_recipe_document > $flash_recipe
^env $jq --raw-output '.files[] | select(.path == "/etc/login_schemes.toml") | .data' $base > "$temporary/login.toml"
if !$status.ok {
    profile_error('cannot project /etc/login_schemes.toml')
}
let login_document = toml_to_json("$temporary/login.toml", $errors)
^printf '%s\n' $login_document > $login
let version = "$(^env $rg --only-matching --replace '$1' '^FLASHOS_RELEASE_VERSION=(.+)$' "$root/versions.env")"
if $version == '' {
    ^rm -rf $temporary
    profile_error('FLASHOS_RELEASE_VERSION is missing from versions.env')
}
^env $jq \
--slurpfile release $release \
--slurpfile base $base \
--slurpfile root $root_manifest \
--slurpfile flash $flash_manifest \
--slurpfile flash_release $flash_release \
--slurpfile flash_recipe $flash_recipe \
--slurpfile login $login \
--arg version $version \
'. as $profile | (($base[0].packages|keys) + ($profile.packages|keys) | unique | sort) as $packages | {profile:$profile, release:$release[0], base:$base[0], root:$root[0], flash:$flash[0], flash_release:$flash_release[0], flash_recipe:$flash_recipe[0], login:$login[0], version:$version, flash_version_semantic:(try ($flash[0].workspace.package.version|test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) catch false), packages:$packages, gui_packages:[$packages[]|select(ascii_downcase|test("cosmic|orbital|wayland|weston|x11|xorg"))], profile_users:($profile.users|keys|sort), release_users:($release[0].users|keys|sort), release_root_has_password:($release[0].users.root|has("password")), release_user_records:[$release[0].users|to_entries[]|{name:.key,password:(.value.password//null),password_lower:(try (.value.password|ascii_downcase) catch null)}], console_init_count:([$profile.files[]|select(.path=="/usr/lib/init.d/30_console" and ((.append//false)|not))]|length), console_init_data:([$profile.files[]|select(.path=="/usr/lib/init.d/30_console" and ((.append//false)|not))][0].data//null), login_file_count:([$base[0].files[]|select(.path=="/etc/login_schemes.toml")]|length), legacy_ui_paths:[($base[0].files+$profile.files)[]|.path|select(.=="/ui" or startswith("/ui/"))], dead_runtime_paths:[($base[0].files+$profile.files)[]|.path|select(.=="/etc/pkg.d/50_redox" or .=="/usr/include" or .=="/include" or .=="/usr/libexec" or .=="/usr/share" or .=="/share")], os_release_count:([$profile.files[]|select(.path=="/usr/lib/os-release" and ((.append//false)|not))]|length), os_release_data:([$profile.files[]|select(.path=="/usr/lib/os-release" and ((.append//false)|not))][0].data//null), issue_count:([$profile.files[]|select(.path=="/etc/issue" and ((.append//false)|not))]|length), issue_data:([$profile.files[]|select(.path=="/etc/issue" and ((.append//false)|not))][0].data//null), identity_postinstall:["/etc/hostname","/etc/issue","/etc/motd","/etc/os-release","/usr/lib/os-release"] | map(. as $path | [($base[0].files+$profile.files)[]|select(.path==$path)][-1].postinstall//false)}' \
$profile > $bundle 2> $errors
if !$status.ok {
    profile_error('cannot project the FlashOS profile contract')
}
try {
    open $bundle | from json | each {|document| validate($document)} | to json > /dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    profile_error($message)
}

if ^test -e "$root/docs/de" {
    ^rm -rf $temporary
    profile_error('German docs are intentionally deferred and must not be restored yet')
}
require_markers(
"$root/README.md",
[
"FlashOS $version",
"Version-$version-",
'actions/workflows/main-qualification.yml/badge.svg?branch=main&amp;event=push',
'alt="Main verified"',
'Status-pre--alpha-',
'Target-x86__64--unknown--redox-',
],
'README badge contract',
$rg,
)
let release_workflow = "$root/.github/workflows/release.yml"
require_markers(
$release_workflow,
[
'name: Publish release',
'candidate-run-id:',
'gh run download',
'make flash-bootstrap',
'make flash-automation-tools',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/release_candidate.fsh select',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/release_candidate.fsh validate',
'environment: production',
'inputs.publish == true',
'published assets are immutable',
'Publish without rebuilding or substituting assets',
],
'release publisher contract',
$rg,
)
require_marker_count($release_workflow, 'source_commit="$(jq -r .source_commit <<<"${selection}")"', '2', 'release publisher selected-run source binding', $rg)
require_marker_count($release_workflow, 'source_commit="$(cat dist/candidate-source-commit)"', '2', 'release publisher candidate source validation', $rg)
require_marker_count($release_workflow, 'git rev-parse "${TAG}^{tree}"', '2', 'release publisher tag-tree validation', $rg)
reject_markers(
$release_workflow,
[
'docker build',
'zstd --',
'attest-build-provenance',
'sbom-action',
'uses: ./.github/workflows/_image.yml',
'tags: ["v*"]',
'--clobber',
'git rev-parse "${TAG}^{commit}"',
],
'release publisher must not regenerate or overwrite candidate bytes',
$rg,
)
let candidate_workflow = "$root/.github/workflows/candidate.yml"
let release_notes_path = "docs/releases/v$version.md"
if ^test -f "$root/$release_notes_path" {
} else {
    profile_error("reviewed release notes are missing: $release_notes_path")
}
require_markers(
$candidate_workflow,
[
'name: Release candidate',
'source-sha:',
"default: $release_notes_path",
'make flash-bootstrap',
'make flash-automation-tools',
'FLASH_AUTOMATION_RG:',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_candidate_qualification.fsh',
'config-name: flashos-release',
'release-evidence: true',
'name: Prepare the source SBOM destination',
'run: mkdir -p dist/candidate',
'name: Generate the source SBOM before downloading binaries',
'name: Download the once-built release images',
'FlashOS-${{ inputs.version }}-source.cdx.json',
'FlashOS-${VERSION}-x86_64-harddrive.img.zst',
'FlashOS-${VERSION}-x86_64-live.iso.zst',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/release_candidate.fsh create',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/release_candidate.fsh validate',
'attest-build-provenance',
'flashos-release-candidate-${{ github.run_id }}-${{ github.run_attempt }}',
],
'release candidate contract',
$rg,
)
let candidate_order = "$(^env $rg --only-matching 'name: (Prepare the source SBOM destination|Generate the source SBOM before downloading binaries|Download the once-built release images)' $candidate_workflow)"
if $candidate_order != "name: Prepare the source SBOM destination\nname: Generate the source SBOM before downloading binaries\nname: Download the once-built release images" {
    profile_error('release candidate must prepare the source SBOM destination before scanning')
}
let image_workflow = "$root/.github/workflows/_image.yml"
require_markers(
$image_workflow,
[
'build/x86_64/${CONFIG_NAME}/harddrive.img',
'build/x86_64/${CONFIG_NAME}/redox-live.iso',
'FlashOS-x86_64-harddrive.img',
'FlashOS-x86_64-live.iso',
'FlashOS-x86_64-image.cdx.json',
'dist/payload',
'release-evidence:',
'if: inputs.release-evidence',
'GIT_CONFIG_COUNT=1',
'GIT_CONFIG_KEY_0=safe.directory',
'GIT_CONFIG_VALUE_0=/workspace',
'name: Record the selected recipe resolution',
'ci/check_profile.fsh --artifacts',
'runtime package closure',
'recipe_name = name.split(".", 1)[0]',
'repo-lock',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_platform.fsh --artifacts',
'--disk-interface nvme',
'--disk-interface usb',
'--expect-passwordless-user',
'--expect-release-services',
'source-ref:',
'type=gha,scope=${CACHE_SCOPE}',
'ignore-error=true',
'qemu-results.json',
],
'image workflow contract',
$rg,
)
if "$(^env $rg --fixed-strings --count-matches -- '--expect-passwordless-user' $image_workflow)" != '2' {
    profile_error('both release QEMU consumers must assert the passwordless user')
}
if "$(^env $rg --fixed-strings --count-matches -- '--expect-release-services' $image_workflow)" != '2' {
    profile_error('both release QEMU consumers must inspect the installed service set')
}
let security_workflow = "$root/.github/workflows/security.yml"
if "$(^sed -n '1p' $security_workflow)" != 'name: Security' {
    profile_error('security workflow name must preserve the Security badge label')
}
require_markers(
$security_workflow,
[
'qualify_security',
'name: security-required',
'DEPENDENCY_RESULT',
'CARGO_RESULT',
'cron: "17 4 * * 1"',
'make flash-bootstrap',
'make flash-automation-tools',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/classify_changes.fsh --null',
],
'security workflow aggregate contract',
$rg,
)
reject_markers(
$security_workflow,
[
"pull_request:\n    paths:",
"  push:\n    branches: [main]",
'python3 ci/classify_changes.py',
],
'security workflow retains redundant policy routing',
$rg,
)
let coverage_workflow = "$root/.github/workflows/coverage.yml"
require_markers(
$coverage_workflow,
[
'name: Coverage',
'workflow_dispatch:',
'id-token: write',
'rustup component add llvm-tools-preview',
'tool: cargo-llvm-cov@0.8.7',
'fallback: none',
'FLASH_AUTOMATION_TAPLO:',
'FLASH_AUTOMATION_JQ:',
'FLASH_AUTOMATION_RG:',
'make flash-bootstrap',
'make flash-automation-tools',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_coverage.fsh coverage/flash.lcov',
'use_oidc: true',
'version: v11.3.1',
'files: coverage/flash.lcov',
'disable_search: true',
'fail_ci_if_error: true',
],
'coverage workflow contract',
$rg,
)
reject_markers(
$coverage_workflow,
[
"  push:\n    branches: [main]",
'  pull_request:',
'  schedule:',
'python3 ../../ci/check_coverage.py',
],
'coverage must remain an explicitly requested diagnostic',
$rg,
)
let ci_workflow = "$root/.github/workflows/ci.yml"
require_markers(
$ci_workflow,
[
"python3 -m unittest discover -s ci/tests -p 'test_*.py'",
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_developer_interface.fsh',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_profile.fsh',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_platform.fsh',
'types: [opened, synchronize, reopened, ready_for_review]',
'ref: ${{ github.event.pull_request.head.sha || github.sha }}',
'name: change-classification',
'git diff --name-only --no-renames -z',
'make flash-bootstrap',
'make flash-automation-tools',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/classify_changes.fsh --null',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/aggregate_ci.fsh',
"needs.scope.outputs.image_required == 'true'",
'root-target-v1-',
'flash-target-v1-',
'github.event.pull_request.draft == false',
'release-evidence: false',
'PR_DRAFT:',
"\n  required:\n",
],
'standard CI candidate-qualification contract',
$rg,
)
reject_markers(
$ci_workflow,
[
'tools/flashos/',
"  push:\n",
"  schedule:\n",
'qualify_image',
'python3 ci/classify_changes.py',
'python3 ci/aggregate_ci.py',
],
'standard CI must not retain redundant orchestration',
$rg,
)
require_markers(
"$root/ci/aggregate_ci.fsh",
[
'classification requires successful product qualification',
'image qualification ran contrary to classification',
],
'standard CI aggregate contract',
$rg,
)
require_markers(
"$root/.github/workflows/main-qualification.yml",
[
'name: Main verified',
"push:\n    branches: [main]",
'actions: read',
'pull-requests: read',
'name: verified',
'make flash-bootstrap',
'make flash-automation-tools',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_main_qualification.fsh',
],
'main qualification workflow contract',
$rg,
)
require_markers(
"$root/ci/check_main_qualification.fsh",
[
"qualify('main'",
'GITHUB_SHA',
'GITHUB_STEP_SUMMARY',
'main qualification: ok:',
],
'main qualification entry-point contract',
$rg,
)
require_markers(
"$root/ci/check_candidate_qualification.fsh",
[
"qualify('candidate'",
'SOURCE_SHA',
'GITHUB_OUTPUT',
'required_run_id=',
'security_run_id=',
],
'candidate qualification entry-point contract',
$rg,
)
require_markers(
"$root/ci/lib/github_qualification.fsh",
[
"'ci.yml'",
"'security.yml'",
"'change-classification'",
"'image-and-runtime / qemu-artifact-consumer'",
"['security-required']",
"['cargo-policy', 'dependency-review']",
'select_main_pull',
'select_candidate_pull',
'main tree $source_tree differs from qualified candidate tree',
'candidate source tree $source_tree differs from qualified pull-request tree',
'for attempt in 1..=3',
],
'shared hosted qualification evidence contract',
$rg,
)
require_markers(
"$root/codecov.yml",
['project: off', 'patch: off', 'comment: false', 'github_checks: false'],
'informational Codecov policy',
$rg,
)
require_markers(
"$root/recipes/terminal/flash/recipe.toml",
[
'COOKBOOK_CARGO_PATH="crates/flash-cli" cookbook_cargo --bin fsh',
'COOKBOOK_CARGO_PATH="crates/flash-lsp" cookbook_cargo --bin flash-language-server',
'name = "lsp"',
'"usr/bin/flash-language-server"',
],
'Flash workspace recipe is missing packaged binary build',
$rg,
)
require_markers(
"$root/recipes/core/relibc/recipe.toml",
[
'name = "dev"',
'"usr/include/**"',
'"usr/lib/*.a"',
'"usr/lib/*.o"',
],
'relibc runtime/development package split is incomplete',
$rg,
)
require_markers(
"$root/mk/prefix.mk",
[
'cp -r "$(RELIBC_TARGET)/stage.dev/usr/". "$@.partial/$(GNU_TARGET)"',
'cp -r "$(RELIBC_TARGET)/stage.dev/usr/". "$@.partial"',
'cp -r "$(RELIBC_FREESTANDING_TARGET)/stage.dev/usr/". "$@.partial/$(GNU_TARGET)"',
],
'compiler sysroot must retain the relibc development projection',
$rg,
)
require_markers(
"$root/recipes/core/base/recipe.toml",
[
'"bootloader"',
'"${COOKBOOK_STAGE}/usr/bin/redoxerd"',
'"${COOKBOOK_STAGE}/usr/lib/drivers/vboxd"',
'"${COOKBOOK_STAGE}/usr/lib/pcid.d/vboxd.toml"',
],
'base runtime exclusion contract is incomplete',
$rg,
)
require_markers(
"$root/recipes/core/kernel/recipe.toml",
[
'"${COOKBOOK_STAGE}/usr/lib/boot/kernel.all"',
'"${COOKBOOK_STAGE}/usr/lib/boot/kernel.sym"',
],
'kernel runtime/debug separation is incomplete',
$rg,
)
require_markers(
"$root/recipes/groups/sys/recipe.toml",
['"relibc.dev"'],
'system build group must select the relibc development projection',
$rg,
)
require_markers(
"$root/recipes/tests/os-test-result/recipe.toml",
['"relibc.dev"'],
'relibc tests must select the relibc development projection',
$rg,
)

for package in [
'base',
'bootloader',
'coreutils',
'flash',
'installer',
'kernel',
'libgcc',
'netdb',
'netutils',
'redoxfs',
'relibc',
'userutils',
'uutils',
] {
    mut recipe = ''
    for section in ['core', 'libs', 'terminal'] {
        let candidate = "$root/recipes/$section/$package/recipe.toml"
        if $recipe == '' && ^test -f $candidate {
            $recipe = $candidate
        }
    }
    if $recipe == '' {
        continue
    }
    let recipe_json = "$temporary/recipe.json"
    let recipe_document = toml_to_json($recipe, $errors)
    ^printf '%s\n' $recipe_document > $recipe_json
    let git_source = "$(^env $jq --raw-output '.source.git // ""' $recipe_json)"
    if $git_source == '' {
        continue
    }
    let revision = "$(^env $jq --raw-output '.source.rev // ""' $recipe_json)"
    if ^printf '%s' $revision | ^env $rg --quiet '^[0-9a-f]{40}$' {
    } else {
        profile_error("shipped recipe is not pinned to an immutable revision: $recipe")
    }
}
let container_recipe = "$root/ci/container/Dockerfile"
if "$(^env $rg --pcre2 --count-matches '^ARG REDOX_BASE_IMAGE=\S+@sha256:[0-9a-f]{64}$' $container_recipe)" != '1' {
    profile_error('CI container base image must have one immutable digest')
}
if "$(^env $rg --pcre2 --count-matches '^ARG RUSTUP_SHA256=[0-9a-f]{64}$' $container_recipe)" != '1' {
    profile_error('CI container Rust installer must have one SHA-256 checksum')
}
require_markers(
$container_recipe,
[
'FROM ${REDOX_BASE_IMAGE}',
'sha256sum --check --strict -',
'cargo install --locked',
],
'CI container supply-chain contract',
$rg,
)
require_markers(
"$root/Makefile",
[
"curl --fail --location --retry 3 --proto '=https'",
'test "$$observed" = "$$expected"',
],
'automation-tool download contract',
$rg,
)
require_markers(
"$root/ci/qemu_smoke.py",
[
'choices=("nvme", "usb")',
'snapshot=on',
'QUALIFICATION_VCPUS = 1',
'str(QUALIFICATION_VCPUS)',
'expected_banner = f"FlashOS {version}".encode()',
'b"Redox OS distribution"',
'"--expect-passwordless-user"',
'if args.expect_passwordless_user:',
'reject=b"password:"',
'"--expect-release-services"',
'if args.expect_release_services:',
'RELEASE_INIT_SERVICES',
],
'QEMU qualification contract',
$rg,
)
for workflow in glob("$root/.github/workflows/*.yml") {
    let unpinned = "$(^env $rg --pcre2 --line-number '^\s*(?:-\s+)?uses:\s+(?!\./)(?!\S+@[0-9a-f]{40}(?:\s+#.*)?$)\S+' $workflow)"
    if $status.ok && $unpinned != '' {
        profile_error("GitHub Action is not pinned to an immutable commit: $workflow:$unpinned")
    }
}
for patch in [
'recipes/core/bootloader/flashos-branding.patch',
'recipes/core/installer/flashos-branding.patch',
'recipes/core/kernel/flashos-branding.patch',
'recipes/core/userutils/flashos-branding.patch',
] {
    if ^test -f "$root/$patch" {
    } else {
        profile_error("branding patches are missing: $patch")
    }
    let inherited = "$(^env $rg --line-number '^\+(?!\+\+).*(Redox OS distribution|Welcome to Redox OS|redox login:)' --pcre2 "$root/$patch")"
    if $status.ok && $inherited != '' {
        profile_error("branding patch adds inherited product identity: $patch:$inherited")
    }
}
require_markers(
"$root/src/web.rs",
['https://github.com/ajhahnde/FlashOS'],
'package web source links must default to the FlashOS repository',
$rg,
)
reject_markers(
"$root/src/web.rs",
['this_repo: "https://gitlab.redox-os.org/redox-os/redox"'],
'package web source links still point to the inherited Redox repository',
$rg,
)

if $artifact_mode {
    for metadata in [
    'recipes/core/base/target/x86_64-unknown-redox/stage.toml',
    'recipes/core/coreutils/target/x86_64-unknown-redox/stage.toml',
    'recipes/terminal/flash/target/x86_64-unknown-redox/stage.toml',
    'recipes/terminal/flash/target/x86_64-unknown-redox/stage.lsp.toml',
    'recipes/core/kernel/target/x86_64-unknown-redox/stage.toml',
    'recipes/libs/libgcc/target/x86_64-unknown-redox/stage.toml',
    'recipes/core/netdb/target/x86_64-unknown-redox/stage.toml',
    'recipes/core/netutils/target/x86_64-unknown-redox/stage.toml',
    'recipes/core/relibc/target/x86_64-unknown-redox/stage.toml',
    'recipes/core/userutils/target/x86_64-unknown-redox/stage.toml',
    'recipes/core/uutils/target/x86_64-unknown-redox/stage.toml',
    ] {
        let artifact = "$root/$metadata"
        if ^test -f $artifact {
        } else {
            profile_error("selected package metadata is missing: $metadata")
        }
        if $metadata == 'recipes/terminal/flash/target/x86_64-unknown-redox/stage.lsp.toml' {
            require_markers($artifact, ['depends = ["flash"]'], 'selected language-server package lost its runtime dependency', $rg)
        } else {
            require_markers($artifact, ['depends = []'], 'selected runtime package gained an uncollected dependency', $rg)
        }
        if ^env $rg --quiet '^storage_size = [1-9][0-9]*$' $artifact {
        } else {
            profile_error("selected package has no measured storage size: $metadata")
        }
    }
    for required in [
    'recipes/core/bootloader/target/x86_64-unknown-redox/stage/usr/lib/boot/bootloader.efi',
    'recipes/core/bootloader/target/x86_64-unknown-redox/stage/usr/lib/boot/bootloader-live.efi',
    'recipes/core/kernel/target/x86_64-unknown-redox/stage/usr/lib/boot/kernel',
    'recipes/core/kernel/target/x86_64-unknown-redox/build/kernel.all',
    'recipes/core/kernel/target/x86_64-unknown-redox/build/kernel.sym',
    'recipes/core/relibc/target/x86_64-unknown-redox/stage/usr/lib/libc.so',
    'recipes/core/relibc/target/x86_64-unknown-redox/stage/usr/lib/ld64.so.1',
    'recipes/core/relibc/target/x86_64-unknown-redox/stage.dev/usr/include',
    'recipes/core/relibc/target/x86_64-unknown-redox/stage.dev/usr/lib/libc.a',
    'recipes/terminal/flash/target/x86_64-unknown-redox/stage/usr/bin/fsh',
    'recipes/terminal/flash/target/x86_64-unknown-redox/stage.lsp/usr/bin/flash-language-server',
    ] {
        if ^test -e "$root/$required" {
        } else {
            profile_error("required runtime or supporting artifact is missing: $required")
        }
    }
    for forbidden in [
    'recipes/core/base/target/x86_64-unknown-redox/stage/usr/bin/redoxerd',
    'recipes/core/base/target/x86_64-unknown-redox/stage/usr/lib/drivers/vboxd',
    'recipes/core/base/target/x86_64-unknown-redox/stage/usr/lib/pcid.d/vboxd.toml',
    'recipes/core/kernel/target/x86_64-unknown-redox/stage/usr/lib/boot/kernel.all',
    'recipes/core/kernel/target/x86_64-unknown-redox/stage/usr/lib/boot/kernel.sym',
    'recipes/core/relibc/target/x86_64-unknown-redox/stage/usr/include',
    'recipes/core/relibc/target/x86_64-unknown-redox/stage/usr/lib/libc.a',
    'recipes/terminal/flash/target/x86_64-unknown-redox/stage/usr/bin/flash-language-server',
    ] {
        if ^test -e "$root/$forbidden" {
            profile_error("excluded runtime artifact is still staged: $forbidden")
        }
    }
}
^rm -rf $temporary
if $artifact_mode {
    let base_init = "$root/recipes/core/base/target/x86_64-unknown-redox/stage/usr/lib/init.d"
    let expected_services = [
    "$base_init/00_base.target",
    "$base_init/00_fbcond.service",
    "$base_init/00_ipcd.service",
    "$base_init/00_pcid-spawner.service",
    "$base_init/00_ptyd.service",
    "$base_init/00_sudo.service",
    "$base_init/00_tmp",
    "$base_init/10_dhcpd.service",
    "$base_init/10_net.target",
    "$base_init/10_smolnetd.service",
    "$base_init/20_audiod.service",
    ]
    let observed_services = "$(^find $base_init -mindepth 1 -maxdepth 1 -print | ^sort)"
    let reviewed_services = "$(^printf '%s\n' ...$expected_services | ^sort)"
    if !$status.ok || $observed_services != $reviewed_services {
        profile_error('base service inventory differs from the reviewed release set')
    }
    for stage in [
    'recipes/core/coreutils/target/x86_64-unknown-redox/stage',
    'recipes/terminal/flash/target/x86_64-unknown-redox/stage',
    'recipes/terminal/flash/target/x86_64-unknown-redox/stage.lsp',
    'recipes/core/kernel/target/x86_64-unknown-redox/stage',
    'recipes/libs/libgcc/target/x86_64-unknown-redox/stage',
    'recipes/core/netdb/target/x86_64-unknown-redox/stage',
    'recipes/core/netutils/target/x86_64-unknown-redox/stage',
    'recipes/core/relibc/target/x86_64-unknown-redox/stage',
    'recipes/core/userutils/target/x86_64-unknown-redox/stage',
    'recipes/core/uutils/target/x86_64-unknown-redox/stage',
    ] {
        let unexpected_services = glob("$root/$stage/usr/lib/init.d/*")
        if $unexpected_services != [] {
            profile_error("selected package installs an unexpected service: ${$unexpected_services[0]}")
        }
    }
}
^printf 'profile contract: ok\n'
^printf 'release: %s\n' $version
^printf 'packages: base, coreutils, flash, flash.lsp, kernel, libgcc, netdb, netutils, relibc, userutils, uutils\n'
if $artifact_mode {
    ^printf 'artifacts: runtime and supporting stages are separated\n'
    ^printf 'services: reviewed local/system set; no network-login daemon\n'
}
^printf 'interface: TUI-only; framebuffer/input/audio retained\n'
