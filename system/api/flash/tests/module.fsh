#!/usr/bin/env fsh

import { system_description_from_envelope } from '../system.fsh'

let success = {
    api: {name: 'flashos.system', schema: 1, maturity: 'experimental'},
    result: {
        action: 'system.describe',
        system: {name: 'FlashOS', release: '0.3.0', architecture: 'x86_64'},
        actions: [{name: 'system.describe', kind: 'query', available: true}],
    },
}
let success_outcome = system_description_from_envelope($success)
if !$success_outcome.ok || $success_outcome.error != null || $success_outcome.result.system.release != '0.3.0' {
    throw 'success outcome differs'
}

let additive = {
    api: {
        name: 'flashos.system',
        schema: 1,
        maturity: 'experimental',
        future: 'ignored',
    },
    result: {
        action: 'system.describe',
        system: {
            name: 'FlashOS',
            release: '0.3.0',
            architecture: 'x86_64',
            future: true,
        },
        actions: [
        {name: 'system.describe', kind: 'query', available: true, future: 1},
        ],
        future: {},
    },
    future: [],
}
if !system_description_from_envelope($additive).ok {
    throw 'additive fields were not ignored'
}

for code in [
'invalid_request',
'unsupported_schema',
'unsupported_action',
'unavailable',
'permission_denied',
'cancelled',
'internal',
] {
    let envelope = {
        api: {name: 'flashos.system', schema: 1, maturity: 'experimental'},
        error: {code: $code, message: 'safe message'},
    }
    let outcome = system_description_from_envelope($envelope)
    if $outcome.ok || $outcome.result != null || $outcome.error.code != $code {
        throw 'semantic error outcome differs'
    }
}

let rejected = [
{},
{api: {name: 'wrong', schema: 1, maturity: 'experimental'}, result: $success.result},
{api: {name: 'flashos.system', schema: 2, maturity: 'experimental'}, result: $success.result},
{api: {name: 'flashos.system', schema: 1, maturity: 'stable'}, result: $success.result},
{api: $success.api, result: $success.result, error: {code: 'internal', message: 'bad'}},
{api: $success.api},
{
    api: $success.api,
    result: {
        action: 'wrong',
        system: $success.result.system,
        actions: $success.result.actions,
    },
},
{
    api: $success.api,
    result: {
        action: 'system.describe',
        system: {name: 'FlashOS', release: '', architecture: 'x86_64'},
        actions: $success.result.actions,
    },
},
{api: $success.api, error: {code: 'unknown', message: 'bad'}},
]

for envelope in $rejected {
    try {
        system_description_from_envelope($envelope)
        throw 'validator accepted an incompatible envelope'
    } catch error {
        if $error.message == 'validator accepted an incompatible envelope' {
            throw $error
        }
    }
}

^printf '%s\n' 'FlashOS system API module tests: ok'
