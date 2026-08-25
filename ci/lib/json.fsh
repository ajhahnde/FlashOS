import { json_query, require_jq } from './tools.fsh'

def json_is_valid(path, error_path) {
    let jq = require_jq()
    ^env $jq --exit-status . $path >/dev/null 2> $error_path
    return $status.ok
}

def json_compact(path, error_path) {
    let jq = require_jq()
    let document = "$(^env $jq --exit-status --compact-output . $path 2> $error_path)"
    if !$status.ok {
        return null
    }
    return $document
}

export { json_compact, json_is_valid }
