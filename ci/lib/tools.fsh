# Frozen Flash v1 adapter for explicitly declared parsing/search tools.
# External programs expose bytes; policy and failure mapping remain in Flash.

def dependency_error(message) {
    ^printf 'automation dependency: %s\n' $message 1>&2
    exit 1
}

def selected_tool(environment_name, fallback) {
    let selected = env($environment_name)
    if $selected == null || $selected == '' {
        return $fallback
    }
    return $selected
}

def exact_version(program, arguments, expected, label) {
    let observed = "$(^env $program ...$arguments 2>/dev/null)"
    if !$status.ok {
        dependency_error("$label is unavailable: $program")
    }
    if $observed != $expected {
        dependency_error("$label version differs: expected $expected, observed $observed")
    }
    return $program
}

def require_taplo() {
    let program = selected_tool('FLASH_AUTOMATION_TAPLO', 'taplo')
    return exact_version($program, ['--version'], 'taplo 0.10.0', 'taplo')
}

def require_jq() {
    let program = selected_tool('FLASH_AUTOMATION_JQ', 'jq')
    let observed = "$(^env $program --version 2>/dev/null)"
    if !$status.ok {
        dependency_error("jq is unavailable: $program")
    }
    if !($observed in ['jq-1.7.1', 'jq-1.7.1-apple']) {
        dependency_error("jq version differs: expected 1.7.1, observed $observed")
    }
    return $program
}

def require_rg() {
    let program = selected_tool('FLASH_AUTOMATION_RG', 'rg')
    let observed = "$(^env $program --version | ^sed -n '1s/ (rev .*)$//p')"
    if !$status.ok {
        dependency_error("rg is unavailable: $program")
    }
    if $observed != 'ripgrep 15.2.0' {
        dependency_error("rg version differs: expected ripgrep 15.2.0, observed $observed")
    }
    return $program
}

def toml_to_json(path, error_path) {
    let taplo = require_taplo()
    let document = "$(^env RUST_LOG=error $taplo get --colors never -f $path -o json 2> $error_path)"
    if !$status.ok {
        if ^test -s $error_path {
            ^cat $error_path 1>&2
        }
        dependency_error("cannot decode TOML: $path")
    }
    return $document
}

def json_query(document_path, query, error_path) {
    let jq = require_jq()
    let value = "$(^env $jq --exit-status --raw-output $query $document_path 2> $error_path)"
    if !$status.ok {
        if ^test -s $error_path {
            ^cat $error_path 1>&2
        }
        dependency_error("cannot project JSON: $document_path")
    }
    return $value
}

export {
    dependency_error,
    json_query,
    require_jq,
    require_rg,
    require_taplo,
    selected_tool,
    toml_to_json,
}
