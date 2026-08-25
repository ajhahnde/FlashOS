#!/usr/bin/env fsh
# Taplo decodes the platform documents and jq exposes field names and bounded
# cross-document projections. ripgrep exposes tracked markers and the live Rust
# enum. Flash owns ABI seam policy, operation ordering, routing, closure, and
# diagnostics.

import { require_jq, require_rg, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def operation_error(message) {
    ^printf 'FlashOS operation map: %s\n' $message 1>&2
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

def validate(bundle) {
    let expected_fields = [
    'abi_seam',
    'architecture',
    'capability_evidence',
    'classification',
    'compiler_source',
    'contract_source',
    'libc_source',
    'operation',
    'platform',
    'platform_baseline',
    'schema_version',
    'selected_adapter',
    'target',
    ]
    if $bundle.fields != $expected_fields {
        throw 'document fields are unexpected'
    }
    let document = $bundle.document
    let expected = {
        schema_version: 2,
        platform: 'flashos',
        architecture: 'x86_64',
        target: 'x86_64-unknown-redox',
        platform_baseline: 'flashos-x86_64.toml',
        capability_evidence: 'flashos-x86_64-capability-evidence.toml',
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
    'capability_evidence',
    'contract_source',
    'selected_adapter',
    'classification',
    ] {
        if $document[$field] != $expected[$field] {
            throw "$field does not preserve the operation-map contract"
        }
    }
    if $bundle.baseline.architecture != $document.architecture {
        throw 'architecture does not match the platform baseline'
    }
    if $bundle.baseline.target.triple != $document.target {
        throw 'target does not match the platform baseline'
    }
    if $bundle.compiler_fields != [
    'mapping_scope',
    'repository',
    'revision',
    'selector',
    'selector_kind',
    ] {
        throw 'compiler_source fields are unexpected'
    }
    let expected_compiler = {
        repository: $bundle.baseline.compiler.source,
        selector_kind: $bundle.baseline.compiler.source_selector_kind,
        selector: $bundle.baseline.compiler.source_selector,
        revision: $bundle.baseline.compiler.commit,
        mapping_scope: 'public-std-api',
    }
    if $document.compiler_source != $expected_compiler {
        throw 'compiler_source does not preserve the platform baseline identity'
    }
    if $bundle.libc_fields != ['mapping_revision', 'mapping_scope', 'repository'] {
        throw 'libc_source fields are unexpected'
    }
    let expected_libc = {
        repository: $bundle.baseline.libc.source,
        mapping_revision: $bundle.baseline.libc.configured_revision,
        mapping_scope: 'configured-source',
    }
    if $document.libc_source != $expected_libc {
        throw 'libc_source does not preserve the configured source identity'
    }
    if $bundle.evidence.classification != 'deferred' {
        throw 'capability evidence classification must remain deferred'
    }
    if $bundle.evidence_variants != $bundle.contract_variants {
        throw 'capability evidence no longer matches the live contract enum'
    }
    if $bundle.expected_operations == [] {
        throw 'capability evidence has no capability array'
    }

    if $document.abi_seam == null || $document.abi_seam == [] {
        throw 'abi_seam must be a non-empty array of tables'
    }
    let seam_fields = [
    'id',
    'interfaces',
    'observation',
    'paths',
    'provider',
    'revision',
    'symbols',
    'tracked_markers',
    'tracked_path',
    ]
    mut seam_index = 0
    for seam in $document.abi_seam {
        let label = "abi_seam[$seam_index]"
        if $bundle.seam_fields[$seam_index] != $seam_fields {
            throw "$label fields are unexpected"
        }
        let identifier = nonempty($seam.id, "$label.id")
        mut occurrences = 0
        for candidate in $bundle.seam_ids {
            if $candidate == $identifier {
                $occurrences = $occurrences + 1
            }
        }
        if $occurrences != 1 {
            throw "duplicate abi_seam id '$identifier'"
        }
        let provider = nonempty($seam.provider, "$label.provider")
        let revision = nonempty($seam.revision, "$label.revision")
        nonempty($seam.tracked_path, "$label.tracked_path")
        validate_strings($seam.tracked_markers, "$label.tracked_markers", true)
        let paths = validate_strings($seam.paths, "$label.paths", false)
        validate_strings($seam.interfaces, "$label.interfaces", true)
        let symbols = validate_strings($seam.symbols, "$label.symbols", false)
        nonempty($seam.observation, "$label.observation")
        if $provider == 'rust-std' {
            if $revision != 'unknown' || $paths != [] || $symbols != [] {
                throw "$label must preserve the unknown Rust source boundary without source paths or inferred libc symbols"
            }
        } else if $provider == 'relibc' {
            if $revision != $document.libc_source.mapping_revision || $paths == [] || $symbols == [] {
                throw "$label must use the configured relibc revision with non-empty source paths and ABI symbols"
            }
        } else {
            throw "$label.provider must be 'rust-std' or 'relibc'"
        }
        $seam_index = $seam_index + 1
    }

    if $document.operation == null || $document.operation == [] {
        throw 'operation must be a non-empty array of tables'
    }
    let operation_fields = [
    'abi_seams',
    'boundary',
    'capability',
    'classification',
    'id',
    'mapping_observation',
    'requirement',
    'source_evidence',
    ]
    mut operation_index = 0
    for operation in $document.operation {
        let label = "operation[$operation_index]"
        if $bundle.operation_fields[$operation_index] != $operation_fields {
            throw "$label fields are unexpected"
        }
        let identifier = nonempty($operation.id, "$label.id")
        mut occurrences = 0
        for candidate in $bundle.operation_ids {
            if $candidate == $identifier {
                $occurrences = $occurrences + 1
            }
        }
        if $occurrences != 1 {
            throw "duplicate operation id '$identifier'"
        }
        nonempty($operation.capability, "$label.capability")
        nonempty($operation.requirement, "$label.requirement")
        let evidence_ids = validate_strings(
        $operation.source_evidence,
        "$label.source_evidence",
        true,
        )
        for evidence_id in $evidence_ids {
            if !($evidence_id in $bundle.source_ids) {
                throw "$label references unknown source evidence '$evidence_id'"
            }
        }
        let seam_ids = validate_strings($operation.abi_seams, "$label.abi_seams", false)
        for seam_id in $seam_ids {
            if !($seam_id in $bundle.seam_ids) {
                throw "$label references unknown ABI seam '$seam_id'"
            }
        }
        let boundary = nonempty($operation.boundary, "$label.boundary")
        let providers = $bundle.operation_seam_providers[$operation_index]
        if $boundary in ['flash-internal', 'unrouted'] {
            if $seam_ids != [] {
                throw "$label boundary '$boundary' must not name an ABI seam"
            }
        } else if $boundary == 'rust-std' {
            if $seam_ids == [] || !('rust-std' in $providers) {
                throw "$label rust-std boundary must name a Rust standard-library seam"
            }
        } else if $boundary == 'libc-abi' {
            if $seam_ids == [] || !('relibc' in $providers) {
                throw "$label libc-abi boundary must name a relibc seam"
            }
        } else {
            throw "$label.boundary is not a mapping boundary"
        }
        nonempty($operation.mapping_observation, "$label.mapping_observation")
        if $operation.classification != 'deferred' {
            throw "$label.classification must remain 'deferred'"
        }
        $operation_index = $operation_index + 1
    }
    if $bundle.actual_operations != $bundle.expected_operations {
        throw 'operation sequence does not exactly cover capability requirements'
    }
    if !same_set($bundle.used_seams, $bundle.seam_ids) {
        throw 'unreferenced ABI seam ids'
    }
    return true
}

def validate_seam_files(bundle, root, rg, jq) {
    mut index = 0
    mut seams_remaining = true
    while $seams_remaining {
        let exists = "$(^env $jq --raw-output --argjson index $index '.document.abi_seam | has($index)' $bundle)"
        if $exists != 'true' {
            $seams_remaining = false
            continue
        }
        let label = "abi_seam[$index]"
        let relative = "$(^env $jq --raw-output --argjson index $index '.document.abi_seam[$index].tracked_path' $bundle)"
        if ^printf '%s' $relative | ^env $rg --quiet '(^/|(^|/)\.\.(/|$))' {
            throw "$label.tracked_path must stay inside the repository"
        }
        let path = "$root/$relative"
        if ^test -f $path {
        } else {
            throw "cannot read $relative"
        }
        mut marker_index = 0
        mut markers_remaining = true
        while $markers_remaining {
            let marker_exists = "$(^env $jq --raw-output --argjson index $index --argjson marker $marker_index '.document.abi_seam[$index].tracked_markers | has($marker)' $bundle)"
            if $marker_exists != 'true' {
                $markers_remaining = false
                continue
            }
            let marker = "$(^env $jq --raw-output --argjson index $index --argjson marker $marker_index '.document.abi_seam[$index].tracked_markers[$marker]' $bundle)"
            if ^env $rg --fixed-strings --quiet -- $marker $path {
            } else {
                throw "$label marker is absent from $relative: '$marker'"
            }
            $marker_index = $marker_index + 1
        }
        let provider = "$(^env $jq --raw-output --argjson index $index '.document.abi_seam[$index].provider' $bundle)"
        if $provider == 'relibc' {
            mut path_index = 0
            mut paths_remaining = true
            while $paths_remaining {
                let path_exists = "$(^env $jq --raw-output --argjson index $index --argjson path $path_index '.document.abi_seam[$index].paths | has($path)' $bundle)"
                if $path_exists != 'true' {
                    $paths_remaining = false
                    continue
                }
                let relibc_path = "$(^env $jq --raw-output --argjson index $index --argjson path $path_index '.document.abi_seam[$index].paths[$path]' $bundle)"
                if ^printf '%s' $relibc_path | ^env $rg --quiet '(^/|(^|/)\.\.(/|$))' {
                    throw "$label.paths must stay inside the relibc repository"
                }
                $path_index = $path_index + 1
            }
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
let temporary = "$(^mktemp -d "$temporary_parent/flashos-operation-map.XXXXXX")"
if !$status.ok {
    operation_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
let map = "$temporary/map.json"
let baseline = "$temporary/baseline.json"
let evidence = "$temporary/evidence.json"
let variants = "$temporary/variants.json"
let bundle = "$temporary/bundle.json"
let map_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-operation-map.toml",
$errors,
)
^printf '%s\n' $map_document > $map
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
^sed -n '/^pub enum Capability {$/,/^}$/p' "$root/components/flash/crates/flash-platform/src/lib.rs" \
| ^env $rg --only-matching --replace '$1' '^    ([A-Z][A-Za-z0-9]+),$' \
| ^env $jq --raw-input --slurp 'split("\n") | map(select(length > 0))' > $variants
if !$status.ok {
    operation_error('cannot locate the Capability enum')
}
^env $jq \
--slurpfile baseline $baseline \
--slurpfile evidence $evidence \
--slurpfile variants $variants \
'. as $document | {document:$document, fields:(keys|sort), baseline:$baseline[0], evidence:$evidence[0], contract_variants:$variants[0], compiler_fields:(try (.compiler_source|keys|sort) catch []), libc_fields:(try (.libc_source|keys|sort) catch []), evidence_variants:(try [$evidence[0].capability[].rust_variant] catch []), source_ids:(try [$evidence[0].source_evidence[].id] catch []), expected_operations:(try [$evidence[0].capability[] | .name as $capability | .requirements[] | {capability:$capability, requirement:.}] catch []), seam_fields:(try [.abi_seam[]|(keys|sort)] catch []), seam_ids:(try [.abi_seam[].id] catch []), operation_fields:(try [.operation[]|(keys|sort)] catch []), operation_ids:(try [.operation[].id] catch []), actual_operations:(try [.operation[]|{capability,requirement}] catch []), used_seams:(try [.operation[].abi_seams[]] catch []), operation_seam_providers:(try [.operation[] | [.abi_seams[] as $id | $document.abi_seam[] | select(.id == $id) | .provider]] catch [])}' \
$map > $bundle 2> $errors
if !$status.ok {
    operation_error('cannot project the operation-map contract')
}
try {
    open $bundle | from json | each {|document| validate($document)} | to json > /dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    operation_error($message)
}
try {
    validate_seam_files($bundle, $root, $rg, $jq)
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    operation_error($message)
}
if ^env $rg --fixed-strings --quiet -- 'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flashos_operation_map.fsh' "$root/.github/workflows/ci.yml" {
} else {
    ^rm -rf $temporary
    operation_error('standard CI does not validate the FlashOS operation map')
}
^rm -rf $temporary
^printf 'FlashOS operation map: mapping contract passed for x86_64-unknown-redox\n'
