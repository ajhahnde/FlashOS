#!/usr/bin/env fsh
# taplo decodes TOML and jq composes decoded documents. Flash owns schema,
# uniqueness, bounds, ordering, summaries, budgets, and diagnostics.

import { require_jq, toml_to_json } from './lib/tools.fsh'

def contract_failure(message) {
    ^printf 'Flash benchmark contract: FAILED: %s\n' $message 1>&2 || exit 1
    exit 1
}

def usage_error(message) {
    ^printf 'usage: flash_benchmarks.fsh [-h] [--result RESULT] [--contract-only] [--contract-json-v1] [--evaluate EVALUATE] [--environment ENVIRONMENT]\n' 1>&2 || exit 2
    ^printf 'flash_benchmarks.fsh: error: %s\n' $message 1>&2 || exit 2
    exit 2
}

def print_help() {
    ^printf '%s\n' \
    'usage: flash_benchmarks.fsh [-h] [--result RESULT] [--contract-only] [--contract-json-v1] [--evaluate EVALUATE] [--environment ENVIRONMENT]' \
    '' 'options:' \
    '  -h, --help            show this help message and exit' \
    '  --result RESULT' '  --contract-only' '  --contract-json-v1' '  --evaluate EVALUATE' \
    '  --environment ENVIRONMENT' || exit 1
    exit 0
}

def sha256(path) {
    mut digest = ''
    if ^shasum --version > /dev/null 2>&1 {
        $digest = "$(^shasum -a 256 $path | ^cut -d ' ' -f 1)"
    } else {
        $digest = "$(^sha256sum $path | ^cut -d ' ' -f 1)"
    }
    if !$status.ok || $digest == '' { contract_failure("cannot hash benchmark input: $path") }
    $digest
}

def require(condition: Bool, message: String) {
    if !$condition { throw $message }
}

def count_matching(values, expected) -> Int {
    mut count = 0
    for value in $values { if $value == $expected { $count = $count + 1 } }
    $count
}

def nth_value(values, position: Int) -> Int {
    mut selected = null
    for candidate in $values {
        mut lower = 0
        mut equal = 0
        for value in $values {
            if $value < $candidate {
                $lower = $lower + 1
            } else if $value == $candidate {
                $equal = $equal + 1
            }
        }
        if $lower <= $position && $position < $lower + $equal { $selected = $candidate }
    }
    if $selected == null { throw 'cannot summarize an empty sample set' }
    $selected
}

def summarize(values) {
    mut length = 0
    for value in $values {
        require($value > 0, 'benchmark samples must be positive integers')
        $length = $length + 1
    }
    require($length > 0, 'benchmark samples must be positive integers')
    mut median = 0
    if $length % 2 == 1 {
        $median = nth_value($values, $length / 2)
    } else {
        $median = (nth_value($values, $length / 2 - 1) + nth_value($values, $length / 2)) / 2
    }
    {
        minimum: nth_value($values, 0),
        median: $median,
        p95: nth_value($values, ($length * 95 + 99) / 100 - 1),
        maximum: nth_value($values, $length - 1),
    }
}

def validate_profile(name, profile) {
    for field in ['warmups', 'samples', 'command_iterations', 'pipeline_bytes', 'stream_items'] {
        mut minimum = 1
        if $field == 'warmups' { $minimum = 0 }
        require($profile[$field] >= $minimum, "profile '$name' has invalid '$field'")
    }
    if $name == 'qualification' {
        for field in ['target_warmups', 'target_samples', 'target_pipeline_bytes'] {
            require($profile[$field] >= 1, "profile '$name' has invalid '$field'")
        }
    }
}

def validate_contract(document) {
    require($document.schema_version == 1, 'benchmark contract must use schema and suite version 1')
    require($document.suite_version == 1, 'benchmark contract must use schema and suite version 1')
    require($document.result_schema == 'flash-performance-result-v1', 'benchmark contract names the wrong result schema')
    require($document.supported_host_os != [], 'benchmark contract has invalid host OS support')
    for host in $document.supported_host_os {
        require($host in ['linux', 'macos'], 'benchmark contract has invalid host OS support')
        require(count_matching($document.supported_host_os, $host) == 1, 'benchmark contract has invalid host OS support')
    }
    validate_profile('smoke', $document.profiles.smoke)
    validate_profile('qualification', $document.profiles.qualification)
    let surfaces = ['startup', 'first_prompt', 'command_overhead', 'pipeline_throughput', 'structured_stream_memory', 'completion_latency']
    require($document.cases != [], 'benchmark contract must define cases')
    for case in $document.cases {
        require($case.id != '', 'every benchmark case needs an id')
        mut duplicates = 0
        for other in $document.cases { if $other.id == $case.id { $duplicates = $duplicates + 1 } }
        require($duplicates == 1, "benchmark case '${$case.id}' is repeated")
        require($case.surface in $surfaces, "benchmark case '${$case.id}' has unknown surface")
        require($case.environment in ['host', 'flashos-qemu-tcg'], "benchmark case '${$case.id}' has unknown environment")
        require($case.direction in ['minimum', 'maximum'], "benchmark case '${$case.id}' has unknown direction")
        require($case.sample_class in ['cold', 'warm'], "benchmark case '${$case.id}' has unknown sample class")
    }
    for surface in $surfaces {
        mut present = false
        for case in $document.cases { if $case.surface == $surface { $present = true } }
        require($present, "benchmark contract omits surfaces: $surface")
    }
    $document
}

def find_case(cases, identifier) {
    mut result = null
    for case in $cases { if $case.id == $identifier { $result = $case } }
    $result
}

def find_measurement(measurements, identifier) {
    mut result = null
    for measurement in $measurements { if $measurement.case_id == $identifier { $result = $measurement } }
    $result
}

def unit(metric) {
    if $metric == 'elapsed_ns' { return 'ns' }
    if $metric == 'elapsed_ns_per_command' { return 'ns/command' }
    if $metric == 'bytes_per_second' { return 'bytes/second' }
    if $metric == 'peak_rss_bytes' { return 'bytes' }
    throw "unknown benchmark metric '$metric'"
}

def validate_result(bundle) {
    let contract = $bundle.contract
    let result = $bundle.result
    require($result.schema == 'flash-performance-result-v1', 'benchmark result has the wrong schema')
    require($result.suite_version == $contract.suite_version, 'benchmark result has the wrong suite version')
    require($result.contract_sha256 == $bundle.contract_sha256, 'benchmark result does not bind the current contract')
    let kind = $result.environment.kind
    require($kind in ['host', 'flashos-qemu-tcg'], 'benchmark result has an unknown environment kind')
    if $kind == 'host' { require($result.environment.os in $contract.supported_host_os, 'benchmark result has an unsupported host OS') }
    require($result.profile in ['smoke', 'qualification'], 'benchmark result has an unknown profile')
    if $kind == 'flashos-qemu-tcg' { require($result.profile == 'qualification', 'target benchmark results must be qualification runs') }
    let profile = $contract.profiles[$result.profile]
    if $kind == 'flashos-qemu-tcg' {
        require($result.parameters.warmups == $profile.target_warmups, "benchmark result parameter 'warmups' does not match its profile")
        require($result.parameters.samples == $profile.target_samples, "benchmark result parameter 'samples' does not match its profile")
        require($result.parameters.pipeline_bytes == $profile.target_pipeline_bytes, "benchmark result parameter 'pipeline_bytes' does not match its profile")
        require($result.image_sha256 != '', 'benchmark result has an invalid image_sha256')
    } else {
        for field in ['warmups', 'samples', 'command_iterations', 'pipeline_bytes', 'stream_items'] {
            require($result.parameters[$field] == $profile[$field], "benchmark result parameter '$field' does not match its profile")
        }
        require($result.binary_sha256 != '', 'benchmark result has an invalid binary_sha256')
    }
    for measurement in $result.measurements {
        mut repeats = 0
        for other in $result.measurements { if $other.case_id == $measurement.case_id { $repeats = $repeats + 1 } }
        require($repeats == 1, "benchmark result repeats '${$measurement.case_id}'")
        let case = find_case($contract.cases, $measurement.case_id)
        require($case != null, "benchmark result has unknown case '${$measurement.case_id}'")
        require($case.environment == $kind, "benchmark result has unknown case '${$measurement.case_id}'")
        require($measurement.unit == unit($case.metric), "benchmark result '${$measurement.case_id}' has wrong unit")
        require($measurement.summary == summarize($measurement.samples), "benchmark result '${$measurement.case_id}' summary drifted")
        for warmup in $measurement.warmup_samples { require($warmup > 0, "benchmark result '${$measurement.case_id}' has invalid warmups") }
        mut sample_count = 0
        for sample in $measurement.samples { $sample_count = $sample_count + 1 }
        mut warmup_count = 0
        for warmup in $measurement.warmup_samples { $warmup_count = $warmup_count + 1 }
        if $case.sample_class == 'cold' {
            require($sample_count == 1, "benchmark result '${$measurement.case_id}' has wrong sample counts")
            require($warmup_count == 0, "benchmark result '${$measurement.case_id}' has wrong sample counts")
        } else if $kind == 'host' {
            require($sample_count == $profile.samples, "benchmark result '${$measurement.case_id}' has wrong sample counts")
            require($warmup_count == $profile.warmups, "benchmark result '${$measurement.case_id}' has wrong sample counts")
        } else {
            require($sample_count == $profile.target_samples, "benchmark result '${$measurement.case_id}' has wrong sample counts")
            require($warmup_count == $profile.target_warmups, "benchmark result '${$measurement.case_id}' has wrong sample counts")
        }
    }
    for case in $contract.cases {
        if $case.environment == $kind { require(find_measurement($result.measurements, $case.id) != null, 'benchmark result case coverage drifted; missing result') }
    }
    $bundle
}

def budget_policy(case, kind) {
    mut statistic = 'p95'
    if $case.direction == 'minimum' {
        $statistic = 'median'
    } else if $case.sample_class == 'cold' || $case.surface == 'structured_stream_memory' {
        $statistic = 'maximum'
    }
    mut numerator = 3
    if $kind == 'host' && $case.sample_class == 'cold' { $numerator = 4 }
    {statistic: $statistic, numerator: $numerator, denominator: 1}
}

def validate_budgets(bundle) {
    let budgets = $bundle.budgets
    require($budgets.schema_version == 1, 'benchmark budgets must use schema version 1')
    require($budgets.contract_sha256 == $bundle.contract_sha256, 'benchmark budgets do not bind the current contract')
    for environment in $budgets.environments {
        mut repeats = 0
        for other in $budgets.environments { if $other.id == $environment.id { $repeats = $repeats + 1 } }
        require($repeats == 1, "budget environment '${$environment.id}' is repeated")
        let evidence = $bundle.evidence[$environment.id]
        require($evidence != null, "budget environment '${$environment.id}' evidence is missing")
        require($environment.evidence_sha256 == $bundle.evidence_sha256[$environment.id], "budget environment '${$environment.id}' evidence drifted")
        for field in $environment.match_keys {
            require($evidence.environment[$field] == $environment['match'][$field], "budget environment '${$environment.id}' mismatches evidence field '$field'")
        }
    }
    for budget in $budgets.budgets {
        mut repeats = 0
        for other in $budgets.budgets { if $other.environment == $budget.environment && $other.case_id == $budget.case_id { $repeats = $repeats + 1 } }
        require($repeats == 1, 'benchmark budget repeats its ownership key')
        let evidence = $bundle.evidence[$budget.environment]
        let case = find_case($bundle.contract.cases, $budget.case_id)
        let measurement = find_measurement($evidence.measurements, $budget.case_id)
        require($evidence != null, 'benchmark budget has unknown ownership')
        require($case != null, 'benchmark budget has unknown ownership')
        require($measurement != null, 'benchmark budget has unknown ownership')
        let expected = budget_policy($case, $evidence.environment.kind)
        require($budget.statistic == $expected.statistic, 'benchmark budget violates the statistic policy')
        require($budget.factor_numerator == $expected.numerator, 'benchmark budget violates the tolerance policy')
        require($budget.factor_denominator == $expected.denominator, 'benchmark budget violates the tolerance policy')
        let baseline = $measurement.summary[$expected.statistic]
        require($budget.baseline == $baseline, 'benchmark budget baseline drifted')
        mut limit = 0
        if $case.direction == 'maximum' {
            $limit = ($baseline * $expected.numerator + $expected.denominator - 1) / $expected.denominator
        } else {
            $limit = $baseline * $expected.denominator / $expected.numerator
        }
        require($budget.limit == $limit, 'benchmark budget limit is not derived')
    }
    if $bundle.evaluation != null {
        let result = $bundle.evaluation.result
        let selected = $bundle.evaluation.environment
        mut environment = null
        for candidate in $budgets.environments { if $candidate.id == $selected { $environment = $candidate } }
        require($environment != null, "unknown budget environment '$selected'")
        require($result.profile == 'qualification', 'only qualification results can be budgeted')
        for field in $environment.match_keys {
            require($result.environment[$field] == $environment['match'][$field], "result does not match '$selected' field '$field'")
        }
        for budget in $budgets.budgets {
            if $budget.environment == $selected {
                let case = find_case($bundle.contract.cases, $budget.case_id)
                let observed = find_measurement($result.measurements, $budget.case_id).summary[$budget.statistic]
                if $case.direction == 'maximum' {
                    require($observed <= $budget.limit, "performance regressions: ${$budget.case_id}: observed $observed, required at most ${$budget.limit}")
                } else {
                    require($observed >= $budget.limit, "performance regressions: ${$budget.case_id}: observed $observed, required at least ${$budget.limit}")
                }
            }
        }
    }
    $bundle
}

def run_policy(path, kind) {
    try {
        if $kind == 'contract' {
            open $path | from json | each {|document| validate_contract($document)} | to json > /dev/null
        } else if $kind == 'result' {
            open $path | from json | each {|document| validate_result($document)} | to json > /dev/null
        } else {
            open $path | from json | each {|document| validate_budgets($document)} | to json > /dev/null
        }
    } catch error { contract_failure($error.message) }
}

let root = "$(pwd)"
let benchmark_root = "$root/components/flash/benchmarks"
let contract_path = "$benchmark_root/contract-v1.toml"
let budgets_path = "$benchmark_root/budgets-v1.toml"
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null || $temporary_parent == '' { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flash-benchmarks.XXXXXX")"
if !$status.ok || $temporary == '' { contract_failure('cannot create benchmark temporary directory') }

for argument in $args { if $argument in ['-h', '--help'] { print_help() } }
let jq = require_jq()
let contract_json = "$temporary/contract.json"
let contract_text = toml_to_json($contract_path, "$temporary/contract.stderr")
^printf '%s\n' $contract_text > $contract_json || exit 1
run_policy($contract_json, 'contract')
let contract_digest = sha256($contract_path)

mut contract_only = false
mut contract_boundary = false
mut evaluate_path = null
mut environment_id = null
mut waiting = null
for argument in $args {
    if $waiting != null {
        if $waiting == 'result' {
            let bundle = "$temporary/result.json"
            ^env $jq -n --slurpfile contract $contract_json --slurpfile result $argument --arg contract_sha256 $contract_digest '{contract:$contract[0],result:$result[0],contract_sha256:$contract_sha256}' > $bundle || contract_failure("cannot load benchmark result $argument")
            run_policy($bundle, 'result')
        } else if $waiting == 'evaluate' {
            $evaluate_path = $argument
        } else {
            $environment_id = $argument
        }
        $waiting = null
    } else if $argument == '--contract-only' {
        $contract_only = true
    } else if $argument == '--contract-json-v1' {
        $contract_boundary = true
    } else if $argument in ['--result', '--evaluate', '--environment'] {
        $waiting = "$(^printf '%s' $argument | ^cut -c 3-)"
    } else if !($argument in ['-h', '--help']) {
        usage_error("unrecognized arguments: $argument")
    }
}
if $waiting != null { usage_error("argument --$waiting: expected one argument") }
if ($contract_only || $contract_boundary) && ($evaluate_path != null || $environment_id != null) { contract_failure('--contract-only cannot evaluate a budget') }
if $contract_only && $contract_boundary { contract_failure('--contract-only and --contract-json-v1 are mutually exclusive') }
if ($evaluate_path == null) != ($environment_id == null) { contract_failure('--evaluate and --environment must be used together') }

if $contract_boundary {
    ^env $jq --compact-output --sort-keys --arg digest $contract_digest '{boundary_schema:1, kind:"flash-benchmark-contract", result_schema:.result_schema, suite_version:.suite_version, contract_sha256:$digest, qualification_profile:.profiles.qualification}' $contract_json
    let result = $status
    ^rm -rf $temporary || exit 1
    if !$result.ok { exit 1 }
    exit 0
}

if !$contract_only {
    let budgets_json = "$temporary/budgets.json"
    let budgets_text = toml_to_json($budgets_path, "$temporary/budgets.stderr")
    ^printf '%s\n' $budgets_text > $budgets_json || exit 1
    let host = "$benchmark_root/evidence/host-darwin-arm64-v1.json"
    let target = "$benchmark_root/evidence/flashos-qemu-tcg-v1.json"
    let bundle = "$temporary/budget-bundle.json"
    let host_digest = sha256($host)
    let target_digest = sha256($target)
    if $evaluate_path == null {
        ^env $jq -n --slurpfile contract $contract_json --slurpfile budgets $budgets_json --slurpfile host $host --slurpfile target $target --arg contract_sha256 $contract_digest --arg host_sha256 $host_digest --arg target_sha256 $target_digest '($budgets[0] | .environments |= map(. + {match_keys:(.match|keys)})) as $b | {contract:$contract[0],budgets:$b,contract_sha256:$contract_sha256,evidence:{"host-darwin-arm64":$host[0],"flashos-qemu-tcg-core2duo":$target[0]},evidence_sha256:{"host-darwin-arm64":$host_sha256,"flashos-qemu-tcg-core2duo":$target_sha256},evaluation:null}' > $bundle || exit 1
    } else {
        ^env $jq -n --slurpfile contract $contract_json --slurpfile budgets $budgets_json --slurpfile host $host --slurpfile target $target --slurpfile evaluation $evaluate_path --arg environment $environment_id --arg contract_sha256 $contract_digest --arg host_sha256 $host_digest --arg target_sha256 $target_digest '($budgets[0] | .environments |= map(. + {match_keys:(.match|keys)})) as $b | {contract:$contract[0],budgets:$b,contract_sha256:$contract_sha256,evidence:{"host-darwin-arm64":$host[0],"flashos-qemu-tcg-core2duo":$target[0]},evidence_sha256:{"host-darwin-arm64":$host_sha256,"flashos-qemu-tcg-core2duo":$target_sha256},evaluation:{environment:$environment,result:$evaluation[0]}}' > $bundle || exit 1
    }
    if $evaluate_path != null {
        let result_bundle = "$temporary/evaluation-result.json"
        ^env $jq -n --slurpfile contract $contract_json --slurpfile result $evaluate_path --arg contract_sha256 $contract_digest '{contract:$contract[0],result:$result[0],contract_sha256:$contract_sha256}' > $result_bundle || contract_failure("cannot load benchmark result $evaluate_path")
        run_policy($result_bundle, 'result')
    }
    run_policy($bundle, 'budgets')
}
^rm -rf $temporary || exit 1
^printf '%s\n' 'Flash benchmark contract: ok' || exit 1
