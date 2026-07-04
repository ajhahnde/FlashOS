# Chapter 14: The Build Pipeline — flashc → Kernel

This tour has quoted dozens of `.flash` files as though they compiled
straight to AArch64 machine code. With `flashc` — a native LLVM compiler —
that is exactly where they are headed; during the transition, FlashOS's
build still routes every module through flashc's bootstrap backend
(`--backend=zig`), and the ordinary Zig toolchain compiles that output as
it always has. That bootstrap detour is temporary and disappears once the
native-object port completes. This chapter is about the pipeline as it
runs today: where the compile step is wired into the build graph, why the
compiler revision is pinned rather than left floating, and why the kernel
symbol table needs the build to run twice.

## The toolchain pin

`flash-toolchain.lock`, at the repository root, names the exact
`flashc` commit the tree compiles against — not just a version
number, a specific commit hash:

```text
flash-version = 1.0.1
flash-commit  = 89cb2fc43ccfe3a2f912ac86350bad1c53998e0f
flashc-binary = zig-out/bin/flashc
```

*(excerpt from `flash-toolchain.lock`)*

Pinning exists because Flash and FlashOS are two separate, independently
moving repositories: without a pin, a `.flash` module's compiled
output could silently drift every time someone rebuilds `flashc` from
whatever the Flash repo's HEAD happens to be that day. `build.zig`
resolves the compiler binary through a `-Dflashc=<path>` option,
defaulting to `~/Flash/zig-out/bin/flashc` — the pinned commit,
built locally with `zig build`, is expected to live there.
Bumping the pin is a deliberate, isolated step: rebuild, then re-run
both boot watchdogs, never folded into an unrelated change.

## `addFlashSource`: one compile step per module

`build.zig` wires each `.flash` module into the build graph through a
small helper that runs `flashc` as an external command and hands its
output back as a normal Zig module root:

```text
fn addFlashSource(b: *std.Build, src: []const u8) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ flashc_path, "--backend=zig" });
    run.setName(b.fmt("flashc {s}", .{src}));
    run.addFileArg(b.path(src));
    run.addArg("-o");
    const out = run.addOutputFileArg(b.fmt("{s}.zig", .{std.fs.path.stem(src)}));
    run.has_side_effects = true;
    return out;
}
```

*(excerpt from `build.zig` — not standalone-compilable; this is
`build.zig` itself, host-side Zig, one of the pieces that deliberately
stays Zig rather than Flash)*

The explicit `--backend=zig` argument pins the bootstrap mode by name:
since Flash v1.0.1 `flashc`'s default output is a native object, so the
build graph has to ask for the Zig backend explicitly rather than lean
on a default that no longer means what it used to.

Two details matter here. First, the `.flash` file is the only thing
committed — the `.zig` it lowers to lands in Zig's build cache and is
never checked in; if you want to see what a module actually compiles
to, you compile it yourself and read the cache output, the same way
this tour's Lab "Compile" button does. Second, `has_side_effects =
true` forces the step to re-run on every build rather than let Zig's
build cache treat it as a pure function of its declared inputs —
`flashc` is an external binary the cache cannot fingerprint the way it
fingerprints ordinary Zig source, so a stale cached compile step could
otherwise green a boot that no longer matches the `.flash` source it
was supposed to reflect. A sibling helper, `addFlashSourceAbs`,
compiles `.flash` files living outside this repository entirely —
Flash's own `std/` directory (`std/io`, `std/tui`, `std/keys` — the
`core` import chapter 12's `less` and `edit` build on) is referenced
straight from the pinned Flash checkout rather than vendored in, so
that toolchain pin is the one place that surface's source of truth
lives too.

## What stays Zig, and why

Not every source file in the tree carries the `.flash` extension. Boot
assembly and linker scripts (`arch/`, `.ld` files) are outside Flash's
domain by construction — a systems language that compiles down to
machine code has no reason to also reinvent AArch64 assembly. The
kernel's own force-link boot trampoline, `src/start.zig`, hosts the
build's module wiring and stays Zig for the same structural reason.
And, as chapter 11 already noted in passing, a couple of low-level
modules — `src/vfs.zig` among them — lean on a Flash language feature
(non-exhaustive enums) the pinned compiler doesn't lower yet, so they
remain plain Zig, consumed as ordinary named modules the rest of the
build graph is indifferent to. `build.zig` itself, and the host
tooling under `scripts/`, never run on the target board at all and
stay Zig as a matter of course.

## The two-pass build: solving a chicken-and-egg problem

Chapter 7's tracing mention and the debugger-friendly `nm`/`objdump`
output both depend on the kernel image carrying its own symbol table —
but a symbol table can't be computed until the kernel is fully linked,
and the kernel can't be linked with a symbol table that doesn't exist
yet. `build.sh` resolves this with a two-pass build:

```text
echo "link kernel8.elf first pass"
zig build -Dboard="$BOARD"

echo "save first pass symbols"
"$NM_BIN" -n "$KERNEL_ELF" | sort | grep -v '\$' > "$NM_TMPDIR/nmfirstpass"

echo "generate symbol area and overwrite src/symbol_area.S"
zig build populate-syms -Dboard="$BOARD"

echo "compile symbol area and link kernel8.elf second pass"
zig build -Dboard="$BOARD"

echo "save second pass symbols"
"$NM_BIN" -n "$KERNEL_ELF" | sort | grep -v '\$' > "$NM_TMPDIR/nmsecondpass"

echo "show diff of symbols (should be nothing):"
diff "$NM_TMPDIR/nmfirstpass" "$NM_TMPDIR/nmsecondpass"
```

*(excerpt from `build.sh` — not standalone-compilable)*

Pass one links the kernel with a *placeholder* symbol section, sized
large enough to hold the real table but filled with nothing meaningful.
`zig build populate-syms` then runs `nm` against that first-pass ELF,
sorts and filters the output, and feeds it through
`scripts/generate_syms.zig`, which overwrites `src/symbol_area.S` with
the real `.quad`/`.string`/`.space` directives — one 64-byte entry per
symbol. Pass two relinks with that populated table now baked in. The
diff between the two `nm` dumps is the correctness check: inserting the
real symbol data must not have perturbed any other symbol's address, or
something about the placeholder's size assumption was wrong. A clean
diff (nothing printed) is the pass; any output fails the build.

`build.sh` also gates on a pinned Zig version — checked against
`.zigversion` before anything else runs — for the same reproducibility
reason the Flash toolchain is pinned: a kernel and its build tooling
should compile identically on any machine that follows the setup
instructions, not merely on whichever machine happened to build it
last.

## Validating a port, not just a build

The Zig-to-Flash migration this pipeline exists to support followed one
rule throughout: every ported module had to compile cleanly, its
compiler output reviewed line-for-line against the `.zig` original it
was replacing, pass the host unit tests, and pass both boot watchdogs —
all *before* the original `.zig` file was deleted. The free-page
checkpoints this tour's chapter 13 just covered were the byte-level
witness that a port never changed behavior: if a module's compiled
output produced a different checkpoint hex than its hand-written
predecessor, the lowering had drifted from the original, full stop,
regardless of how plausible the diff looked by eye.

## What's next

The last chapter closes the loop this tour opened at power-on: what
changes when the same kernel image runs on a real Raspberry Pi 4
instead of QEMU — the SD card, the serial console, and the USB-C
gadget console that makes a Pi need no adapter cable at all.
