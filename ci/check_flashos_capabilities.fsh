#!/usr/bin/env fsh
# Taplo decodes tracked TOML and jq exposes field names. ripgrep exposes exact
# source markers and the live Rust enum. Flash owns schema, ordering, evidence
# closure, repository boundaries, and all public diagnostics.

import { require_jq, require_rg, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def capability_error(message) {
    ^printf 'FlashOS capability evidence: %s\n' $message 1>&2
    exit 1
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

def validate_records(records, fields, ids, label) {
    if $records == null || $records == [] {
        throw "$label must be a non-empty array of tables"
    }
    let expected_fields = ['id', 'markers', 'observation', 'path']
    mut index = 0
    for record in $records {
        let item = "$label[$index]"
        if $fields[$index] != $expected_fields {
            throw "$item fields are unexpected"
        }
        let identifier = nonempty($record.id, "$item.id")
        mut occurrences = 0
        for candidate in $ids {
            if $candidate == $identifier {
                $occurrences = $occurrences + 1
            }
        }
        if $occurrences != 1 {
            throw "duplicate $label id '$identifier'"
        }
        nonempty($record.path, "$item.path")
        validate_strings($record.markers, "$item.markers", true)
        nonempty($record.observation, "$item.observation")
        $index = $index + 1
    }
    return true
}

def validate(bundle) {
    let expected_fields = [
    'architecture',
    'capability',
    'classification',
    'contract_source',
    'platform',
    'platform_baseline',
    'runtime_evidence',
    'schema_version',
    'selected_adapter',
    'source_evidence',
    'target',
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
        contract_source: 'components/flash/crates/flash-platform/src/lib.rs',
        selected_adapter: 'flash-platform-flashos::FlashOsPlatform',
        classification: 'deferred',
    }
    for field in [
    'schema_version',
    'platform',
    'architecture',
    'target',
    'platform_baseline',
    'contract_source',
    'selected_adapter',
    'classification',
    ] {
        if $document[$field] != $expected[$field] {
            throw "$field is '${$document[$field]}', expected '${$expected[$field]}'"
        }
    }
    if $bundle.baseline.architecture != $document.architecture {
        throw 'architecture does not match the platform baseline'
    }
    if $bundle.baseline.target.triple != $document.target {
        throw 'target does not match the platform baseline'
    }

    validate_records(
    $document.source_evidence,
    $bundle.source_fields,
    $bundle.source_ids,
    'source_evidence',
    )
    validate_records(
    $document.runtime_evidence,
    $bundle.runtime_fields,
    $bundle.runtime_ids,
    'runtime_evidence',
    )
    if $document.capability == null || $document.capability == [] {
        throw 'capability must be a non-empty array of tables'
    }
    let expected_capability_fields = [
    'classification',
    'name',
    'requirements',
    'runtime_evidence',
    'runtime_observation',
    'rust_variant',
    'source_evidence',
    'source_observation',
    ]
    mut index = 0
    for capability in $document.capability {
        let label = "capability[$index]"
        if $bundle.capability_fields[$index] != $expected_capability_fields {
            throw "$label fields are unexpected"
        }
        let name = nonempty($capability.name, "$label.name")
        let variant = nonempty($capability.rust_variant, "$label.rust_variant")
        validate_strings($capability.requirements, "$label.requirements", true)
        let selected_source = validate_strings(
        $capability.source_evidence,
        "$label.source_evidence",
        true,
        )
        let selected_runtime = validate_strings(
        $capability.runtime_evidence,
        "$label.runtime_evidence",
        false,
        )
        for identifier in $selected_source {
            if !($identifier in $bundle.source_ids) {
                throw "$label references unknown source evidence '$identifier'"
            }
        }
        for identifier in $selected_runtime {
            if !($identifier in $bundle.runtime_ids) {
                throw "$label references unknown runtime evidence '$identifier'"
            }
        }
        nonempty($capability.source_observation, "$label.source_observation")
        nonempty($capability.runtime_observation, "$label.runtime_observation")
        if $capability.classification != 'deferred' {
            throw "$label.classification must remain 'deferred'"
        }
        $index = $index + 1
    }
    for name in $bundle.capability_names {
        mut occurrences = 0
        for candidate in $bundle.capability_names {
            if $candidate == $name {
                $occurrences = $occurrences + 1
            }
        }
        if $occurrences != 1 {
            throw 'capability names contain duplicates'
        }
    }
    for variant in $bundle.capability_variants {
        mut occurrences = 0
        for candidate in $bundle.capability_variants {
            if $candidate == $variant {
                $occurrences = $occurrences + 1
            }
        }
        if $occurrences != 1 {
            throw 'capability rust_variant values contain duplicates'
        }
    }
    if $bundle.capability_variants != $bundle.contract_variants {
        throw 'manifest variants do not match the live contract enum'
    }
    if !same_set($bundle.used_source, $bundle.source_ids) {
        throw 'unreferenced source evidence ids'
    }
    if !same_set($bundle.used_runtime, $bundle.runtime_ids) {
        throw 'unreferenced runtime evidence ids'
    }
    return true
}

def validate_record_files(bundle, section, label, root, rg, jq) {
    mut index = 0
    mut records_remaining = true
    while $records_remaining {
        let exists = "$(^env $jq --raw-output --arg section $section --argjson index $index '.document[$section] | has($index)' $bundle)"
        if $exists != 'true' {
            $records_remaining = false
            continue
        }
        let item = "$label[$index]"
        let relative = "$(^env $jq --raw-output --arg section $section --argjson index $index '.document[$section][$index].path' $bundle)"
        if ^printf '%s' $relative | ^env $rg --quiet '(^/|(^|/)\.\.(/|$))' {
            throw "$item.path must stay inside the repository"
        }
        let path = "$root/$relative"
        if ^test -f $path {
        } else {
            throw "cannot read $relative"
        }
        mut marker_index = 0
        mut markers_remaining = true
        while $markers_remaining {
            let marker_exists = "$(^env $jq --raw-output --arg section $section --argjson index $index --argjson marker $marker_index '.document[$section][$index].markers | has($marker)' $bundle)"
            if $marker_exists != 'true' {
                $markers_remaining = false
                continue
            }
            let marker = "$(^env $jq --raw-output --arg section $section --argjson index $index --argjson marker $marker_index '.document[$section][$index].markers[$marker]' $bundle)"
            if ^env $rg --fixed-strings --quiet -- $marker $path {
            } else {
                throw "$item marker is absent from $relative: '$marker'"
            }
            $marker_index = $marker_index + 1
        }
        $index = $index + 1
    }
}

let root = repository_root('versions.env')
let rg = require_rg()
let jq = require_jq()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flashos-capabilities.XXXXXX")"
if !$status.ok {
    capability_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
let evidence = "$temporary/evidence.json"
let baseline = "$temporary/baseline.json"
let bundle = "$temporary/bundle.json"
let evidence_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-capability-evidence.toml",
$errors,
)
^printf '%s\n' $evidence_document > $evidence
let baseline_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64.toml",
$errors,
)
^printf '%s\n' $baseline_document > $baseline
let variants = "$temporary/variants.json"
^sed -n '/^pub enum Capability {$/,/^}$/p' "$root/components/flash/crates/flash-platform/src/lib.rs" \
| ^env $rg --only-matching --replace '$1' '^    ([A-Z][A-Za-z0-9]+),$' \
| ^env $jq --raw-input --slurp 'split("\n") | map(select(length > 0))' > $variants
if !$status.ok {
    capability_error('cannot locate the Capability enum')
}
^env $jq \
--slurpfile baseline $baseline \
--slurpfile variants $variants \
'{document:., fields:(keys|sort), baseline:$baseline[0], contract_variants:$variants[0], source_fields:(try [.source_evidence[]|(keys|sort)] catch []), source_ids:(try [.source_evidence[].id] catch []), runtime_fields:(try [.runtime_evidence[]|(keys|sort)] catch []), runtime_ids:(try [.runtime_evidence[].id] catch []), capability_fields:(try [.capability[]|(keys|sort)] catch []), capability_names:(try [.capability[].name] catch []), capability_variants:(try [.capability[].rust_variant] catch []), used_source:(try [.capability[].source_evidence[]] catch []), used_runtime:(try [.capability[].runtime_evidence[]] catch [])}' \
$evidence > $bundle 2> $errors
if !$status.ok {
    capability_error('cannot project the capability evidence contract')
}
try {
    open $bundle | from json | each {|document| validate($document)} | to json > /dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    capability_error($message)
}
try {
    validate_record_files($bundle, 'source_evidence', 'source_evidence', $root, $rg, $jq)
    validate_record_files($bundle, 'runtime_evidence', 'runtime_evidence', $root, $rg, $jq)
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    capability_error($message)
}
if ^env $rg --fixed-strings --quiet -- 'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_capabilities.fsh' "$root/.github/workflows/ci.yml" {
} else {
    ^rm -rf $temporary
    capability_error('standard CI does not validate the capability evidence inventory')
}
^rm -rf $temporary
^printf 'FlashOS capability evidence: source/runtime comparison contract passed for x86_64-unknown-redox\n'
