#!/usr/bin/env fsh
# Native dependencies: jq, sha256sum or shasum, stat, zstd, glob, and small
# POSIX file/process primitives. They provide parsing, hashing, compression,
# and filesystem observations; Flash owns candidate policy and decisions.

import { require_jq } from './lib/tools.fsh'

mut jq = 'jq'

def candidate_error(message) {
    ^printf 'release candidate: FAILED: %s\n' $message 1>&2 || exit 1
    exit 1
}

def usage_error(message) {
    ^printf 'usage: release_candidate.fsh {create,validate,select} ...\n' 1>&2 || exit 2
    ^printf 'release_candidate.fsh: error: %s\n' $message 1>&2 || exit 2
    exit 2
}

def require_candidate(condition: Bool, message: String) {
    if !$condition {
        throw $message
    }
}

def count_values(values) {
    mut count = 0
    for value in $values {
        $count = $count + 1
    }
    $count
}

def occurrences(values, expected) {
    mut count = 0
    for value in $values {
        if $value == $expected {
            $count = $count + 1
        }
    }
    $count
}

def validate_same_set(observed, expected, message) {
    require_candidate(count_values($observed) == count_values($expected), $message)
    for value in $observed {
        require_candidate(occurrences($observed, $value) == 1, $message)
        require_candidate(occurrences($expected, $value) == 1, $message)
    }
    for value in $expected {
        require_candidate(occurrences($observed, $value) == 1, $message)
    }
}

def python_list_difference(values, other) {
    mut rendered = '['
    mut first = true
    for value in $values {
        if occurrences($other, $value) == 0 {
            if !$first {
                $rendered = "${$rendered}, "
            }
            $rendered = "${$rendered}'${$value}'"
            $first = false
        }
    }
    "${$rendered}]"
}

def python_list(values) {
    mut rendered = '['
    mut first = true
    for value in $values {
        if !$first {
            $rendered = "${$rendered}, "
        }
        $rendered = "${$rendered}'${$value}'"
        $first = false
    }
    "${$rendered}]"
}

def validate_ascii_codes(codes, length, mode, message) {
    if $length != 0 {
        require_candidate(count_values($codes) == $length, $message)
    }
    require_candidate(count_values($codes) > 0, $message)
    mut index = 0
    for code in $codes {
        mut allowed = $code in 48..=57
        if $mode == 'lower-hex' {
            if $code in 97..=102 {
                $allowed = true
            }
        }
        if $mode == 'positive' {
            if $index == 0 {
                require_candidate($code in 49..=57, $message)
            }
        }
        require_candidate($allowed, $message)
        $index = $index + 1
    }
}

def validate_version_codes(codes) {
    let message = 'version must be semantic and must not include a leading v'
    require_candidate(count_values($codes) > 0, $message)
    mut component = 0
    mut component_digits = 0
    mut suffix = false
    mut suffix_count = 0
    for code in $codes {
        if !$suffix {
            if $code in 48..=57 {
                $component_digits = $component_digits + 1
            } else if $code == 46 {
                if $component < 2 {
                    if $component_digits > 0 {
                        $component = $component + 1
                        $component_digits = 0
                    } else {
                        throw $message
                    }
                } else {
                    throw $message
                }
            } else if $code == 43 {
                if $component == 2 {
                    if $component_digits > 0 {
                        $suffix = true
                    } else {
                        throw $message
                    }
                } else {
                    throw $message
                }
            } else if $code == 45 {
                if $component == 2 {
                    if $component_digits > 0 {
                        $suffix = true
                    } else {
                        throw $message
                    }
                } else {
                    throw $message
                }
            } else {
                throw $message
            }
        } else {
            mut allowed = false
            if $code in 48..=57 {
                $allowed = true
            } else if $code in 65..=90 {
                $allowed = true
            } else if $code in 97..=122 {
                $allowed = true
            } else if $code == 45 {
                $allowed = true
            } else if $code == 46 {
                $allowed = true
            }
            require_candidate($allowed, $message)
            $suffix_count = $suffix_count + 1
        }
    }
    require_candidate($component == 2, $message)
    require_candidate($component_digits > 0, $message)
    if $suffix {
        require_candidate($suffix_count > 0, $message)
    }
}

def validate_text_document(document, mode, length, message) {
    if $mode == 'version' {
        validate_version_codes($document.codes)
    } else {
        validate_ascii_codes($document.codes, $length, $mode, $message)
    }
}

def validate_text_codes(value, mode, length, message) {
    try {
        ^env $jq -n --arg value $value '{codes: ($value | explode)}' | from json | each {|document| validate_text_document($document, $mode, $length, $message)} | to json > /dev/null
    } catch error {
        candidate_error($error.message)
    }
}

def validate_checksum_entries(entries) {
    for entry in $entries {
        let message = "invalid SHA256SUMS line ${$entry.line_number}"
        require_candidate(count_values($entry.fields) == 2, $message)
        require_candidate($entry.name != '', $message)
        require_candidate(!('/' in $entry.name), $message)
        validate_ascii_codes($entry.digest_codes, 64, 'lower-hex', $message)
        mut repeats = 0
        for other in $entries {
            if $other.name == $entry.name {
                $repeats = $repeats + 1
            }
        }
        require_candidate($repeats == 1, "duplicate checksum entry: ${$entry.name}")
    }
    $entries
}

def validate_selection(document) {
    require_candidate($document.run_id_kind == 'number', 'candidate run response has the wrong run ID')
    require_candidate($document.observed_run_id == $document.run_id, 'candidate run response has the wrong run ID')
    require_candidate($document.repository_kind == 'string', 'candidate run belongs to another repository')
    require_candidate($document.observed_repository == $document.repository, 'candidate run belongs to another repository')
    require_candidate($document.path_kind == 'string', 'selected run is not candidate.yml')
    require_candidate($document.path == '.github/workflows/candidate.yml', 'selected run is not candidate.yml')
    require_candidate($document.event_kind == 'string', 'selected candidate run is not successfully completed')
    require_candidate($document.event == 'workflow_dispatch', 'selected candidate run is not successfully completed')
    require_candidate($document.status_kind == 'string', 'selected candidate run is not successfully completed')
    require_candidate($document.run_status == 'completed', 'selected candidate run is not successfully completed')
    require_candidate($document.conclusion_kind == 'string', 'selected candidate run is not successfully completed')
    require_candidate($document.conclusion == 'success', 'selected candidate run is not successfully completed')
    require_candidate($document.source_commit_kind == 'string', 'candidate run head SHA must be a full lowercase Git object ID')
    validate_ascii_codes($document.source_commit_codes, 40, 'lower-hex', 'candidate run head SHA must be a full lowercase Git object ID')
    require_candidate($document.attempt_kind == 'number', 'candidate run attempt must be positive')
    validate_ascii_codes($document.attempt_codes, 0, 'positive', 'candidate run attempt must be positive')
    require_candidate($document.artifacts_kind == 'array', 'candidate artifact response is invalid')
    let expected_name = "flashos-release-candidate-${$document.run_id}-${$document.run_attempt}"
    mut matches = 0
    for artifact in $document.artifacts {
        if $artifact.kind == 'object' {
            if $artifact.name_kind == 'string' {
                if $artifact.name == $expected_name {
                    if $artifact.expired_kind == 'boolean' {
                        if $artifact.expired == false {
                            $matches = $matches + 1
                        }
                    }
                }
            }
        }
    }
    require_candidate($matches == 1, 'candidate artifact is missing, ambiguous, or expired')
    {artifact_name: $expected_name, run_attempt: $document.run_attempt, source_commit: $document.source_commit}
}

def sha256(path) {
    mut digest = ''
    if ^shasum --version > /dev/null 2>&1 {
        $digest = "$(^shasum -a 256 $path | ^cut -d ' ' -f 1)"
    } else {
        $digest = "$(^sha256sum $path | ^cut -d ' ' -f 1)"
    }
    if !$status.ok || $digest == '' {
        candidate_error("cannot hash $path")
    }
    $digest
}

def file_size(path) {
    mut size = "$(^stat -f %z $path 2> /dev/null)"
    if !$status.ok || $size == '' {
        $size = "$(^stat -c %s $path 2> /dev/null)"
    }
    if !$status.ok || $size == '' {
        candidate_error("cannot stat $path")
    }
    $size
}

def require_regular(path, name) {
    if ^test -f $path {
        if ^test -L $path {
            candidate_error("candidate file is missing or not regular: $name")
        }
    } else {
        candidate_error("candidate file is missing or not regular: $name")
    }
}

def require_positive_text(value, label) {
    validate_text_codes($value, 'positive', 0, "$label must be positive")
}

def require_positive(value, label) {
    let value_type = "$(^printf '%s' $value | ^env $jq -r 'type' 2> /dev/null)"
    if $value_type != 'number' {
        candidate_error("$label must be positive")
    }
    require_positive_text($value, $label)
}

def require_oid(value, label) {
    validate_text_codes($value, 'lower-hex', 40, "$label must be a full lowercase Git object ID")
}

def require_version(value) {
    validate_text_codes($value, 'version', 0, 'version must be semantic and must not include a leading v')
}

def load_object(path, label) {
    let value_type = "$(^env $jq -r 'type' $path 2> /dev/null)"
    if !$status.ok || $value_type != 'object' {
        candidate_error("cannot read JSON from $path: invalid JSON object")
    }
    $path
}

def expected_payload(version) {
    [
    "FlashOS-$version-x86_64-harddrive.img.zst",
    "FlashOS-$version-x86_64-live.iso.zst",
    "FlashOS-$version-source.cdx.json",
    "FlashOS-$version-image.cdx.json",
    "FlashOS-$version-release-notes.md",
    'cookbook.lock',
    'qemu-harddrive-performance.json',
    'qemu-harddrive-smoke.log',
    'qemu-live-usb-smoke.log',
    'qemu-results.json',
    ]
}

def sorted_allowlist(version) {
    [
    "FlashOS-$version-image.cdx.json",
    "FlashOS-$version-release-notes.md",
    "FlashOS-$version-source.cdx.json",
    "FlashOS-$version-x86_64-harddrive.img.zst",
    "FlashOS-$version-x86_64-live.iso.zst",
    'SHA256SUMS',
    'candidate-manifest.json',
    'cookbook.lock',
    'qemu-harddrive-performance.json',
    'qemu-harddrive-smoke.log',
    'qemu-live-usb-smoke.log',
    'qemu-results.json',
    ]
}

def sorted_payload(version) {
    [
    "FlashOS-$version-image.cdx.json",
    "FlashOS-$version-release-notes.md",
    "FlashOS-$version-source.cdx.json",
    "FlashOS-$version-x86_64-harddrive.img.zst",
    "FlashOS-$version-x86_64-live.iso.zst",
    'cookbook.lock',
    'qemu-harddrive-performance.json',
    'qemu-harddrive-smoke.log',
    'qemu-live-usb-smoke.log',
    'qemu-results.json',
    ]
}

def sorted_record_names(version) {
    [
    "FlashOS-$version-image.cdx.json",
    "FlashOS-$version-release-notes.md",
    "FlashOS-$version-source.cdx.json",
    "FlashOS-$version-x86_64-harddrive.img.zst",
    "FlashOS-$version-x86_64-live.iso.zst",
    'SHA256SUMS',
    'cookbook.lock',
    'qemu-harddrive-performance.json',
    'qemu-harddrive-smoke.log',
    'qemu-live-usb-smoke.log',
    'qemu-results.json',
    ]
}

def write_json_list(values, destination) {
    ^env $jq -n --args '$ARGS.positional' ...$values > $destination || exit 1
}

def validate_create_checksum_inventory(document) {
    let message = 'checksum inventory mismatch'
    try {
        validate_same_set($document.observed, $document.expected, $message)
    } catch error {
        let missing = python_list_difference($document.expected, $document.observed)
        let unexpected = python_list_difference($document.observed, $document.expected)
        throw "$message; missing=$missing, unexpected=$unexpected"
    }
}

def validate_named_set(document) {
    validate_same_set($document.observed, $document.expected, $document.message)
}

def validate_allowlist(document) {
    require_candidate($document.kind == 'array', 'candidate filename allowlist is invalid')
    for kind in $document.item_kinds {
        require_candidate($kind == 'string', 'candidate filename allowlist is invalid')
    }
    validate_same_set($document.observed, $document.expected, 'candidate filename allowlist differs from the schema')
}

def validate_inventory(document) {
    try {
        validate_same_set($document.actual, $document.allowlist, 'candidate inventory mismatch')
    } catch error {
        let actual = python_list($document.actual)
        let allowlist = python_list($document.allowlist)
        throw "candidate inventory mismatch; actual=$actual, allowlist=$allowlist"
    }
}

def validate_record_keys(document) {
    require_candidate($document.kind == 'object', 'candidate file records do not match the allowlist')
    validate_same_set($document.observed, $document.expected, 'candidate file records do not match the allowlist')
}

def validate_checksum_records(document) {
    validate_same_set($document.checksum_names, $document.expected_names, 'SHA256SUMS inventory does not match candidate payload')
    for entry in $document.entries {
        require_candidate($document.records[$entry.name].sha256 == $entry.digest, "SHA256SUMS digest mismatch: ${$entry.name}")
    }
}

def validate_input_identity(document) {
    require_candidate($document.observed_kind == 'object', 'candidate input graph differs from the selected source')
    validate_same_set($document.observed_keys, $document.expected_keys, 'candidate input graph differs from the selected source')
    require_candidate($document.observed_files_kind == 'object', 'candidate input graph differs from the selected source')
    validate_same_set($document.observed_file_keys, $document.expected_file_keys, 'candidate input graph differs from the selected source')
    require_candidate($document.observed.recipe_graph_sha256 == $document.expected.recipe_graph_sha256, 'candidate input graph differs from the selected source')
    require_candidate($document.observed.recipe_count == $document.expected.recipe_count, 'candidate input graph differs from the selected source')
    for name in $document.expected_file_keys {
        require_candidate($document.observed.files[$name] == $document.expected.files[$name], 'candidate input graph differs from the selected source')
    }
}

def validate_file_record(document) {
    let message = "candidate file identity mismatch: ${$document.name}"
    require_candidate($document.kind == 'object', $message)
    validate_same_set($document.keys, ['sha256', 'size'], $message)
    require_candidate($document.digest_kind == 'string', $message)
    require_candidate($document.digest == $document.expected_digest, $message)
    require_candidate($document.size_kind == 'number', $message)
    require_candidate($document.size == $document.expected_size, $message)
}

def validate_raw_images(document) {
    require_candidate($document.kind == 'object', 'manifest raw-image digests differ from QEMU evidence')
    validate_same_set($document.keys, ['harddrive', 'live'], 'manifest raw-image digests differ from QEMU evidence')
    require_candidate($document.observed.harddrive == $document.expected.harddrive, 'manifest raw-image digests differ from QEMU evidence')
    require_candidate($document.observed.live == $document.expected.live, 'manifest raw-image digests differ from QEMU evidence')
}

def validate_qemu_document(document) {
    require_candidate($document.schema_kind == 'number', 'QEMU results do not match the candidate source')
    require_candidate($document.schema == 1, 'QEMU results do not match the candidate source')
    require_candidate($document.source_kind == 'string', 'QEMU results do not match the candidate source')
    require_candidate($document.source_commit == $document.expected_source, 'QEMU results do not match the candidate source')
    for result in $document.results {
        require_candidate($result.kind == 'object', "QEMU results are missing ${$result.name}")
        require_candidate($result.result_kind == 'string', "QEMU ${$result.name} must succeed on the first attempt for a candidate")
        require_candidate($result.result == 'success', "QEMU ${$result.name} must succeed on the first attempt for a candidate")
        require_candidate($result.attempt_kind == 'number', "QEMU ${$result.name} must succeed on the first attempt for a candidate")
        require_candidate($result.attempt == 1, "QEMU ${$result.name} must succeed on the first attempt for a candidate")
        require_candidate($result.digest_kind == 'string', "QEMU ${$result.name} has an invalid image digest")
        validate_ascii_codes($result.digest_codes, 64, 'lower-hex', "QEMU ${$result.name} has an invalid image digest")
    }
    {harddrive: $document.results[0].digest, live: $document.results[1].digest}
}

def validate_qemu(path, source_commit, raw_output) {
    load_object($path, 'QEMU results')
    let observation = "$raw_output.observation"
    ^env $jq --arg expected_source $source_commit '
. as $document |
{
  schema_kind: ($document.schema | type), schema: $document.schema,
  source_kind: ($document.source_commit | type), source_commit: $document.source_commit,
  expected_source: $expected_source,
  results: ["harddrive", "live"] | map(. as $name | $document[$name] as $result | {
    name: $name,
    kind: ($result | type),
    result_kind: ($result.result | type), result: $result.result,
    attempt_kind: ($result.attempt | type), attempt: $result.attempt,
    digest_kind: ($result.sha256 | type), digest: $result.sha256,
    digest_codes: (if ($result.sha256 | type) == "string" then ($result.sha256 | explode) else [] end)
  })
}' $path > $observation || exit 1
    try {
        open $observation | from json | each {|document| validate_qemu_document($document)} | to json > $raw_output
    } catch error {
        candidate_error($error.message)
    }
}

def parse_checksums(path, output) {
    let entries = "$output.entries"
    if ^env $jq -Rsc '
gsub("\r\n"; "\n") | gsub("\r"; "\n") |
split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end |
to_entries | map(.value as $line | ($line | split("  ")) as $fields | {
  line_number: (.key + 1),
  fields: $fields,
  digest: ($fields[0] // ""),
  name: ($fields[1] // ""),
  digest_codes: (($fields[0] // "") | explode)
})' $path > $entries 2> /dev/null {
    } else {
        candidate_error('invalid SHA256SUMS line 1')
    }
    try {
        open $entries | from json | each {|document| validate_checksum_entries($document)} | to json > $output
    } catch error {
        candidate_error($error.message)
    }
}

def validate_checksum_file(document) {
    mut matches = 0
    for entry in $document.entries {
        if $entry.name == $document.name {
            $matches = $matches + 1
            require_candidate($entry.digest == $document.digest, "candidate checksum mismatch: ${$document.name}")
        }
    }
    require_candidate($matches == 1, "candidate checksum mismatch: ${$document.name}")
}

def input_identity(root, temporary, output) {
    let fixed = [
    'Cargo.lock',
    'components/flash/Cargo.lock',
    'components/flash/rust-toolchain.toml',
    'config/flashos-base.toml',
    'config/x86_64/flashos-release.toml',
    'ci/container/Dockerfile',
    'rust-toolchain.toml',
    ]
    let fixed_jsonl = "$temporary/input-files.jsonl"
    ^printf '%s' '' > $fixed_jsonl || exit 1
    for relative in $fixed {
        let path = "$root/$relative"
        if ^test -f $path {
        } else {
            candidate_error("candidate input is missing: $relative")
        }
        let digest = sha256($path)
        ^env $jq -n --arg name $relative --arg digest $digest '{key: $name, value: $digest}' >> $fixed_jsonl || exit 1
    }
    let fixed_json = "$temporary/input-files.json"
    ^env $jq -s 'from_entries' $fixed_jsonl > $fixed_json || exit 1

    let recipes = glob("$root/recipes/**/recipe.toml")
    if $recipes == [] {
        candidate_error('candidate recipe graph is empty')
    }
    let recipe_preimage = "$temporary/recipe-preimage"
    ^printf '%s' '' > $recipe_preimage || exit 1
    mut recipe_count = 0
    for recipe in $recipes {
        let relative = "$(^env $jq -nr --arg path $recipe --arg root "$root/" '$path | ltrimstr($root)')"
        ^printf '%s\0' $relative >> $recipe_preimage || exit 1
        ^cat $recipe >> $recipe_preimage || exit 1
        ^printf '\0' >> $recipe_preimage || exit 1
        $recipe_count = $recipe_count + 1
    }
    let recipe_digest = sha256($recipe_preimage)
    ^env $jq -n \
    --slurpfile files $fixed_json \
    --arg recipe_graph_sha256 $recipe_digest \
    --argjson recipe_count $recipe_count \
    '{files: $files[0], recipe_graph_sha256: $recipe_graph_sha256, recipe_count: $recipe_count}' \
    > $output || exit 1
}

def create_manifest(root, bundle, version, repository, source_commit, source_tree, run_id, run_attempt, required_run_id, security_run_id) {
    require_version($version)
    require_oid($source_commit, 'source commit')
    require_oid($source_tree, 'source tree')
    if '/' in $repository && $repository != '' {
    } else {
        candidate_error('repository must use owner/name form')
    }
    require_positive_text($run_id, 'run ID')
    require_positive_text($run_attempt, 'run attempt')
    require_positive_text($required_run_id, 'required run ID')
    require_positive_text($security_run_id, 'security run ID')

    mut temporary_parent = env('TMPDIR')
    if $temporary_parent == null || $temporary_parent == '' {
        $temporary_parent = '/tmp'
    }
    let temporary = "$(^mktemp -d "$temporary_parent/flash-release-create.XXXXXX")"
    if !$status.ok || $temporary == '' {
        candidate_error('cannot create candidate temporary directory')
    }
    let raw_images = "$temporary/raw-images.json"
    validate_qemu("$bundle/qemu-results.json", $source_commit, $raw_images)
    let checksums_path = "$bundle/SHA256SUMS"
    if ^test -f $checksums_path {
    } else {
        ^rm -rf $temporary
        candidate_error('candidate is missing SHA256SUMS')
    }
    let checksums = "$temporary/checksums.json"
    parse_checksums($checksums_path, $checksums)
    let payload = expected_payload($version)
    let expected_payload_json = "$temporary/expected.json"
    write_json_list(sorted_payload($version), $expected_payload_json)
    let checksum_names = "$temporary/checksum-names.json"
    ^env $jq -r '.[].name' $checksums | decode utf8 | lines | sort | collect | to json > $checksum_names || exit 1
    let checksum_inventory = "$temporary/checksum-inventory.json"
    ^env $jq -n --slurpfile observed $checksum_names --slurpfile expected $expected_payload_json '{observed: $observed[0], expected: $expected[0]}' > $checksum_inventory || exit 1
    try {
        open $checksum_inventory | from json | each {|document| validate_create_checksum_inventory($document)} | to json > /dev/null
    } catch error {
        ^rm -rf $temporary
        candidate_error($error.message)
    }

    let records_jsonl = "$temporary/records.jsonl"
    ^printf '%s' '' > $records_jsonl || exit 1
    for name in sorted_record_names($version) {
        let path = "$bundle/$name"
        require_regular($path, $name)
        let digest = sha256($path)
        if $name != 'SHA256SUMS' {
            let checksum_document = "$temporary/checksum-file.json"
            ^env $jq --arg name $name --arg digest $digest '{entries: ., name: $name, digest: $digest}' $checksums > $checksum_document || exit 1
            try {
                open $checksum_document | from json | each {|document| validate_checksum_file($document)} | to json > /dev/null
            } catch error {
                ^rm -rf $temporary
                candidate_error($error.message)
            }
        }
        let size = file_size($path)
        ^env $jq -n --arg name $name --arg digest $digest --argjson size $size '{key: $name, value: {sha256: $digest, size: $size}}' >> $records_jsonl || exit 1
    }
    let records = "$temporary/records.json"
    ^env $jq -s 'from_entries' $records_jsonl > $records || exit 1
    let inputs = "$temporary/inputs.json"
    input_identity($root, $temporary, $inputs)
    let allowlist = "$temporary/allowlist.json"
    write_json_list(sorted_allowlist($version), $allowlist)

    ^env $jq -n \
    --arg repository $repository \
    --argjson run_id $run_id \
    --argjson run_attempt $run_attempt \
    --arg source_commit $source_commit \
    --arg source_tree $source_tree \
    --arg version $version \
    --argjson required_run_id $required_run_id \
    --argjson security_run_id $security_run_id \
    --slurpfile inputs $inputs \
    --slurpfile raw_images $raw_images \
    --slurpfile files $records \
    --slurpfile allowlist $allowlist \
    '{schema: 1, repository: $repository, workflow: {name: "candidate.yml", run_id: $run_id, run_attempt: $run_attempt}, source: {commit: $source_commit, tree: $source_tree}, version: $version, profile: "flashos-release", qualification: {required_run_id: $required_run_id, security_run_id: $security_run_id}, inputs: $inputs[0], raw_images: $raw_images[0], qemu: {results: "qemu-results.json", harddrive: "success-first-attempt", live: "success-first-attempt"}, files: $files[0], allowlisted_filenames: $allowlist[0]}' \
    > "$bundle/candidate-manifest.json" || exit 1
    ^rm -rf $temporary || exit 1
}

def validate_bundle(bundle, root, repository, version, source_commit, source_tree, run_id, run_attempt, tag, verify_compressed) {
    let manifest = "$bundle/candidate-manifest.json"
    load_object($manifest, 'candidate manifest')
    try {
        ^env $jq '{observed: keys_unsorted, expected: ["schema", "repository", "workflow", "source", "version", "profile", "qualification", "inputs", "raw_images", "qemu", "files", "allowlisted_filenames"], message: "candidate manifest fields are missing or unexpected"}' $manifest | from json | each {|document| validate_named_set($document)} | to json > /dev/null
    } catch error {
        candidate_error($error.message)
    }
    if "$(^env $jq -c '.schema' $manifest)" != '1' {
        candidate_error('unsupported candidate manifest schema')
    }
    if "$(^env $jq -c '.profile' $manifest)" != '"flashos-release"' {
        candidate_error('candidate profile is not flashos-release')
    }
    let manifest_version_kind = "$(^env $jq -r '.version | type' $manifest)"
    if $manifest_version_kind != 'string' {
        candidate_error('candidate version is missing')
    }
    let manifest_version = "$(^env $jq -r '.version // ""' $manifest)"
    require_version($manifest_version)
    let manifest_commit = "$(^env $jq -r '.source.commit // ""' $manifest)"
    let manifest_tree = "$(^env $jq -r '.source.tree // ""' $manifest)"
    require_oid($manifest_commit, 'candidate source commit')
    require_oid($manifest_tree, 'candidate source tree')
    if "$(^env $jq -r '.workflow.name // ""' $manifest)" != 'candidate.yml' {
        candidate_error('candidate was not produced by candidate.yml')
    }
    let manifest_run_id = "$(^env $jq -r '.workflow.run_id' $manifest)"
    let manifest_attempt = "$(^env $jq -r '.workflow.run_attempt' $manifest)"
    require_positive_text($manifest_run_id, 'candidate run ID')
    require_positive_text($manifest_attempt, 'candidate run attempt')
    require_positive("$(^env $jq -c '.qualification.required_run_id' $manifest)", 'required run ID')
    require_positive("$(^env $jq -c '.qualification.security_run_id' $manifest)", 'security run ID')

    mut temporary_parent = env('TMPDIR')
    if $temporary_parent == null || $temporary_parent == '' {
        $temporary_parent = '/tmp'
    }
    let temporary = "$(^mktemp -d "$temporary_parent/flash-release-validate.XXXXXX")"
    if !$status.ok || $temporary == '' {
        candidate_error('cannot create validation temporary directory')
    }
    let inputs = "$temporary/inputs.json"
    input_identity($root, $temporary, $inputs)
    let inputs_document = "$temporary/inputs-document.json"
    ^env $jq --slurpfile expected $inputs '.inputs as $observed | {observed_kind: ($observed | type), observed_keys: (if ($observed | type) == "object" then ($observed | keys_unsorted) else [] end), observed_files_kind: ($observed.files | type), observed_file_keys: (if ($observed.files | type) == "object" then ($observed.files | keys_unsorted) else [] end), observed: $observed, expected: $expected[0], expected_keys: ($expected[0] | keys_unsorted), expected_file_keys: ($expected[0].files | keys_unsorted)}' $manifest > $inputs_document || exit 1
    try {
        open $inputs_document | from json | each {|document| validate_input_identity($document)} | to json > /dev/null
    } catch error {
        ^rm -rf $temporary
        candidate_error($error.message)
    }
    for expectation in [
    {expected: $repository, actual: "$(^env $jq -r '.repository // ""' $manifest)", label: 'repository'},
    {expected: $version, actual: $manifest_version, label: 'version'},
    {expected: $source_commit, actual: $manifest_commit, label: 'source commit'},
    {expected: $source_tree, actual: $manifest_tree, label: 'source tree'},
    {expected: $run_id, actual: $manifest_run_id, label: 'run ID'},
    {expected: $run_attempt, actual: $manifest_attempt, label: 'run attempt'},
    ] {
        if $expectation.expected != null && $expectation.expected != $expectation.actual {
            ^rm -rf $temporary
            candidate_error("candidate ${$expectation.label} mismatch: '${$expectation.actual}' != '${$expectation.expected}'")
        }
    }
    if $tag != null && $tag != "v$manifest_version" {
        ^rm -rf $temporary
        candidate_error('tag does not match the candidate version')
    }

    let payload = expected_payload($manifest_version)
    let expected_allowlist = "$temporary/allowlist.json"
    write_json_list(sorted_allowlist($manifest_version), $expected_allowlist)
    let allowlist_document = "$temporary/allowlist-document.json"
    ^env $jq --slurpfile expected $expected_allowlist '{kind: (.allowlisted_filenames | type), item_kinds: (if (.allowlisted_filenames | type) == "array" then [.allowlisted_filenames[] | type] else [] end), observed: (if (.allowlisted_filenames | type) == "array" then .allowlisted_filenames else [] end), expected: $expected[0]}' $manifest > $allowlist_document || exit 1
    try {
        open $allowlist_document | from json | each {|document| validate_allowlist($document)} | to json > /dev/null
    } catch error {
        ^rm -rf $temporary
        candidate_error($error.message)
    }
    let actual_inventory = "$temporary/inventory.json"
    let member_names = "$temporary/inventory.txt"
    ^find $bundle -mindepth 1 -maxdepth 1 -print | ^sed 's|.*/||' > $member_names || exit 1
    open $member_names | decode utf8 | lines | sort | collect | to json > $actual_inventory
    let inventory_document = "$temporary/inventory-document.json"
    ^env $jq -n --slurpfile actual $actual_inventory --slurpfile manifest $manifest '{actual: $actual[0], allowlist: $manifest[0].allowlisted_filenames}' > $inventory_document || exit 1
    try {
        open $inventory_document | from json | each {|document| validate_inventory($document)} | to json > /dev/null
    } catch error {
        ^rm -rf $temporary
        candidate_error($error.message)
    }
    let expected_record_keys = "$temporary/record-keys.json"
    write_json_list(sorted_record_names($manifest_version), $expected_record_keys)
    let record_keys_document = "$temporary/record-keys-document.json"
    ^env $jq --slurpfile expected $expected_record_keys '{kind: (.files | type), observed: (if (.files | type) == "object" then (.files | keys_unsorted) else [] end), expected: $expected[0]}' $manifest > $record_keys_document || exit 1
    try {
        open $record_keys_document | from json | each {|document| validate_record_keys($document)} | to json > /dev/null
    } catch error {
        ^rm -rf $temporary
        candidate_error($error.message)
    }
    for name in sorted_payload($manifest_version) {
        let path = "$bundle/$name"
        if ^test -L $path {
            ^rm -rf $temporary
            candidate_error("candidate member is not a regular file: $name")
        }
        if ^test -f $path {
        } else {
            ^rm -rf $temporary
            candidate_error("candidate member is not a regular file: $name")
        }
        let digest = sha256($path)
        let size = file_size($path)
        let record_document = "$temporary/file-record.json"
        ^env $jq --arg name $name --arg expected_digest $digest --argjson expected_size $size '.files[$name] as $record | {name: $name, kind: ($record | type), keys: (if ($record | type) == "object" then ($record | keys_unsorted) else [] end), digest_kind: ($record.sha256 | type), digest: $record.sha256, size_kind: ($record.size | type), size: $record.size, expected_digest: $expected_digest, expected_size: $expected_size}' $manifest > $record_document || exit 1
        try {
            open $record_document | from json | each {|document| validate_file_record($document)} | to json > /dev/null
        } catch error {
            ^rm -rf $temporary
            candidate_error($error.message)
        }
    }
    let sums_path = "$bundle/SHA256SUMS"
    if ^test -L $sums_path {
        ^rm -rf $temporary
        candidate_error('candidate member is not a regular file: SHA256SUMS')
    }
    if ^test -f $sums_path {
    } else {
        ^rm -rf $temporary
        candidate_error('candidate member is not a regular file: SHA256SUMS')
    }
    let sums_file_digest = sha256($sums_path)
    let sums_file_size = file_size($sums_path)
    let sums_record_document = "$temporary/sums-record.json"
    ^env $jq --arg expected_digest $sums_file_digest --argjson expected_size $sums_file_size '.files.SHA256SUMS as $record | {name: "SHA256SUMS", kind: ($record | type), keys: (if ($record | type) == "object" then ($record | keys_unsorted) else [] end), digest_kind: ($record.sha256 | type), digest: $record.sha256, size_kind: ($record.size | type), size: $record.size, expected_digest: $expected_digest, expected_size: $expected_size}' $manifest > $sums_record_document || exit 1
    try {
        open $sums_record_document | from json | each {|document| validate_file_record($document)} | to json > /dev/null
    } catch error {
        ^rm -rf $temporary
        candidate_error($error.message)
    }
    let checksums = "$temporary/checksums.json"
    parse_checksums("$bundle/SHA256SUMS", $checksums)
    let checksum_names = "$temporary/checksum-names.json"
    ^env $jq -r '.[].name' $checksums | decode utf8 | lines | sort | collect | to json > $checksum_names || exit 1
    let expected_checksum_names = "$temporary/expected-checksum-names.json"
    write_json_list(sorted_payload($manifest_version), $expected_checksum_names)
    let checksum_document = "$temporary/checksum-records.json"
    ^env $jq -n --slurpfile entries $checksums --slurpfile names $checksum_names --slurpfile expected $expected_checksum_names --slurpfile manifest $manifest '{entries: $entries[0], checksum_names: $names[0], expected_names: $expected[0], records: $manifest[0].files}' > $checksum_document || exit 1
    try {
        open $checksum_document | from json | each {|document| validate_checksum_records($document)} | to json > /dev/null
    } catch error {
        ^rm -rf $temporary
        candidate_error($error.message)
    }
    let raw_images = "$temporary/raw-images.json"
    let qemu_results = "$(^env $jq -r '.qemu.results // ""' $manifest)"
    validate_qemu("$bundle/$qemu_results", $manifest_commit, $raw_images)
    let raw_images_document = "$temporary/raw-images-document.json"
    ^env $jq --slurpfile expected $raw_images '.raw_images as $observed | {kind: ($observed | type), keys: (if ($observed | type) == "object" then ($observed | keys_unsorted) else [] end), observed: $observed, expected: $expected[0]}' $manifest > $raw_images_document || exit 1
    try {
        open $raw_images_document | from json | each {|document| validate_raw_images($document)} | to json > /dev/null
    } catch error {
        ^rm -rf $temporary
        candidate_error($error.message)
    }
    if $verify_compressed {
        for image in [
        {name: 'harddrive', filename: "FlashOS-$manifest_version-x86_64-harddrive.img.zst", path: "$bundle/FlashOS-$manifest_version-x86_64-harddrive.img.zst"},
        {name: 'live', filename: "FlashOS-$manifest_version-x86_64-live.iso.zst", path: "$bundle/FlashOS-$manifest_version-x86_64-live.iso.zst"},
        ] {
            let image_name = $image.name
            let image_filename = $image.filename
            let image_path = $image.path
            let observed = "$(^zstd --decompress --stdout $image_path 2> "$temporary/zstd.stderr" | ^sha256sum | ^cut -d ' ' -f 1)"
            if !$status.ok {
                let error = "$(^cat "$temporary/zstd.stderr")"
                ^rm -rf $temporary
                candidate_error("cannot decompress $image_filename: $error")
            }
            let expected = "$(^env $jq -r --arg name $image_name '.[$name]' $raw_images)"
            if $observed != $expected {
                ^rm -rf $temporary
                candidate_error("compressed $image_name bytes differ from the QEMU-qualified raw image")
            }
        }
    }
    ^rm -rf $temporary || exit 1
}

def select_candidate(run_path, artifacts_path, repository, run_id) {
    load_object($run_path, 'candidate run')
    load_object($artifacts_path, 'candidate artifacts')
    require_positive_text($run_id, 'run ID')
    mut temporary_parent = env('TMPDIR')
    if $temporary_parent == null || $temporary_parent == '' {
        $temporary_parent = '/tmp'
    }
    let temporary = "$(^mktemp -d "$temporary_parent/flash-candidate-select.XXXXXX")"
    if !$status.ok || $temporary == '' {
        candidate_error('cannot create selection temporary directory')
    }
    let document = "$temporary/document.json"
    let selected = "$temporary/selected.json"
    ^env $jq -n --slurpfile run $run_path --slurpfile artifact_response $artifacts_path --arg repository $repository --argjson run_id $run_id '
$run[0] as $run |
$artifact_response[0].artifacts as $artifacts |
{
  run_id: $run_id,
  observed_run_id: $run.id, run_id_kind: ($run.id | type),
  repository: $repository,
  observed_repository: $run.head_repository.full_name, repository_kind: ($run.head_repository.full_name | type),
  path: $run.path, path_kind: ($run.path | type),
  event: $run.event, event_kind: ($run.event | type),
  run_status: $run.status, status_kind: ($run.status | type),
  conclusion: $run.conclusion, conclusion_kind: ($run.conclusion | type),
  source_commit: $run.head_sha, source_commit_kind: ($run.head_sha | type),
  source_commit_codes: (if ($run.head_sha | type) == "string" then ($run.head_sha | explode) else [] end),
  run_attempt: $run.run_attempt, attempt_kind: ($run.run_attempt | type),
  attempt_codes: (if ($run.run_attempt | type) == "number" then ($run.run_attempt | tostring | explode) else [] end),
  artifacts_kind: ($artifacts | type),
  artifacts: (if ($artifacts | type) == "array" then $artifacts | map(. as $artifact | {
    kind: ($artifact | type),
    name: $artifact.name, name_kind: ($artifact.name | type),
    expired: $artifact.expired, expired_kind: ($artifact.expired | type)
  }) else [] end)
}' > $document || exit 1
    try {
        open $document | from json | each {|value| validate_selection($value)} | to json > $selected
    } catch error {
        ^rm -rf $temporary
        candidate_error($error.message)
    }
    ^env $jq -c '.' $selected || exit 1
    ^rm -rf $temporary || exit 1
}

mut command_name = null
mut root = '.'
mut bundle = null
mut version = null
mut repository = null
mut source_commit = null
mut source_tree = null
mut run_id = null
mut run_attempt = null
mut required_run_id = null
mut security_run_id = null
mut tag = null
mut verify_compressed = false
mut run_path = null
mut artifacts_path = null
mut waiting = null

for argument in $args {
    if $command_name == null {
        if $argument in ['create', 'validate', 'select'] {
            $command_name = $argument
        } else {
            usage_error("argument command: invalid choice: '$argument'")
        }
    } else if $waiting != null {
        if $waiting == 'root' {
            $root = $argument
        } else if $waiting == 'bundle' {
            $bundle = $argument
        } else if $waiting == 'version' {
            $version = $argument
        } else if $waiting == 'repository' {
            $repository = $argument
        } else if $waiting == 'source-commit' {
            $source_commit = $argument
        } else if $waiting == 'source-tree' {
            $source_tree = $argument
        } else if $waiting == 'run-id' {
            $run_id = $argument
        } else if $waiting == 'run-attempt' {
            $run_attempt = $argument
        } else if $waiting == 'required-run-id' {
            $required_run_id = $argument
        } else if $waiting == 'security-run-id' {
            $security_run_id = $argument
        } else if $waiting == 'tag' {
            $tag = $argument
        } else if $waiting == 'run' {
            $run_path = $argument
        } else if $waiting == 'artifacts' {
            $artifacts_path = $argument
        }
        $waiting = null
    } else if $argument == '--verify-compressed' {
        $verify_compressed = true
    } else if $argument in ['--root', '--bundle', '--version', '--repository', '--source-commit', '--source-tree', '--run-id', '--run-attempt', '--required-run-id', '--security-run-id', '--tag', '--run', '--artifacts'] {
        $waiting = "$(^printf '%s' $argument | ^cut -c 3-)"
    } else {
        usage_error("unrecognized arguments: $argument")
    }
}
if $command_name == null {
    usage_error('the following arguments are required: command')
}
if $waiting != null {
    usage_error("argument --$waiting: expected one argument")
}

$jq = require_jq()

if $command_name == 'create' {
    if $bundle == null || $version == null || $repository == null || $source_commit == null || $source_tree == null || $run_id == null || $run_attempt == null || $required_run_id == null || $security_run_id == null {
        usage_error('the following arguments are required for create')
    }
    create_manifest($root, $bundle, $version, $repository, $source_commit, $source_tree, $run_id, $run_attempt, $required_run_id, $security_run_id)
} else if $command_name == 'validate' {
    if $bundle == null {
        usage_error('the following arguments are required: --bundle')
    }
    validate_bundle($bundle, $root, $repository, $version, $source_commit, $source_tree, $run_id, $run_attempt, $tag, $verify_compressed)
} else {
    if $run_path == null || $artifacts_path == null || $repository == null || $run_id == null {
        usage_error('the following arguments are required for select')
    }
    select_candidate($run_path, $artifacts_path, $repository, $run_id)
    exit 0
}

^printf '%s\n' 'release candidate: ok' || exit 1
