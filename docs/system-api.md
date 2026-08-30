# FlashOS System API

[FlashOS](../README.md) › [Product Guide](README.md) › System API

FlashOS images built from this source install an experimental, versioned local
system API. The first schema deliberately contains one read-only query:
`system.describe`. Published FlashOS 0.2.0 images predate this interface.

The API is a semantic contract owned by FlashOS. Its Rust types, JSON command,
and Flash records are representations of that contract, not stable binary or
language ABIs. Long-lived stability will be considered only after another
independent consumer has exercised the seam.

## Query from Flash

Import the installed validator and keep every representation change explicit:

```fsh
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
```

The same executable example is installed at
`/usr/share/doc/flashos-system/examples/system-description.fsh`. The external
stage produces bytes, `from json` produces a decoded record, and the imported
pure function validates and maps that record. The transport status stays in
the complete pipeline status; a valid API error and an unsuccessful transport
completion therefore remain separately observable.

## Schema 1

A successful query emits exactly one JSON object followed by LF:

```json
{
  "api": {
    "name": "flashos.system",
    "schema": 1,
    "maturity": "experimental"
  },
  "result": {
    "action": "system.describe",
    "system": {
      "name": "FlashOS",
      "release": "<installed release>",
      "architecture": "x86_64"
    },
    "actions": [
      {
        "name": "system.describe",
        "kind": "query",
        "available": true
      }
    ]
  }
}
```

The release value comes from the assembled image's
`/usr/lib/os-release`; it is not inferred from the host or the package version.
Success contains `result` and omits `error`.

A semantic failure contains `error` and omits `result`:

```json
{
  "api": {
    "name": "flashos.system",
    "schema": 1,
    "maturity": "experimental"
  },
  "error": {
    "code": "unavailable",
    "message": "system description is unavailable"
  }
}
```

The closed schema 1 codes are `invalid_request`, `unsupported_schema`,
`unsupported_action`, `unavailable`, `permission_denied`, `cancelled`, and
`internal`. Consumers may ignore documented additive fields, but must reject a
different contract name, schema, maturity, required field type, or mutually
conflicting success and error members.

## Transport contract and limits

The only invocation is:

```text
flashos-system describe --schema 1 --format json
```

Both options are required. Missing, repeated, non-UTF-8, unknown, or additional
arguments fail closed. The transport accepts at most five arguments after the
executable and 4 KiB of argument bytes, reads no request body or standard input,
emits at most 64 KiB on standard output, and reserves at most 4 KiB for a
bounded diagnostic. Semantic messages are valid UTF-8 without control
characters and at most 512 bytes.

Exit status is `0` for success, `1` when a valid error envelope was emitted,
and greater than `1` only when the transport could not emit a valid envelope.
The process performs no privilege escalation and opens no socket, service,
listener, scheme, or persistent state.

## Compatibility and non-goals

Schema number and maturity are independent. Schema `1` always identifies this
decodable shape and always reports `experimental`; a release number does not
make it stable. Removing or renaming a required field, changing a field's
meaning, or narrowing an accepted value requires a new schema and an explicit
migration decision.

This boundary does not provide service, process, package, network, storage,
device, settings, power, or account management. It has no mutating action,
daemon, remote transport, stable C/Rust/syscall ABI, plugin system, SDK, secrets
interface, or elevated helper. Flash remains independently installable and no
built-in command, grammar, value, carrier, or platform-trait change is implied.

---

[← Previous: Flash and FlashOS](flash.md) · [Documentation index](README.md) · [Next: Architecture →](architecture.md)
