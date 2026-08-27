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

def validate_target_matrix(envelope) {
    let document = $envelope.document
    expect_equal($envelope.keys, ['architecture', 'capability_classification', 'capability_report', 'case', 'configured_prompt', 'consumers', 'continuation_prompt', 'matrix_version', 'max_interaction_bytes', 'platform', 'primary_prompt', 'required_surfaces', 'runtime_fixtures', 'schema_version', 'scope', 'script_transport_chunk_bytes', 'target', 'terminator_hex', 'withheld_capabilities'], 'document fields differ')
    if $document.schema_version != 1 {
        throw "schema_version is ${$envelope.scalar_repr.schema_version}, expected 1"
    }
    if $document.matrix_version != 1 {
        throw "matrix_version is ${$envelope.scalar_repr.matrix_version}, expected 1"
    }
    expect_equal($document.scope, 'advertised-capabilities', 'scope differs')
    expect_equal($document.platform, 'flashos', 'platform differs')
    expect_equal($document.architecture, 'x86_64', 'architecture differs')
    expect_equal($document.target, 'x86_64-unknown-redox', 'target differs')
    expect_equal($document.capability_report, 'flashos-x86_64-capability-report-v1.toml', 'capability_report differs')
    expect_equal($document.capability_classification, 'flashos-x86_64-capability-classification.toml', 'capability_classification differs')
    expect_equal($document.runtime_fixtures, 'flashos-x86_64-runtime-fixtures-v1.toml', 'runtime_fixtures differs')
    expect_equal($document.primary_prompt, '>> ', 'primary_prompt differs')
    expect_equal($document.continuation_prompt, '...> ', 'continuation_prompt differs')
    expect_equal($document.configured_prompt, 'C> ', 'configured_prompt differs')
    expect_equal($document.terminator_hex, '0d', 'terminator_hex differs')
    expect_equal($document.max_interaction_bytes, 16, 'max_interaction_bytes differs')
    expect_equal($document.script_transport_chunk_bytes, 16, 'script_transport_chunk_bytes differs')
    let consumers = require_string_list_observation($envelope.consumers, 'consumers', true)
    expect_equal($consumers, ['qemu', 'operator-observed-target'], 'consumers must preserve qemu and operator-observed-target order')
    require_string_list_observation($envelope.required_surfaces, 'required_surfaces', true)
    require_string_list_observation($envelope.withheld_capabilities, 'withheld_capabilities', true)
    if $envelope.case_type != 'array' || $envelope.cases == [] {
        throw 'case must be a non-empty array of tables'
    }
    for selected_case in $envelope.cases {
        let label = "case[${$selected_case.index}]"
        if $selected_case.type != 'object' {
            throw "$label must be a table"
        }
        expect_equal($selected_case.keys, ['capabilities', 'id', 'operation_ids', 'reject', 'step', 'summary', 'surfaces'], "$label fields differ")
        require_string_observation($selected_case.id, "$label.id")
        require_string_observation($selected_case.summary, "$label.summary")
        require_string_list_observation($selected_case.surfaces, "$label.surfaces", true)
        require_string_list_observation($selected_case.capabilities, "$label.capabilities", true)
        require_string_list_observation($selected_case.operation_ids, "$label.operation_ids", false)
        require_string_list_observation($selected_case.reject, "$label.reject", false)
        if $selected_case.step_type != 'array' || $selected_case.steps == [] {
            throw "$label.step must not be empty"
        }
        for step in $selected_case.steps {
            let step_label = "$label.step[${$step.index}]"
            if $step.type != 'object' {
                throw "$step_label must be a table"
            }
            for key in $step.keys {
                if !($key in ['expect', 'input', 'input_hex', 'manual', 'rendered', 'send']) {
                    throw "$step_label has unknown fields"
                }
            }
            if !$step.has_send || !$step.has_expect || !$step.has_manual {
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
            if $step.has_input {
                require_string_observation($step.input, "$step_label.input")
            } else {
                require_hex_observation($step.input_hex, "$step_label.input_hex")
            }
            let send = require_string_observation($step.send, "$step_label.send")
            if !($send in ['line', 'keys', 'script']) {
                throw "$step_label.send must be line, keys, or script"
            }
            if $send == 'line' && !$step.has_rendered {
                throw "$step_label.rendered is required for line input"
            }
            if $step.has_rendered {
                require_string_observation($step.rendered, "$step_label.rendered")
            }
            require_string_list_observation($step.expect, "$step_label.expect", true)
            require_string_observation($step.manual, "$step_label.manual")
        }
    }
    expect_unique($envelope.case_ids, 'case ids contain duplicates')
    return $document
}

def usage_error(message) {
    ^printf '%s\n' "usage: flashos_target_matrix.fsh [-h] [--matrix MATRIX] [--output {text,json-v1}]" 1>&2
    ^printf '%s\n' "flashos_target_matrix.fsh: error: $message" 1>&2
    exit 2
}

def print_help() {
    ^printf '%s\n' \
    'usage: flashos_target_matrix.fsh [-h] [--matrix MATRIX] [--output {text,json-v1}]' \
    '' \
    'Render the tracked FlashOS target capability matrix' \
    '' \
    'options:' \
    '  -h, --help       show this help message and exit' \
    '  --matrix MATRIX' \
    '  --output {text,json-v1}' || exit 1
    exit 0
}

def contract_error(message) {
    ^printf 'FlashOS target matrix: %s\n' $message 1>&2
    exit 1
}

let root = repository_root('versions.env')
mut matrix = "$root/components/flash/platforms/flashos-x86_64-target-matrix-v1.toml"
mut output = 'text'
mut expecting = ''
for argument in $args {
    if $expecting == 'matrix' {
        $matrix = $argument
        $expecting = ''
    } else if $expecting == 'output' {
        if $argument in ['text', 'json-v1'] {
            $output = $argument
        } else {
            usage_error("argument --output: invalid choice: '$argument'")
        }
        $expecting = ''
    } else if $argument == '--matrix' {
        $expecting = 'matrix'
    } else if $argument == '--output' {
        $expecting = 'output'
    } else if '--matrix=' in $argument {
        let rg = require_rg()
        if ^printf '%s' $argument | ^env $rg --quiet '^--matrix=' {
            $matrix = "$(^printf '%s' $argument | ^sed 's/^--matrix=//')"
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
if $expecting == 'matrix' {
    usage_error('argument --matrix: expected one argument')
}
if $expecting == 'output' {
    usage_error('argument --output: expected one argument')
}

if ^test -f $matrix {
    let matrix_exists = true
} else {
    contract_error("cannot read $matrix: [Errno 2] No such file or directory: '$matrix'")
}

let taplo = require_taplo()
let jq = require_jq()
mut temporary_parent = env('TMPDIR')
if $temporary_parent == null {
    $temporary_parent = '/tmp'
}
let temporary = "$(^mktemp -d "$temporary_parent/flashos-target-matrix.XXXXXX")"
if !$status.ok {
    contract_error('cannot create temporary directory')
}
let decoded = "$temporary/decoded.json"
let observed = "$temporary/observed.json"
let validated = "$temporary/validated.json"
let boundary = "$temporary/boundary.json"
let errors = "$temporary/errors"

^env RUST_LOG=error $taplo get --colors never -f $matrix -o json > $decoded 2> $errors
if !$status.ok {
    if ^test -s $errors {
        ^cat $errors 1>&2
    }
    ^rm -rf $temporary
    contract_error("cannot read $matrix")
}

let observe = '
def string_observation:
  {value:., type:type,
   non_whitespace:(try test("\\S") catch false),
   even_length:(try ((length % 2) == 0) catch false),
   hex_characters:(try test("^[0-9A-Fa-f]+$") catch false)};
def list_observation:
  {type:type, values:(try [ .[] ] catch []), items:(try [ .[] | string_observation ] catch [])};
. as $document |
{document:$document,
 keys:(try (keys | sort) catch []),
 scalar_repr:{schema_version:($document.schema_version|tojson), matrix_version:($document.matrix_version|tojson)},
 consumers:($document.consumers|list_observation),
 required_surfaces:($document.required_surfaces|list_observation),
 withheld_capabilities:($document.withheld_capabilities|list_observation),
 case_type:($document.case|type),
 case_ids:(try [ $document.case[].id ] catch []),
 cases:(try [ $document.case | to_entries[] |
   .key as $case_index | .value as $case |
   {index:$case_index, type:($case|type), keys:(try ($case|keys|sort) catch []),
    id:($case.id|string_observation), summary:($case.summary|string_observation),
    surfaces:($case.surfaces|list_observation), capabilities:($case.capabilities|list_observation),
    operation_ids:($case.operation_ids|list_observation), reject:($case.reject|list_observation),
    step_type:($case.step|type),
    steps:(try [ $case.step | to_entries[] |
      .key as $step_index | .value as $step |
      {index:$step_index, type:($step|type), keys:(try ($step|keys|sort) catch []),
       has_input:(try ($step|has("input")) catch false), has_input_hex:(try ($step|has("input_hex")) catch false),
       has_send:(try ($step|has("send")) catch false), has_rendered:(try ($step|has("rendered")) catch false),
       has_expect:(try ($step|has("expect")) catch false), has_manual:(try ($step|has("manual")) catch false),
       input:($step.input|string_observation), input_hex:($step.input_hex|string_observation),
       send:($step.send|string_observation), rendered:($step.rendered|string_observation),
       expect:($step.expect|list_observation), manual:($step.manual|string_observation)} ] catch [])} ] catch [])}'

^env $jq --sort-keys $observe $decoded > $observed 2> $errors
if !$status.ok {
    ^rm -rf $temporary
    contract_error('decoded target-matrix contract is invalid')
}
try {
    open $observed | from json | each {|envelope| validate_target_matrix($envelope)} | to json > $validated
} catch error {
    let message = $error.message
    ^rm -rf $temporary
    contract_error($message)
}

let project_boundary = '
{
  boundary_schema:1,
  kind:"flashos-target-matrix",
  matrix_version,
  scope,
  consumers,
  prompts:{
    primary:{encoding:"utf8",text:.primary_prompt},
    continuation:{encoding:"utf8",text:.continuation_prompt},
    configured:{encoding:"utf8",text:.configured_prompt}
  },
  terminator:{encoding:"hex",data:(.terminator_hex|ascii_downcase)},
  max_interaction_bytes,
  script_transport_chunk_bytes,
  required_surfaces,
  withheld_capabilities,
  cases:[
    .case | to_entries[] |
    .value as $case |
    {
      id:$case.id,
      summary:$case.summary,
      surfaces:$case.surfaces,
      capabilities:$case.capabilities,
      operation_ids:$case.operation_ids,
      rejected:[ $case.reject[] | {encoding:"utf8",text:.} ],
      steps:[
        $case.step | to_entries[] |
        .value as $step |
        {
          payload:(if $step|has("input") then {encoding:"utf8",text:$step.input} else {encoding:"hex",data:($step.input_hex|ascii_downcase)} end),
          send:$step.send,
          rendered:(if $step|has("rendered") then {encoding:"utf8",text:$step.rendered} else null end),
          expected:[ $step.expect[] | {encoding:"utf8",text:.} ],
          manual:$step.manual
        }
      ]
    }
  ]
}'

^env $jq --sort-keys --compact-output $project_boundary $validated > $boundary 2> $errors
if !$status.ok {
    ^rm -rf $temporary
    contract_error('cannot project validated target-matrix contract')
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
  else
    (.data | hex_bytes | implode) |
    gsub("\u001b\\[A"; "<Up>") |
    gsub("\u001b\\[B"; "<Down>") |
    gsub("\u001b\\[C"; "<Right>") |
    gsub("\u001b\\[D"; "<Left>") |
    gsub("\u0003"; "<Ctrl-C>") |
    gsub("\u0009"; "<Tab>") |
    gsub("\u000d"; "<Enter>") |
    gsub("\u007f"; "<Backspace>")
  end;
[
  "FlashOS target capability matrix v\(.matrix_version) (\(.scope))",
  "Log in as user, wait for the Flash prompt, and perform every case in order.",
  "Record observations against the exact image identity; rendering is not a run.",
  (.cases[] |
    "",
    "\(.id): \(.summary)",
    (.steps | to_entries[] |
      .key as $index | .value as $step |
      (if $step.send == "script" then
        "  \($index + 1). Script:",
        ($step.payload.text | split("\n")[:-1][] | "     | \(.)")
       else
        "  \($index + 1). \(if $step.send == "line" then "Enter" else "Keys" end): \($step.payload|payload_text)"
       end),
      "     Observe: \($step.manual)",
      ($step.expected[] | "     Expect in order: \(.text|pyrepr)")),
    (.rejected[] | "  Reject any case transcript containing: \(.text|pyrepr)"))
] | .[]'

^env $jq --raw-output $render $boundary
let result = $status
^rm -rf $temporary
if !$result.ok {
    exit 1
}
