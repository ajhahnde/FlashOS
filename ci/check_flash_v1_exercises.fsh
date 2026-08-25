#!/usr/bin/env fsh
# Taplo and jq decode/project contract data; ripgrep exposes source markers.
# Flash owns schemas, namespaces, ownership, ordering, evidence, and diagnostics.

import { require_jq, require_rg, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def exercises_error(message) {
    ^printf 'Flash v1 exercises: %s\n' $message 1>&2
    exit 1
}

def exercise_string(value, label) {
    if $value == null || $value == '' {
        throw "$label must be a non-empty string"
    }
    return $value
}

def exercise_list(values, label) {
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

def has_value(values, expected) -> Bool {
    for value in $values {
        if $value == $expected {
            return true
        }
    }
    return false
}

def quoted_list(values) {
    mut rendered = '['
    mut first = true
    for value in $values {
        if !$first {
            $rendered = "$rendered, "
        }
        $rendered = "$rendered'$value'"
        $first = false
    }
    return "$rendered]"
}

def surface_by_id(surfaces, identifier) {
    for surface in $surfaces {
        if $surface.id == $identifier {
            return $surface
        }
    }
    throw "missing closed surface $identifier"
}

def validate_exercises(bundle) {
    let expected_fields = [
    'compatibility',
    'compatibility_decision',
    'documentation_roots',
    'documentation_rule',
    'environment',
    'host_case_inventory',
    'host_evidence',
    'host_runner',
    'language_major',
    'schema_version',
    'suite_version',
    'surface',
    'target_fixtures',
    'target_matrix',
    ]
    if $bundle.contract_fields != $expected_fields {
        throw 'document fields do not match the exhaustive exercise schema'
    }
    let document = $bundle.contract
    for field in ['schema_version', 'suite_version', 'language_major'] {
        if $document[$field] != 1 {
            let observed = $document[$field]
            throw "$field is $observed, expected 1"
        }
    }
    let expected_scalars = {
        host_runner: 'exercises/run.fsh',
        host_case_inventory: 'exercises/host-cases-v1.json',
        host_evidence: 'exercises/evidence/host-v1.json',
        target_matrix: 'platforms/flashos-x86_64-target-matrix-v1.toml',
        target_fixtures: 'platforms/flashos-x86_64-runtime-fixtures-v1.toml',
    }
    for field in ['host_runner', 'host_case_inventory', 'host_evidence', 'target_matrix', 'target_fixtures'] {
        if $document[$field] != $expected_scalars[$field] {
            throw "$field does not preserve the frozen exercise path"
        }
    }
    exercise_string($document.compatibility_decision, 'compatibility_decision')

    let expected_environment_fields = ['availability', 'evidence_owner', 'id', 'limitations']
    let expected_environments = ['host-posix', 'flashos-qemu-x86_64', 'physical-flashos-x86_64']
    mut environment_index = 0
    for environment in $document.environment {
        if $bundle.environment_fields[$environment_index] != $expected_environment_fields {
            throw "environment[$environment_index] fields do not match the frozen schema"
        }
        if $environment_index >= 3 || $environment.id != $expected_environments[$environment_index] {
            throw 'environment ids do not preserve the frozen order'
        }
        for field in ['id', 'availability', 'evidence_owner', 'limitations'] {
            exercise_string($environment[$field], "environment[$environment_index].$field")
        }
        $environment_index = $environment_index + 1
    }
    if $environment_index != 3 {
        throw 'environment ids do not preserve the frozen order'
    }

    if $document.surface == [] {
        throw 'surface must be a non-empty array'
    }
    let required_surface_fields = ['category', 'exercise_case', 'flashos_owner', 'id', 'members']
    let allowed_surface_fields = ['category', 'exercise_case', 'flashos_owner', 'id', 'members', 'negative_case']
    let expected_categories = ['builtin', 'config', 'documentation', 'editor', 'frontend', 'intrinsic', 'language', 'lsp', 'platform', 'process']
    mut surface_index = 0
    for surface in $document.surface {
        let fields = $bundle.surface_fields[$surface_index]
        for required in $required_surface_fields {
            if !has_value($fields, $required) {
                throw "surface[$surface_index] is missing required fields"
            }
        }
        for field in $fields {
            if !has_value($allowed_surface_fields, $field) {
                throw "surface[$surface_index] has unknown fields"
            }
        }
        exercise_string($surface.id, "surface[$surface_index].id")
        exercise_string($surface.category, "surface[$surface_index].category")
        if !has_value($expected_categories, $surface.category) {
            throw "surface[$surface_index].category is unknown"
        }
        exercise_list($surface.members, "surface[$surface_index].members")
        exercise_string($surface.exercise_case, "surface[$surface_index].exercise_case")
        exercise_string($surface.flashos_owner, "surface[$surface_index].flashos_owner")
        if has_value($fields, 'negative_case') {
            exercise_string($surface.negative_case, "surface[$surface_index].negative_case")
        }
        for candidate in $document.surface {
            if $candidate.id == $surface.id {
                let matching_id = true
            }
            if $candidate.category == $surface.category {
                for member in $surface.members {
                    mut occurrences = 0
                    for candidate_member in $candidate.members {
                        if $candidate_member == $member {
                            $occurrences = $occurrences + 1
                        }
                    }
                    if $candidate.id != $surface.id && $occurrences > 0 {
                        let surface_category = $surface.category
                        throw "surface member $surface_category:$member has multiple owners"
                    }
                }
            }
        }
        mut id_occurrences = 0
        for candidate in $document.surface {
            if $candidate.id == $surface.id {
                $id_occurrences = $id_occurrences + 1
            }
        }
        if $id_occurrences != 1 {
            throw "surface[$surface_index].id is invalid or duplicated"
        }
        $surface_index = $surface_index + 1
    }
    for category in $expected_categories {
        mut present = false
        for surface in $document.surface {
            if $surface.category == $category {
                $present = true
            }
        }
        if !$present {
            throw 'surface categories do not preserve the closed category set'
        }
    }

    let intrinsics = ['env', 'float', 'glob', 'int']
    if surface_by_id($document.surface, 'expression-intrinsics').members != $intrinsics {
        throw 'expression-intrinsics does not match ExpressionIntrinsic::ALL'
    }
    let builtins = [
    'bg', 'cd', 'check', 'collect', 'command', 'decode', 'each', 'encode',
    'exit', 'fg', 'first', 'from', 'get', 'help', 'jobs', 'kill', 'last',
    'length', 'lines', 'ls', 'open', 'pwd', 'save', 'select', 'sort', 'to',
    'update', 'wait', 'where', 'which',
    ]
    if surface_by_id($document.surface, 'standard-builtins').members != $builtins {
        throw 'standard-builtins does not match the standard registry'
    }
    let config = ['pipefail', 'capture_limit', 'completion', 'history', 'prompt', 'continuation_prompt']
    if surface_by_id($document.surface, 'configuration').members != $config {
        throw 'configuration does not match the settings implementation'
    }
    let capabilities = [
    'environment', 'working-directory', 'file-actions', 'pipes',
    'process-spawn', 'process-groups', 'foreground-terminal', 'signals',
    'terminal-info', 'monotonic-clock', 'standard-directories',
    'directory-read', 'shell-executable', 'hangup-disposition',
    ]
    if surface_by_id($document.surface, 'platform-capabilities').members != $capabilities {
        throw 'platform-capabilities does not match Capability::ALL'
    }

    if $bundle.host_fields != ['command_cases', 'owners', 'schema_version', 'smoke_cases'] {
        throw 'host case inventory fields do not match the frozen schema'
    }
    if $bundle.host.schema_version != 1 {
        throw 'host case inventory schema_version must be 1'
    }
    let smoke = exercise_list($bundle.host.smoke_cases, 'host case inventory.smoke_cases')
    let commands = exercise_list($bundle.host.command_cases, 'host case inventory.command_cases')
    if $bundle.host_owner_fields == [] {
        throw 'host case inventory.owners must be a non-empty object'
    }
    for surface in $document.surface {
        for field in ['exercise_case', 'negative_case'] {
            if $field in $surface {
                let owner = $surface[$field]
                if !has_value($bundle.host_owner_fields, $owner) {
                    throw 'host case ownership does not match the contract'
                }
                let selected = $bundle.host.owners[$owner]
                if !has_value($smoke, $selected) && !has_value($commands, $selected) {
                    throw 'host case owners are not executable'
                }
            }
        }
    }
    for owner in $bundle.host_owner_fields {
        mut required = false
        for surface in $document.surface {
            if $surface.exercise_case == $owner {
                $required = true
            }
            if 'negative_case' in $surface && $surface.negative_case == $owner {
                $required = true
            }
        }
        if !$required {
            throw 'host case ownership does not match the contract'
        }
    }

    let qualification = $bundle.report.qualification
    let valid_report_owner = "capability-report:$qualification"
    for surface in $document.surface {
        let owner = $surface.flashos_owner
        mut valid = $owner == $valid_report_owner
        for matrix_case in $bundle.matrix.case {
            let matrix_id = $matrix_case.id
            if $owner == "target-matrix:$matrix_id" {
                $valid = true
            }
        }
        if !$valid {
            let surface_id = $surface.id
            throw "surface '$surface_id' has unknown FlashOS owner '$owner'"
        }
    }

    let expected_roots = ['README.md', 'docs/architecture.md', 'docs/development.md', 'docs/language-guide.md', 'docs/scripting.md']
    let roots = exercise_list($document.documentation_roots, 'documentation_roots')
    if $roots != $expected_roots {
        throw 'documentation_roots do not preserve the complete documentation set'
    }
    if $document.documentation_rule == [] {
        throw 'documentation_rule must be a non-empty array'
    }
    let rule_fields = ['classification', 'evidence_owner', 'first_block', 'last_block', 'path']
    let block_counts = [4, 11, 63, 65, 66]
    mut rule_index = 0
    for rule in $document.documentation_rule {
        if $bundle.documentation_rule_fields[$rule_index] != $rule_fields {
            throw "documentation_rule[$rule_index] fields do not match the frozen schema"
        }
        exercise_string($rule.path, "documentation_rule[$rule_index].path")
        exercise_string($rule.classification, "documentation_rule[$rule_index].classification")
        exercise_string($rule.evidence_owner, "documentation_rule[$rule_index].evidence_owner")
        mut root_index = 0
        mut known_root = false
        for root_path in $roots {
            if $rule.path == $root_path {
                $known_root = true
                if $rule.first_block < 1 || $rule.last_block < $rule.first_block || $rule.last_block > $block_counts[$root_index] {
                    throw "documentation_rule[$rule_index] has an invalid block interval"
                }
            }
            $root_index = $root_index + 1
        }
        if !$known_root {
            throw "documentation_rule[$rule_index].path is not a documentation root"
        }
        $rule_index = $rule_index + 1
    }
    mut root_index = 0
    for root_path in $roots {
        for ordinal in 1..=$block_counts[$root_index] {
            mut owners = 0
            for rule in $document.documentation_rule {
                if $rule.path == $root_path && $ordinal >= $rule.first_block && $ordinal <= $rule.last_block {
                    $owners = $owners + 1
                }
            }
            if $owners > 1 {
                throw "documentation block $root_path#$ordinal has multiple owners"
            }
            if $owners == 0 {
                throw 'documentation ownership is incomplete'
            }
        }
        $root_index = $root_index + 1
    }

    if $document.compatibility == [] {
        throw 'compatibility must be a non-empty array'
    }
    let compatibility_fields = ['classification', 'id', 'marker', 'owner', 'path']
    let compatibility_ids = ['analysis-control', 'execution-loaders', 'namespace-evolution-machinery']
    mut compatibility_index = 0
    for record in $document.compatibility {
        if $bundle.compatibility_fields[$compatibility_index] != $compatibility_fields {
            throw "compatibility[$compatibility_index] fields do not match the frozen schema"
        }
        for field in $compatibility_fields {
            exercise_string($record[$field], "compatibility[$compatibility_index].$field")
        }
        if $compatibility_index >= 3 || $record.id != $compatibility_ids[$compatibility_index] {
            throw 'compatibility ownership does not preserve the classified records'
        }
        mut duplicates = 0
        for candidate in $document.compatibility {
            if $candidate.path == $record.path && $candidate.marker == $record.marker {
                $duplicates = $duplicates + 1
            }
        }
        if $duplicates != 1 {
            throw 'duplicate compatibility owner'
        }
        $compatibility_index = $compatibility_index + 1
    }
    if $compatibility_index != 3 {
        throw 'compatibility ownership does not preserve the classified records'
    }

    let evidence = $bundle.evidence
    let expected_evidence_fields = ['candidate', 'contract_cases', 'environment', 'limitations', 'profile', 'results', 'schema_version', 'suite_version']
    if $bundle.evidence_fields != $expected_evidence_fields {
        let actual_fields = quoted_list($bundle.evidence_fields)
        let required_fields = quoted_list($expected_evidence_fields)
        throw "host evidence fields are $actual_fields, expected $required_fields"
    }
    if $evidence.schema_version != 1 {
        throw 'host evidence schema_version must be 1'
    }
    if $evidence.suite_version != $document.suite_version {
        throw 'host evidence suite_version does not match the contract'
    }
    if !($evidence.profile in ['ci', 'full']) {
        throw 'host evidence must record the complete ci or full profile'
    }
    let candidate_fields = ['commit', 'source_sha256', 'tree', 'worktree']
    if $bundle.candidate_fields != $candidate_fields {
        throw 'host evidence candidate fields do not match the frozen schema'
    }
    for field in $candidate_fields {
        exercise_string($evidence.candidate[$field], "host evidence candidate.$field")
    }
    let environment_fields = ['architecture', 'cargo', 'flash', 'id', 'rustc', 'system']
    if $bundle.evidence_environment_fields != $environment_fields {
        let actual_fields = quoted_list($bundle.evidence_environment_fields)
        let required_fields = quoted_list($environment_fields)
        throw "host evidence environment fields are $actual_fields, expected $required_fields"
    }
    if $evidence.environment.id != 'host-posix' {
        throw 'host evidence must identify the host-posix environment'
    }
    for field in ['system', 'architecture', 'flash', 'rustc', 'cargo'] {
        exercise_string($evidence.environment[$field], "host evidence environment.$field")
    }
    if $evidence.environment.flash != 'fsh 1.0.0' {
        throw 'host evidence must identify the Flash 1.0.0 driving runtime'
    }
    if $bundle.evidence_contract_cases != $bundle.host_owners {
        throw 'host evidence contract-case ownership is stale'
    }
    if $evidence.results == [] {
        throw 'host evidence results must be a non-empty array'
    }
    mut result_index = 0
    for expected in $smoke {
        if $evidence.results[$result_index].id != $expected {
            throw 'host evidence does not contain every executable case in order'
        }
        $result_index = $result_index + 1
    }
    for expected in $commands {
        if $evidence.results[$result_index].id != $expected {
            throw 'host evidence does not contain every executable case in order'
        }
        $result_index = $result_index + 1
    }
    for result in $evidence.results {
        if $result.result != 'pass' {
            throw 'host evidence contains a non-pass result'
        }
    }
    let expected_limitations = [
    'Host results do not establish FlashOS target behavior.',
    'Physical-device execution remains identification- and approval-gated.',
    'Flash v1 has no guaranteed scope-exit cleanup; interruption or a runtime adapter failure can leave the owned temporary directory for inspection.',
    ]
    if $evidence.limitations != $expected_limitations {
        throw 'host evidence limitations do not match the native Flash runner'
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
let temporary = "$(^mktemp -d "$temporary_parent/flash-exercise-contract.XXXXXX")"
if !$status.ok {
    exercises_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
for input in [
{name: 'contract', path: "$flash_root/exercises/v1.toml", type: 'toml'},
{name: 'matrix', path: "$flash_root/platforms/flashos-x86_64-target-matrix-v1.toml", type: 'toml'},
{name: 'report', path: "$flash_root/platforms/flashos-x86_64-capability-report-v1.toml", type: 'toml'},
] {
    let decoded = toml_to_json($input.path, $errors)
    let name = $input.name
    ^printf '%s' $decoded > "$temporary/$name.json" || exit 1
}
^cp "$flash_root/exercises/host-cases-v1.json" "$temporary/host.json" || exit 1
^cp "$flash_root/exercises/evidence/host-v1.json" "$temporary/evidence.json" || exit 1
let bundle = "$temporary/bundle.json"
^env $jq --slurpfile contract "$temporary/contract.json" \
--slurpfile host "$temporary/host.json" \
--slurpfile matrix "$temporary/matrix.json" \
--slurpfile report "$temporary/report.json" \
--slurpfile evidence "$temporary/evidence.json" \
'{contract: $contract[0], contract_fields: ($contract[0] | keys | sort), environment_fields: [$contract[0].environment[] | (keys | sort)], surface_fields: [$contract[0].surface[] | (keys | sort)], documentation_rule_fields: [$contract[0].documentation_rule[] | (keys | sort)], compatibility_fields: [$contract[0].compatibility[] | (keys | sort)], host: $host[0], host_fields: ($host[0] | keys | sort), host_owner_fields: ($host[0].owners | keys | sort), host_owners: ($host[0].owners | to_entries | sort_by(.key)), matrix: $matrix[0], report: $report[0], evidence: $evidence[0], evidence_fields: ($evidence[0] | keys | sort), candidate_fields: ($evidence[0].candidate | keys | sort), evidence_environment_fields: ($evidence[0].environment | keys | sort), evidence_contract_cases: ($evidence[0].contract_cases | to_entries | sort_by(.key))}' \
-n > $bundle
if !$status.ok {
    ^rm -rf $temporary
    exercises_error('cannot project the exercise contracts')
}
try {
    open $bundle | from json | each {|value| validate_exercises($value)} | to json >/dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    exercises_error($message)
}

let documentation_paths = ['README.md', 'docs/architecture.md', 'docs/development.md', 'docs/language-guide.md', 'docs/scripting.md']
let documentation_fences = ['8', '22', '126', '130', '132']
mut documentation_index = 0
for relative in $documentation_paths {
    let count = "$(^env $rg --count-matches '^```' "$flash_root/$relative")"
    if $count != $documentation_fences[$documentation_index] {
        ^rm -rf $temporary
        exercises_error("$relative contains an unclosed or changed code-block inventory")
    }
    $documentation_index = $documentation_index + 1
}

mut compatibility_index = 0
mut compatibility_remaining = true
while $compatibility_remaining {
    let exists = "$(^env $jq --raw-output --argjson index $compatibility_index '.contract.compatibility | has($index)' $bundle)"
    if $exists != 'true' {
        $compatibility_remaining = false
        continue
    }
    let relative = "$(^env $jq --raw-output --argjson index $compatibility_index '.contract.compatibility[$index].path' $bundle)"
    let marker = "$(^env $jq --raw-output --argjson index $compatibility_index '.contract.compatibility[$index].marker' $bundle)"
    if ^env $rg --fixed-strings --quiet -- $marker "$flash_root/$relative" {
    } else {
        ^rm -rf $temporary
        exercises_error("compatibility[$compatibility_index].marker is absent from $relative")
    }
    $compatibility_index = $compatibility_index + 1
}

let intrinsic_lines = "$(^env $rg --multiline --only-matching 'pub const ALL: \[Self; 4\] = \[(?s:.*?)\];' "$flash_root/crates/flash-runtime/src/intrinsic.rs" | ^env $rg --only-matching --replace '$1' 'Self::([A-Za-z]+)' | ^tr '[:upper:]' '[:lower:]')"
if $intrinsic_lines != "env\nfloat\nglob\nint" {
    ^rm -rf $temporary
    exercises_error('expression intrinsics differ from the closed namespace')
}
let builtin_lines = "$(^env $rg --multiline --only-matching --replace '$1' 'CommandSignature::(?:new|passthrough)\(\s*"([a-z]+)"' "$flash_root/crates/flash-runtime/src/builtin.rs" | ^env LC_ALL=C sort -u)"
if $builtin_lines != "bg\ncd\ncheck\ncollect\ncommand\ndecode\neach\nencode\nexit\nfg\nfirst\nfrom\nget\nhelp\njobs\nkill\nlast\nlength\nlines\nls\nopen\npwd\nsave\nselect\nsort\nto\nupdate\nwait\nwhere\nwhich" {
    ^rm -rf $temporary
    exercises_error('standard built-ins differ from the closed namespace')
}
let config_lines = "$(^env $rg --only-matching --replace '$1' '^const [A-Z][A-Z0-9_]*_SETTING: &str = "([a-z][a-z0-9_]*)";$' "$flash_root/crates/flash-cli/src/config.rs")"
if $config_lines != "pipefail\ncapture_limit\ncompletion\nhistory\nprompt\ncontinuation_prompt" {
    ^rm -rf $temporary
    exercises_error('config settings differ from the closed namespace')
}

let candidates_nul = "$temporary/candidates.nul"
let candidates_lines = "$temporary/candidates-lines"
let candidates = "$temporary/candidates"
let digest_input = "$temporary/digest-input"
^git -C $root ls-files -co --exclude-standard -z > $candidates_nul
if !$status.ok {
    ^rm -rf $temporary
    exercises_error('cannot enumerate candidate sources')
}
^tr '\0' '\n' < $candidates_nul > $candidates_lines || exit 1
^env $rg --invert-match '^(components/flash/target/|components/flash/exercises/evidence/host-v1\.json)$' $candidates_lines \
| ^env LC_ALL=C sort > $candidates
if !$status.ok {
    ^rm -rf $temporary
    exercises_error('cannot filter candidate sources')
}
^printf '%s' '' > $digest_input || exit 1
mut digest_runner = env('FLASH_V1_BOOTSTRAP_FSH')
if $digest_runner == null || $digest_runner == '' {
    $digest_runner = 'fsh'
}
let digest_version = "$(^env $digest_runner --version)"
if !$status.ok || $digest_version != 'fsh 1.0.0' {
    ^rm -rf $temporary
    exercises_error('the source-digest helper requires an explicitly selected Flash 1.0.0 runtime')
}
^tr '\n' '\0' < $candidates \
| ^xargs -0 -n 64 $digest_runner "$flash_root/exercises/run.fsh" --internal-digest-append $digest_input
if !$status.ok {
    ^rm -rf $temporary
    exercises_error('cannot assemble the candidate source digest')
}
mut source_sha256 = ''
if ^shasum -a 256 $digest_input >/dev/null 2>&1 {
    $source_sha256 = "$(^shasum -a 256 $digest_input | ^cut -d ' ' -f 1)"
} else {
    $source_sha256 = "$(^sha256sum $digest_input | ^cut -d ' ' -f 1)"
}
if !$status.ok || $source_sha256 == '' {
    ^rm -rf $temporary
    exercises_error('cannot hash candidate sources')
}
let evidence_digest = "$(^env $jq --raw-output '.evidence.candidate.source_sha256' $bundle)"
if $evidence_digest != $source_sha256 {
    ^rm -rf $temporary
    exercises_error('host evidence does not match the current candidate source digest')
}

for field in ['host_runner', 'host_case_inventory', 'target_matrix', 'target_fixtures'] {
    let relative = "$(^env $jq --raw-output --arg field $field '.contract[$field]' $bundle)"
    if ^test -f "$flash_root/$relative" {
    } else {
        ^rm -rf $temporary
        exercises_error("$field does not name a file: $relative")
    }
}
for command in [
'build/flash-bootstrap/134635a5e1282b5d8455a4b2aeb754be5a3a77c1/fsh ci/check_flash_v1_exercises.fsh',
'components/flash/target/debug/fsh components/flash/exercises/run.fsh --profile ci --no-build',
] {
    let count = "$(^env $rg --fixed-strings --count-matches -- $command "$root/.github/workflows/ci.yml")"
    if $count != '1' {
        ^rm -rf $temporary
        exercises_error("CI workflow must contain exactly one '$command'")
    }
}
^rm -rf $temporary || exit 1
^printf '%s\n' 'Flash v1 exercises: exhaustive contract passed'
