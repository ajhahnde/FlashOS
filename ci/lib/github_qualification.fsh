# Read-only GitHub qualification boundary for frozen Flash v1. Curl transports
# bytes with bounded retries; jq projects API fields; Flash owns every evidence,
# ordering, classification, and job-policy decision.

import { json_query, require_jq, selected_tool } from './tools.fsh'
import { expect_equal } from './validation.fsh'

def qualification_error(message) {
    throw $message
}

def api_get(api_url, token, path, query, output, errors) {
    mut url = "$api_url$path"
    if $query != '' {
        $url = "$url?$query"
    }
    mut last_http = ''
    mut last_error = ''
    let curl = selected_tool('FLASH_AUTOMATION_CURL', 'curl')
    for attempt in 1..=3 {
        let http = "$(^env $curl --disable --silent --show-error --location --connect-timeout 10 --max-time 30 --output $output --write-out '%{http_code}' --header 'Accept: application/vnd.github+json' --header "Authorization: Bearer $token" --header 'X-GitHub-Api-Version: 2022-11-28' --header 'User-Agent: FlashOS-main-qualification' -- $url 2> $errors)"
        let curl_status = $status
        $last_http = $http
        if ^test -s $errors {
            $last_error = "$(^cat $errors)"
        }
        if $curl_status.ok && "$http" != '' && "$http"[0] == '2' {
            return $output
        }
        mut retryable = false
        if !$curl_status.ok {
            $retryable = true
        } else if $http == '429' {
            $retryable = true
        } else if "$http" != '' && "$http"[0] == '5' {
            $retryable = true
        }
        if !$retryable || $attempt == 3 {
            if $http != '' && $http != '000' {
                mut detail = ''
                if ^test -f $output {
                    $detail = "$(^cat $output)"
                }
                qualification_error("GitHub API $path failed with HTTP $http: $detail")
            }
            qualification_error("GitHub API $path remained unavailable: $last_error")
        }
        ^sleep $attempt || exit 1
    }
    qualification_error('bounded GitHub API loop did not return or raise')
}

def select_main_pull(pulls, main_sha) {
    mut selected = null
    mut count = 0
    for pull in $pulls {
        if $pull.merged_at != null && $pull.base.ref == 'main' {
            $selected = $pull
            $count = $count + 1
        }
    }
    if $count != 1 {
        qualification_error("main commit $main_sha must identify exactly one merged pull request; found $count")
    }
    if $selected.draft {
        qualification_error("merged pull request #${$selected.number} is still marked draft")
    }
    return $selected
}

def select_candidate_pull(pulls, source_sha) {
    mut selected = null
    mut count = 0
    for pull in $pulls {
        mut reviewable = false
        if $pull.state == 'open' || $pull.merged_at != null {
            $reviewable = true
        }
        mut identity = false
        if $pull.head.sha == $source_sha {
            $identity = true
        } else if $pull.merged_at != null && $pull.merge_commit_sha == $source_sha {
            $identity = true
        }
        if $pull.base.ref == 'main' && !$pull.draft && $reviewable && $identity {
            $selected = $pull
            $count = $count + 1
        }
    }
    if $count != 1 {
        qualification_error("candidate source $source_sha must identify exactly one reviewable or merged pull request; found $count")
    }
    return $selected
}

def require_tree(commit, commit_sha) -> String {
    if $commit.tree.sha == null || $commit.tree.sha == '' {
        qualification_error("commit $commit_sha did not expose a Git tree")
    }
    return $commit.tree.sha
}

def jobs_satisfy(payload, required) -> Bool {
    for required_name in $required {
        mut successful = false
        for job in $payload.jobs {
            if $job.name == $required_name && $job.conclusion == 'success' {
                $successful = true
            }
        }
        if !$successful {
            return false
        }
    }
    return true
}

def validate_classification(classification) {
    expect_equal($classification.schema, 1, 'classification schema or reasons are invalid')
    if $classification.reasons == [] {
        qualification_error('classification schema or reasons are invalid')
    }
    for reason in $classification.reasons {
        if $reason == null || $reason == '' {
            qualification_error('classification schema or reasons are invalid')
        }
    }
    mut valid = false
    if $classification.lane == 'fast' && !$classification.image_required && !$classification.target_required {
        $valid = true
    } else if $classification.lane == 'product' && $classification.image_required {
        $valid = true
    }
    if !$valid {
        qualification_error('classification selected an invalid lane')
    }
    return $classification
}

def write_selected_pull(mode, pulls_path, source_sha, output) {
    if $mode == 'main' {
        open $pulls_path | from json | each {|pulls| select_main_pull($pulls, $source_sha)} | to json > $output
    } else {
        open $pulls_path | from json | each {|pulls| select_candidate_pull($pulls, $source_sha)} | to json > $output
    }
}

def fetch_tree(api_url, token, repository, commit_sha, directory, label) -> String {
    let payload = "$directory/$label-commit.json"
    let errors = "$directory/$label-commit-errors"
    api_get($api_url, $token, "/repos/$repository/git/commits/$commit_sha", '', $payload, $errors)
    let selected = "$directory/$label-tree.json"
    open $payload | from json | each {|commit| require_tree($commit, $commit_sha)} | to json > $selected
    let jq = require_jq()
    return "$(^env $jq --raw-output . $selected)"
}

def classifier_runtime() -> String {
    let runtime = selected_tool('FLASH_AUTOMATION_RUNTIME', 'fsh')
    let version = "$(^env $runtime --version)"
    if !$status.ok || $version != 'fsh 1.0.0' {
        qualification_error("Flash classifier runtime must be fsh 1.0.0: $runtime")
    }
    return $runtime
}

def classify_pull(api_url, token, repository, pull_number, directory, output) {
    let jq = require_jq()
    let paths = "$directory/changed-paths"
    ^printf '%s' '' > $paths || exit 1
    mut complete = false
    for page in 1..=30 {
        let payload = "$directory/files-$page.json"
        let errors = "$directory/files-$page-errors"
        api_get($api_url, $token, "/repos/$repository/pulls/$pull_number/files", "per_page=100&page=$page", $payload, $errors)
        ^env $jq --join-output '.[] | .filename, "\u0000", (if .status == "renamed" and .previous_filename then .previous_filename, "\u0000" else empty end)' $payload >> $paths || exit 1
        let count = "$(^env $jq --raw-output 'length' $payload)"
        if ^test $count -lt 100 {
            $complete = true
            break
        }
    }
    if !$complete {
        qualification_error("pull request #$pull_number changed more than 3000 files; classification is incomplete")
    }
    let runtime = classifier_runtime()
    ^env -u GITHUB_TOKEN -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY $runtime ci/classify_changes.fsh --null --json < $paths > $output
    if !$status.ok {
        qualification_error("pull request #$pull_number change classification failed")
    }
    let validated = "$directory/classification-validated.json"
    open $output | from json | each {|classification| validate_classification($classification)} | to json > $validated
    ^cp $validated $output || exit 1
}

def successful_run(api_url, token, repository, workflow, candidate_sha, pull_number, required_jobs, directory, label, output) {
    let jq = require_jq()
    let runs = "$directory/$label-runs.json"
    let errors = "$directory/$label-runs-errors"
    api_get($api_url, $token, "/repos/$repository/actions/workflows/$workflow/runs", "event=pull_request&head_sha=$candidate_sha&status=success&per_page=100", $runs, $errors)
    let ordered = "$directory/$label-ordered-runs.json"
    ^env $jq --arg head $candidate_sha '[.workflow_runs[] | select(.event == "pull_request" and .head_sha == $head and .conclusion == "success")] | sort_by((.run_attempt // 0), (.id // 0)) | reverse' $runs > $ordered || exit 1
    for index in 0..100 {
        let id = "$(^env $jq --raw-output ".[$index].id // empty" $ordered)"
        if $id == '' {
            break
        }
        let attempt = "$(^env $jq --raw-output ".[$index].run_attempt // 0" $ordered)"
        let url = "$(^env $jq --raw-output ".[$index].html_url // empty" $ordered)"
        let jobs = "$directory/$label-jobs-$id.json"
        let job_errors = "$directory/$label-jobs-$id-errors"
        api_get($api_url, $token, "/repos/$repository/actions/runs/$id/jobs", 'filter=latest&per_page=100', $jobs, $job_errors)
        let accepted = "$directory/$label-jobs-$id-accepted.json"
        open $jobs | from json | each {|payload| jobs_satisfy($payload, $required_jobs)} | to json > $accepted
        let ok = "$(^env $jq --raw-output . $accepted)"
        if $ok == 'true' {
            ^env $jq --null-input --argjson id $id --argjson run_attempt $attempt --arg url $url --arg jobs $jobs '{id:$id,run_attempt:$run_attempt,url:$url,jobs:$jobs}' > $output || exit 1
            return
        }
    }
    mut required = ''
    for name in $required_jobs {
        if $required == '' {
            $required = $name
        } else {
            $required = "$required, $name"
        }
    }
    qualification_error("pull request #$pull_number head $candidate_sha has no successful $workflow run containing the required jobs: $required")
}

def select_job_conclusion(payload, name) -> String {
    mut conclusion = ''
    for job in $payload.jobs {
        if $job.name != null && $job.name != '' && $job.name == $name {
            if $job.conclusion == null {
                $conclusion = ''
            } else {
                $conclusion = $job.conclusion
            }
        }
    }
    return $conclusion
}

def job_conclusion(jobs_path, name, selected_path) {
    open $jobs_path | from json | each {|payload| select_job_conclusion($payload, $name)} | to json > $selected_path
    let jq = require_jq()
    return "$(^env $jq --raw-output . $selected_path)"
}

def qualify(mode, api_url, token, repository, source_sha, directory, evidence_path) {
    let jq = require_jq()
    let pulls = "$directory/pulls.json"
    api_get($api_url, $token, "/repos/$repository/commits/$source_sha/pulls", '', $pulls, "$directory/pulls-errors")
    let pull = "$directory/pull.json"
    write_selected_pull($mode, $pulls, $source_sha, $pull)
    let pull_number = "$(^env $jq --raw-output .number $pull)"
    let candidate_sha = "$(^env $jq --raw-output '.head.sha // empty' $pull)"
    if $candidate_sha == '' {
        qualification_error("pull request #$pull_number has no head commit")
    }
    let source_tree = fetch_tree($api_url, $token, $repository, $source_sha, $directory, 'source')
    let candidate_tree = fetch_tree($api_url, $token, $repository, $candidate_sha, $directory, 'candidate')
    if $source_tree != $candidate_tree {
        if $mode == 'main' {
            qualification_error("main tree $source_tree differs from qualified candidate tree $candidate_tree")
        }
        qualification_error("candidate source tree $source_tree differs from qualified pull-request tree $candidate_tree")
    }
    let classification = "$directory/classification.json"
    classify_pull($api_url, $token, $repository, $pull_number, $directory, $classification)
    let lane = "$(^env $jq --raw-output .lane $classification)"
    let image_required = "$(^env $jq --raw-output .image_required $classification)"
    let security_required = "$(^env $jq --raw-output .security_required $classification)"

    let candidate_run = "$directory/candidate-run.json"
    successful_run($api_url, $token, $repository, 'ci.yml', $candidate_sha, $pull_number, ['change-classification', 'flash-quality', 'repository-quality', 'required'], $directory, 'candidate', $candidate_run)
    let candidate_jobs = "$(^env $jq --raw-output .jobs $candidate_run)"
    let selected_conclusion = "$directory/selected-conclusion.json"
    mut image_failure = ''
    for name in ['image-and-runtime / docker-clean-room-build', 'image-and-runtime / qemu-artifact-consumer'] {
        let conclusion = job_conclusion($candidate_jobs, $name, $selected_conclusion)
        if $image_required == 'true' && $conclusion != 'success' {
            if $image_failure == '' { $image_failure = $name } else { $image_failure = "$image_failure, $name" }
        } else if $image_required == 'false' && $conclusion == 'success' {
            if $image_failure == '' { $image_failure = $name } else { $image_failure = "$image_failure, $name" }
        }
    }
    if $image_failure != '' {
        if $image_required == 'true' {
            qualification_error("pull request #$pull_number was classified for product qualification but successful image jobs are missing: $image_failure")
        }
        qualification_error("pull request #$pull_number was classified for the fast lane but image jobs ran: $image_failure")
    }

    let security_run = "$directory/security-run.json"
    successful_run($api_url, $token, $repository, 'security.yml', $candidate_sha, $pull_number, ['security-required'], $directory, 'security', $security_run)
    let security_jobs = "$(^env $jq --raw-output .jobs $security_run)"
    mut policy_failure = ''
    for name in ['cargo-policy', 'dependency-review'] {
        let conclusion = job_conclusion($security_jobs, $name, $selected_conclusion)
        if $security_required == 'true' && $conclusion != 'success' {
            if $policy_failure == '' { $policy_failure = $name } else { $policy_failure = "$policy_failure, $name" }
        } else if $security_required == 'false' && $conclusion == 'success' {
            if $policy_failure == '' { $policy_failure = $name } else { $policy_failure = "$policy_failure, $name" }
        }
    }
    if $policy_failure != '' {
        if $security_required == 'true' {
            qualification_error("pull request #$pull_number requires dependency policy but successful jobs are missing: $policy_failure")
        }
        qualification_error("pull request #$pull_number classified a dependency-policy skip but jobs ran: $policy_failure")
    }
    let candidate_run_id = "$(^env $jq --raw-output .id $candidate_run)"
    let candidate_run_url = "$(^env $jq --raw-output .url $candidate_run)"
    let security_run_id = "$(^env $jq --raw-output .id $security_run)"
    let security_run_url = "$(^env $jq --raw-output .url $security_run)"
    ^env $jq --null-input \
    --argjson pull_number $pull_number \
    --arg candidate_sha $candidate_sha \
    --arg tree_sha $source_tree \
    --arg candidate_run_url $candidate_run_url \
    --arg security_run_url $security_run_url \
    --arg lane $lane \
    --argjson image_required $image_required \
    --argjson candidate_run_id $candidate_run_id \
    --argjson security_run_id $security_run_id \
    '{pull_number:$pull_number,candidate_sha:$candidate_sha,tree_sha:$tree_sha,candidate_run_url:$candidate_run_url,security_run_url:$security_run_url,lane:$lane,image_required:$image_required,candidate_run_id:$candidate_run_id,security_run_id:$security_run_id}' > $evidence_path || exit 1
}

export { qualify, qualification_error }
