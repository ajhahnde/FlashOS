#!/usr/bin/env python3
"""Validate the recorded FlashOS toolchain and target ABI baseline."""

from __future__ import annotations

import argparse
import json
import struct
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
BASELINE_PATH = ROOT / "components/flash/platforms/flashos-x86_64.toml"
TARGET = "x86_64-unknown-redox"
FLASH_TARGET = ROOT / f"recipes/terminal/flash/target/{TARGET}"
RELIBC_TARGET = ROOT / f"recipes/core/relibc/target/{TARGET}"


def fail(message: str) -> NoReturn:
    print(f"FlashOS platform baseline: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_toml(path: Path) -> dict:
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"cannot read {path.relative_to(ROOT)}: {error}")


def require_equal(actual: object, expected: object, field: str) -> None:
    if actual != expected:
        fail(f"{field} is {actual!r}, expected {expected!r}")


def require_table(document: dict, name: str) -> dict:
    value = document.get(name)
    if not isinstance(value, dict):
        fail(f"{name} must be a table")
    return value


def validate_source_contract(baseline: dict) -> None:
    require_equal(baseline.get("schema_version"), 2, "schema_version")
    require_equal(baseline.get("platform"), "flashos", "platform")
    require_equal(baseline.get("architecture"), "x86_64", "architecture")
    require_equal(
        baseline.get("image_profiles"),
        ["flashos", "flashos-release"],
        "image_profiles",
    )

    target = require_table(baseline, "target")
    require_equal(target.get("triple"), TARGET, "target.triple")

    config_source = (ROOT / "mk/config.mk").read_text()
    if "export TARGET=$(ARCH)-unknown-redox" not in config_source:
        fail("mk/config.mk no longer derives the recorded target triple")

    base = load_toml(ROOT / "config/flashos-base.toml")
    for profile_name in baseline["image_profiles"]:
        profile = load_toml(ROOT / f"config/x86_64/{profile_name}.toml")
        if "flash" not in require_table(profile, "packages"):
            fail(f"the {profile_name} image profile no longer includes Flash")
    if "relibc" not in require_table(base, "packages"):
        fail("the FlashOS base profile no longer includes relibc")

    build = require_table(baseline, "build")
    require_equal(build.get("image_package_rule"), "source", "build.image_package_rule")
    root_toolchain = load_toml(ROOT / "rust-toolchain.toml")
    require_equal(
        require_table(root_toolchain, "toolchain").get("channel"),
        build.get("root_toolchain"),
        "build.root_toolchain",
    )
    container_source = (ROOT / "ci/container/Dockerfile").read_text()
    expected_toolchain = f"ARG RUST_TOOLCHAIN={build.get('root_toolchain')}"
    if expected_toolchain not in container_source:
        fail("the hosted image builder does not use build.root_toolchain")
    if (
        "ENV REPO_BINARY=0" not in container_source
        or "ENV REPO_BINARY=1" in container_source
    ):
        fail("the hosted image container does not default to source packages")

    compiler = require_table(baseline, "compiler")
    rust_recipe = load_toml(ROOT / "recipes/dev/rust/recipe.toml")
    rust_source = require_table(rust_recipe, "source")
    require_equal(rust_source.get("git"), compiler.get("source"), "compiler.source")
    require_equal(
        compiler.get("source_selector_kind"),
        "branch",
        "compiler.source_selector_kind",
    )
    require_equal(
        rust_source.get("branch"),
        compiler.get("source_selector"),
        "compiler.source_selector",
    )
    prefix_source = (ROOT / "mk/prefix.mk").read_text()
    selector_date = str(compiler.get("source_selector", "")).removeprefix("redox-")
    if f"UPSTREAM_RUSTC_VERSION={selector_date}" not in prefix_source:
        fail("mk/prefix.mk does not match compiler.source_selector")

    libc = require_table(baseline, "libc")
    relibc_recipe = load_toml(ROOT / "recipes/core/relibc/recipe.toml")
    relibc_source = require_table(relibc_recipe, "source")
    require_equal(relibc_source.get("git"), libc.get("source"), "libc.source")
    require_equal(
        relibc_source.get("rev"),
        libc.get("configured_revision"),
        "libc.configured_revision",
    )

    ci_source = (ROOT / ".github/workflows/ci.yml").read_text()
    image_source = (ROOT / ".github/workflows/_image.yml").read_text()
    if "python3 ci/check_flashos_platform.py" not in ci_source:
        fail("standard CI does not validate the source platform baseline")
    if "python3 ci/check_flashos_platform.py --artifacts" not in image_source:
        fail("image CI does not validate platform build artifacts")
    if "REPO_BINARY=0" not in image_source or "REPO_BINARY=1" in image_source:
        fail("image CI does not require source packages")


def validate_relibc_package(relibc_stage: dict, libc: dict, target: dict) -> None:
    require_equal(relibc_stage.get("name"), libc.get("name"), "libc.name")
    require_equal(relibc_stage.get("target"), target.get("triple"), "libc target")
    require_equal(
        relibc_stage.get("source_identifier"),
        libc.get("configured_revision"),
        "libc.configured_revision artifact source",
    )
    commit_identifier = relibc_stage.get("commit_identifier")
    if not isinstance(commit_identifier, str) or not commit_identifier:
        fail("libc package has no build-tree commit identifier")


def parse_version_output(output: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in output.splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value
    return fields


def parse_cfg_output(output: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in output.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key] = value.strip('"')
    return fields


def read_rustc_fingerprint(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read compiler fingerprint {path.relative_to(ROOT)}: {error}")

    outputs = document.get("outputs")
    if not isinstance(outputs, dict):
        fail("compiler fingerprint has no outputs table")

    version: dict[str, str] | None = None
    target_cfg: dict[str, str] | None = None
    for result in outputs.values():
        if not isinstance(result, dict) or result.get("success") is not True:
            continue
        output = result.get("stdout")
        if not isinstance(output, str):
            continue
        if "binary: rustc" in output and "release:" in output:
            version = parse_version_output(output)
        cfg = parse_cfg_output(output)
        if cfg.get("target_os") == "redox" and cfg.get("target_arch") == "x86_64":
            target_cfg = cfg

    if version is None:
        fail("compiler fingerprint has no successful rustc version query")
    if target_cfg is None:
        fail("compiler fingerprint has no successful FlashOS target query")
    return version, target_cfg


@dataclass(frozen=True)
class ElfInfo:
    bit_class: int
    endianness: str
    elf_type: int
    machine: int
    interpreter: str | None
    needed: tuple[str, ...]
    soname: str | None
    position_independent: bool


def _cstring(data: bytes, offset: int) -> str:
    end = data.find(b"\0", offset)
    if end < 0:
        fail("ELF string table contains an unterminated string")
    return data[offset:end].decode("utf-8")


def read_elf(path: Path) -> ElfInfo:
    try:
        data = path.read_bytes()
    except OSError as error:
        fail(f"cannot read ELF artifact {path.relative_to(ROOT)}: {error}")
    if len(data) < 64 or data[:4] != b"\x7fELF":
        fail(f"{path.relative_to(ROOT)} is not an ELF artifact")
    if data[4] != 2 or data[5] != 1:
        fail(f"{path.relative_to(ROOT)} is not little-endian ELF64")

    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    elf_type, machine, phoff, phentsize, phnum = (
        header[1],
        header[2],
        header[5],
        header[9],
        header[10],
    )
    if phentsize != 56:
        fail(f"{path.relative_to(ROOT)} has an unsupported program-header size")

    load_segments: list[tuple[int, int, int]] = []
    interpreter: str | None = None
    dynamic: tuple[int, int] | None = None
    for index in range(phnum):
        offset = phoff + index * phentsize
        if offset + phentsize > len(data):
            fail(f"{path.relative_to(ROOT)} has a truncated program-header table")
        p_type, _, p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from(
            "<IIQQQQQQ", data, offset
        )
        if p_type == 1:
            load_segments.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 3:
            interpreter = _cstring(data, p_offset)
        elif p_type == 2:
            dynamic = (p_offset, p_filesz)

    needed_offsets: list[int] = []
    soname_offset: int | None = None
    string_table_address: int | None = None
    flags_1 = 0
    if dynamic is not None:
        dynamic_offset, dynamic_size = dynamic
        for offset in range(dynamic_offset, dynamic_offset + dynamic_size, 16):
            tag, value = struct.unpack_from("<qQ", data, offset)
            if tag == 0:
                break
            if tag == 1:
                needed_offsets.append(value)
            elif tag == 5:
                string_table_address = value
            elif tag == 14:
                soname_offset = value
            elif tag == 0x6FFFFFFB:
                flags_1 = value

    def virtual_to_file(address: int) -> int:
        for virtual, file_offset, file_size in load_segments:
            if virtual <= address < virtual + file_size:
                return file_offset + address - virtual
        fail(f"{path.relative_to(ROOT)} has an unmapped dynamic string table")

    needed: tuple[str, ...] = ()
    soname: str | None = None
    if string_table_address is not None:
        string_table = virtual_to_file(string_table_address)
        needed = tuple(_cstring(data, string_table + value) for value in needed_offsets)
        if soname_offset is not None:
            soname = _cstring(data, string_table + soname_offset)

    return ElfInfo(
        bit_class=64,
        endianness="little",
        elf_type=elf_type,
        machine=machine,
        interpreter=interpreter,
        needed=needed,
        soname=soname,
        position_independent=bool(flags_1 & 0x08000000),
    )


def validate_artifacts(baseline: dict) -> None:
    compiler = require_table(baseline, "compiler")
    target = require_table(baseline, "target")
    version, cfg = read_rustc_fingerprint(
        FLASH_TARGET / "build/target/.rustc_info.json"
    )
    require_equal(version.get("release"), compiler.get("release"), "compiler.release")
    require_equal(version.get("commit-hash"), compiler.get("commit"), "compiler.commit")
    require_equal(
        version.get("LLVM version"),
        compiler.get("llvm_version"),
        "compiler.llvm_version",
    )
    for manifest_key, cfg_key in (
        ("os", "target_os"),
        ("environment", "target_env"),
        ("family", "target_family"),
        ("pointer_width", "target_pointer_width"),
        ("endianness", "target_endian"),
        ("object_format", "target_object_format"),
    ):
        expected = str(target.get(manifest_key))
        require_equal(cfg.get(cfg_key), expected, f"target.{manifest_key}")
    require_equal(
        cfg.get("target_arch"),
        baseline.get("architecture"),
        "architecture",
    )

    libc = require_table(baseline, "libc")
    relibc_stage = load_toml(RELIBC_TARGET / "stage.toml")
    validate_relibc_package(relibc_stage, libc, target)
    executable = require_table(baseline, "executable")
    require_equal(
        executable.get("format"), target.get("object_format"), "executable.format"
    )
    require_equal(
        executable.get("machine"),
        baseline.get("architecture"),
        "executable.machine",
    )
    require_equal(executable.get("type"), "shared-object", "executable.type")
    fsh = read_elf(FLASH_TARGET / "stage/usr/bin/fsh")
    require_equal(fsh.bit_class, executable.get("class"), "executable.class")
    require_equal(fsh.endianness, executable.get("endianness"), "executable.endianness")
    require_equal(fsh.machine, 62, "executable.machine")
    require_equal(fsh.elf_type, 3, "executable.type")
    require_equal(
        fsh.position_independent,
        executable.get("position_independent"),
        "executable.position_independent",
    )
    require_equal(fsh.interpreter, libc.get("dynamic_linker"), "libc.dynamic_linker")
    require_equal(
        sorted(fsh.needed),
        sorted(executable.get("required_libraries", [])),
        "executable.required_libraries",
    )

    libc_elf = read_elf(RELIBC_TARGET / "stage/usr/lib/libc.so")
    require_equal(libc_elf.bit_class, executable.get("class"), "libc ELF class")
    require_equal(libc_elf.machine, 62, "libc ELF machine")
    require_equal(libc_elf.soname, libc.get("soname"), "libc.soname")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifacts",
        action="store_true",
        help="also validate compiler, package, and ELF outputs from an image build",
    )
    args = parser.parse_args()

    baseline = load_toml(BASELINE_PATH)
    validate_source_contract(baseline)
    if args.artifacts:
        validate_artifacts(baseline)
    mode = "source and artifact" if args.artifacts else "source"
    print(f"FlashOS platform baseline: {mode} contract passed for {TARGET}")


if __name__ == "__main__":
    main()
