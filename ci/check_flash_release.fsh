#!/usr/bin/env fsh
# Native dependencies decode TOML and project object field names. Flash owns
# release identity, package closure, ordering, source claims, and diagnostics.

import { require_jq, require_rg, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def release_error(message) {
    ^printf 'Flash release: %s\n' $message 1>&2
    exit 1
}

def release_string(value, label) {
    if $value == null || $value == '' {
        throw "$label must be a non-empty string"
    }
    return $value
}

def release_list(values, label, nonempty) {
    if $nonempty && $values == [] {
        throw "$label must not be empty"
    }
    for selected in $values {
        if $selected == null || $selected == '' {
            throw "$label must be a list of non-empty strings"
        }
        mut occurrences = 0
        for candidate in $values {
            if $candidate == $selected {
                $occurrences = $occurrences + 1
            }
        }
        if $occurrences != 1 {
            throw "$label contains duplicates"
        }
    }
    return $values
}

def package_version(packages, name) {
    mut found = null
    mut occurrences = 0
    for package in $packages {
        if $package.name == $name {
            $found = $package.version
            $occurrences = $occurrences + 1
        }
    }
    if $occurrences != 1 {
        return null
    }
    return $found
}

def validate_release(bundle) {
    let expected_fields = [
    'capability_report',
    'claim_documents',
    'conformance',
    'exercise_contract',
    'host_evidence',
    'language_major',
    'limitations',
    'qualified_environments',
    'release_date',
    'release_findings',
    'release_version',
    'required_checks',
    'schema_version',
    'status',
    'target_matrix',
    'unexamined_inventory_items',
    ]
    if $bundle.release_fields != $expected_fields {
        throw 'document fields do not match the Flash release schema'
    }
    let document = $bundle.release
    if $document.schema_version != 1 {
        throw 'schema_version must be 1'
    }
    let version = release_string($document.release_version, 'release_version')
    if $version != '1.0.0' {
        throw 'release_version must be 1.0.0'
    }
    if $document.language_major != 1 {
        throw 'language_major must be 1'
    }
    if $document.status != 'released' {
        throw "status must be 'released'"
    }
    release_string($document.release_date, 'release_date')
    if $bundle.workspace.workspace.package.version != $version {
        throw 'workspace version does not match the release version'
    }

    let flash_packages = [
    'flash-cli',
    'flash-lsp',
    'flash-platform',
    'flash-platform-flashos',
    'flash-platform-posix',
    'flash-runtime',
    'flash-syntax',
    ]
    for name in $flash_packages {
        let locked = package_version($bundle.lock.package, $name)
        if $locked == null {
            throw 'components/flash/Cargo.lock does not contain every Flash package'
        }
        if $locked != $version {
            throw 'components/flash/Cargo.lock retains pre-release Flash versions'
        }
    }
    for name in ['flash-platform', 'flash-runtime', 'flash-syntax'] {
        let locked = package_version($bundle.fuzz_lock.package, $name)
        if $locked == null {
            throw 'components/flash/fuzz/Cargo.lock does not contain every Flash package'
        }
        if $locked != $version {
            throw 'components/flash/fuzz/Cargo.lock retains pre-release Flash versions'
        }
    }

    let expected_references = {
        conformance: 'conformance/v1.toml',
        exercise_contract: 'exercises/v1.toml',
        host_evidence: 'exercises/evidence/host-v1.json',
        capability_report: 'platforms/flashos-x86_64-capability-report-v1.toml',
        target_matrix: 'platforms/flashos-x86_64-target-matrix-v1.toml',
    }
    for field in ['conformance', 'exercise_contract', 'host_evidence', 'capability_report', 'target_matrix'] {
        if $document[$field] != $expected_references[$field] {
            throw "$field does not select the released contract"
        }
    }
    if $bundle.conformance.language_major != 1 || $bundle.conformance.contract_status != 'frozen' {
        throw 'the released conformance contract identity is invalid'
    }
    if $bundle.exercises.language_major != 1 {
        throw 'exercise language major does not match the release'
    }
    if $bundle.report.flash_language_major != 1 {
        throw 'capability-report language major does not match the release'
    }
    if $bundle.report.flash_workspace_version != $version {
        throw 'capability-report workspace version does not match the release'
    }
    if $bundle.report.target_matrix != 'flashos-x86_64-target-matrix-v1.toml' {
        throw 'capability report does not select the release target matrix'
    }

    release_list($document.release_findings, 'release_findings', false)
    if $document.release_findings != [] {
        throw 'release_findings must be empty'
    }
    release_list($document.unexamined_inventory_items, 'unexamined_inventory_items', false)
    if $document.unexamined_inventory_items != [] {
        throw 'unexamined_inventory_items must be empty'
    }
    let environments = release_list($document.qualified_environments, 'qualified_environments', true)
    if $environments != ['host-posix', 'flashos-qemu-x86_64'] {
        throw 'qualified_environments must name the host and exact FlashOS candidate'
    }
    let expected_checks = [
    'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_capability_report.fsh',
    'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_target_matrix.fsh',
    'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flash_conformance.fsh',
    'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flash_v1_exercises.fsh',
    'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flash_release.fsh',
    'components/flash/target/debug/fsh components/flash/exercises/run.fsh --profile ci --no-build',
    ]
    let checks = release_list($document.required_checks, 'required_checks', true)
    if $checks != $expected_checks {
        throw 'required_checks do not preserve the release qualification set'
    }
    let expected_claims = [
    'components/flash/README.md',
    'components/flash/docs/README.md',
    'components/flash/docs/architecture.md',
    'components/flash/docs/development.md',
    'components/flash/docs/language-guide.md',
    'components/flash/docs/scripting.md',
    'docs/roadmap.md',
    ]
    let claims = release_list($document.claim_documents, 'claim_documents', true)
    if $claims != $expected_claims {
        throw 'claim_documents do not preserve the complete release claim set'
    }
    let expected_limitations = [
    'FlashOS product versions, images, tags, and publication remain separate release boundaries.',
    'Physical FlashOS hardware remains outside this component release and requires separately recorded, approval-gated evidence.',
    ]
    let limitations = release_list($document.limitations, 'limitations', true)
    if $limitations != $expected_limitations {
        throw 'limitations must preserve exact product-release and physical boundaries'
    }
    return true
}

let root = repository_root('versions.env')
let flash_root = "$root/components/flash"
let jq = require_jq()
let rg = require_rg()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flash-release.XXXXXX")"
if !$status.ok {
    release_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
for input in [
{name: 'release', path: "$flash_root/release/v1.toml"},
{name: 'workspace', path: "$flash_root/Cargo.toml"},
{name: 'lock', path: "$flash_root/Cargo.lock"},
{name: 'fuzz-lock', path: "$flash_root/fuzz/Cargo.lock"},
{name: 'conformance', path: "$flash_root/conformance/v1.toml"},
{name: 'exercises', path: "$flash_root/exercises/v1.toml"},
{name: 'report', path: "$flash_root/platforms/flashos-x86_64-capability-report-v1.toml"},
] {
    let decoded = toml_to_json($input.path, $errors)
    let input_name = $input.name
    ^printf '%s' $decoded > "$temporary/$input_name.json" || exit 1
}
let bundle = "$temporary/bundle.json"
^env $jq --slurpfile release "$temporary/release.json" \
--slurpfile workspace "$temporary/workspace.json" \
--slurpfile lock "$temporary/lock.json" \
--slurpfile fuzz_lock "$temporary/fuzz-lock.json" \
--slurpfile conformance "$temporary/conformance.json" \
--slurpfile exercises "$temporary/exercises.json" \
--slurpfile report "$temporary/report.json" \
'{release: $release[0], release_fields: ($release[0] | keys | sort), workspace: $workspace[0], lock: $lock[0], fuzz_lock: $fuzz_lock[0], conformance: $conformance[0], exercises: $exercises[0], report: $report[0]}' \
-n > $bundle
if !$status.ok {
    ^rm -rf $temporary
    release_error('cannot project the release contracts')
}
try {
    open $bundle | from json | each {|value| validate_release($value)} | to json >/dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    release_error($message)
}

let release_date = "$(^env $jq --raw-output '.release.release_date' $bundle)"
if ^printf '%s' $release_date | ^env $rg --quiet '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' {
} else {
    ^rm -rf $temporary
    release_error('release_date must be an ISO calendar date')
}
mut calendar_date = false
let bsd_date = "$(^date -j -f '%Y-%m-%d' $release_date '+%Y-%m-%d' 2>/dev/null)"
if $status.ok && $bsd_date == $release_date {
    $calendar_date = true
}
if !$calendar_date {
    let gnu_date = "$(^date -d $release_date '+%Y-%m-%d' 2>/dev/null)"
    if $status.ok && $gnu_date == $release_date {
        $calendar_date = true
    }
}
if !$calendar_date {
    ^rm -rf $temporary
    release_error('release_date must be an ISO calendar date')
}
for path in [
'components/flash/conformance/v1.toml',
'components/flash/exercises/v1.toml',
'components/flash/exercises/evidence/host-v1.json',
'components/flash/platforms/flashos-x86_64-capability-report-v1.toml',
'components/flash/platforms/flashos-x86_64-target-matrix-v1.toml',
] {
    if ^test -f "$root/$path" {
    } else {
        ^rm -rf $temporary
        release_error("release reference does not name a file: $path")
    }
}
let target_matrix = "$flash_root/platforms/flashos-x86_64-target-matrix-v1.toml"
let observed_version_count = "$(^env $rg --fixed-strings --count-matches 'fsh 1.0.0' $target_matrix)"
if $observed_version_count != '1' {
    ^rm -rf $temporary
    release_error('target matrix does not observe the exact released fsh version once')
}
let workflow = "$root/.github/workflows/ci.yml"
for check in [
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_capability_report.fsh',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_target_matrix.fsh',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flash_conformance.fsh',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flash_v1_exercises.fsh',
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flash_release.fsh',
'components/flash/target/debug/fsh components/flash/exercises/run.fsh --profile ci --no-build',
] {
    let count = "$(^env $rg --fixed-strings --count-matches -- $check $workflow)"
    if $count != '1' {
        ^rm -rf $temporary
        release_error("candidate workflow must contain exactly one '$check'")
    }
}
for claim in [
'components/flash/README.md',
'components/flash/docs/README.md',
'components/flash/docs/architecture.md',
'components/flash/docs/development.md',
'components/flash/docs/language-guide.md',
'components/flash/docs/scripting.md',
'docs/roadmap.md',
] {
    let path = "$root/$claim"
    if ^test -f $path {
    } else {
        ^rm -rf $temporary
        release_error("claim document does not name a file: $claim")
    }
    for marker in [
    'Flash v1.0 has not yet been released',
    'entering the v1 release candidate',
    'Now: Complete and qualify Flash v1',
    'one contiguous internal island',
    'remain required for Flash v1',
    ] {
        if ^env $rg --fixed-strings --quiet -- $marker $path {
            ^rm -rf $temporary
            release_error("$claim retains pre-release claim '$marker'")
        }
    }
}
let heading = "## [Unreleased]\n\n## [1.0.0] - $release_date"
if ^env $rg --multiline --fixed-strings --quiet -- $heading "$flash_root/CHANGELOG.md" {
} else {
    ^rm -rf $temporary
    release_error('component changelog does not promote the exact release and date')
}
^rm -rf $temporary || exit 1
^printf '%s\n' 'Flash release: 1.0.0 contract passed'
