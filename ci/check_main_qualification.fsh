#!/usr/bin/env fsh
# Native dependencies: curl and the pinned JSON/classification adapters.

import { qualify } from './lib/github_qualification.fsh'
import { require_jq } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

let root = repository_root('versions.env')
let repository_value = env('GITHUB_REPOSITORY')
let sha_value = env('GITHUB_SHA')
let token_value = env('GITHUB_TOKEN')
mut repository = ''
mut main_sha = ''
mut token = ''
if $repository_value != null { $repository = $repository_value }
if $sha_value != null { $main_sha = $sha_value }
if $token_value != null { $token = $token_value }
mut api_url = 'https://api.github.com'
let api_value = env('GITHUB_API_URL')
if $api_value != null && $api_value != '' { $api_url = $api_value }
if $repository == '' || $main_sha == '' || $token == '' {
    ^printf '%s\n' 'main qualification: GITHUB_REPOSITORY, GITHUB_SHA, and GITHUB_TOKEN are required' 1>&2
    exit 2
}
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flashos-main-qualification.XXXXXX")"
if !$status.ok { exit 1 }
let evidence = "$temporary/evidence.json"
try {
    qualify('main', $api_url, $token, $repository, $main_sha, $temporary, $evidence)
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    ^printf 'main qualification: FAILED: %s\n' $message 1>&2
    exit 1
}
let jq = require_jq()
let pull_number = "$(^env $jq --raw-output .pull_number $evidence)"
let candidate_sha = "$(^env $jq --raw-output .candidate_sha $evidence)"
let tree_sha = "$(^env $jq --raw-output .tree_sha $evidence)"
let lane = "$(^env $jq --raw-output .lane $evidence)"
let image_required = "$(^env $jq --raw-output .image_required $evidence)"
let candidate_url = "$(^env $jq --raw-output .candidate_run_url $evidence)"
let security_url = "$(^env $jq --raw-output .security_run_url $evidence)"
let summary = env('GITHUB_STEP_SUMMARY')
if $summary != null && $summary != '' {
    ^printf '%s\n' \
    '## FlashOS main qualification' \
    '' \
    "- merged pull request: #$pull_number" \
    "- qualified candidate: `$candidate_sha`" \
    "- exact Git tree: `$tree_sha`" \
    "- qualification lane: `$lane`" \
    "- image required: `$image_required`" \
    "- [candidate qualification]($candidate_url)" \
    "- [dependency policy]($security_url)" >> $summary || exit 1
}
^rm -rf $temporary
^printf 'main qualification: ok: PR #%s tree %s\n' $pull_number $tree_sha
