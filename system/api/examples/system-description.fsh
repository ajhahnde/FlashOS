#!/usr/bin/env fsh

import { system_description_from_envelope } from '/usr/share/flashos/flash/system.fsh'

^flashos-system describe --schema 1 --format json \
| from json \
| each {|envelope| system_description_from_envelope($envelope)} \
| to json \
| ^cat

let transport_status = $status.stages[0]
if !$transport_status.ok {
    exit 1
}
