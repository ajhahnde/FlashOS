#!/usr/bin/env fsh
# Exercise the native hosted-qualification pair through deterministic local
# GitHub API transport fixtures.

import { repository_root } from '../lib/repository.fsh'

def test_error(message) {
    ^printf 'main qualification tests: FAILED: %s\n' $message 1>&2
    exit 1
}

def expect_success(result, expected, label) {
    let stdout_path = $result.stdout
    let stderr_path = $result.stderr
    let observed_stdout = "$(^cat $stdout_path)"
    let observed_stderr = "$(^cat $stderr_path)"
    if $result.code != 0 || $observed_stdout != $expected || $observed_stderr != '' {
        test_error("$label expected success, observed status ${$result.code}, stdout '$observed_stdout', stderr '$observed_stderr'")
    }
}

def expect_failure(result, marker, label) {
    let stdout_path = $result.stdout
    let stderr_path = $result.stderr
    let observed_stdout = "$(^cat $stdout_path)"
    let observed_stderr = "$(^cat $stderr_path)"
    if $result.code != 1 || $observed_stdout != '' || !($marker in $observed_stderr) {
        test_error("$label expected failure containing '$marker', observed status ${$result.code}, stdout '$observed_stdout', stderr '$observed_stderr'")
    }
}

def install_curl(temporary) {
    let curl = "$temporary/curl"
    ^printf '%s\n' \
    '#!/bin/sh' \
    'output=' \
    'url=' \
    'while [ "$#" -gt 0 ]; do' \
    '  case "$1" in' \
    '    --output) output=$2; shift 2 ;;' \
    '    --) shift; url=$1; shift ;;' \
    '    *) shift ;;' \
    '  esac' \
    'done' \
    'key=${url#*\/repos\/example\/flashos\/}' \
    'key=${key%%\?*}' \
    'key=$(printf "%s" "$key" | tr / _)' \
    'if [ ! -f "$FIXTURE_ROOT/$key.json" ]; then printf 404; exit 0; fi' \
    'cp "$FIXTURE_ROOT/$key.json" "$output" || exit 1' \
    'printf 200' > $curl
    ^chmod 755 $curl
    if !$status.ok { test_error('cannot create local curl fixture') }
    return $curl
}

def write_fixture_set(directory, source_sha, candidate_tree, changed_path, image_jobs, security_aggregate, security_policy, pull_state) {
    ^mkdir -p $directory
    if !$status.ok { test_error('cannot create GitHub fixture directory') }
    let main_sha = '1111111111111111111111111111111111111111'
    let head_sha = '2222222222222222222222222222222222222222'
    let tree_sha = '3333333333333333333333333333333333333333'
    mut state = 'open'
    if $pull_state != '' { $state = $pull_state }
    let pull = "[{\"number\":47,\"merged_at\":\"2026-08-20T18:48:00Z\",\"merge_commit_sha\":\"$main_sha\",\"draft\":false,\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$head_sha\"},\"state\":\"$state\"}]"
    ^printf '%s\n' $pull > "$directory/commits_${$source_sha}_pulls.json"
    ^printf '%s\n' $pull > "$directory/commits_${$head_sha}_pulls.json"
    ^printf '{"tree":{"sha":"%s"}}\n' $tree_sha > "$directory/git_commits_${$source_sha}.json"
    ^printf '{"tree":{"sha":"%s"}}\n' $candidate_tree > "$directory/git_commits_${$head_sha}.json"
    ^printf '[{"filename":"%s"}]\n' $changed_path > "$directory/pulls_47_files.json"
    ^printf '%s\n' "{\"workflow_runs\":[{\"id\":10,\"event\":\"pull_request\",\"head_sha\":\"$head_sha\",\"conclusion\":\"success\",\"run_attempt\":1,\"pull_requests\":[],\"html_url\":\"https://example.test/candidate\"}]}" > "$directory/actions_workflows_ci.yml_runs.json"
    ^printf '%s\n' "{\"workflow_runs\":[{\"id\":11,\"event\":\"pull_request\",\"head_sha\":\"$head_sha\",\"conclusion\":\"success\",\"run_attempt\":1,\"pull_requests\":[],\"html_url\":\"https://example.test/security\"}]}" > "$directory/actions_workflows_security.yml_runs.json"
    mut candidate_jobs = '{"jobs":[{"name":"change-classification","conclusion":"success"},{"name":"flash-quality","conclusion":"success"},{"name":"repository-quality","conclusion":"success"},{"name":"required","conclusion":"success"}'
    if $image_jobs {
        $candidate_jobs = "$candidate_jobs,{\"name\":\"image-and-runtime / docker-clean-room-build\",\"conclusion\":\"success\"},{\"name\":\"image-and-runtime / qemu-artifact-consumer\",\"conclusion\":\"success\"}"
    }
    $candidate_jobs = "$candidate_jobs]}"
    ^printf '%s\n' $candidate_jobs > "$directory/actions_runs_10_jobs.json"
    mut security_jobs = '{"jobs":['
    if $security_aggregate {
        $security_jobs = "$security_jobs{\"name\":\"security-required\",\"conclusion\":\"success\"}"
    } else {
        $security_jobs = "$security_jobs{\"name\":\"dependency-scope\",\"conclusion\":\"success\"}"
    }
    if $security_policy {
        $security_jobs = "$security_jobs,{\"name\":\"cargo-policy\",\"conclusion\":\"success\"},{\"name\":\"dependency-review\",\"conclusion\":\"success\"}"
    }
    $security_jobs = "$security_jobs]}"
    ^printf '%s\n' $security_jobs > "$directory/actions_runs_11_jobs.json"
    if !$status.ok { test_error('cannot write GitHub API fixtures') }
}

def run_main(runtime, script, temporary, curl, fixtures, label) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    ^env \
    "TMPDIR=$temporary" \
    "FIXTURE_ROOT=$fixtures" \
    "FLASH_AUTOMATION_CURL=$curl" \
    'GITHUB_API_URL=https://api.example.test' \
    'GITHUB_REPOSITORY=example/flashos' \
    'GITHUB_SHA=1111111111111111111111111111111111111111' \
    'GITHUB_TOKEN=test-token' \
    $runtime $script > $stdout 2> $stderr
    let result = $status
    let observation = {code: $result.code, stdout: "$stdout", stderr: "$stderr"}
    return $observation
}

def run_candidate(runtime, script, temporary, curl, fixtures, source_sha, label) {
    let stdout = "$temporary/$label.stdout"
    let stderr = "$temporary/$label.stderr"
    ^env \
    "TMPDIR=$temporary" \
    "FIXTURE_ROOT=$fixtures" \
    "FLASH_AUTOMATION_CURL=$curl" \
    'GITHUB_API_URL=https://api.example.test' \
    'GITHUB_REPOSITORY=example/flashos' \
    "SOURCE_SHA=$source_sha" \
    'GITHUB_TOKEN=test-token' \
    $runtime $script > $stdout 2> $stderr
    let result = $status
    let observation = {code: $result.code, stdout: "$stdout", stderr: "$stderr"}
    return $observation
}

let root = repository_root('versions.env')
let runtime_value = env('FLASH_AUTOMATION_RUNTIME')
if $runtime_value == null || $runtime_value == '' { test_error('FLASH_AUTOMATION_RUNTIME is required') }
let runtime = $runtime_value
if "$(^$runtime --version 2>/dev/null)" != 'fsh 1.0.0' { test_error('FLASH_AUTOMATION_RUNTIME must report fsh 1.0.0') }
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null { $temporary_parent = '/tmp' }
let temporary = "$(^mktemp -d "$temporary_parent/main-qualification-tests.XXXXXX")"
if !$status.ok || $temporary == '' { test_error('cannot create temporary directory') }
let curl = install_curl($temporary)
let main_script = "$root/ci/check_main_qualification.fsh"
let candidate_script = "$root/ci/check_candidate_qualification.fsh"
let main_sha = '1111111111111111111111111111111111111111'
let head_sha = '2222222222222222222222222222222222222222'
let tree_sha = '3333333333333333333333333333333333333333'

let product = "$temporary/product"
write_fixture_set($product, $main_sha, $tree_sha, 'src/lib.rs', true, true, false, 'open')
let product_result = run_main($runtime, $main_script, $temporary, $curl, $product, 'product-result')
expect_success($product_result, "main qualification: ok: PR #47 tree $tree_sha", 'exact product tree')

let different = "$temporary/different"
write_fixture_set($different, $main_sha, '4444444444444444444444444444444444444444', 'src/lib.rs', true, true, false, 'open')
let different_result = run_main($runtime, $main_script, $temporary, $curl, $different, 'different-result')
expect_failure($different_result, 'differs from qualified candidate tree', 'different main tree')

let missing_image = "$temporary/missing-image"
write_fixture_set($missing_image, $main_sha, $tree_sha, 'src/lib.rs', false, true, false, 'open')
let missing_image_result = run_main($runtime, $main_script, $temporary, $curl, $missing_image, 'missing-image-result')
expect_failure($missing_image_result, 'successful image jobs are missing', 'missing product image evidence')

let fast = "$temporary/fast"
write_fixture_set($fast, $main_sha, $tree_sha, 'docs/verification.md', false, true, false, 'open')
let fast_result = run_main($runtime, $main_script, $temporary, $curl, $fast, 'fast-result')
expect_success($fast_result, "main qualification: ok: PR #47 tree $tree_sha", 'classified fast lane')

let fast_image = "$temporary/fast-image"
write_fixture_set($fast_image, $main_sha, $tree_sha, 'docs/verification.md', true, true, false, 'open')
let fast_image_result = run_main($runtime, $main_script, $temporary, $curl, $fast_image, 'fast-image-result')
expect_failure($fast_image_result, 'classified for the fast lane but image jobs ran', 'unexpected fast-lane image evidence')

let missing_security = "$temporary/missing-security"
write_fixture_set($missing_security, $main_sha, $tree_sha, 'docs/verification.md', false, false, false, 'open')
let missing_security_result = run_main($runtime, $main_script, $temporary, $curl, $missing_security, 'missing-security-result')
expect_failure($missing_security_result, 'required jobs', 'missing security aggregate')

let dependency = "$temporary/dependency"
write_fixture_set($dependency, $main_sha, $tree_sha, '.github/dependabot.yml', false, true, false, 'open')
let dependency_result = run_main($runtime, $main_script, $temporary, $curl, $dependency, 'dependency-result')
expect_failure($dependency_result, 'requires dependency policy', 'missing dependency-policy jobs')

let dependency_ok = "$temporary/dependency-ok"
write_fixture_set($dependency_ok, $main_sha, $tree_sha, '.github/dependabot.yml', false, true, true, 'open')
let dependency_ok_result = run_main($runtime, $main_script, $temporary, $curl, $dependency_ok, 'dependency-ok-result')
expect_success($dependency_ok_result, "main qualification: ok: PR #47 tree $tree_sha", 'complete dependency-policy evidence')

let candidate_head = "$temporary/candidate-head"
write_fixture_set($candidate_head, $head_sha, $tree_sha, 'src/lib.rs', true, true, false, 'open')
let candidate_head_result = run_candidate($runtime, $candidate_script, $temporary, $curl, $candidate_head, $head_sha, 'candidate-head-result')
expect_success($candidate_head_result, "candidate qualification: ok: PR #47 tree $tree_sha", 'exact reviewable candidate head')

let candidate_merged = "$temporary/candidate-merged"
write_fixture_set($candidate_merged, $main_sha, $tree_sha, 'src/lib.rs', true, true, false, 'closed')
let candidate_merged_result = run_candidate($runtime, $candidate_script, $temporary, $curl, $candidate_merged, $main_sha, 'candidate-merged-result')
expect_success($candidate_merged_result, "candidate qualification: ok: PR #47 tree $tree_sha", 'exact merged candidate tree')

^rm -rf $temporary
^printf '%s\n' 'main qualification tests: ok'
