#!/usr/bin/env fsh
# Native dependencies: curl and the pinned JSON/classification adapters.

import { qualify } from './lib/github_qualification.fsh'
import { require_jq, require_rg } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

let root = repository_root('versions.env')
let repository_value = env('GITHUB_REPOSITORY')
let sha_value = env('SOURCE_SHA')
let token_value = env('GITHUB_TOKEN')
mut repository = ''
mut source_sha = ''
mut token = ''
if $repository_value != null { $repository = $repository_value }
if $sha_value != null { $source_sha = $sha_value }
if $token_value != null { $token = $token_value }
mut api_url = 'https://api.github.com'
let api_value = env('GITHUB_API_URL')
if $api_value != null && $api_value != '' { $api_url = $api_value }
let rg = require_rg()
^printf '%s' $source_sha | ^env $rg --quiet '^[0-9a-f]{40}$'
let sha_valid = $status.ok
if $repository == '' || $token == '' || !$sha_valid {
    ^printf '%s\n' 'candidate qualification: GITHUB_REPOSITORY, GITHUB_TOKEN, and a full lowercase SOURCE_SHA are required' 1>&2
    exit 2
}
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/flashos-candidate-qualification.XXXXXX")"
if !$status.ok { exit 1 }
let evidence = "$temporary/evidence.json"
try {
    qualify('candidate', $api_url, $token, $repository, $source_sha, $temporary, $evidence)
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    ^printf 'candidate qualification: FAILED: %s\n' $message 1>&2
    exit 1
}
let jq = require_jq()
let tree_sha = "$(^env $jq --raw-output .tree_sha $evidence)"
let pull_number = "$(^env $jq --raw-output .pull_number $evidence)"
let candidate_sha = "$(^env $jq --raw-output .candidate_sha $evidence)"
let candidate_run_id = "$(^env $jq --raw-output .candidate_run_id $evidence)"
let security_run_id = "$(^env $jq --raw-output .security_run_id $evidence)"
let github_output = env('GITHUB_OUTPUT')
if $github_output != null && $github_output != '' {
    ^printf '%s\n' \
    "source_tree=$tree_sha" \
    "pull_number=$pull_number" \
    "candidate_sha=$candidate_sha" \
    "required_run_id=$candidate_run_id" \
    "security_run_id=$security_run_id" >> $github_output || exit 1
}
^rm -rf $temporary
^printf 'candidate qualification: ok: PR #%s tree %s\n' $pull_number $tree_sha
