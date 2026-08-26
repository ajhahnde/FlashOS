#!/usr/bin/env fsh
# Native dependencies: taplo 0.10.0 decodes TOML, jq 1.7.1 projects object
# field names, and ripgrep 15.2.0 exposes source matches. Flash owns every
# contract comparison, ordering rule, path boundary, and diagnostic.

import { require_jq, require_rg, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def conformance_error(message) {
    ^printf 'Flash v1 conformance: %s\n' $message 1>&2
    exit 1
}

def nonempty(value, label) {
    if $value == null || $value == '' {
        throw "$label must be a non-empty string"
    }
    return $value
}

def unique_nonempty(values, label) {
    if $values == [] {
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

def safe_file(root, flash_root, value, label, rg) {
    if ^printf '%s' $value | ^env $rg --quiet '(^/|(^|/)\.\.(/|$))' {
        throw "$label must stay inside components/flash"
    }
    let path = "$flash_root/$value"
    if ^test -f $path {
        let exists = true
    } else {
        throw "$label does not name a file: $value"
    }
    return $path
}

def owner_is_enabled(root, flash_root, owner, label, rg) {
    if ^printf '%s' $owner | ^env $rg --quiet '^[^:]+::[a-z][a-z0-9_]*$' {
    } else {
        throw "$label must use path::test_name syntax"
    }
    let relative = "$(^printf '%s' $owner | ^sed 's/::.*$//')"
    let test_name = "$(^printf '%s' $owner | ^sed 's/^.*:://')"
    if !$status.ok {
        throw "$label must use path::test_name syntax"
    }
    let path = safe_file($root, $flash_root, $relative, "$label path", $rg)
    let declaration = "(?m)^#\\[test\\]\\n(?:#\\[[^\\n]+\\]\\n)*fn $test_name\\(\\) \\{"
    if ^env $rg --multiline --quiet $declaration $path {
    } else {
        throw "$label does not resolve to an enabled #[test]: $owner"
    }
}

def list_has(values, expected) -> Bool {
    for value in $values {
        if $value == $expected {
            return true
        }
    }
    return false
}

def validate_boundaries(root, rg, jq, temporary) {
    let runtime_root = "$root/components/flash/crates/flash-runtime/src"
    let constructors = 'RuntimeErrorKind::Unsupported \{|Err\(RuntimeErrorKind::ExecutionUnsupported\)|RuntimeError::new\(RuntimeErrorKind::ExecutionUnsupported|=> RuntimeErrorKind::ExecutionUnsupported|self.error\(RuntimeErrorKind::ExecutionUnsupported|self.unsupported\("'
    let raw_hits = "$temporary/boundary-hits.ndjson"
    let hits = "$temporary/boundary-hits.json"
    ^env $rg --json --glob '*.rs' $constructors $runtime_root > $raw_hits
    if !$status.ok && $status.code != 1 {
        throw 'cannot inspect runtime refusal boundaries'
    }
    ^env $jq --slurp '[.[] | select(.type == "match") | {path: .data.path.text, line: .data.line_number, start: ([.data.line_number - 3, 1] | max), end: (.data.line_number - 1)}]' $raw_hits > $hits
    if !$status.ok {
        throw 'cannot project runtime refusal boundaries'
    }
    mut hit_index = 0
    mut hits_remaining = true
    while $hits_remaining {
        let exists = "$(^env $jq --raw-output --argjson index $hit_index 'has($index)' $hits)"
        if $exists != 'true' {
            $hits_remaining = false
            continue
        }
        let path = "$(^env $jq --raw-output --argjson index $hit_index '.[$index].path' $hits)"
        let line = "$(^env $jq --raw-output --argjson index $hit_index '.[$index].line' $hits)"
        let start = "$(^env $jq --raw-output --argjson index $hit_index '.[$index].start' $hits)"
        let end = "$(^env $jq --raw-output --argjson index $hit_index '.[$index].end' $hits)"
        let nearby = "$temporary/nearby-$hit_index"
        let sed_range = "$start,$end"
        ^sed -n "${$sed_range}p" $path > $nearby
        if !$status.ok {
            throw 'cannot inspect a runtime refusal boundary'
        }
        let category = "$(^env $rg --only-matching --replace '$1' '^\s*// flash-v1-boundary\(([a-z-]+)\): \S.*\.$' $nearby)"
        let annotation_count = "$(^env $rg --count-matches '^\s*// flash-v1-boundary\([a-z-]+\): \S.*\.$' $nearby)"
        let relative = "$(^realpath -m "--relative-to=$root" -- $path)"
        if $annotation_count != '1' {
            throw "$relative:$line needs one nearby flash-v1-boundary annotation"
        }
        if !($category in ['carrier-refusal', 'embedding-refusal', 'executor-invariant', 'platform-refusal']) {
            throw "$relative:$line uses unknown boundary category '$category'"
        }
        $hit_index = $hit_index + 1
    }
    for path in glob("$runtime_root/*.rs") {
        for marker in [
        'todo!()',
        'unimplemented!()',
        'not yet supported',
        'deferred to a later evaluation slice',
        'backend-only',
        ] {
            if ^env $rg --fixed-strings --quiet -- $marker $path {
                let relative = "$(^realpath -m "--relative-to=$root" -- $path)"
                throw "$relative retains forbidden marker '$marker'"
            }
        }
    }
}

def validate_document(bundle, root, flash_root, rg) {
    let document_fields = [
    'ci_workflow',
    'config_settings',
    'contract_status',
    'family',
    'language_major',
    'platform_contracts',
    'schema_version',
    'workspace_test_command',
    ]
    if $bundle.document_fields != $document_fields {
        throw 'document fields do not match the frozen conformance schema'
    }
    let document = $bundle.document
    if $document.schema_version != 1 {
        throw 'schema_version must be 1'
    }
    if $document.language_major != 1 {
        throw 'language_major must be 1'
    }
    if $document.contract_status != 'frozen' {
        throw "contract_status must be 'frozen'"
    }
    if $document.workspace_test_command != 'cargo test --workspace --locked' {
        throw 'workspace_test_command must run the complete locked workspace suite'
    }
    if $document.ci_workflow != '.github/workflows/ci.yml' {
        throw 'ci_workflow must name the standard candidate workflow'
    }

    let expected_families = [
    'syntax-values-and-expressions',
    'effectful-language-composition',
    'dynamic-status-environment-and-glob',
    'interactive-session-state',
    'execution-plan-inspection',
    'dynamic-external-execution',
    'typed-command-capture',
    'structured-language-errors',
    'static-contract-analysis',
    'complete-job-semantics',
    'grammar-aware-path-completion',
    'portable-interactive-behavior',
    'shared-developer-frontends',
    'flashos-platform-routes',
    ]
    let expected_family_fields = ['id', 'layers', 'summary', 'tests']
    mut family_index = 0
    for family in $document.family {
        if $bundle.family_fields[$family_index] != $expected_family_fields {
            throw "family[$family_index] fields do not match the frozen schema"
        }
        let label = "family[$family_index]"
        nonempty($family.id, "$label.id")
        if $family_index >= 14 || $family.id != $expected_families[$family_index] {
            throw 'family ids do not preserve the frozen order'
        }
        nonempty($family.summary, "$label.summary")
        let layers = unique_nonempty($family.layers, "$label.layers")
        for layer in $layers {
            if !($layer in ['syntax', 'runtime', 'cli', 'repl', 'checker', 'formatter', 'lsp', 'platform']) {
                throw "$label.layers contains unknown values"
            }
        }
        let tests = unique_nonempty($family.tests, "$label.tests")
        mut test_count = 0
        for owner in $tests {
            for earlier_family in $document.family {
                for candidate in $earlier_family.tests {
                    if $candidate == $owner {
                        let same_owner = true
                    }
                }
            }
            $test_count = $test_count + 1
        }
        if $test_count < 2 {
            throw "$label.tests must contain at least two executable owners"
        }
        $family_index = $family_index + 1
    }
    if $family_index != 14 {
        throw 'family ids do not preserve the frozen order'
    }
    for required_layer in ['syntax', 'runtime', 'cli', 'repl', 'checker', 'formatter', 'lsp', 'platform'] {
        mut covered = false
        for family in $document.family {
            if list_has($family.layers, $required_layer) {
                $covered = true
            }
        }
        if !$covered {
            throw 'covered layers do not preserve the frozen layer set'
        }
    }
    for family in $document.family {
        for owner in $family.tests {
            mut occurrences = 0
            for candidate_family in $document.family {
                for candidate in $candidate_family.tests {
                    if $candidate == $owner {
                        $occurrences = $occurrences + 1
                    }
                }
            }
            if $occurrences != 1 {
                throw 'test owners must not be reused across conformance families'
            }
        }
    }

    let contracts = unique_nonempty($document.platform_contracts, 'platform_contracts')
    let expected_contracts = [
    'ci/check_flashos_platform.fsh',
    'ci/check_flashos_capabilities.fsh',
    'ci/check_flashos_operation_map.fsh',
    'ci/check_flashos_capability_classification.fsh',
    ]
    if $contracts != $expected_contracts {
        throw 'platform_contracts do not preserve the frozen order'
    }
    mut contract_index = 0
    for contract in $contracts {
        $contract_index = $contract_index + 1
    }

    let expected_settings = ['pipefail', 'capture_limit', 'completion', 'history', 'prompt', 'continuation_prompt']
    let settings = unique_nonempty($document.config_settings, 'config_settings')
    if $settings != $expected_settings {
        throw 'config_settings do not preserve the frozen order'
    }
    return true
}

let root = repository_root('versions.env')
let flash_root = "$root/components/flash"
let rg = require_rg()
let jq = require_jq()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flash-conformance.XXXXXX")"
if !$status.ok {
    conformance_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
let raw = "$temporary/raw.json"
let bundle = "$temporary/bundle.json"
let document = toml_to_json("$flash_root/conformance/v1.toml", $errors)
^printf '%s' $document > $raw || exit 1
^env $jq '{document: ., document_fields: (keys | sort), family_fields: [.family[] | (keys | sort)]}' $raw > $bundle
if !$status.ok {
    ^rm -rf $temporary
    conformance_error('cannot project the conformance inventory')
}
try {
    open $bundle | from json | each {|value| validate_document($value, $root, $flash_root, $rg)} | to json >/dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    conformance_error($message)
}

mut family_index = 0
while $family_index < 14 {
    let identifier = "$(^env $jq --raw-output --argjson family $family_index '.document.family[$family].id' $bundle)"
    if ^printf '%s' $identifier | ^env $rg --quiet '^[a-z][a-z0-9-]*$' {
    } else {
        ^rm -rf $temporary
        conformance_error("family[$family_index].id is not a public kebab-case identifier")
    }
    mut test_index = 0
    mut tests_remaining = true
    while $tests_remaining {
        let exists = "$(^env $jq --raw-output --argjson family $family_index --argjson test $test_index '.document.family[$family].tests | has($test)' $bundle)"
        if $exists != 'true' {
            $tests_remaining = false
            continue
        }
        let owner = "$(^env $jq --raw-output --argjson family $family_index --argjson test $test_index '.document.family[$family].tests[$test]' $bundle)"
        try {
            owner_is_enabled($root, $flash_root, $owner, "family[$family_index].tests[$test_index]", $rg)
        } catch error {
            let message = $error.message
            ^rm -rf $temporary
            conformance_error($message)
        }
        $test_index = $test_index + 1
    }
    $family_index = $family_index + 1
}
for contract in [
'ci/check_flashos_platform.fsh',
'ci/check_flashos_capabilities.fsh',
'ci/check_flashos_operation_map.fsh',
'ci/check_flashos_capability_classification.fsh',
] {
    if ^test -f "$root/$contract" {
    } else {
        ^rm -rf $temporary
        conformance_error("platform contract does not name a file: $contract")
    }
}
let config_path = "$flash_root/crates/flash-cli/src/config.rs"
let projected_settings = "$(^env $rg --only-matching --replace '$1' '^const [A-Z][A-Z0-9_]*_SETTING: &str = "([a-z][a-z0-9_]*)";$' $config_path)"
let expected_lines = "pipefail\ncapture_limit\ncompletion\nhistory\nprompt\ncontinuation_prompt"
if $projected_settings != $expected_lines {
    ^rm -rf $temporary
    conformance_error('components/flash/crates/flash-cli/src/config.rs config settings differ from the frozen order')
}
let workflow = "$root/.github/workflows/ci.yml"
for fragment in [
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flash_conformance.fsh',
'cargo test --workspace --locked',
] {
    let count = "$(^env $rg --fixed-strings --count-matches -- $fragment $workflow)"
    if $count != '1' {
        ^rm -rf $temporary
        conformance_error("CI workflow must contain exactly one '$fragment'")
    }
}
try {
    validate_boundaries($root, $rg, $jq, $temporary)
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    conformance_error($message)
}
^rm -rf $temporary || exit 1
^printf '%s\n' 'Flash v1 conformance: ok'
