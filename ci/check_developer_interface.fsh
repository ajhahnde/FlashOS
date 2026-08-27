#!/usr/bin/env fsh
# Bash and Zsh are the public interfaces under test. ripgrep exposes bounded
# command inventories; Flash owns the expected surface, comparisons, refusal
# probes, and diagnostics.

import { require_rg } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'

def interface_error(message) {
    ^printf 'developer interface contract: %s\n' $message 1>&2
    exit 1
}

def require_success(program, arguments, label, errors) {
    let output = "$(^env $program ...$arguments 2> $errors)"
    if !$status.ok {
        mut details = "$(^cat $errors)"
        if $details == '' {
            $details = $output
        }
        if $details == '' {
            $details = "exit $status.code"
        }
        interface_error("$label failed: $details")
    }
    return $output
}

def require_absent(path, relative) {
    if ^test -e $path {
        interface_error("removed helper still exists: $relative")
    }
}

let commands = [
'status', 'doctor', 'version', 'versions', 'profile', 'env', 'build',
'run', 'smoke', 'qualify', 'recipe', 'artifacts', 'logs', 'changes',
'check', 'shell', 'podman', 'clean', 'root', 'list', 'help',
]
let direct_helpers = [
'flash-check', 'flashos', 'flashos-artifacts', 'flashos-build',
'flashos-changes', 'flashos-check', 'flashos-clean', 'flashos-doctor',
'flashos-env', 'flashos-list', 'flashos-logs', 'flashos-podman',
'flashos-profile', 'flashos-qualify', 'flashos-recipe', 'flashos-run',
'flashos-smoke', 'flashos-status', 'flashos-version', 'flashos-versions',
'fos',
]
let removed_commands = ['ask', 'commit', 'setup', 'log', 'change']
let command_lines = "$(^printf '%s\n' ...$commands)"
let direct_helper_lines = "$(^printf '%s\n' ...$direct_helpers)"
let removed_paths = [
'tools/flashos/flashos-ask.py',
'tools/flashos/flashos-commit.py',
'tools/flashos/flashos_ai.py',
'tools/flashos/contexts/flashos-ask-context.json',
'tools/flashos/contexts/flashos-commit-context.json',
]

let root = repository_root('versions.env')
let rg = require_rg()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flash-developer-interface.XXXXXX")"
if !$status.ok {
    interface_error('cannot create temporary directory')
}
let errors = "$temporary/errors"
let public_text = "$temporary/public-text"

for relative in $removed_paths {
    require_absent("$root/$relative", $relative)
}
for relative in [
'flashos.sh',
'flashos.zsh',
'docs/development.md',
'docs/verification.md',
'.github/workflows/ci.yml',
] {
    ^cat "$root/$relative" >> $public_text
    ^printf '\n' >> $public_text
}
for command in ['ask', 'commit'] {
    if ^env $rg --fixed-strings --quiet -- "flashos $command" $public_text {
        interface_error("removed command remains documented or exposed: $command")
    }
}
for marker in ['tools/flashos/', 'flashshell-check'] {
    if ^env $rg --fixed-strings --quiet -- $marker $public_text {
        interface_error("removed helper boundary remains exposed: $marker")
    }
}

require_success('bash', ['-n', 'flashos.sh'], 'Bash syntax check', $errors)
let help_output = require_success(
'bash',
['-c', 'source ./flashos.sh; flashos help'],
'Bash help',
$errors,
)
let help_inventory = "$(^printf '%s\n' $help_output | ^env $rg --only-matching --replace '$1' '^  ([a-z][a-z-]*)(?:\s|\[|<)')"
if $help_inventory != $command_lines {
    interface_error('Bash help command inventory drifted')
}
let alias_output = require_success(
'bash',
['-c', 'source ./flashos.sh; fos help'],
'fos alias',
$errors,
)
if $alias_output != $help_output {
    interface_error('fos help differs from flashos help')
}
let completion_output = require_success(
'bash',
[
'-c',
'source ./flashos.sh; COMP_WORDS=(flashos ""); COMP_CWORD=1; _flashos_bash_completion; printf "%s\\n" "${COMPREPLY[@]}"',
],
'Bash completion',
$errors,
)
if $completion_output != $command_lines {
    interface_error('Bash completion command inventory drifted')
}
let list_output = require_success(
'bash',
['-c', 'source ./flashos.sh; flashos list'],
'direct helper list',
$errors,
)
let listed = "$(^printf '%s\n' $list_output | ^sed -n '/^== Direct helper functions ==$/,$p' | ^sed '1d' | ^env LC_ALL=C sort)"
if $listed != $direct_helper_lines {
    interface_error('direct helper inventory drifted')
}

let removed = "$(^printf '%s ' ...$removed_commands | ^sed 's/ $//')"
require_success(
'bash',
[
'-c',
"source ./flashos.sh; for name in $removed; do if flashos \"\$name\" >/dev/null 2>&1; then exit 1; fi; done",
],
'removed command rejection',
$errors,
)
require_success(
'bash',
[
'-c',
'source ./flashos.sh; for name in status doctor version root list help; do if flashos "$name" unexpected >/dev/null 2>&1; then exit 1; fi; done; if flashos profile dev unexpected >/dev/null 2>&1; then exit 1; fi',
],
'unexpected argument rejection',
$errors,
)
require_success(
'bash',
[
'-c',
'source ./flashos.sh; if flashos profile development >/dev/null 2>&1; then exit 1; fi; if flashos build harddrive >/dev/null 2>&1; then exit 1; fi; if flashos run iso >/dev/null 2>&1; then exit 1; fi; if flashos smoke harddrive >/dev/null 2>&1; then exit 1; fi; if flashos artifacts path harddrive >/dev/null 2>&1; then exit 1; fi; if flashos logs iso >/dev/null 2>&1; then exit 1; fi',
],
'legacy alias rejection',
$errors,
)
require_success(
'bash',
[
'-c',
'source ./flashos.sh; podman() { :; }; if flashos podman list >/dev/null 2>&1; then exit 1; fi',
],
'legacy Podman alias rejection',
$errors,
)

let static_commands = "$(^env $rg --only-matching --replace '$1' '^\s+\u0027([a-z][a-z-]*):' "$root/flashos.zsh")"
if $static_commands != $command_lines {
    interface_error('Zsh completion command inventory drifted')
}
^env zsh --version >/dev/null 2> $errors
if !$status.ok {
    ^printf 'developer interface contract: zsh unavailable; runtime Zsh checks skipped\n' 1>&2
} else {
    require_success('zsh', ['-n', 'flashos.sh'], 'Zsh shared syntax check', $errors)
    require_success('zsh', ['-n', 'flashos.zsh'], 'Zsh entrypoint syntax check', $errors)
    let zsh_help = require_success(
    'zsh',
    ['-f', '-c', 'source ./flashos.zsh; flashos help'],
    'Zsh help',
    $errors,
    )
    let zsh_help_inventory = "$(^printf '%s\n' $zsh_help | ^env $rg --only-matching --replace '$1' '^  ([a-z][a-z-]*)(?:\s|\[|<)')"
    if $zsh_help_inventory != $command_lines {
        interface_error('Zsh help command inventory drifted')
    }
    let zsh_completion = require_success(
    'zsh',
    [
    '-f',
    '-c',
    'compdef() { :; }; source ./flashos.zsh; _describe() { local name="$4"; eval "print -rl -- \${${name}[@]}"; }; CURRENT=2; words=(flashos ""); _flashos_zsh_completion',
    ],
    'Zsh completion',
    $errors,
    )
    let completed = "$(^printf '%s\n' $zsh_completion | ^sed 's/:.*$//')"
    if $completed != $command_lines {
        interface_error('Zsh runtime completion command inventory drifted')
    }
}

^rm -rf $temporary
^printf 'developer interface contract: ok\n'
