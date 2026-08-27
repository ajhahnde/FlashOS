#!/usr/bin/env fsh
# Taplo exposes Cargo workspace membership, jq projects LCOV/parser records,
# and ripgrep performs bounded path classification. Flash owns the coverage
# policy, ordering, diagnostics, and exit status.

import { require_jq, require_rg, toml_to_json } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def contract_error(message: String) {
    ^printf '%s\n' "coverage contract: $message" 1>&2 || exit
    exit 1
}

def fail_owned(message: String, temporary: String) {
    ^rm -rf -- $temporary
    if !$status.ok {
        exit
    }
    contract_error($message)
}

def usage_error(message: String) {
    ^printf '%s\n' 'usage: check_coverage.fsh [-h] report' 1>&2 || exit
    ^printf '%s\n' "check_coverage.fsh: error: $message" 1>&2 || exit
    exit 2
}

def print_help() {
    ^printf '%s\n' \
    'usage: check_coverage.fsh [-h] report' \
    '' \
    'Reject empty or structurally incomplete Flash host-coverage reports.' \
    '' \
    'positional arguments:' \
    '  report      LCOV report to validate' \
    '' \
    'options:' \
    '  -h, --help  show this help message and exit' || exit
    exit 0
}

def repository_path(raw_path: String, repository_root: String, flash_root: String, rg: String) {
    mut candidates = []
    if ^printf '%s' $raw_path | ^env $rg --quiet '^/' {
        $candidates = [$raw_path]
    } else {
        $candidates = ["$repository_root/$raw_path", "$flash_root/$raw_path"]
    }

    for candidate in $candidates {
        let relative = "$(^realpath -m "--relative-to=$repository_root" -- $candidate 2> /dev/null)"
        if $status.ok {
            if $relative == '..' {
            } else if ^printf '%s' $relative | ^env $rg --quiet '^\.\./' {
            } else {
                return $relative
            }
        }
    }

    null
}

def is_first_party_crate(path: String, rg: String) -> Bool {
    if $path == 'components/flash/crates' {
        return true
    }

    ^printf '%s' $path | ^env $rg --quiet '^components/flash/crates/'
    return $status.ok
}

def validate_workspace(bundle) {
    if $bundle.members_type != 'array' || $bundle.members == [] {
        throw 'Flash workspace members are missing or invalid'
    }
    for member_type in $bundle.member_types {
        if $member_type != 'string' {
            throw 'Flash workspace members are missing or invalid'
        }
    }
    return true
}

let rg = require_rg()
mut argument_count = 0
for argument in $args {
    if $argument in ['-h', '--help'] {
        print_help()
    }
    $argument_count = $argument_count + 1
}

if $argument_count == 0 {
    usage_error('the following arguments are required: report')
}

mut report_argument = ''
mut first_extra = 1
if $args[0] == '--' {
    if $argument_count == 1 {
        usage_error('the following arguments are required: report')
    }
    $report_argument = $args[1]
    $first_extra = 2
} else {
    let first_argument = $args[0]
    if ^printf '%s' $first_argument | ^env $rg --quiet '^-' {
        usage_error("unrecognized arguments: $first_argument")
    }
    $report_argument = $args[0]
}

if $argument_count > $first_extra {
    mut extras = ''
    mut index = 0
    for argument in $args {
        if $index >= $first_extra {
            if $extras == '' {
                $extras = $argument
            } else {
                $extras = "$extras $argument"
            }
        }
        $index = $index + 1
    }
    usage_error("unrecognized arguments: $extras")
}

let root = repository_root('versions.env')
let flash_root = "$root/components/flash"
let flash_manifest = "$flash_root/Cargo.toml"
let jq = require_jq()
let report = "$(^realpath -m -- $report_argument)"
if !$status.ok {
    exit
}

if ^test -f $report && ^test -s $report {
} else {
    contract_error("report is missing or empty: $report")
}

mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flash-coverage.XXXXXX")"
if !$status.ok {
    exit
}
let events_path = "$temporary/events.json"
let covered_files_path = "$temporary/covered-files"
^printf '%s' '' > $covered_files_path
if !$status.ok {
    fail_owned('cannot create coverage validation state', $temporary)
}

^env $jq -Rs \
'gsub("\r\n"; "\n") | gsub("\r"; "\n") | split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end | to_entries | map(. as $entry | $entry.value as $line | if ($line | startswith("SF:")) then {kind: "sf", value: $line[3:]} elif ($line | startswith("DA:")) then {kind: "da", fields: ($line[3:] | split(","))} else {kind: "other"} end)' \
$report > $events_path
if !$status.ok {
    fail_owned('cannot parse the coverage report', $temporary)
}

mut current_file = null
mut executable_lines = 0
mut hit_lines = 0
mut event_index = 0
mut events_remaining = true
while $events_remaining {
    let event_exists = "$(^env $jq --raw-output --argjson index $event_index 'has($index)' $events_path)"
    if !$status.ok {
        fail_owned('cannot parse the coverage report', $temporary)
    }
    if $event_exists != 'true' {
        $events_remaining = false
        continue
    }

    let event_kind = "$(^env $jq --raw-output --argjson index $event_index '.[$index].kind' $events_path)"
    if !$status.ok {
        fail_owned('cannot parse the coverage report', $temporary)
    }

    if $event_kind == 'sf' {
        let source_value = "$(^env $jq --raw-output --argjson index $event_index '.[$index].value' $events_path)"
        if !$status.ok {
            fail_owned('cannot parse the coverage report', $temporary)
        }
        $current_file = repository_path($source_value, $root, $flash_root, $rg)
        if $current_file != null {
            if is_first_party_crate($current_file, $rg) {
                if ^env $rg --fixed-strings --line-regexp --quiet -- $current_file $covered_files_path {
                } else {
                    ^printf '%s\n' $current_file >> $covered_files_path
                    if !$status.ok {
                        fail_owned('cannot record covered files', $temporary)
                    }
                }
            } else {
                $current_file = null
            }
        }
    } else if $event_kind == 'da' && $current_file != null {
        let field_count = "$(^env $jq --raw-output --argjson index $event_index '.[$index].fields | length' $events_path)"
        if !$status.ok {
            fail_owned('cannot parse the coverage report', $temporary)
        }
        let line_number = $event_index + 1
        if $field_count == '0' || $field_count == '1' {
            fail_owned("invalid DA record at line $line_number", $temporary)
        }

        let raw_count = "$(^env $jq --raw-output --argjson index $event_index '.[$index].fields[1]' $events_path)"
        if !$status.ok {
            fail_owned('cannot parse the coverage report', $temporary)
        }
        if ^printf '%s' $raw_count | ^env $rg --quiet '^[[:space:]]*[+-]?[0-9](_?[0-9])*[[:space:]]*$' {
        } else {
            fail_owned("invalid execution count at line $line_number", $temporary)
        }

        $executable_lines = $executable_lines + 1
        let normalized_count = "$(^printf '%s' $raw_count | ^tr -d '[:space:]_')"
        if !$status.ok {
            fail_owned('cannot normalize an execution count', $temporary)
        }
        if ^printf '%s' $normalized_count | ^env $rg --quiet '^-' {
        } else if ^printf '%s' $normalized_count | ^env $rg --quiet '^\+?0+$' {
        } else {
            $hit_lines = $hit_lines + 1
        }
    }

    $event_index = $event_index + 1
}

mut covered_files_empty = false
if ^test -s $covered_files_path {
} else {
    $covered_files_empty = true
}
if $covered_files_empty || $executable_lines == 0 {
    fail_owned('report contains no first-party executable Rust lines', $temporary)
}
if $hit_lines == 0 {
    fail_owned('report contains no executed first-party Rust lines', $temporary)
}

let workspace_path = "$temporary/workspace.json"
let workspace_bundle = "$temporary/workspace-bundle.json"
let members_path = "$temporary/members.json"
let workspace_document = toml_to_json($flash_manifest, "$temporary/taplo-errors")
^printf '%s' $workspace_document > $workspace_path
if !$status.ok {
    fail_owned('Flash workspace members are missing or invalid', $temporary)
}
^env $jq \
'{members: (.workspace.members // null), members_type: ((.workspace.members // null) | type), member_types: [(.workspace.members // [])[] | type]}' \
$workspace_path > $workspace_bundle
if !$status.ok {
    fail_owned('Flash workspace members are missing or invalid', $temporary)
}
try {
    open $workspace_bundle | from json | each {|bundle| validate_workspace($bundle)} | to json >/dev/null
} catch error {
    let message = $error.message
    fail_owned($message, $temporary)
}
^env $jq --compact-output '.members' $workspace_bundle > $members_path
if !$status.ok {
    fail_owned('Flash workspace members are missing or invalid', $temporary)
}
mut missing_members = ''
mut member_index = 0
mut members_remaining = true
while $members_remaining {
    let member_exists = "$(^env $jq --raw-output --argjson index $member_index 'has($index)' $members_path)"
    if !$status.ok {
        fail_owned('Flash workspace members are missing or invalid', $temporary)
    }
    if $member_exists != 'true' {
        $members_remaining = false
        continue
    }

    let raw_member = "$(^env $jq --raw-output --argjson index $member_index '.[$index]' $members_path)"
    if !$status.ok {
        fail_owned('Flash workspace members are missing or invalid', $temporary)
    }
    let member = "components/flash/$raw_member"
    let source_root = "$member/src"
    if ^env $rg --quiet "^$source_root/" $covered_files_path {
    } else if $missing_members == '' {
        $missing_members = $member
    } else {
        $missing_members = "$missing_members, $member"
    }
    $member_index = $member_index + 1
}

if $member_index == 0 {
    fail_owned('Flash workspace members are missing or invalid', $temporary)
}

if $missing_members != '' {
    fail_owned("report omitted Flash workspace members: $missing_members", $temporary)
}

let covered_file_count_text = "$(^wc -l < $covered_files_path)"
if !$status.ok {
    fail_owned('cannot count covered files', $temporary)
}

let percent = $hit_lines * 100.0 / $executable_lines
^printf '%s\n' 'coverage contract: ok' || exit
^printf 'workspace members: %d\n' $member_index || exit
^printf 'reported first-party files: %d\n' $covered_file_count_text || exit
^printf 'host line coverage: %d/%d (%.2f%%)\n' $hit_lines $executable_lines $percent || exit
^rm -rf -- $temporary || exit
