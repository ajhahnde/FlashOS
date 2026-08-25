#!/usr/bin/env fsh
# Taplo decodes report sources, jq exposes field names and fixture associations,
# and ripgrep exposes the selected adapter and public consumers. Flash owns
# version identity, capability order, advertised/withheld policy, fixture
# closure, qualification, and diagnostics.

import { require_jq, require_rg, selected_tool, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def report_error(message) {
    ^printf 'FlashOS capability report: %s\n' $message 1>&2
    exit 1
}

def require_runtime(program) {
    let observed = "$(^env $program --version 2>/dev/null)"
    if !$status.ok || $observed != 'fsh 1.0.0' {
        report_error("fsh version differs: expected fsh 1.0.0, observed $observed")
    }
    return $program
}

def nonempty(value, label) {
    if $value == null || $value == '' {
        throw "$label must be a non-empty string"
    }
    return $value
}

def validate_strings(values, label, nonempty_required) {
    if $values == null {
        throw "$label must be a list of non-empty strings"
    }
    if $nonempty_required && $values == [] {
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

def same_set(observed, expected) -> Bool {
    for value in $observed {
        if !($value in $expected) {
            return false
        }
    }
    for value in $expected {
        if !($value in $observed) {
            return false
        }
    }
    return true
}

def validate(bundle) {
    let expected_fields = [
    'architecture',
    'capability',
    'capability_classification',
    'capability_evidence',
    'contract_source',
    'flash_language_major',
    'flash_workspace_version',
    'flashos_release',
    'platform',
    'platform_baseline',
    'qualification',
    'report_version',
    'runtime_fixtures',
    'schema_version',
    'selected_adapter',
    'semantics',
    'target',
    'target_matrix',
    ]
    if $bundle.fields != $expected_fields {
        throw 'document fields are unexpected'
    }
    let document = $bundle.document
    let expected = {
        schema_version: 1,
        report_version: 1,
        platform: 'flashos',
        architecture: 'x86_64',
        target: 'x86_64-unknown-redox',
        flash_language_major: 1,
        flash_workspace_version: $bundle.workspace.workspace.package.version,
        flashos_release: $bundle.flashos_release,
        platform_baseline: 'flashos-x86_64.toml',
        capability_evidence: 'flashos-x86_64-capability-evidence.toml',
        capability_classification: 'flashos-x86_64-capability-classification.toml',
        runtime_fixtures: 'flashos-x86_64-runtime-fixtures-v1.toml',
        target_matrix: 'flashos-x86_64-target-matrix-v1.toml',
        contract_source: 'components/flash/crates/flash-platform/src/lib.rs',
        selected_adapter: 'flash-platform-flashos::FlashOsPlatform',
        qualification: 'bounded',
    }
    for field in [
    'schema_version',
    'report_version',
    'platform',
    'architecture',
    'target',
    'flash_language_major',
    'flash_workspace_version',
    'flashos_release',
    'platform_baseline',
    'capability_evidence',
    'capability_classification',
    'runtime_fixtures',
    'target_matrix',
    'contract_source',
    'selected_adapter',
    'qualification',
    ] {
        if $document[$field] != $expected[$field] {
            throw "$field does not preserve the versioned capability report"
        }
    }
    if $bundle.semantics_fields != ['advertised', 'scope', 'withheld'] {
        throw 'semantics fields are unexpected'
    }
    for field in ['advertised', 'withheld', 'scope'] {
        nonempty($document.semantics[$field], "semantics.$field")
    }
    for field in [
    'platform',
    'architecture',
    'target',
    'platform_baseline',
    'contract_source',
    'selected_adapter',
    ] {
        if $bundle.evidence[$field] != $document[$field] {
            throw "$field does not match the capability evidence"
        }
        if $bundle.classification[$field] != $document[$field] {
            throw "$field does not match the capability classification"
        }
    }
    if $bundle.evidence_count == 0 {
        throw 'capability evidence has no capability array'
    }
    if $bundle.classification_count != $bundle.evidence_count {
        throw 'capability classification does not cover the evidence'
    }
    if $bundle.report_count != $bundle.evidence_count {
        throw 'report must cover every capability exactly once'
    }
    for name in $bundle.evidence_names {
        if $name == null || $name == '' {
            throw 'evidence capability names contain duplicates or invalid records'
        }
        mut occurrences = 0
        for candidate in $bundle.evidence_names {
            if $candidate == $name {
                $occurrences = $occurrences + 1
            }
        }
        if $occurrences != 1 {
            throw 'evidence capability names contain duplicates or invalid records'
        }
    }
    if $bundle.omitted_name == null {
        throw 'selected adapter withholds an unknown capability'
    }
    if !same_set($bundle.fixture_capabilities, $bundle.advertised_names) {
        throw 'runtime fixtures must cover every advertised capability exactly as a set'
    }

    let capability_fields = [
    'advertised',
    'classification',
    'fixture_ids',
    'limitations',
    'name',
    'qualification',
    'rust_variant',
    'summary',
    ]
    mut index = 0
    for capability in $document.capability {
        let label = "capability[$index]"
        if $bundle.capability_fields[$index] != $capability_fields {
            throw "$label fields are unexpected"
        }
        let evidenced = $bundle.evidence.capability[$index]
        let classified = $bundle.classification.capability[$index]
        let name = nonempty($capability.name, "$label.name")
        let variant = nonempty($capability.rust_variant, "$label.rust_variant")
        if $name != $evidenced.name || $variant != $evidenced.rust_variant {
            throw "$label does not match the ordered capability evidence"
        }
        if $name != $classified.name || $variant != $classified.rust_variant {
            throw "$label does not match the ordered capability classification"
        }
        if $capability.classification != $classified.classification {
            throw "$label.classification does not match the route classification"
        }
        nonempty($capability.summary, "$label.summary")
        validate_strings($capability.limitations, "$label.limitations", true)
        if !($capability.advertised in [true, false]) {
            throw "$label.advertised must be a boolean"
        }
        let expected_advertised = $variant != $bundle.omitted_variant
        if $capability.advertised != $expected_advertised {
            throw "$label.advertised does not match the selected adapter"
        }
        mut expected_qualification = 'withheld'
        if $capability.advertised {
            $expected_qualification = 'bounded'
        }
        if $capability.qualification != $expected_qualification {
            throw "$label.qualification must be '$expected_qualification'"
        }
        let fixture_ids = validate_strings(
        $capability.fixture_ids,
        "$label.fixture_ids",
        $capability.advertised,
        )
        if !$capability.advertised && $fixture_ids != [] {
            throw "$label.fixture_ids must be empty while the capability is withheld"
        }
        for identifier in $fixture_ids {
            if !($identifier in $bundle.fixture_ids) {
                throw "$label references unknown fixture '$identifier'"
            }
        }
        if !$bundle.capability_fixture_membership[$index] {
            throw "$label references a fixture that does not declare capability '$name'"
        }
        $index = $index + 1
    }
    if !same_set($bundle.used_fixtures, $bundle.fixture_ids) {
        throw 'unreferenced runtime fixtures'
    }
    return true
}

let root = repository_root('versions.env')
let jq = require_jq()
let rg = require_rg()
let runtime_program = selected_tool(
'FLASH_AUTOMATION_RUNTIME',
'components/flash/target/debug/fsh',
)
let runtime = require_runtime($runtime_program)
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flashos-capability-report.XXXXXX")"
if !$status.ok {
    report_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
let report = "$temporary/report.json"
let evidence = "$temporary/evidence.json"
let classification = "$temporary/classification.json"
let workspace = "$temporary/workspace.json"
let fixtures = "$temporary/fixtures.json"
let bundle = "$temporary/bundle.json"
let report_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-capability-report-v1.toml",
$errors,
)
^printf '%s\n' $report_document > $report
let evidence_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-capability-evidence.toml",
$errors,
)
^printf '%s\n' $evidence_document > $evidence
let classification_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-capability-classification.toml",
$errors,
)
^printf '%s\n' $classification_document > $classification
let workspace_document = toml_to_json("$root/components/flash/Cargo.toml", $errors)
^printf '%s\n' $workspace_document > $workspace
^env $runtime \
ci/flashos_runtime_fixtures.fsh \
--output json-v1 > $fixtures 2> $errors
if !$status.ok {
    ^cat $errors 1>&2
    ^rm -rf $temporary
    report_error('runtime fixture contract is invalid')
}
let omitted_variant = "$(^env $rg --only-matching --replace '$1' 'Capabilities::full_without\(Capability::([A-Za-z]+)\)' "$root/components/flash/crates/flash-platform-flashos/src/lib.rs")"
if $omitted_variant == '' {
    ^rm -rf $temporary
    report_error('selected adapter capability declaration has an unknown shape')
}
let flashos_release = "$(^env $rg --only-matching --replace '$1' '^FLASHOS_RELEASE_VERSION=(.+)$' "$root/versions.env")"
if $flashos_release == '' {
    ^rm -rf $temporary
    report_error('FLASHOS_RELEASE_VERSION is missing')
}
^env $jq \
--slurpfile evidence $evidence \
--slurpfile classification $classification \
--slurpfile workspace $workspace \
--slurpfile fixtures $fixtures \
--arg omitted_variant $omitted_variant \
--arg flashos_release $flashos_release \
'. as $document | ($evidence[0].capability | map(select(.rust_variant == $omitted_variant)) | .[0].name) as $omitted_name | {document:$document, fields:(keys|sort), evidence:$evidence[0], classification:$classification[0], workspace:$workspace[0], fixtures:$fixtures[0], flashos_release:$flashos_release, semantics_fields:(try (.semantics|keys|sort) catch []), evidence_count:(try ($evidence[0].capability|length) catch 0), classification_count:(try ($classification[0].capability|length) catch 0), report_count:(try (.capability|length) catch 0), evidence_names:(try [$evidence[0].capability[].name] catch []), omitted_variant:$omitted_variant, omitted_name:$omitted_name, advertised_names:(try [.capability[]|select(.advertised == true)|.name] catch []), fixture_ids:(try [$fixtures[0].fixtures[].id] catch []), fixture_capabilities:(try [$fixtures[0].fixtures[].capabilities[]] catch []), capability_fields:(try [.capability[]|(keys|sort)] catch []), capability_fixture_membership:(try [.capability[] | .name as $name | .fixture_ids as $ids | all($ids[]; . as $id | any($fixtures[0].fixtures[]; .id == $id and (.capabilities | index($name) != null)))] catch []), used_fixtures:(try [.capability[].fixture_ids[]] catch [])}' \
$report > $bundle 2> $errors
if !$status.ok {
    report_error('cannot project the capability report')
}
try {
    open $bundle | from json | each {|document| validate($document)} | to json > /dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    report_error($message)
}
for marker in [
'load_fixture_suite(args.fixtures)',
'for fixture in runtime_suite.fixtures:',
'for step in fixture.steps:',
] {
    if ^env $rg --fixed-strings --quiet -- $marker "$root/ci/qemu_smoke.py" {
    } else {
        ^rm -rf $temporary
        report_error("QEMU runner does not consume the fixture contract: $marker")
    }
}
if ^env $rg --fixed-strings --quiet -- 'ci/check_flashos_capability_report.fsh' "$root/.github/workflows/ci.yml" {
} else {
    ^rm -rf $temporary
    report_error('standard CI does not validate the versioned capability report')
}
^rm -rf $temporary
^printf 'FlashOS capability report: bounded contract passed for x86_64-unknown-redox\n'
