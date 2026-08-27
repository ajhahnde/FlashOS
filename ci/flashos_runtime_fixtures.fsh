#!/usr/bin/env fsh
# Native dependencies: jq 1.7.1 and taplo 0.10.0. Taplo owns TOML decoding;
# Flash owns the CLI, validation, versioned byte boundary, and rendering.

import { require_jq, require_rg, require_taplo } from './lib/tools.fsh'
import { repository_root } from './lib/repository.fsh'
import { expect_equal, expect_unique } from './lib/validation.fsh'

def require_string_observation(observation, label) {
    if $observation.type != 'string' || !$observation.non_whitespace {
        throw "$label must be a non-empty string"
    }
    return $observation.value
}

def require_string_list_observation(observation, label, nonempty) {
    if $observation.type != 'array' {
        throw "$label must be a list of non-empty strings"
    }
    if $nonempty && $observation.items == [] {
        throw "$label must be a list of non-empty strings"
    }
    for item in $observation.items {
        require_string_observation($item, $label)
    }
    expect_unique($observation.values, "$label contains duplicates")
    return $observation.values
}

def require_hex_observation(observation, label) {
    require_string_observation($observation, $label)
    if !$observation.even_length || !$observation.hex_characters {
        throw "$label must contain complete hexadecimal bytes"
    }
    return $observation.value
}

def validate_runtime_fixture(envelope) {
    let document = $envelope.document
    expect_equal($envelope.keys, ['architecture', 'capability_report', 'consumers', 'fixture', 'max_interaction_bytes', 'platform', 'prompt', 'schema_version', 'scope', 'suite_version', 'target', 'terminator_hex'], 'document fields differ')
    if $document.schema_version != 1 {
        throw "schema_version is ${$envelope.scalar_repr.schema_version}, expected 1"
    }
    if $document.suite_version != 1 {
        throw "suite_version is ${$envelope.scalar_repr.suite_version}, expected 1"
    }
    if $document.scope != 'bounded' {
        throw "scope is ${$envelope.scalar_repr.scope}, expected \"bounded\""
    }
    if $document.platform != 'flashos' {
        throw "platform is ${$envelope.scalar_repr.platform}, expected \"flashos\""
    }
    if $document.architecture != 'x86_64' {
        throw "architecture is ${$envelope.scalar_repr.architecture}, expected \"x86_64\""
    }
    if $document.target != 'x86_64-unknown-redox' {
        throw "target is ${$envelope.scalar_repr.target}, expected \"x86_64-unknown-redox\""
    }
    expect_equal($document.capability_report, 'flashos-x86_64-capability-report-v1.toml', 'capability_report differs')
    expect_equal($document.prompt, '>> ', 'prompt differs')
    expect_equal($document.terminator_hex, '0d', 'terminator_hex differs')
    expect_equal($document.max_interaction_bytes, 16, 'max_interaction_bytes differs')
    let consumers = require_string_list_observation($envelope.consumers, 'consumers', true)
    expect_equal($consumers, ['qemu', 'real-system'], 'consumers must preserve the qemu and real-system contract')
    if $envelope.fixture_type != 'array' || $envelope.fixtures == [] {
        throw 'fixture must be a non-empty array of tables'
    }
    for fixture in $envelope.fixtures {
        let label = "fixture[${$fixture.index}]"
        if $fixture.type != 'object' {
            throw "$label must be a table"
        }
        expect_equal($fixture.keys, ['capabilities', 'id', 'reject', 'step', 'summary'], "$label fields differ")
        require_string_observation($fixture.id, "$label.id")
        require_string_observation($fixture.summary, "$label.summary")
        require_string_list_observation($fixture.capabilities, "$label.capabilities", true)
        require_string_list_observation($fixture.reject, "$label.reject", false)
        if $fixture.step_type != 'array' || $fixture.steps == [] {
            throw "$label.step must not be empty"
        }
        for step in $fixture.steps {
            let step_label = "$label.step[${$step.index}]"
            if $step.type != 'object' {
                throw "$step_label must be a table"
            }
            for key in $step.keys {
                if !($key in ['expect', 'input', 'input_hex', 'manual', 'rendered']) {
                    throw "$step_label has unknown fields"
                }
            }
            if !$step.has_rendered || !$step.has_manual {
                throw "$step_label is missing required fields"
            }
            mut input_fields = 0
            if $step.has_input {
                $input_fields = $input_fields + 1
            }
            if $step.has_input_hex {
                $input_fields = $input_fields + 1
            }
            if $input_fields != 1 {
                throw "$step_label must contain exactly one input field"
            }
            require_string_observation($step.rendered, "$step_label.rendered")
            require_string_observation($step.manual, "$step_label.manual")
            if $step.has_expect {
                require_string_observation($step.expect, "$step_label.expect")
            }
            mut payload_bytes = 0
            mut contains_terminator = false
            if $step.has_input {
                require_string_observation($step.input, "$step_label.input")
                $payload_bytes = $step.input.utf8_bytes
                $contains_terminator = $step.input.contains_terminator
            } else {
                require_hex_observation($step.input_hex, "$step_label.input_hex")
                $payload_bytes = $step.input_hex.byte_length
                $contains_terminator = $step.input_hex.contains_terminator
            }
            if $payload_bytes + 1 > 16 {
                throw "$step_label exceeds the 16-byte interaction limit"
            }
            if $contains_terminator {
                throw "$step_label input must not contain its terminator"
            }
            if !$step.rendered.starts_prompt {
                throw "$step_label.rendered must start with the suite prompt"
            }
        }
    }
    expect_unique($envelope.fixture_ids, 'fixture ids contain duplicates')
    return $document
}

def usage_error(message) {
    ^printf '%s\n' "usage: flashos_runtime_fixtures.fsh [-h] [--fixtures FIXTURES] [--output {text,json-v1}]" 1>&2
    ^printf '%s\n' "flashos_runtime_fixtures.fsh: error: $message" 1>&2
    exit 2
}

def print_help() {
    ^printf '%s\n' \
    'usage: flashos_runtime_fixtures.fsh [-h] [--fixtures FIXTURES] [--output {text,json-v1}]' \
    '' \
    'Render the tracked FlashOS smoke fixtures for a real system' \
    '' \
    'options:' \
    '  -h, --help           show this help message and exit' \
    '  --fixtures FIXTURES' \
    '  --output {text,json-v1}' || exit 1
    exit 0
}

def contract_error(message) {
    ^printf 'FlashOS runtime fixtures: %s\n' $message 1>&2
    exit 1
}

let root = repository_root('versions.env')
mut fixtures = "$root/components/flash/platforms/flashos-x86_64-runtime-fixtures-v1.toml"
mut output = 'text'
mut expecting = ''
for argument in $args {
    if $expecting == 'fixtures' {
        $fixtures = $argument
        $expecting = ''
    } else if $expecting == 'output' {
        if $argument in ['text', 'json-v1'] {
            $output = $argument
        } else {
            usage_error("argument --output: invalid choice: '$argument'")
        }
        $expecting = ''
    } else if $argument == '--fixtures' {
        $expecting = 'fixtures'
    } else if $argument == '--output' {
        $expecting = 'output'
    } else if '--fixtures=' in $argument {
        let rg = require_rg()
        if ^printf '%s' $argument | ^env $rg --quiet '^--fixtures=' {
            $fixtures = "$(^printf '%s' $argument | ^sed 's/^--fixtures=//')"
        } else {
            usage_error("unrecognized arguments: $argument")
        }
    } else if '--output=' in $argument {
        let rg = require_rg()
        if ^printf '%s' $argument | ^env $rg --quiet '^--output=' {
            let selected = "$(^printf '%s' $argument | ^sed 's/^--output=//')"
            if $selected in ['text', 'json-v1'] {
                $output = $selected
            } else {
                usage_error("argument --output: invalid choice: '$selected'")
            }
        } else {
            usage_error("unrecognized arguments: $argument")
        }
    } else if $argument in ['-h', '--help'] {
        print_help()
    } else {
        usage_error("unrecognized arguments: $argument")
    }
}
if $expecting == 'fixtures' {
    usage_error('argument --fixtures: expected one argument')
}
if $expecting == 'output' {
    usage_error('argument --output: expected one argument')
}

if ^test -f $fixtures {
    let fixture_exists = true
} else {
    contract_error("cannot read $fixtures: [Errno 2] No such file or directory: '$fixtures'")
}

let taplo = require_taplo()
let jq = require_jq()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flashos-runtime-fixtures.XXXXXX")"
if !$status.ok {
    contract_error('cannot create temporary directory')
}
let decoded = "$temporary/decoded.json"
let observed = "$temporary/observed.json"
let validated = "$temporary/validated.json"
let boundary = "$temporary/boundary.json"
let errors = "$temporary/errors"

^env RUST_LOG=error $taplo get --colors never -f $fixtures -o json > $decoded 2> $errors
if !$status.ok {
    if ^test -s $errors {
        ^cat $errors 1>&2
    }
    ^rm -rf $temporary
    contract_error("cannot read $fixtures")
}

let observe = '
def string_observation:
  {value:., type:type,
   non_whitespace:(try test("\\S") catch false),
   even_length:(try ((length % 2) == 0) catch false),
   hex_characters:(try test("^[0-9A-Fa-f]+$") catch false),
   byte_length:(try (length / 2) catch -1),
   utf8_bytes:(try utf8bytelength catch -1),
   contains_terminator:(try (contains("\r") or (ascii_downcase | test("(^|..)0d(..|$)"))) catch false),
   starts_prompt:(try startswith(">> ") catch false)};
def list_observation:
  {type:type, values:(try [ .[] ] catch []), items:(try [ .[] | string_observation ] catch [])};
. as $document |
{document:$document,
 keys:(try (keys | sort) catch []),
 scalar_repr:{schema_version:($document.schema_version|tojson), suite_version:($document.suite_version|tojson), scope:($document.scope|tojson), platform:($document.platform|tojson), architecture:($document.architecture|tojson), target:($document.target|tojson)},
 consumers:($document.consumers | list_observation),
 fixture_type:($document.fixture | type),
 fixture_ids:(try [ $document.fixture[].id ] catch []),
 fixtures:(try [ $document.fixture | to_entries[] |
   .key as $fixture_index | .value as $fixture |
   {index:$fixture_index, type:($fixture|type), keys:(try ($fixture|keys|sort) catch []),
    id:($fixture.id|string_observation), summary:($fixture.summary|string_observation),
    capabilities:($fixture.capabilities|list_observation), reject:($fixture.reject|list_observation),
    step_type:($fixture.step|type),
    steps:(try [ $fixture.step | to_entries[] |
      .key as $step_index | .value as $step |
      {index:$step_index, type:($step|type), keys:(try ($step|keys|sort) catch []),
       has_input:(try ($step|has("input")) catch false), has_input_hex:(try ($step|has("input_hex")) catch false),
       has_rendered:(try ($step|has("rendered")) catch false), has_expect:(try ($step|has("expect")) catch false),
       has_manual:(try ($step|has("manual")) catch false),
       input:($step.input|string_observation), input_hex:($step.input_hex|string_observation),
       rendered:($step.rendered|string_observation), expect:($step.expect|string_observation),
       manual:($step.manual|string_observation)} ] catch [])} ] catch [])}'

^env $jq --sort-keys $observe $decoded > $observed 2> $errors
if !$status.ok {
    ^rm -rf $temporary
    contract_error('decoded fixture contract is invalid')
}
try {
    open $observed | from json | each {|envelope| validate_runtime_fixture($envelope)} | to json > $validated
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    contract_error($message)
}

let project_boundary = '
{
  boundary_schema: 1,
  kind: "flashos-runtime-fixtures",
  suite_version,
  scope,
  consumers,
  prompt: {encoding:"utf8", text:.prompt},
  terminator: {encoding:"hex", data:(.terminator_hex|ascii_downcase)},
  max_interaction_bytes,
  fixtures: [
    .fixture | to_entries[] |
    .value as $fixture |
    {
      id:$fixture.id,
      summary:$fixture.summary,
      capabilities:$fixture.capabilities,
      rejected:[ $fixture.reject[] | {encoding:"utf8", text:.} ],
      steps:[
        $fixture.step | to_entries[] |
        .value as $step |
        {
          payload:(if $step|has("input") then {encoding:"utf8",text:$step.input} else {encoding:"hex",data:($step.input_hex|ascii_downcase)} end),
          rendered:{encoding:"utf8",text:$step.rendered},
          expected:(if $step|has("expect") then {encoding:"utf8",text:$step.expect} else null end),
          manual:$step.manual
        }
      ]
    }
  ]
}'

^env $jq --sort-keys --compact-output $project_boundary $validated > $boundary 2> $errors
if !$status.ok {
    ^rm -rf $temporary
    contract_error('cannot project validated fixture contract')
}

if $output == 'json-v1' {
    ^cat $boundary
    let result = $status
    ^rm -rf $temporary
    if !$result.ok {
        exit 1
    }
    exit 0
}

let render = '
def pyrepr:
  . as $value | @json as $json |
  if ($value|contains("\u0027")) and (($value|contains("\""))|not) then $json
  else "\u0027" + ($json[1:-1] | gsub("\\\\\""; "\"")) + "\u0027" end;
def hex_digit: . as $digit | ("0123456789abcdef" | index($digit));
def hex_bytes:
  ascii_downcase as $hex |
  [range(0; $hex|length; 2) as $index |
   (($hex[$index:$index+1]|hex_digit) * 16 + ($hex[$index+1:$index+2]|hex_digit))];
def payload_text:
  if .encoding == "utf8" then .text
  else .data | hex_bytes | map(
    if . == 127 then "<Backspace>"
    elif . >= 32 and . <= 126 then [.] | implode
    else . as $byte |
      "<0x" +
      ("0123456789ABCDEF"[(($byte / 16) | floor):((($byte / 16) | floor) + 1)]) +
      ("0123456789ABCDEF"[($byte % 16):(($byte % 16) + 1)]) + ">"
    end) | join("")
  end;
[
  "FlashOS runtime smoke fixtures v\(.suite_version) (\(.scope))",
  "Log in as user, wait for the Flash prompt, and run these fixtures in order.",
  (.fixtures[] |
    "",
    "\(.id): \(.summary)",
    (.steps | to_entries[] |
      "  \(.key + 1). Enter: \(.value.payload|payload_text)",
      "     Observe: \(.value.manual)",
      (if .value.expected == null then empty else "     Expect: \(.value.expected.text|pyrepr)" end)),
    (.rejected[] | "  Reject any transcript containing: \(.text|pyrepr)"))
] | .[]'

^env $jq --raw-output $render $boundary
let result = $status
^rm -rf $temporary
if !$result.ok {
    exit 1
}
