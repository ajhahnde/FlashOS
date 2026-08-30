#!/usr/bin/env python3
"""Boot an immutable FlashOS disk image and verify its serial contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import selectors
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

DEFAULT_OVMF_PATHS = (
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/OVMF/OVMF_CODE_4M.fd",
    "/usr/share/edk2/ovmf/OVMF_CODE.fd",
    "/opt/homebrew/opt/qemu/share/qemu/edk2-x86_64-code.fd",
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_PATH = (
    REPOSITORY_ROOT
    / "components/flash/platforms/flashos-x86_64-runtime-fixtures-v1.toml"
)
MATRIX_PATH = (
    REPOSITORY_ROOT / "components/flash/platforms/flashos-x86_64-target-matrix-v1.toml"
)
DEFAULT_AUTOMATION_RUNTIME = REPOSITORY_ROOT / "components/flash/target/debug/fsh"
PUBLIC_AUTOMATION_ROOTS = (
    REPOSITORY_ROOT / "recipes/groups/auto-test/auto-test.fsh",
    REPOSITORY_ROOT / "recipes/tests/acid/acid-runner.fsh",
    REPOSITORY_ROOT / "recipes/tests/relibc-tests-bins/relibc-tests-runner.fsh",
    REPOSITORY_ROOT / "recipes/tests/os-test-bins/os-test-runner.fsh",
)

# This gate qualifies deterministic product behavior, not SMP scheduling.
# Keeping TCG to one virtual CPU prevents scheduler timing from becoming an
# uncontrolled input; multicore behavior belongs in a dedicated runtime gate.
QUALIFICATION_VCPUS = 1

# Exact init entries allowed in a release image. The package-stage contract
# checks their source inventory; the QEMU assertion below proves that image
# assembly did not add or omit an entry. None is a remote-login service.
RELEASE_INIT_SERVICES = (
    "00_base.target",
    "00_fbcond.service",
    "00_ipcd.service",
    "00_pcid-spawner.service",
    "00_ptyd.service",
    "00_sudo.service",
    "00_tmp",
    "10_dhcpd.service",
    "10_net.target",
    "10_smolnetd.service",
    "20_audiod.service",
    "30_console",
)


def release_version() -> str:
    for line in (REPOSITORY_ROOT / "versions.env").read_text().splitlines():
        if line.startswith("FLASHOS_RELEASE_VERSION="):
            return line.split("=", 1)[1]
    raise SystemExit("qemu smoke: FLASHOS_RELEASE_VERSION is missing")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--qemu", default="qemu-system-x86_64")
    parser.add_argument("--ovmf", type=Path)
    parser.add_argument("--log", type=Path, default=Path("qemu-smoke.log"))
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument(
        "--automation-runtime",
        type=Path,
        default=DEFAULT_AUTOMATION_RUNTIME,
        help="Flash 1.0 runtime for versioned automation JSON boundaries",
    )
    parser.add_argument(
        "--fixtures",
        type=Path,
        default=FIXTURE_PATH,
        help="Versioned FlashOS runtime fixture suite",
    )
    parser.add_argument(
        "--target-matrix",
        type=Path,
        default=MATRIX_PATH,
        help="Versioned exhaustive FlashOS target-capability matrix",
    )
    parser.add_argument(
        "--disk-interface",
        choices=("nvme", "usb"),
        default="nvme",
        help="Expose the image as an NVMe disk or USB mass-storage device",
    )
    parser.add_argument(
        "--expect-root-locked",
        action="store_true",
        help="Assert that the root account rejects a login attempt",
    )
    parser.add_argument(
        "--expect-passwordless-user",
        action="store_true",
        help="Assert that the ordinary user logs in without a password prompt",
    )
    parser.add_argument(
        "--expect-release-services",
        action="store_true",
        help="Assert the exact reviewed release init-service inventory",
    )
    parser.add_argument(
        "--benchmark-output",
        type=Path,
        help="Retain bounded target performance observations as JSON",
    )
    return parser.parse_args()


def resolve_ovmf(explicit: Path | None) -> Path:
    candidates = [explicit] if explicit else [Path(path) for path in DEFAULT_OVMF_PATHS]
    for candidate in candidates:
        if candidate and candidate.is_file():
            return candidate.resolve()
    raise SystemExit("qemu smoke: no OVMF/edk2 x86_64 firmware found")


def load_flash_boundary(
    runtime: Path,
    script: str,
    arguments: list[str],
    *,
    kind: str,
) -> dict[str, object]:
    process = subprocess.run(
        [str(runtime), str(REPOSITORY_ROOT / script), *arguments],
        cwd=REPOSITORY_ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if process.returncode != 0:
        details = process.stderr.strip() or process.stdout.strip()
        raise SystemExit(f"qemu smoke: invalid {kind}: {details}")
    try:
        document = json.loads(process.stdout)
    except json.JSONDecodeError as error:
        message = f"qemu smoke: invalid {kind} JSON boundary: {error}"
        raise SystemExit(message) from error
    if (
        not isinstance(document, dict)
        or document.get("boundary_schema") != 1
        or document.get("kind") != kind
    ):
        raise SystemExit(f"qemu smoke: invalid {kind} identity")
    return document


def boundary_bytes(payload: object) -> bytes:
    if not isinstance(payload, dict):
        raise SystemExit("qemu smoke: invalid encoded byte boundary")
    if payload.get("encoding") == "utf8" and isinstance(payload.get("text"), str):
        return payload["text"].encode()
    if payload.get("encoding") == "hex" and isinstance(payload.get("data"), str):
        try:
            return bytes.fromhex(payload["data"])
        except ValueError as error:
            raise SystemExit("qemu smoke: invalid hexadecimal byte boundary") from error
    raise SystemExit("qemu smoke: invalid encoded byte boundary")


def load_fixture_suite(path: Path) -> SimpleNamespace:
    runtime = args.automation_runtime.resolve()
    document = load_flash_boundary(
        runtime,
        "ci/flashos_runtime_fixtures.fsh",
        ["--fixtures", str(path), "--output", "json-v1"],
        kind="flashos-runtime-fixtures",
    )
    fixtures = []
    for fixture in document["fixtures"]:
        steps = []
        for step in fixture["steps"]:
            expected = step["expected"]
            steps.append(
                SimpleNamespace(
                    payload=boundary_bytes(step["payload"]),
                    rendered=boundary_bytes(step["rendered"]),
                    expected=None if expected is None else boundary_bytes(expected),
                    manual=step["manual"],
                )
            )
        fixtures.append(
            SimpleNamespace(
                identifier=fixture["id"],
                capabilities=tuple(fixture["capabilities"]),
                steps=tuple(steps),
                rejected=tuple(boundary_bytes(item) for item in fixture["rejected"]),
            )
        )
    return SimpleNamespace(
        suite_version=document["suite_version"],
        prompt=boundary_bytes(document["prompt"]),
        terminator=boundary_bytes(document["terminator"]),
        max_interaction_bytes=document["max_interaction_bytes"],
        fixtures=tuple(fixtures),
    )


def load_target_matrix(path: Path) -> SimpleNamespace:
    runtime = args.automation_runtime.resolve()
    document = load_flash_boundary(
        runtime,
        "ci/flashos_target_matrix.fsh",
        ["--matrix", str(path), "--output", "json-v1"],
        kind="flashos-target-matrix",
    )
    cases = []
    for selected_case in document["cases"]:
        steps = []
        for step in selected_case["steps"]:
            rendered = step["rendered"]
            steps.append(
                SimpleNamespace(
                    payload=boundary_bytes(step["payload"]),
                    send=step["send"],
                    rendered=None if rendered is None else boundary_bytes(rendered),
                    expected=tuple(boundary_bytes(item) for item in step["expected"]),
                    manual=step["manual"],
                )
            )
        cases.append(
            SimpleNamespace(
                identifier=selected_case["id"],
                surfaces=tuple(selected_case["surfaces"]),
                capabilities=tuple(selected_case["capabilities"]),
                operation_ids=tuple(selected_case["operation_ids"]),
                steps=tuple(steps),
                rejected=tuple(
                    boundary_bytes(item) for item in selected_case["rejected"]
                ),
            )
        )
    prompts = document["prompts"]
    return SimpleNamespace(
        matrix_version=document["matrix_version"],
        primary_prompt=boundary_bytes(prompts["primary"]),
        continuation_prompt=boundary_bytes(prompts["continuation"]),
        configured_prompt=boundary_bytes(prompts["configured"]),
        terminator=boundary_bytes(document["terminator"]),
        max_interaction_bytes=document["max_interaction_bytes"],
        script_transport_chunk_bytes=document["script_transport_chunk_bytes"],
        cases=tuple(cases),
    )


def script_transport_chunks(source: bytes, limit: int) -> tuple[bytes, ...]:
    if limit < 1:
        raise SystemExit("qemu smoke: target matrix has an invalid chunk boundary")
    return tuple(
        source[offset : offset + limit] for offset in range(0, len(source), limit)
    )


def summarize_samples(values: list[int]) -> dict[str, int]:
    if not values or any(not isinstance(value, int) or value <= 0 for value in values):
        raise RuntimeError("benchmark samples must be positive integers")
    ordered = sorted(values)
    length = len(ordered)
    median = (
        ordered[length // 2]
        if length % 2
        else (ordered[length // 2 - 1] + ordered[length // 2]) // 2
    )
    p95_index = max(1, (length * 95 + 99) // 100) - 1
    return {
        "minimum": ordered[0],
        "median": median,
        "p95": ordered[min(p95_index, length - 1)],
        "maximum": ordered[-1],
    }


def validate_benchmark_result(runtime: Path, path: Path) -> None:
    process = subprocess.run(
        [
            str(runtime),
            str(REPOSITORY_ROOT / "ci/flash_benchmarks.fsh"),
            "--result",
            str(path),
            "--evaluate",
            str(path),
            "--environment",
            "flashos-qemu-tcg-core2duo",
        ],
        cwd=REPOSITORY_ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if process.returncode != 0:
        details = process.stderr.strip() or process.stdout.strip()
        raise SystemExit(f"qemu smoke: invalid target benchmark result: {details}")


args = parse_args()
automation_runtime = args.automation_runtime.resolve()
if not automation_runtime.is_file():
    raise SystemExit(f"qemu smoke: automation runtime not found: {automation_runtime}")
runtime_suite = load_fixture_suite(args.fixtures)
target_matrix = load_target_matrix(args.target_matrix)
benchmark_contract = (
    load_flash_boundary(
        automation_runtime,
        "ci/flash_benchmarks.fsh",
        ["--contract-json-v1"],
        kind="flash-benchmark-contract",
    )
    if args.benchmark_output is not None
    else None
)
benchmark_started_utc = (
    time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if benchmark_contract is not None
    else None
)
benchmark_profile = (
    benchmark_contract["qualification_profile"]
    if benchmark_contract is not None
    else {}
)
benchmark_warmups = int(benchmark_profile.get("target_warmups", 0))
benchmark_samples = int(benchmark_profile.get("target_samples", 0))
benchmark_pipeline_bytes = int(benchmark_profile.get("target_pipeline_bytes", 0))
version = release_version()
image = args.image.resolve()
if not image.is_file():
    raise SystemExit(f"qemu smoke: image not found: {image}")

ovmf = resolve_ovmf(args.ovmf)
args.log.parent.mkdir(parents=True, exist_ok=True)

command = [
    args.qemu,
    "-name",
    "FlashOS x86_64 CI",
    "-machine",
    "q35,accel=tcg",
    "-cpu",
    "core2duo",
    "-smp",
    str(QUALIFICATION_VCPUS),
    "-m",
    "1024",
    "-drive",
    f"if=pflash,format=raw,unit=0,file={ovmf},readonly=on",
]

command.extend(["-drive", f"file={image},format=raw,if=none,id=drv0,snapshot=on"])
if args.disk_interface == "nvme":
    command.extend(["-device", "nvme,drive=drv0,serial=NVME_SERIAL"])

command.extend(["-device", "qemu-xhci,id=xhci"])
if args.disk_interface == "usb":
    command.extend(["-device", "usb-storage,drive=drv0,bus=xhci.0"])

command.extend(
    [
        "-device",
        "usb-kbd,bus=xhci.0",
        "-audiodev",
        "none,id=audio0",
        "-device",
        "ich9-intel-hda",
        "-device",
        "hda-output,audiodev=audio0",
        "-device",
        "e1000,netdev=net0,id=nic0",
        "-netdev",
        "user,id=net0",
        "-vga",
        "std",
        "-display",
        "none",
        "-chardev",
        "stdio,id=debug,signal=off,mux=on",
        "-serial",
        "chardev:debug",
        "-mon",
        "chardev=debug",
    ]
)

process = subprocess.Popen(
    command,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    bufsize=0,
)
assert process.stdin is not None
assert process.stdout is not None

selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
captured = bytearray()
deadline = time.monotonic() + args.timeout
CSI_SEQUENCE = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")


def collect_until(
    marker: bytes,
    start: int = 0,
    *,
    visible: bool = False,
    reject: bytes | None = None,
) -> None:
    def observed() -> bytes:
        transcript = bytes(captured[start:])
        return CSI_SEQUENCE.sub(b"", transcript) if visible else transcript

    while marker not in observed():
        if reject is not None and reject in observed():
            raise RuntimeError(f"observed rejected marker {reject!r} before {marker!r}")
        if process.poll() is not None:
            raise RuntimeError(
                f"QEMU exited with {process.returncode} before {marker!r}"
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {marker!r}")
        for key, _ in selector.select(min(1.0, remaining)):
            chunk = os.read(key.fd, 65536)
            if not chunk:
                continue
            captured.extend(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()


def send(data: bytes) -> None:
    process.stdin.write(data)
    process.stdin.flush()


EDITOR_INTERACTION_LIMIT = runtime_suite.max_interaction_bytes
EDITOR_INTERACTION_SETTLE = 0.05
SCRIPT_TRANSPORT_SETTLE = 0.05


def send_editor_input(
    payload: bytes,
    terminator: bytes,
) -> None:
    """Queue one UART-FIFO-bounded interaction in the guest terminal.

    The portable editor drains one ready terminal chunk into its internal byte
    queue. The emulated 16550 receiver holds sixteen bytes, so keeping every
    complete interaction within that boundary proves the target path without
    depending on another notification within the batch.
    """
    interaction = payload + terminator
    if len(interaction) > EDITOR_INTERACTION_LIMIT:
        raise ValueError("editor interaction exceeds the emulated UART FIFO")
    time.sleep(EDITOR_INTERACTION_SETTLE)
    send(interaction)


# How long the interactive assertions may take once the image has booted. Kept
# separate from the boot budget so a slow boot and a failing assertion cannot
# produce the same diagnostic.
INTERACTIVE_TIMEOUT = 180
TARGET_MATRIX_TIMEOUT = 900


def submit_line(
    payload: bytes,
    row: bytes,
) -> int:
    """Submit `payload` and return its scoped transcript offset.

    Each row uses one bounded UART batch because the target serial path does
    not guarantee a second readiness notification within one interaction.
    """
    if len(payload + runtime_suite.terminator) > EDITOR_INTERACTION_LIMIT:
        raise ValueError("editor interaction exceeds the emulated UART FIFO")
    row_start = len(captured)
    send_editor_input(payload, runtime_suite.terminator)
    # Highlighting may insert CSI style sequences within the visible row. Match
    # its terminal text so the assertion still proves the completed edit.
    collect_until(row, row_start, visible=True)
    return row_start


def materialize_matrix_script(source: bytes) -> None:
    """Stream exact source into a bounded foreground reader that creates `m`."""
    command = f"^head -c{len(source)}>m".encode()
    interaction = command + target_matrix.terminator
    if len(interaction) > target_matrix.max_interaction_bytes:
        raise ValueError("target matrix script reader exceeds the UART boundary")
    submit_line(command, target_matrix.primary_prompt + command)
    for chunk in script_transport_chunks(
        source, target_matrix.script_transport_chunk_bytes
    ):
        if len(chunk) > target_matrix.max_interaction_bytes:
            raise ValueError("target matrix script chunk exceeds the UART boundary")
        time.sleep(SCRIPT_TRANSPORT_SETTLE)
        send(chunk)


def collect_matrix_expectations(step, start: int) -> None:
    for expected in step.expected:
        if expected in {
            target_matrix.primary_prompt,
            target_matrix.continuation_prompt,
            target_matrix.configured_prompt,
        }:
            # The target console can defer a completed prompt until the next
            # input arrives. The following rendered row proves that transition;
            # all non-prompt observations remain scoped to this step.
            continue
        collect_until(expected, start, visible=True)


def confirm_preceding_command() -> None:
    """Prove the previously submitted guest command has completed."""
    # The printable confirmation is encoded in the command, so observing Q
    # cannot be satisfied by the editor's echoed input.
    confirmation = b"^printf '\\121'"
    observation_start = submit_line(
        confirmation, target_matrix.primary_prompt + confirmation
    )
    collect_until(b"Q", observation_start, visible=True)


def inspect_release_services() -> None:
    """Prove the assembled image contains only the reviewed init entries."""
    # `ls` writes to a pipe, so it cannot select terminal colour implicitly.
    # Enter the command in the same bounded chunks as the target matrix rather
    # than weakening the proven UART interaction limit for this inspection.
    command = b"^ls -1A /usr/lib/init.d|^sha256sum"
    observation_start = len(captured)
    for offset in range(0, len(command), EDITOR_INTERACTION_LIMIT):
        send_editor_input(
            command[offset : offset + EDITOR_INTERACTION_LIMIT], b""
        )
    time.sleep(EDITOR_INTERACTION_SETTLE)
    send(runtime_suite.terminator)
    inventory = ("\n".join(RELEASE_INIT_SERVICES) + "\n").encode()
    expected_digest = hashlib.sha256(inventory).hexdigest().encode()
    collect_until(expected_digest, observation_start, visible=True)


def materialize_named_script(source: bytes, short_name: bytes) -> None:
    """Create one short-lived executable source fixture in the guest home."""
    materialize_matrix_script(source)
    time.sleep(SCRIPT_TRANSPORT_SETTLE)
    command = b"^cp m " + short_name
    submit_line(command, target_matrix.primary_prompt + command)
    confirm_preceding_command()


def exercise_public_automation() -> None:
    """Run the exact migrated sources through the target fsh and fake tools."""
    auto_test, acid_runner, relibc_runner, os_runner = (
        path.read_bytes() for path in PUBLIC_AUTOMATION_ROOTS
    )
    cargo_probe = b"""#!/usr/bin/fsh
echo AUTOMATION-CARGO
exit 7
"""
    make_probe = b"""#!/usr/bin/fsh
if $args[0] == "run" {
    echo AUTOMATION-RELIBC
} else {
    echo AUTOMATION-OS
}
exit 9
"""
    materialize_named_script(acid_runner, b"a")
    materialize_named_script(relibc_runner, b"r")
    materialize_named_script(os_runner, b"o")
    materialize_named_script(cargo_probe, b"c")
    materialize_named_script(make_probe, b"k")

    setup = b"""#!/usr/bin/fsh
^mkdir -p /home/user/acid /home/user/relibc-tests /home/user/os-test | check
^cp a acid-runner | check
^cp r relibc-tests-runner | check
^cp o os-test-runner | check
^cp c cargo | check
^cp k make | check
^chmod +x acid-runner relibc-tests-runner os-test-runner cargo make | check
echo AUTOMATION-READY
"""
    materialize_matrix_script(setup)
    command = b"^fsh m"
    setup_start = submit_line(command, target_matrix.primary_prompt + command)
    collect_until(b"AUTOMATION-READY", setup_start, visible=True)

    materialize_named_script(auto_test, b"t")
    wrapper = b"""#!/usr/bin/fsh
export PATH = "/home/user:/usr/bin"
^fsh t || echo AUTOMATION-DONE
"""
    materialize_matrix_script(wrapper)
    time.sleep(SCRIPT_TRANSPORT_SETTLE)
    confirm_preceding_command()
    command = b"^fsh m"
    run_start = submit_line(command, target_matrix.primary_prompt + command)
    markers = (
        b"AUTOMATION-CARGO",
        b"AUTOMATION-RELIBC",
        b"AUTOMATION-OS",
        b"AUTOMATION-DONE",
    )
    for marker in markers:
        collect_until(marker, run_start, visible=True)
    transcript = CSI_SEQUENCE.sub(b"", bytes(captured[run_start:]))
    offsets = [transcript.find(b"\n" + marker + b"\r") for marker in markers]
    if offsets != sorted(offsets) or any(offset < 0 for offset in offsets):
        raise RuntimeError(
            "FlashOS public automation did not preserve target execution order"
        )


def exercise_system_api() -> None:
    """Qualify the installed transport and exact static Flash integration."""
    source = b"""#!/usr/bin/env fsh
import { system_description_from_envelope } from '/usr/share/flashos/flash/system.fsh'

def qualify_system_description(outcome: Record) -> Record {
    if !$outcome.ok || $outcome.error != null {
        throw 'FlashOS system API outcome is not successful'
    }
    if $outcome.result.action != 'system.describe' {
        throw 'FlashOS system API action differs'
    }
    if $outcome.result.system.name != 'FlashOS' {
        throw 'FlashOS system API product name differs'
    }
    if $outcome.result.system.release != '@VERSION@' {
        throw 'FlashOS system API release differs'
    }
    if $outcome.result.system.architecture != 'x86_64' {
        throw 'FlashOS system API architecture differs'
    }
    return $outcome
}

^flashos-system describe --schema 1 --format json \
| from json \
| each {|envelope| system_description_from_envelope($envelope)} \
| each {|outcome| qualify_system_description($outcome)} \
| to json \
| ^cat

let api_status = $status
if !$api_status.ok || !$api_status.stages[0].ok {
    throw 'FlashOS system API transport failed'
}
^printf '%s\n' FLASHOS-SYSTEM-API-OK
""".replace(b"@VERSION@", version.encode())
    materialize_matrix_script(source)
    command = b"^fsh m"
    observation_start = submit_line(command, target_matrix.primary_prompt + command)
    collect_until(b"FLASHOS-SYSTEM-API-OK", observation_start, visible=True)
    transcript = CSI_SEQUENCE.sub(b"", bytes(captured[observation_start:]))
    required = (
        b'"ok":true',
        b'"action":"system.describe"',
        b'"name":"FlashOS"',
        f'"release":"{version}"'.encode(),
        b'"architecture":"x86_64"',
    )
    for marker in required:
        if marker not in transcript:
            raise RuntimeError(f"FlashOS system API output omitted {marker!r}")
    if b'"error":null' not in transcript or b'"ok":false' in transcript:
        raise RuntimeError("FlashOS system API output did not remain a success outcome")


failure: BaseException | None = None
benchmark_measurements: list[dict[str, object]] = []
try:
    collect_until(b"FlashOS Bootloader")
    collect_until(b"Arrow keys and enter select mode")
    send(b"\r")
    collect_until(b"FlashOS starting")
    collect_until(b"Starting framebuffer debug")
    collect_until(b'pcid-spawner: spawn "/usr/lib/drivers/ihdad"')
    banner_start = len(captured)
    collect_until(b"username:", banner_start)
    banner = bytes(captured[banner_start:])
    expected_banner = f"FlashOS {version}".encode()
    if expected_banner not in banner:
        raise RuntimeError(f"login banner does not contain {expected_banner!r}")
    for forbidden_banner in (
        b"Redox OS distribution",
        b"Welcome to Redox OS",
        b"redox login:",
    ):
        if forbidden_banner in banner:
            raise RuntimeError(
                f"login banner contains inherited identity {forbidden_banner!r}"
            )

    # Boot is done. Re-arm the deadline so authentication and interactive
    # assertions get their own budget. The commands below exercise the selected
    # FlashOS adapter from its target-only editor through internal, external,
    # script, pipeline, and job-control paths.
    deadline = time.monotonic() + INTERACTIVE_TIMEOUT

    if args.expect_root_locked:
        # Only the release profile locks root. Test that policy before the
        # ordinary user session so it is independent of later editor behavior.
        attempt_start = len(captured)
        send(b"root\r")
        collect_until(b"assword", attempt_start)
        rejected_start = len(captured)
        send(b"password\r")
        collect_until(b"username:", rejected_start)
    login_start = len(captured)
    send(b"user\r")
    if args.expect_passwordless_user:
        collect_until(b"Login successful!", login_start, reject=b"password:")
        if b"password:" in bytes(captured[login_start:]):
            raise RuntimeError("passwordless user login requested a password")
    else:
        collect_until(b"password:", login_start)
        send(b"user\r")
    collect_until(b"Login successful!", login_start)
    first_prompt_started = time.perf_counter_ns()
    collect_until(runtime_suite.prompt, login_start)
    first_prompt_elapsed = time.perf_counter_ns() - first_prompt_started

    # The same ordered, versioned suite is suitable for the automated QEMU
    # consumer and for manually observed real systems. Keeping the commands and
    # expected markers outside this transport harness prevents those two
    # evidence paths from drifting. The current suite remains deliberately
    # bounded; the exhaustive target matrix is a separate qualification gate.
    for fixture in runtime_suite.fixtures:
        fixture_start = len(captured)
        for step in fixture.steps:
            step_start = submit_line(step.payload, step.rendered)
            if step.expected is not None:
                collect_until(step.expected, step_start)
        fixture_transcript = bytes(captured[fixture_start:])
        for rejected in fixture.rejected:
            if rejected in fixture_transcript:
                raise RuntimeError(
                    f"FlashOS runtime fixture {fixture.identifier!r} "
                    f"observed rejected marker {rejected!r}"
                )

    # The exhaustive matrix deliberately follows the bounded fixtures. It
    # qualifies every advertised capability and required target surface while
    # retaining Signals as a separately withheld group. Long source cases are
    # materialized through bounded commands; live editor interactions remain
    # within the same proven UART boundary as the smoke fixtures.
    deadline = time.monotonic() + TARGET_MATRIX_TIMEOUT
    for case in target_matrix.cases:
        case_start = len(captured)
        for step in case.steps:
            if step.send == "line":
                assert step.rendered is not None
                observation_start = submit_line(step.payload, step.rendered)
                collect_matrix_expectations(step, observation_start)
            elif step.send == "script":
                materialize_matrix_script(step.payload)
                command = b"^fsh m"
                observation_start = submit_line(
                    command, target_matrix.primary_prompt + command
                )
                collect_matrix_expectations(step, observation_start)
            else:
                observation_start = len(captured)
                send_editor_input(step.payload, b"")
                if step.rendered is not None:
                    collect_until(step.rendered, observation_start, visible=True)
                collect_matrix_expectations(step, observation_start)
        case_transcript = bytes(captured[case_start:])
        for rejected in case.rejected:
            if rejected in case_transcript:
                raise RuntimeError(
                    f"FlashOS target matrix case {case.identifier!r} "
                    f"observed rejected marker {rejected!r}"
                )

    exercise_public_automation()
    exercise_system_api()

    if args.benchmark_output is not None:
        benchmark_measurements.append(
            {
                "case_id": "flashos-first-prompt-cold",
                "unit": "ns",
                "warmup_samples": [],
                "samples": [first_prompt_elapsed],
                "summary": summarize_samples([first_prompt_elapsed]),
            }
        )

        def timed_line(payload: bytes, marker: bytes) -> int:
            if len(payload + runtime_suite.terminator) > EDITOR_INTERACTION_LIMIT:
                raise ValueError("timed command exceeds the UART interaction boundary")
            time.sleep(EDITOR_INTERACTION_SETTLE)
            start = len(captured)
            started = time.perf_counter_ns()
            send(payload + runtime_suite.terminator)
            collect_until(marker, start, visible=True)
            return time.perf_counter_ns() - started

        command_probe = b"^printf '\\120'"
        command_warmups = [
            timed_line(command_probe, b"P") for _ in range(benchmark_warmups)
        ]
        command_samples = [
            timed_line(command_probe, b"P") for _ in range(benchmark_samples)
        ]
        benchmark_measurements.append(
            {
                "case_id": "flashos-command-latency-warm",
                "unit": "ns",
                "warmup_samples": command_warmups,
                "samples": command_samples,
                "summary": summarize_samples(command_samples),
            }
        )

        pipeline = (
            f"^yes|^head -c{benchmark_pipeline_bytes}|^wc -c|^tr 0-9 A-J".encode()
        )
        pipeline_marker = (
            str(benchmark_pipeline_bytes)
            .translate(str.maketrans("0123456789", "ABCDEFGHIJ"))
            .encode()
        )

        def timed_pipeline() -> int:
            for offset in range(0, len(pipeline), EDITOR_INTERACTION_LIMIT):
                send_editor_input(
                    pipeline[offset : offset + EDITOR_INTERACTION_LIMIT], b""
                )
            time.sleep(EDITOR_INTERACTION_SETTLE)
            start = len(captured)
            started = time.perf_counter_ns()
            send(runtime_suite.terminator)
            collect_until(pipeline_marker, start, visible=True)
            elapsed = time.perf_counter_ns() - started
            return benchmark_pipeline_bytes * 1_000_000_000 // elapsed

        pipeline_warmups = [timed_pipeline() for _ in range(benchmark_warmups)]
        pipeline_samples = [timed_pipeline() for _ in range(benchmark_samples)]
        benchmark_measurements.append(
            {
                "case_id": "flashos-pipeline-throughput-warm",
                "unit": "bytes/second",
                "warmup_samples": pipeline_warmups,
                "samples": pipeline_samples,
                "summary": summarize_samples(pipeline_samples),
            }
        )

        def timed_completion() -> int:
            row_start = len(captured)
            send_editor_input(b"pw", b"")
            collect_until(runtime_suite.prompt + b"pw", row_start, visible=True)
            time.sleep(EDITOR_INTERACTION_SETTLE)
            started = time.perf_counter_ns()
            send(b"\t")
            collect_until(runtime_suite.prompt + b"pwd ", row_start, visible=True)
            elapsed = time.perf_counter_ns() - started
            reset_start = len(captured)
            send_editor_input(b"\x03", b"")
            collect_until(runtime_suite.prompt, reset_start, visible=True)
            return elapsed

        completion_warmups = [timed_completion() for _ in range(benchmark_warmups)]
        completion_samples = [timed_completion() for _ in range(benchmark_samples)]
        benchmark_measurements.append(
            {
                "case_id": "flashos-completion-latency-warm",
                "unit": "ns",
                "warmup_samples": completion_warmups,
                "samples": completion_samples,
                "summary": summarize_samples(completion_samples),
            }
        )

    # Run this after the behavioral suites: the external pipeline used for the
    # inventory digest advances Flash's job counter, which is itself covered by
    # the versioned runtime fixtures above.
    if args.expect_release_services:
        inspect_release_services()
except BaseException as error:
    failure = error
finally:
    args.log.write_bytes(captured)
    if process.poll() is None:
        try:
            send(b"\x01x")
            process.wait(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

if failure is not None:
    print(f"\nqemu smoke: FAILED: {failure}", file=sys.stderr)
    raise SystemExit(1)

if args.benchmark_output is not None:
    args.benchmark_output.parent.mkdir(parents=True, exist_ok=True)
    result = {
        "schema": benchmark_contract["result_schema"],
        "suite_version": benchmark_contract["suite_version"],
        "profile": "qualification",
        "started_utc": benchmark_started_utc,
        "finished_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "contract_sha256": benchmark_contract["contract_sha256"],
        "image_sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
        "environment": {
            "kind": "flashos-qemu-tcg",
            "qemu": subprocess.check_output(
                [args.qemu, "--version"], text=True
            ).splitlines()[0],
            "machine": "q35",
            "cpu": "core2duo",
            "vcpus": QUALIFICATION_VCPUS,
            "memory_mib": 1024,
            "disk_interface": args.disk_interface,
        },
        "noise_controls": {
            "acceleration": "tcg",
            "fixed_vcpus": True,
            "snapshot_disk": True,
            "measurement_clock": "host monotonic",
            "uart_settle_excluded": True,
            "sample_order": "surface-grouped; warmup discarded",
        },
        "parameters": {
            "warmups": benchmark_warmups,
            "samples": benchmark_samples,
            "pipeline_bytes": benchmark_pipeline_bytes,
        },
        "measurements": benchmark_measurements,
    }
    args.benchmark_output.write_text(json.dumps(result, indent=2) + "\n")
    validate_benchmark_result(automation_runtime, args.benchmark_output)
    print(f"target benchmark result: {args.benchmark_output}")

print("\nqemu smoke: ok")
verified = [
    "FlashOS identity",
    "TUI login",
    "Flash internal command",
    "Flash target runtime",
    "non-interactive Flash script",
    "experimental FlashOS system API",
    "external pipeline",
    "structured directory command",
    "foreground and background job execution",
    "IHDA audio driver",
    "interactive editing",
    f"runtime fixtures v{runtime_suite.suite_version}",
    f"target capability matrix v{target_matrix.matrix_version}",
]
if args.expect_root_locked:
    verified.append("locked root account")
if args.expect_passwordless_user:
    verified.append("passwordless user account")
if args.expect_release_services:
    verified.append("reviewed release service inventory")
print(f"verified: {', '.join(verified)}")
