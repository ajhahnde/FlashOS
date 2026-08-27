#!/usr/bin/env fsh
# The native matrix renderer validates the versioned matrix schema and projects
# its JSON-v1 byte boundary. Taplo decodes linked platform records, jq exposes
# ordered associations and byte observations, and ripgrep exposes the selected
# adapter and consumers. Flash owns advertised capability policy, case/operation
# ownership, UART limits, coverage, and diagnostics.

import { require_jq, require_rg, selected_tool, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def matrix_error(message) {
    ^printf 'FlashOS target matrix: %s\n' $message 1>&2
    exit 1
}

def require_runtime(program) {
    let observed = "$(^env $program --version 2>/dev/null)"
    if !$status.ok || $observed != 'fsh 1.0.0' {
        matrix_error("fsh version differs: expected fsh 1.0.0, observed $observed")
    }
    return $program
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
    let required_surfaces = [
    'startup',
    'config-options',
    'script-execution',
    'builtins',
    'argv-environment',
    'working-directory',
    'pipelines',
    'redirections',
    'cancellation',
    'history',
    'completion',
    'structured-data',
    'typed-capture',
    'structured-errors',
    'dynamic-external',
    'status-conditions',
    'glob',
    'unicode-multiline-editing',
    'job-semantics',
    'clean-exit',
    'language-values',
    'language-control',
    'functions-modules',
    'intrinsics',
    'launcher-frontends',
    'language-server',
    'documentation-examples',
    'intentional-refusals',
    ]
    let matrix = $bundle.matrix
    if $matrix.required_surfaces != $required_surfaces {
        throw 'required surfaces do not preserve the complete ordered target set'
    }
    if $bundle.report.target_matrix != 'flashos-x86_64-target-matrix-v1.toml' {
        throw 'capability report does not reference the selected target matrix'
    }
    if $bundle.report_count == 0 {
        throw 'capability report has no capability array'
    }
    if $bundle.classification_count != $bundle.report_count {
        throw 'capability classification does not cover the report'
    }
    if $bundle.operation_count == 0 {
        throw 'capability classification has no operation array'
    }
    if $bundle.omitted_name == null {
        throw 'selected adapter withholds an unknown capability'
    }
    if $matrix.withheld_capabilities != [$bundle.omitted_name] {
        throw 'withheld capabilities do not match the selected adapter'
    }
    if $bundle.reported_withheld != [$bundle.omitted_name] {
        throw 'capability report and selected adapter disagree on the withheld set'
    }
    mut case_index = 0
    for selected_case in $matrix.cases {
        let identifier = $selected_case.id
        for surface in $selected_case.surfaces {
            if !($surface in $required_surfaces) {
                throw "case '$identifier' has unknown surfaces"
            }
        }
        for capability in $selected_case.capabilities {
            if !($capability in $bundle.advertised) {
                throw "case '$identifier' has unadvertised capabilities"
            }
        }
        mut operation_index = 0
        for operation_id in $selected_case.operation_ids {
            let capability = $bundle.case_operation_capabilities[$case_index][$operation_index]
            if $capability == null {
                throw "case '$identifier' references unknown operation '$operation_id'"
            }
            if !($capability in $selected_case.capabilities) {
                throw "case '$identifier' operation '$operation_id' belongs to undeclared capability '$capability'"
            }
            $operation_index = $operation_index + 1
        }
        mut step_index = 0
        for step in $selected_case.steps {
            let observation = $bundle.step_observations[$case_index][$step_index]
            if $step.send == 'script' {
                if $observation.script_reader_bytes + $bundle.terminator_bytes > $matrix.max_interaction_bytes {
                    throw "case '$identifier' script reader exceeds the target UART boundary"
                }
            }
            if $step.send == 'line' && !$observation.starts_declared_prompt {
                throw "case '$identifier' line rendering does not start with a declared prompt"
            }
            mut interaction_bytes = $observation.payload_bytes
            if $step.send == 'line' {
                $interaction_bytes = $interaction_bytes + $bundle.terminator_bytes
            }
            if $step.send in ['line', 'keys'] && $interaction_bytes > $matrix.max_interaction_bytes {
                throw "case '$identifier' interactive input exceeds the target UART boundary"
            }
            $step_index = $step_index + 1
        }
        $case_index = $case_index + 1
    }
    if !same_set($bundle.seen_surfaces, $required_surfaces) {
        throw 'matrix cases do not cover every required surface'
    }
    if !same_set($bundle.seen_capabilities, $bundle.advertised) {
        throw 'matrix cases do not cover every advertised capability'
    }
    if !same_set($bundle.seen_operations, $bundle.expected_operations) {
        throw 'matrix operations must have complete single ownership'
    }
    for operation in $bundle.seen_operations {
        mut occurrences = 0
        for candidate in $bundle.seen_operations {
            if $candidate == $operation {
                $occurrences = $occurrences + 1
            }
        }
        if $occurrences != 1 {
            throw 'matrix operations must have complete single ownership'
        }
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
let temporary = "$(^mktemp -d "$temporary_parent/flashos-target-validation.XXXXXX")"
if !$status.ok {
    matrix_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
let matrix = "$temporary/matrix.json"
let report = "$temporary/report.json"
let classification = "$temporary/classification.json"
let bundle = "$temporary/bundle.json"
^env $runtime ci/flashos_target_matrix.fsh --output json-v1 > $matrix 2> $errors
if !$status.ok {
    ^cat $errors 1>&2
    ^rm -rf $temporary
    matrix_error('target-matrix contract is invalid')
}
let report_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-capability-report-v1.toml",
$errors,
)
^printf '%s\n' $report_document > $report
let classification_document = toml_to_json(
"$root/components/flash/platforms/flashos-x86_64-capability-classification.toml",
$errors,
)
^printf '%s\n' $classification_document > $classification
let omitted_variant = "$(^env $rg --only-matching --replace '$1' 'Capabilities::full_without\(Capability::([A-Za-z]+)\)' "$root/components/flash/crates/flash-platform-flashos/src/lib.rs")"
if $omitted_variant == '' {
    ^rm -rf $temporary
    matrix_error('selected adapter capability declaration has an unknown shape')
}
^env $jq \
--slurpfile report $report \
--slurpfile classification $classification \
--arg omitted_variant $omitted_variant \
'. as $matrix | ($report[0].capability | map(select(.rust_variant == $omitted_variant)) | .[0].name) as $omitted_name | {matrix:$matrix, report:$report[0], classification:$classification[0], report_count:(try ($report[0].capability|length) catch 0), classification_count:(try ($classification[0].capability|length) catch 0), operation_count:(try ($classification[0].operation|length) catch 0), omitted_name:$omitted_name, advertised:(try [$report[0].capability[]|select(.advertised == true)|.name] catch []), reported_withheld:(try [$report[0].capability[]|select(.advertised == false)|.name] catch []), case_operation_capabilities:(try [.cases[] | [.operation_ids[] as $id | ([$classification[0].operation[] | select(.id == $id) | .capability][0] // null)]] catch []), seen_surfaces:(try [.cases[].surfaces[]] catch []), seen_capabilities:(try [.cases[].capabilities[]] catch []), seen_operations:(try [.cases[].operation_ids[]] catch []), expected_operations:(try [$classification[0].operation[] | .capability as $name | select(any($report[0].capability[]; .name == $name and .advertised == true)) | .id] catch []), terminator_bytes:(.terminator.data|length/2), step_observations:(try [.cases[] | [.steps[] | . as $step | {payload_bytes:(if $step.payload.encoding == "utf8" then ($step.payload.text|utf8bytelength) else ($step.payload.data|length/2) end), script_reader_bytes:("^head -c" + ((if $step.payload.encoding == "utf8" then ($step.payload.text|length) else ($step.payload.data|length/2) end)|tostring) + ">m" | utf8bytelength), starts_declared_prompt:($step.rendered != null and ([ $matrix.prompts[].text | . as $prompt | ($step.rendered.text | startswith($prompt)) ] | any))}]] catch [])}' \
$matrix > $bundle 2> $errors
if !$status.ok {
    matrix_error('cannot project the target-matrix relationships')
}
try {
    open $bundle | from json | each {|document| validate($document)} | to json > /dev/null
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    matrix_error($message)
}
for marker in [
'load_target_matrix(args.target_matrix)',
'script_transport_chunks(',
'for case in target_matrix.cases:',
'for step in case.steps:',
] {
    if ^env $rg --fixed-strings --quiet -- $marker "$root/ci/qemu_smoke.py" {
    } else {
        ^rm -rf $temporary
        matrix_error("QEMU runner does not consume the target matrix: $marker")
    }
}
if ^env $rg --fixed-strings --quiet -- 'ci/check_flashos_target_matrix.fsh' "$root/.github/workflows/ci.yml" {
} else {
    ^rm -rf $temporary
    matrix_error('standard CI does not validate the target matrix')
}
^rm -rf $temporary
^printf 'FlashOS target matrix: advertised capability contract passed\n'
