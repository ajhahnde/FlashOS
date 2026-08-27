def repository_error(message) {
    ^printf 'automation repository: %s\n' $message 1>&2
    exit 1
}

def repository_root(marker) {
    let root = "$(pwd)"
    if ^test -f "$root/$marker" {
        let marker_exists = true
    } else {
        repository_error("must be invoked from the repository root (missing $marker)")
    }
    return $root
}

def require_regular_file(path, label) {
    if ^test -f $path {
        let file_exists = true
    } else {
        repository_error("$label is missing or unsafe: $path")
    }
    if ^test -L $path {
        repository_error("$label is missing or unsafe: $path")
    }
    return $path
}

export { repository_error, repository_root, require_regular_file }
