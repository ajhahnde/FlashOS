# 14. The Native Rust Build Pipeline

`xtask/src/main.rs` defines the command surface; `xtask/src/build.rs` owns the
production graph. Cargo builds Rust crates, Clang assembles retained AArch64
sources, `rust-lld` links, and pinned Rust LLVM tools inspect and convert the
results.

## Production graph

```text
Rust kernel + user crates
          ↓
EL0 build and inspection
          ↓
deterministic shadow + initramfs
          ↓
Clang assembly of retained .S files
          ↓
rust-lld + board linker script
          ↓
kernel8.elf inspection
          ↓
llvm-objcopy → kernel8.img
```

The bare-metal target is fixed as `aarch64-unknown-none-softfloat`. The
repository pin selects Rust and its matching LLVM components.

## Useful commands

```bash
cargo xtask build --board rpi4b
cargo xtask armstub
cargo xtask test
cargo xtask build --board rpi4b --trace
cargo xtask guard --board rpi4b --full
cargo xtask clean
```

`cargo xtask clean` removes both Cargo's `target/` cache and the assembled
`rust-out/` product tree.

## Deterministic initramfs

Every user program is built and inspected before staging. The build generates
the seed shadow database, adds the initramfs subset of checked-in `rootfs/`
data, sorts entries, and encodes a deterministic newc archive. Equivalent
inputs therefore produce the same archive bytes.

## Two-pass symbols

The linked image reserves exactly 128 KiB for `_symbols`. The user-facing
`build` helper:

1. links once;
2. runs `cargo xtask populate-syms --board rpi4b`;
3. rewrites `crates/kernel/generated/symbol_area.S` from pinned `llvm-nm` output;
4. links again;
5. proves the symbol addresses converged.

The fixed-size section prevents population from moving later sections.

## Guarding the toolchain boundary

The full guard builds behind command shims that reject disallowed compilers or
tools, then examines the subprocess trace. The production census independently
checks that the maintained implementation contains zero retired-language
source implementations.

`FLASHOS_CLANG` can select the host Clang explicitly. Other linker, `nm`,
`objcopy`, target, and component choices come from the repository-pinned Rust
toolchain and build driver.

## Board scope

`--board rpi4b` is the supported production target. The retained `virt` inputs
remain useful for archaeology and limited comparison, but are frozen and not
part of the release qualification.

> [!CAUTION]
> Symbol regeneration changes a tracked generated assembly file. It belongs at
> the stage-closing convergence point, not in every incidental documentation or
> source edit.

The final chapter separates what QEMU proves from what only the Pi can prove.
