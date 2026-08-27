#!/usr/bin/env fsh
# Native dependency: jq 1.7.1 for bounded JSON decoding/projection. Flash owns
# classification agreement, lane policy, gate enforcement, and diagnostics.

import { require_jq } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def aggregate_error(message) {
    ^printf 'CI aggregate: FAILED: %s\n' $message 1>&2
    exit 1
}

def boolean(value, label) -> Bool {
    if $value == 'true' {
        return true
    }
    if $value == 'false' {
        return false
    }
    throw "$label must be true or false"
}

def parse_and_enforce(classification) {
    if $classification.schema != 1 {
        throw 'classification schema or reasons are invalid'
    }
    if $classification.reasons == [] {
        throw 'classification schema or reasons are invalid'
    }
    for reason in $classification.reasons {
        if $reason == null || $reason == '' {
            throw 'classification schema or reasons are invalid'
        }
    }
    let event_value = env('EVENT_NAME')
    mut event = ''
    if $event_value != null {
        $event = $event_value
    }
    let draft_value = env('PR_DRAFT')
    mut draft_raw = 'false'
    if $draft_value != null {
        $draft_raw = $draft_value
    }
    let scope_value = env('SCOPE_RESULT')
    mut scope = ''
    if $scope_value != null {
        $scope = $scope_value
    }
    let lane_value = env('LANE')
    mut lane = ''
    if $lane_value != null {
        $lane = $lane_value
    }
    let image_value = env('IMAGE_REQUIRED')
    mut image_raw = ''
    if $image_value != null {
        $image_raw = $image_value
    }
    let target_value = env('TARGET_REQUIRED')
    mut target_raw = ''
    if $target_value != null {
        $target_raw = $target_value
    }
    let root_value = env('ROOT_RESULT')
    mut root_result = ''
    if $root_value != null {
        $root_result = $root_value
    }
    let shell_value = env('SHELL_RESULT')
    mut shell_result = ''
    if $shell_value != null {
        $shell_result = $shell_value
    }
    let image_result_value = env('IMAGE_RESULT')
    mut image_result = ''
    if $image_result_value != null {
        $image_result = $image_result_value
    }
    let draft = boolean($draft_raw, 'PR_DRAFT')
    let image_required = boolean($image_raw, 'IMAGE_REQUIRED')
    let target_required = boolean($target_raw, 'TARGET_REQUIRED')
    if $classification.lane != $lane || $classification.image_required != $image_required || $classification.target_required != $target_required {
        throw 'job outputs disagree with the classification payload'
    }
    if $scope != 'success' {
        throw 'change classification failed'
    }
    mut valid_lane = false
    if $lane == 'fast' && !$image_required && !$target_required {
        $valid_lane = true
    } else if $lane == 'product' && $image_required {
        $valid_lane = true
    }
    if !$valid_lane {
        throw 'change classification selected an invalid lane'
    }
    if $root_result != 'success' || $shell_result != 'success' {
        throw 'one or more required source gates failed'
    }
    if $image_result == 'success' {
        if !$image_required {
            throw 'image qualification ran contrary to classification'
        }
    } else if $image_result == 'skipped' && !$image_required {
        let controlled_skip = true
    } else if $event == 'pull_request' && $draft && $image_required && $image_result == 'skipped' {
        let draft_skip = true
    } else {
        throw 'classification requires successful product qualification'
    }
    let result = {
        event: $event,
        draft: $draft,
        scope: $scope,
        lane: $lane,
        image_required: $image_required,
        target_required: $target_required,
        root: $root_result,
        flash: $shell_result,
        image: $image_result,
        reasons: $classification.reasons,
    }
    return $result
}

let root = repository_root('versions.env')
let jq = require_jq()
let classification = env('CLASSIFICATION')
if $classification == null {
    aggregate_error("classification output is invalid: 'CLASSIFICATION'")
}
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flashos-aggregate.XXXXXX")"
if !$status.ok {
    aggregate_error('cannot create temporary directory')
}
let input = "$temporary/classification.json"
let result = "$temporary/result.json"
^printf '%s' $classification > $input || exit 1
try {
    open $input | from json | each {|document| parse_and_enforce($document)} | to json > $result
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    if 'malformed JSON at byte offset' in $message {
        aggregate_error("classification output is invalid: $message")
    }
    aggregate_error($message)
}

let summary = env('GITHUB_STEP_SUMMARY')
if $summary != null && $summary != '' {
    let render = '[
      "## FlashOS CI", "", "| gate | result |", "|:--|:--|",
      "| change classification | \(.scope) (\(.lane)) |",
      "| repository + product contract | \(.root) |",
      "| Flash | \(.flash) |",
      "| Docker image + QEMU runtime | \(.image) |", "",
      "Image required: `\(.image_required)`; target-affecting paths: `\(.target_required)`.",
      "", "Classification reasons:", (.reasons[] | "- " + .)
    ] | .[]'
    ^env $jq --raw-output $render $result >> $summary || exit 1
}
^rm -rf $temporary
^printf '%s\n' 'CI aggregate: ok'
