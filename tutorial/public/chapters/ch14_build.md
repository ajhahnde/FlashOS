# Chapter 14: Native Compilation behind `zig build`

The command surface and the compiler pipeline are two different layers.
Developers invoke `zig build`, and `build.zig` still owns targets, options,
artifact paths, QEMU steps, and deployment. Inside that graph, however,
shipping Flash source is compiled through `flashc`'s native LLVM path. The
generated-Zig compatibility backend is reserved for tests and build tooling;
it is never an input to a kernel, userland, or utility ELF.

## The toolchain pin

`flash-toolchain.lock` names the exact Flash compiler revision the tree uses.
The pin matters because Flash and FlashOS move independently: rebuilding with
an arbitrary compiler checkout could otherwise change native objects without
any source change in this repository.

The setup guide shows how to check out and build that revision. Bumping the
pin is an isolated maintenance operation followed by the full host-test and
boot-watchdog battery; it is never an incidental part of editing a kernel
module.

## Native production units

For a production unit, `build.zig` invokes the compiler's unit-oriented LLVM
emission, lowers that IR to an AArch64 object, and adds the object to the
existing link graph. In outline:

```text
.flash source
    -> flashc native unit / LLVM emission
    -> AArch64 object
    -> build.zig addObjectFile
    -> kernel, userland, or tool ELF
```

Named module mappings preserve the same import graph Flash source uses. A unit
is compiled once for its target and optimization mode, then linked wherever
that artifact belongs. No generated `.zig` source sits between a product
module and its machine code.

The distinction is observable, not just wording: the build's migration gate
rejects compatibility-backend invocations outside the explicitly marked test
helper, and release validation inspects the final ELF inputs.

## Why tests retain a compatibility path

Flash source contains host-side `test` blocks, while the native compiler path
does not yet provide an equivalent test runner. `zig build test` therefore
lowers test roots and their Flash stubs through the Zig compatibility backend,
then runs those temporary test executables on the host.

That is a narrow exception:

- production helpers request native objects;
- the host-test helper alone may request generated Zig;
- in-kernel runtime tests execute inside the natively compiled kernel;
- every maintained product, tool, stub, and generator source remains `.flash`.

The tutorial playground follows the same non-shipping compatibility seam so it
can display readable lowering output in a browser. Passing that check proves a
lab parses and lowers; it does not claim to reproduce the production link.

## What remains outside Flash source

Only formats that serve a different role stay outside the Flash source census:

- **AArch64 assembly and linker scripts** express early boot, exception
  vectors, context switching, and section layout directly.
- **`build.zig` and package metadata** are the host orchestration island. They
  choose what to compile but are not linked into FlashOS.

Kernel modules, userland, host tools, generators, test stubs, and tracing logic
are authored in Flash. Any Zig visible in a test cache is generated output,
not a second maintained implementation.

## The two-pass symbol build

The kernel carries a compact copy of its own symbol table for tracing and
diagnostics. That creates a chicken-and-egg problem: the table needs final
linked addresses, but it must also occupy space in the image whose addresses
are being computed.

The `build` helper from `flashos.zsh` resolves this with two passes:

```text
# pass 1: link against the fixed-size symbol-area placeholder
zig build -Dboard="$BOARD" -Dskip-hygiene=true

# extract addresses and populate src/symbol_area.S
zig build populate-syms -Dboard="$BOARD" -Dskip-hygiene=true

# pass 2: relink with the populated table
zig build -Dboard="$BOARD" -Dskip-hygiene=true

# compare first- and second-pass symbol addresses
diff "$FIRST_PASS" "$SECOND_PASS"
```

Pass one determines every address while reserving the symbol area's full
budget. `populate-syms` converts sorted `nm` output into fixed-size assembly
records. Pass two replaces placeholder bytes with those records without
changing the section size. If another symbol moves, the final diff is nonempty
and the helper fails — the layout did not converge.

The plain `zig build` command is enough for day-to-day compilation. The helper
is the stronger release-style proof because it rebuilds, populates, rebuilds,
and verifies in one operation.

## Validation follows the artifact boundary

The pipeline has three useful proof levels:

1. Compatibility host tests prove pure logic and keep every Flash `test` block
   active.
2. Native compilation and link inspection prove product ELFs contain only
   native Flash objects plus assembly.
3. The QEMU watchdog boots that linked AArch64 artifact and checks the runtime
   contract, including page-accounting invariants and the final shell hand-off.

The last level catches errors that valid object files can still contain: an ABI
mismatch, a bad link address, or a page leak visible only after real
fork/exec/reap cycles.

## What's next

The final chapter moves the same kernel artifact from QEMU to a Raspberry Pi 4:
SD-card deployment, physical serial channels, and the USB-C gadget console.
