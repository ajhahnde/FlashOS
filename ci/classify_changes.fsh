#!/usr/bin/env fsh
# Native dependency: jq 1.7.1. Jq exposes bounded string observations; Flash
# owns path acceptance, ordering, uniqueness, and every classification decision.

import { require_jq } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'
import { expect_equal, expect_unique } from './lib/validation.fsh'

def usage_error(message) {
    ^printf '%s\n' 'usage: classify_changes.fsh [-h] [--json] [--null] [paths ...]' 1>&2
    ^printf 'classify_changes.fsh: error: %s\n' $message 1>&2
    exit 2
}

def print_help() {
    ^printf '%s\n' \
    'usage: classify_changes.fsh [-h] [--json] [--null] [paths ...]' \
    '' \
    'positional arguments:' \
    '  paths       repository-relative changed paths; stdin is used when omitted' \
    '' \
    'options:' \
    '  -h, --help  show this help message and exit' \
    '  --json      emit JSON' \
    '  --null      read NUL-delimited paths from stdin' || exit 1
    exit 0
}

def observe(projected) {
    if $projected.blank {
        return null
    }
    if $projected.absolute || $projected.parent_segment {
        throw "invalid repository-relative path: '${$projected.raw}'"
    }
    let low_risk_files = [
    '.github/SECURITY.md', '.github/dependabot.yml', '.gitignore',
    'CODE_OF_CONDUCT.md', 'CHANGELOG.md', 'CONTRIBUTING.md',
    'DOCUMENTATION.md', 'HARDWARE.md', 'LICENSE', 'NOTICE', 'README.md',
    'TRADEMARK.md', 'codecov.yml', 'flashos.sh', 'flashos.zsh',
    ]
    let security_files = [
    '.github/dependabot.yml', '.github/workflows/security.yml', 'Cargo.lock',
    'Cargo.toml', 'deny.toml', 'components/flash/Cargo.lock',
    'components/flash/Cargo.toml', 'components/flash/deny.toml',
    'system/api/Cargo.lock', 'system/api/Cargo.toml', 'system/api/deny.toml',
    ]
    mut low_risk = false
    if $projected.normalized in $low_risk_files {
        $low_risk = true
    } else if $projected.low_risk_prefix {
        $low_risk = true
    } else if $projected.adjacent_doc_prefix && $projected.markdown_suffix {
        $low_risk = true
    }
    mut target = false
    if $projected.fsh_suffix {
        $target = true
    } else if $projected.component_prefix {
        $target = true
    } else if $projected.config_prefix {
        $target = true
    } else if $projected.flash_recipe_prefix {
        $target = true
    } else if $projected.system_api_target {
        $target = true
    }
    mut security = false
    if $projected.normalized in $security_files {
        $security = true
    } else if $projected.security_nested_manifest {
        $security = true
    }
    let observation = {
        position: $projected.position,
        path: $projected.normalized,
        low_risk: $low_risk,
        source_qualified: $projected.system_api_source,
        target: $target,
        security: $security,
    }
    return $observation
}

def first_occurrence(all, selected) -> Bool {
    for candidate in $all {
        if $candidate.normalized == $selected.normalized && $candidate.position < $selected.position {
            return false
        }
    }
    return true
}

def select_observation(item) {
    return observe($item.selected)
}

def product_reason(observation) -> String {
    return "product: ${$observation.path}"
}

def decide(observations) {
    mut product_count = 0
    mut source_count = 0
    mut security_required = false
    mut target_required = false
    for observation in $observations {
        if $observation.security {
            $security_required = true
        }
        if $observation.source_qualified {
            $source_count = $source_count + 1
        } else if !$observation.low_risk {
            $product_count = $product_count + 1
            if $observation.target {
                $target_required = true
            }
        }
    }
    if $observations == [] {
        let empty = {
            lane: 'product',
            image_required: true,
            target_required: true,
            security_required: true,
            product_count: 0,
            source_count: 0,
        }
        return $empty
    }
    if $product_count > 0 {
        let product = {
            lane: 'product',
            image_required: true,
            target_required: $target_required,
            security_required: $security_required,
            product_count: $product_count,
            source_count: $source_count,
        }
        return $product
    }
    if $source_count > 0 {
        let source = {
            lane: 'source',
            image_required: false,
            target_required: false,
            security_required: $security_required,
            product_count: 0,
            source_count: $source_count,
        }
        return $source
    }
    let fast = {
        lane: 'fast',
        image_required: false,
        target_required: false,
        security_required: $security_required,
        product_count: 0,
        source_count: 0,
    }
    return $fast
}

def validate(envelope) {
    let result = $envelope.document
    let observations = $envelope.observations
    expect_equal($envelope.keys, ['image_required', 'lane', 'paths', 'reasons', 'schema', 'security_required', 'target_required'], 'classification fields are invalid')
    expect_equal($result.schema, 1, 'classification schema is invalid')
    expect_unique($result.paths, 'classification paths contain duplicates')
    mut previous = null
    mut product_count = 0
    mut source_count = 0
    mut security_required = false
    mut target_required = false
    mut path_index = 0
    for observation in $observations {
        let path = $result.paths[$path_index]
        expect_equal($observation.path, $path, 'classification path projection differs')
        if $previous != null && $path < $previous {
            throw 'classification paths are not sorted'
        }
        $previous = $path
        if $observation.security {
            $security_required = true
        }
        if $observation.source_qualified {
            $source_count = $source_count + 1
        } else if !$observation.low_risk {
            $product_count = $product_count + 1
            if $observation.target {
                $target_required = true
            }
        }
        $path_index = $path_index + 1
    }
    mut path_count = 0
    for path in $result.paths {
        $path_count = $path_count + 1
    }
    expect_equal($path_index, $path_count, 'classification observation count differs')
    if $result.paths == [] {
        expect_equal($result.lane, 'product', 'empty classification lane differs')
        expect_equal($result.image_required, true, 'empty classification image decision differs')
        expect_equal($result.target_required, true, 'empty classification target decision differs')
        expect_equal($result.security_required, true, 'empty classification security decision differs')
        expect_equal($result.reasons, ['no changed paths were supplied; qualification fails closed'], 'empty classification reasons differ')
        return $result
    }
    expect_equal($result.security_required, $security_required, 'classification security decision differs')
    if $product_count == 0 && $source_count == 0 {
        expect_equal($result.lane, 'fast', 'fast classification lane differs')
        expect_equal($result.image_required, false, 'fast classification image decision differs')
        expect_equal($result.target_required, false, 'fast classification target decision differs')
        expect_equal($result.reasons, ['every changed path is explicitly isolated documentation, policy, reporting, or host tooling'], 'fast classification reasons differ')
        return $result
    }
    if $product_count == 0 {
        expect_equal($result.lane, 'source', 'source classification lane differs')
        expect_equal($result.image_required, false, 'source image decision differs')
        expect_equal($result.target_required, false, 'source target decision differs')
        expect_equal($result.reasons, ['every product path is covered by the complete FlashOS system API host contract'], 'source classification reasons differ')
        return $result
    }
    expect_equal($result.lane, 'product', 'product classification lane differs')
    expect_equal($result.image_required, true, 'product classification image decision differs')
    expect_equal($result.target_required, $target_required, 'product classification target decision differs')
    mut expected_reason_count = 1 + $product_count
    if $target_required {
        $expected_reason_count = $expected_reason_count + 1
    }
    mut actual_reason_count = 0
    for reason in $result.reasons {
        $actual_reason_count = $actual_reason_count + 1
    }
    expect_equal($actual_reason_count, $expected_reason_count, 'product classification reason count differs')
    expect_equal($result.reasons[0], 'product or unknown paths require image and runtime qualification', 'product classification reason heading differs')
    mut reason_index = 1
    for observation in $observations {
        if !$observation.low_risk && !$observation.source_qualified {
            expect_equal($result.reasons[$reason_index], "product: ${$observation.path}", 'product classification reason order differs')
            $reason_index = $reason_index + 1
        }
    }
    if $target_required {
        expect_equal($result.reasons[$reason_index], 'target-affecting paths are compiled by the image producer', 'target classification reason differs')
    }
    return $result
}

let root = repository_root('versions.env')
let jq = require_jq()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flashos-classify.XXXXXX")"
if !$status.ok {
    ^printf '%s\n' 'classify changes: cannot create temporary directory' 1>&2
    exit 1
}
let input = "$temporary/paths"
let decoded = "$temporary/paths.json"
let expanded = "$temporary/expanded.json"
let observations_raw = "$temporary/observations-raw.json"
let observations = "$temporary/observations.json"
let decision = "$temporary/decision.json"
let paths_json = "$temporary/paths-output.json"
let reason_documents = "$temporary/reason-documents.json"
let reasons_json = "$temporary/reasons.json"
let candidate = "$temporary/candidate.json"
let envelope = "$temporary/envelope.json"
let raw_payload = "$temporary/raw.json"
let payload_path = "$temporary/classification.json"
let errors = "$temporary/errors"
^printf '%s' '' > $input || exit 1

mut json_output = false
mut null_input = false
mut positional_count = 0
for argument in $args {
    if $argument == '--json' {
        $json_output = true
    } else if $argument == '--null' {
        $null_input = true
    } else if $argument in ['-h', '--help'] {
        ^rm -rf $temporary
        print_help()
    } else if $argument != '' && $argument[0] == '-' {
        ^rm -rf $temporary
        usage_error("unrecognized arguments: $argument")
    } else {
        ^printf '%s\0' $argument >> $input || exit 1
        $positional_count = $positional_count + 1
    }
}
if $positional_count == 0 {
    ^cat > $input || exit 1
}

mut nul_mode = 'false'
if $null_input || $positional_count > 0 {
    $nul_mode = 'true'
}
let project_paths = '
($raw | if $nul then split("\u0000") else split("\n") end) |
to_entries |
map(.key as $position | .value as $raw |
    ($raw | gsub("^\\s+|\\s+$"; "") | gsub("\\\\"; "/") | gsub("^(\\./)+"; "")) as $prepared |
    ($prepared | if . == "." then . else split("/") | map(select(. != "" and . != ".")) | join("/") end) as $normalized |
    {
      position:$position,
      raw:$raw,
      normalized:$normalized,
      blank:($prepared == ""),
      absolute:($prepared|startswith("/")),
      parent_segment:($prepared|test("(^|/)\\.\\.(/|$)")),
      low_risk_prefix:($normalized|test("^(\\.github/(ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE)/|docs/|LICENSES/)")),
      adjacent_doc_prefix:($normalized|startswith("components/flash/docs/")),
      markdown_suffix:($normalized|endswith(".md")),
      fsh_suffix:($normalized|endswith(".fsh")),
      component_prefix:($normalized|startswith("components/flash/")),
      config_prefix:($normalized|startswith("config/")),
      flash_recipe_prefix:($normalized|startswith("recipes/terminal/flash/")),
      system_api_source:($normalized|test("^system/api/(src/(contract|lib|transport)\\.rs|tests/[^/]+\\.rs)$")),
      system_api_target:($normalized|test("^(system/api/(Cargo\\.(lock|toml)|src/(main|provider)\\.rs|flash/|examples/)|recipes/system/flashos-system/)")),
      security_nested_manifest:($normalized|test("^(components/flash/.+/Cargo\\.toml|system/api/Cargo\\.toml)$"))
    })'
^env $jq --null-input --argjson nul $nul_mode --rawfile raw $input $project_paths > $decoded 2> $errors
if !$status.ok {
    ^rm -rf $temporary
    usage_error('cannot decode changed paths')
}
^env $jq '[group_by(.normalized)[] | {all:., selected:min_by(.position)}]' $decoded > $expanded || exit 1
try {
    open $expanded \
    | from json array \
    | where {|item| first_occurrence($item.all, $item.selected)} \
    | each {|item| select_observation($item)} \
    | where {|observation| $observation != null} \
    | sort path \
    | collect \
    | to json > $observations_raw
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    usage_error($message)
}
^cp $observations_raw $observations || exit 1
try {
    open $observations | from json | each {|values| decide($values)} | to json > $decision
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    usage_error($message)
}
open $observations | from json array | get path | collect | to json > $paths_json
let selected_lane = "$(^env $jq --raw-output .lane $decision)"
let selected_image = "$(^env $jq --raw-output .image_required $decision)"
let selected_target = "$(^env $jq --raw-output .target_required $decision)"
let selected_security = "$(^env $jq --raw-output .security_required $decision)"
if $selected_lane == 'fast' {
    ^printf '%s' '"every changed path is explicitly isolated documentation, policy, reporting, or host tooling"' > $reason_documents || exit 1
} else if $selected_lane == 'source' {
    ^printf '%s' '"every product path is covered by the complete FlashOS system API host contract"' > $reason_documents || exit 1
} else if "$(^env $jq --raw-output 'length' $observations)" == '0' {
    ^printf '%s' '"no changed paths were supplied; qualification fails closed"' > $reason_documents || exit 1
} else {
    ^printf '%s' '"product or unknown paths require image and runtime qualification"' > $reason_documents || exit 1
    open $observations \
    | from json array \
    | where {|observation| !$observation.low_risk && !$observation.source_qualified} \
    | each {|observation| product_reason($observation)} \
    | to json >> $reason_documents
    if $selected_target == 'true' {
        ^printf '%s' '"target-affecting paths are compiled by the image producer"' >> $reason_documents || exit 1
    }
}
^env $jq --slurp . $reason_documents > $reasons_json || exit 1
let assemble = '{schema:1,lane:$lane,image_required:$image,target_required:$target,security_required:$security,reasons:$reasons[0],paths:$paths[0]}'
^env $jq --null-input \
--arg lane $selected_lane \
--argjson image $selected_image \
--argjson target $selected_target \
--argjson security $selected_security \
--slurpfile reasons $reasons_json \
--slurpfile paths $paths_json \
$assemble > $candidate || exit 1
^env $jq --slurpfile observations $observations '{document:., keys:(keys|sort), observations:$observations[0]}' $candidate > $envelope || exit 1
try {
    open $envelope | from json | each {|value| validate($value)} | to json > $raw_payload
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    usage_error($message)
}
^env $jq --compact-output --sort-keys . $raw_payload > $payload_path || exit 1

let lane = "$(^env $jq --raw-output .lane $payload_path)"
let image_required = "$(^env $jq --raw-output .image_required $payload_path)"
let target_required = "$(^env $jq --raw-output .target_required $payload_path)"
let security_required = "$(^env $jq --raw-output .security_required $payload_path)"
let payload = "$(^cat $payload_path)"
let github_output = env('GITHUB_OUTPUT')
if $github_output != null && $github_output != '' {
    ^printf '%s\n' \
    "lane=$lane" \
    "image_required=$image_required" \
    "target_required=$target_required" \
    "security_required=$security_required" \
    "classification=$payload" >> $github_output || exit 1
}
let summary = env('GITHUB_STEP_SUMMARY')
if $summary != null && $summary != '' {
    ^printf '%s\n' \
    '## FlashOS change classification' \
    '' \
    "- lane: `$lane`" \
    "- image required: `$image_required`" \
    "- target-affecting paths: `$target_required`" \
    "- dependency policy required: `$security_required`" \
    '- reasons:' >> $summary || exit 1
    ^env $jq --raw-output '.reasons[] | "  - " + .' $payload_path >> $summary || exit 1
}
if $json_output || $github_output == null || $github_output == '' {
    ^cat $payload_path || exit 1
}
^rm -rf $temporary
