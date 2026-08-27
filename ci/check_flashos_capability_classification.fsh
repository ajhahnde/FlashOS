#!/usr/bin/env fsh
# Taplo decodes the three tracked platform documents and jq exposes field names
# plus index-aligned observations. Flash owns verdict validity and precedence,
# basis selection, ordered coverage, qualification state, and diagnostics.

import { require_jq, require_rg, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def classification_error(message) {
    ^printf 'FlashOS capability classification: %s\n' $message 1>&2
    exit 1
}

def nonempty(value, label) {
    if $value == null || $value == '' {
        throw "$label must be a non-empty string"
    }
    return $value
}

def nonempty_list(values, label) {
    if $values == null || $values == [] {
        throw "$label must be a non-empty list of non-empty strings"
    }
    for selected in $values {
        if $selected == null || $selected == '' {
            throw "$label must be a non-empty list of non-empty strings"
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

def aggregate_verdict(verdicts) {
    if 'kernel-work' in $verdicts {
        return 'kernel-work'
    }
    if 'deliberately-unsupported' in $verdicts {
        return 'deliberately-unsupported'
    }
    if 'shimmed' in $verdicts {
        return 'shimmed'
    }
    return 'native'
}

def validate(bundle) {
    let expected_fields = [
    'architecture',
    'capability',
    'capability_evidence',
    'classification',
    'contract_source',
    'operation',
    'operation_map',
    'platform',
    'platform_baseline',
    'schema_version',
    'selected_adapter',
    'semantics',
    'target',
    'target_qualification',
    ]
    if $bundle.fields != $expected_fields {
        throw 'document fields are unexpected'
    }
    let document = $bundle.document
    let expected = {
        schema_version: 1,
        platform: 'flashos',
        architecture: 'x86_64',
        target: 'x86_64-unknown-redox',
        platform_baseline: 'flashos-x86_64.toml',
        capability_evidence: 'flashos-x86_64-capability-evidence.toml',
        operation_map: 'flashos-x86_64-operation-map.toml',
        contract_source: 'components/flash/crates/flash-platform/src/lib.rs',
        selected_adapter: 'flash-platform-flashos::FlashOsPlatform',
        classification: 'complete',
        target_qualification: 'pending',
    }
    for field in [
    'schema_version',
    'platform',
    'architecture',
    'target',
    'platform_baseline',
    'capability_evidence',
    'operation_map',
    'contract_source',
    'selected_adapter',
    'classification',
    'target_qualification',
    ] {
        if $document[$field] != $expected[$field] {
            throw "$field does not preserve the classification contract"
        }
    }
    let semantics_fields = [
    'aggregation',
    'deliberately_unsupported',
    'kernel_work',
    'native',
    'qualification',
    'shimmed',
    ]
    if $bundle.semantics_fields != $semantics_fields {
        throw 'semantics fields are unexpected'
    }
    for field in $semantics_fields {
        nonempty($document.semantics[$field], "semantics.$field")
    }
    if $bundle.baseline.architecture != $document.architecture {
        throw 'architecture does not match the platform baseline'
    }
    if $bundle.baseline.target.triple != $document.target {
        throw 'target does not match the platform baseline'
    }
    if $bundle.evidence.classification != 'deferred' {
        throw 'capability evidence classification must remain deferred'
    }
    if $bundle.map.classification != 'deferred' {
        throw 'operation map classification must remain deferred'
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
        if $bundle.map[$field] != $document[$field] {
            throw "$field does not match the operation map"
        }
    }
    if $bundle.map.capability_evidence != $document.capability_evidence {
        throw 'operation map does not reference the selected capability evidence'
    }

    if $bundle.mapped_operations == [] {
        throw 'operation map has no operation array'
    }
    if $document.operation == null || $bundle.operation_count != $bundle.mapped_operation_count {
        throw 'classification must cover every mapped operation exactly once'
    }
    let operation_fields = ['basis', 'capability', 'classification', 'id', 'rationale']
    let verdicts = ['native', 'shimmed', 'deliberately-unsupported', 'kernel-work']
    mut operation_index = 0
    for operation in $document.operation {
        let label = "operation[$operation_index]"
        if $bundle.operation_fields[$operation_index] != $operation_fields {
            throw "$label fields are unexpected"
        }
        let mapped = $bundle.mapped_operations[$operation_index]
        let identifier = nonempty($operation.id, "$label.id")
        let capability = nonempty($operation.capability, "$label.capability")
        let verdict = nonempty($operation.classification, "$label.classification")
        let basis = nonempty($operation.basis, "$label.basis")
        nonempty($operation.rationale, "$label.rationale")
        if !($verdict in $verdicts) {
            throw "$label.classification is not a classification verdict"
        }
        if $identifier != $mapped.id || $capability != $mapped.capability {
            throw "$label does not match the ordered operation map"
        }
        mut expected_basis = null
        if $verdict == 'native' {
            if $mapped.boundary == 'flash-internal' {
                $expected_basis = 'existing-flash-route'
            } else if $mapped.boundary == 'rust-std' {
                $expected_basis = 'existing-rust-std-route'
            } else if $mapped.boundary == 'libc-abi' {
                $expected_basis = 'existing-libc-abi-route'
            } else {
                throw "$label cannot classify an unrouted operation as native"
            }
        } else if $verdict == 'shimmed' {
            $expected_basis = 'flashos-policy-shim'
        } else if $verdict == 'deliberately-unsupported' {
            $expected_basis = 'deliberate-policy'
        } else {
            $expected_basis = 'missing-kernel-primitive'
        }
        if $basis != $expected_basis {
            throw "$label.basis does not match its classification and boundary"
        }
        let id_occurrences = $bundle.operation_id_counts[$operation_index]
        if $id_occurrences != 1 {
            throw 'operation ids contain duplicates'
        }
        $operation_index = $operation_index + 1
    }

    if $bundle.evidence_capabilities == [] {
        throw 'capability evidence has no capability array'
    }
    if $document.capability == null || $bundle.capability_count != $bundle.evidence_capability_count {
        throw 'classification must cover every capability exactly once'
    }
    let capability_fields = [
    'classification',
    'name',
    'operation_ids',
    'rationale',
    'rust_variant',
    'target_qualification',
    ]
    mut capability_index = 0
    for capability in $document.capability {
        let label = "capability[$capability_index]"
        if $bundle.capability_fields[$capability_index] != $capability_fields {
            throw "$label fields are unexpected"
        }
        let evidenced = $bundle.evidence_capabilities[$capability_index]
        let name = nonempty($capability.name, "$label.name")
        let variant = nonempty($capability.rust_variant, "$label.rust_variant")
        if $name != $evidenced.name || $variant != $evidenced.rust_variant {
            throw "$label does not match the ordered capability evidence"
        }
        let ids = nonempty_list($capability.operation_ids, "$label.operation_ids")
        if $ids != $bundle.capability_expected_ids[$capability_index] {
            throw "$label.operation_ids do not exactly cover the capability"
        }
        let verdict = nonempty($capability.classification, "$label.classification")
        if !($verdict in $verdicts) {
            throw "$label.classification is not a classification verdict"
        }
        let expected_verdict = aggregate_verdict($bundle.capability_operation_verdicts[$capability_index])
        if $verdict != $expected_verdict {
            throw "$label.classification does not match its operation aggregate"
        }
        if $capability.target_qualification != 'pending' {
            throw "$label.target_qualification must remain 'pending'"
        }
        nonempty($capability.rationale, "$label.rationale")
        $capability_index = $capability_index + 1
    }
    if $bundle.used_operation_ids != $bundle.operation_ids {
        throw 'capability operation lists do not preserve complete ordered coverage'
    }
    return true
}

let root = repository_root('versions.env')
let jq = require_jq()
let rg = require_rg()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flashos-classification.XXXXXX")"
if !$status.ok {
    classification_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
let classification = "$temporary/classification.json"
let baseline = "$temporary/baseline.json"
let evidence = "$temporary/evidence.json"
let map = "$temporary/map.json"
let bundle = "$temporary/bundle.json"
let classification_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-capability-classification.toml",
$errors,
)
^printf '%s\n' $classification_document > $classification
let baseline_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64.toml",
$errors,
)
^printf '%s\n' $baseline_document > $baseline
let evidence_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-capability-evidence.toml",
$errors,
)
^printf '%s\n' $evidence_document > $evidence
let map_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-operation-map.toml",
$errors,
)
^printf '%s\n' $map_document > $map
^env $jq \
--slurpfile baseline $baseline \
--slurpfile evidence $evidence \
--slurpfile map $map \
'. as $document | {document:$document, fields:(keys|sort), baseline:$baseline[0], evidence:$evidence[0], map:$map[0], semantics_fields:(try (.semantics|keys|sort) catch []), mapped_operations:(try $map[0].operation catch []), mapped_operation_count:(try ($map[0].operation|length) catch 0), operation_fields:(try [.operation[]|(keys|sort)] catch []), operation_count:(try (.operation|length) catch 0), operation_ids:(try [.operation[].id] catch []), operation_id_counts:(try [.operation[].id as $id | [$document.operation[].id | select(. == $id)] | length] catch []), evidence_capabilities:(try $evidence[0].capability catch []), evidence_capability_count:(try ($evidence[0].capability|length) catch 0), capability_fields:(try [.capability[]|(keys|sort)] catch []), capability_count:(try (.capability|length) catch 0), capability_expected_ids:(try [.capability[].name as $name | [$document.operation[] | select(.capability == $name) | .id]] catch []), capability_operation_verdicts:(try [.capability[].operation_ids as $ids | [$ids[] as $id | $document.operation[] | select(.id == $id) | .classification]] catch []), used_operation_ids:(try [.capability[].operation_ids[]] catch [])}' \
$classification > $bundle 2> $errors
if !$status.ok {
    classification_error('cannot project the capability classification')
}
try {
    open $bundle | from json | each {|document| validate($document)} | to json > /dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    classification_error($message)
}
if ^env $rg --fixed-strings --quiet -- 'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_capability_classification.fsh' "$root/.github/workflows/ci.yml" {
} else {
    ^rm -rf $temporary
    classification_error('standard CI does not validate the FlashOS capability classification')
}
^rm -rf $temporary
^printf 'FlashOS capability classification: contract passed for x86_64-unknown-redox\n'
