## Validate a decoded schema 1 `system.describe` envelope.
##
## This function is pure: the caller owns the external command, JSON boundary,
## and pipeline status. Additional record fields are ignored.
def system_description_from_envelope(envelope: Record) -> Record {
    if !('api' in $envelope) {
        throw 'FlashOS system API envelope is missing api'
    }
    let api: Record = $envelope.api
    if !('name' in $api) || !('schema' in $api) || !('maturity' in $api) {
        throw 'FlashOS system API identity is incomplete'
    }
    let api_name: String = $api.name
    let api_schema: Int = $api.schema
    let api_maturity: String = $api.maturity
    if $api_name != 'flashos.system' || $api_schema != 1 || $api_maturity != 'experimental' {
        throw 'FlashOS system API identity is incompatible'
    }

    let has_result = 'result' in $envelope
    let has_error = 'error' in $envelope
    if $has_result == $has_error {
        throw 'FlashOS system API envelope must contain exactly one outcome'
    }

    if $has_error {
        let semantic_error: Record = $envelope.error
        if !('code' in $semantic_error) || !('message' in $semantic_error) {
            throw 'FlashOS system API error is incomplete'
        }
        let code: String = $semantic_error.code
        let message: String = $semantic_error.message
        if !($code in [
        'invalid_request',
        'unsupported_schema',
        'unsupported_action',
        'unavailable',
        'permission_denied',
        'cancelled',
        'internal',
        ]) {
            throw 'FlashOS system API error code is incompatible'
        }
        let outcome = {
            ok: false,
            result: null,
            error: {code: $code, message: $message},
        }
        return $outcome
    }

    let result: Record = $envelope.result
    if !('action' in $result) || !('system' in $result) || !('actions' in $result) {
        throw 'FlashOS system description is incomplete'
    }
    let action: String = $result.action
    if $action != 'system.describe' {
        throw 'FlashOS system description action is incompatible'
    }
    let system: Record = $result.system
    if !('name' in $system) || !('release' in $system) || !('architecture' in $system) {
        throw 'FlashOS system identity is incomplete'
    }
    let system_name: String = $system.name
    let release: String = $system.release
    let architecture: String = $system.architecture
    if $system_name != 'FlashOS' || $release == '' || $architecture != 'x86_64' {
        throw 'FlashOS system identity is incompatible'
    }

    let actions: List[Record] = $result.actions
    mut action_count = 0
    for available_action in $actions {
        if !('name' in $available_action) || !('kind' in $available_action) || !('available' in $available_action) {
            throw 'FlashOS system action inventory is incomplete'
        }
        let available_name: String = $available_action.name
        let available_kind: String = $available_action.kind
        let available: Bool = $available_action.available
        if $available_name != 'system.describe' || $available_kind != 'query' || !$available {
            throw 'FlashOS system action inventory is incompatible'
        }
        $action_count = $action_count + 1
    }
    if $action_count != 1 {
        throw 'FlashOS system action inventory is incompatible'
    }

    let outcome = {
        ok: true,
        result: $result,
        error: null,
    }
    return $outcome
}

export { system_description_from_envelope }
