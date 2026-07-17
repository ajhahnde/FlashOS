const std = @import("std");
const builtin = @import("builtin");

// Hard pin: FlashOS uses inline asm, freestanding aarch64, custom linker
// scripts and patchable-function-entry hooks that are sensitive to Zig
// compiler changes. Bumping is a deliberate act — install the new Zig,
// raise REQUIRED_ZIG_VERSION here and `minimum_zig_version` in
// build.zig.zon, fix any breakage, commit. The .zigversion file mirrors
// this for version managers (zigup / zvm / anyzig).
const REQUIRED_ZIG_VERSION = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };

comptime {
    const v = builtin.zig_version;
    const r = REQUIRED_ZIG_VERSION;
    if (v.major != r.major or v.minor != r.minor or v.patch != r.patch) {
        @compileError(std.fmt.comptimePrint(
            "FlashOS requires Zig {d}.{d}.{d} exactly. Found Zig {d}.{d}.{d}. " ++
                "To upgrade: bump REQUIRED_ZIG_VERSION in build.zig and " ++
                "minimum_zig_version in build.zig.zon, then fix breakage.",
            .{ r.major, r.minor, r.patch, v.major, v.minor, v.patch },
        ));
    }
}

// Residual Zig build. The kernel and every EL0 payload are built natively by
// `cargo xtask build` now — the kernel link, the initramfs, and the raw image
// left this file when src/start.zig retired. What stays here is only what has
// no Rust owner yet:
//   * armstub8.bin — the small EL3→EL1 bootstrap shim (rpi4b only), still
//     assembled from armstub/src/armstub8.S.
//   * the host-side unit tests for the surviving Zig/Flash modules, and the
//     whitespace/hex hygiene gate.
// Both retire once the host tooling finishes moving to xtask; until then
// `zig build test` / `zig build armstub` are the only reasons to invoke Zig.

const Board = enum { rpi4b, virt };

// Host-test wiring helper. Covers all three call patterns the suite
// uses (shared-stub leaf, shared-stub + named imports, per-target stub
// + imports) and returns the created test Module so a caller can reuse
// it as a named-import target downstream — e.g. wait_queue's test
// module is also pipe's "wait_queue" import.
const HostTest = struct {
    src: []const u8,
    // When set, the test compiles this generated source instead of b.path(src).
    // Used for Flash-transpiled modules whose .zig lives in the build cache (a
    // composed WriteFiles directory) rather than on disk; `src` stays the
    // human-readable label.
    src_lazy: ?std.Build.LazyPath = null,
    stubs: ?*std.Build.Step.Compile = null,
    extra_stubs: []const *std.Build.Step.Compile = &.{},
    object_files: []const std.Build.LazyPath = &.{},
    imports: []const struct {
        name: []const u8,
        mod: *std.Build.Module,
    } = &.{},
};

// Set from the -Dcoverage option in build(); read by addHostTest below.
var host_tests_use_llvm = false;

// Set from the -Dtest-filter option in build(); read by addHostTest below. When
// non-null, only tests whose name contains this substring run (zig test filter).
var host_test_filter: ?[]const u8 = null;

// Source files of every host test addHostTest wires, in registration order.
// The `test` step's final tally (scripts/test_tally.sh) counts the `test "…"`
// blocks across exactly these files, so the printed pass count is derived from
// the build graph itself and can never drift from the suite. Fixed cap — there
// are ~60 host tests; bump if the suite ever outgrows it.
var host_test_srcs: [256][]const u8 = undefined;
var host_test_n: usize = 0;

fn addHostTest(b: *std.Build, step: *std.Build.Step, cfg: HostTest) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = if (cfg.src_lazy) |lp| lp else b.path(cfg.src),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    if (cfg.stubs) |s| m.addObject(s);
    for (cfg.extra_stubs) |s| m.addObject(s);
    for (cfg.object_files) |object| m.addObjectFile(object);
    for (cfg.imports) |imp| m.addImport(imp.name, imp.mod);
    const t = b.addTest(.{
        .root_module = m,
        .use_llvm = if (host_tests_use_llvm) true else null,
        .filters = if (host_test_filter) |f| &.{f} else &.{},
    });
    step.dependOn(&b.addRunArtifact(t).step);
    host_test_srcs[host_test_n] = cfg.src;
    host_test_n += 1;
    return m;
}

// Set from the -Dflashc option in build(); read by addFlashSource below.
// flashc is a native LLVM compiler; FlashOS consumes its bootstrap
// --backend=zig mode until the native-object port (transitional, deliberate).
var flashc_path: []const u8 = "flashc";

// Flash transpile helper. Registers a flashc run step (Flash -> Zig) and
// returns the generated .zig as a LazyPath usable as a module root. The
// .flash file is the source of truth: the generated Zig lands in the
// build cache and is never committed. The step always re-runs
// (has_side_effects): flashc is an external binary the cache cannot
// fingerprint, so a stale cached output could otherwise green a boot
// that no longer matches its source.
fn addFlashSource(b: *std.Build, src: []const u8) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ flashc_path, "--backend=zig" });
    run.setName(b.fmt("flashc {s}", .{src}));
    run.addFileArg(b.path(src));
    run.addArg("-o");
    const out = run.addOutputFileArg(b.fmt("{s}.zig", .{std.fs.path.stem(src)}));
    run.has_side_effects = true;
    return out;
}

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        // Force +strict-align so LLVM never widens a byte copy or a
        // >16-byte by-value return into a NEON `str q` aimed at an
        // only-8-aligned slot. Those stores fault under SCTLR_EL1.A on real
        // silicon (data abort, DFSC 0x21) while sailing through QEMU's
        // lenient TCG. Covers the kernel and every freestanding EL0 program
        // that shares this target, so the whole class is closed at codegen
        // instead of with per-site `align(16)` / volatile dodges.
        .cpu_features_add = std.Target.aarch64.featureSet(&.{.strict_align}),
    });
    // Default .ReleaseSmall keeps the kernel inside its symbol/image
    // budget, but it also compiles out the integer-overflow and
    // bounds-check traps: a missed overflow becomes silent UB instead of a
    // panic. Deliberate ceiling — arithmetic on untrusted input carries
    // explicit checks at the source (the ELF p_vaddr/p_memsz range+wrap
    // guards in crates/kernel/src/elf.rs, the clusterLba fail-closed guard in
    // src/fat32.zig). Pass -Doptimize=ReleaseSafe to restore the traps.
    const optimize: std.builtin.OptimizeMode = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;
    const board: Board = b.option(
        Board,
        "board",
        "Target board (rpi4b | virt)",
    ) orelse .rpi4b;

    // virt has no driver set in the build graph: its leaves and the comptime
    // alias bag they hung from were cut once the kernel reached its drivers by
    // direct call rather than through a per-board indirection. The sources are
    // still in src/board/virt/ for a later revival. Fail closed and say so --
    // otherwise selecting the board dies on a missing-module error that reads
    // like a broken checkout.
    if (board == .virt) {
        std.debug.print(
            \\-Dboard=virt cannot build: the virt driver leaves are not wired
            \\into this build graph. The sources remain under src/board/virt/.
            \\Build with -Dboard=rpi4b.
            \\
        , .{});
        std.process.exit(1);
    }

    // The kernel and every EL0 payload are built by `cargo xtask build` now;
    // the build_options module and the -Dverbose-fork / -Dci-login-seed /
    // -Dboot-selftest gates that fed the Zig kernel link moved there as cargo
    // features. Only -Dtrace survives here, because the sole remaining Zig
    // artifact — the armstub shim — keys its frame-pointer policy on it.
    const trace = b.option(
        bool,
        "trace",
        "Match the kernel's frame-pointer policy in the armstub shim (kernel tracing itself is a `cargo xtask build --trace` feature now)",
    ) orelse false;

    // Coverage builds force the LLVM backend for host test binaries:
    // zig's self-hosted x86_64 backend (the Debug-mode default on
    // x86_64-linux) emits DWARF that kcov cannot read, so coverage data
    // silently vanishes. Only host test binaries are affected; kernel
    // artifacts never see this option.
    host_tests_use_llvm = b.option(
        bool,
        "coverage",
        "Force the LLVM backend for host test binaries (kcov-readable DWARF)",
    ) orelse false;

    // Substring filter for the host-test step: `zig build test -Dtest-filter=foo`
    // runs only tests whose name contains "foo". Null (default) runs the suite.
    host_test_filter = b.option(
        []const u8,
        "test-filter",
        "Run only host tests whose name contains this substring",
    );

    // Path to the flashc transpiler (Flash -> Zig). Modules ported to
    // Flash (*.flash) transpile at build time via addFlashSource; the
    // pinned compiler revision lives in flash-toolchain.lock. The default
    // expects that checkout at ~/Flash, built with `zig build`.
    flashc_path = b.option(
        []const u8,
        "flashc",
        "Path to the flashc transpiler binary (default: ~/Flash/zig-out/bin/flashc)",
    ) orelse blk: {
        const home = b.graph.environ_map.get("HOME") orelse break :blk "flashc";
        break :blk b.pathJoin(&.{ home, "Flash", "zig-out", "bin", "flashc" });
    };

    // ---- hygiene checks (trailing space, hard tabs, lowercase hex) ----
    const skip_hygiene = b.option(bool, "skip-hygiene", "Skip the hygiene check step") orelse false;
    const hygiene_step = b.step("check-hygiene", "Fail on whitespace or hex-literal regressions");

    if (!skip_hygiene) {
        const whitespace_check = b.addSystemCommand(&.{ "sh", "scripts/check_whitespace_hygiene.sh" });
        hygiene_step.dependOn(&whitespace_check.step);

        const hex_check = b.addSystemCommand(&.{ "sh", "scripts/check_hex_hygiene.sh" });
        hygiene_step.dependOn(&hex_check.step);
    }

    // Shared syscall ID constants — single source of truth for the
    // kernel-side dispatch table (src/sys.zig); the EL0 side now takes them
    // from crates/abi, which pins the same numbers. The Flash syscall-defs
    // module (lib/syscall_defs.flash) was reached only through the kernel-log
    // adapter, which has since moved its storage into Rust; nothing in the
    // kernel link imports these constants any more, so the module is gone. The
    // .flash source stays on disk until the shared source deletion.

    // console_ui — shared terminal look (status tags, ANSI palette, the
    // boot-success marker, and the line/stage/banner renderers). No image
    // consumes this copy any more: the kernel boot log was the last one, and it
    // now renders through crates/console-ui. What remains is the pair the drift
    // gate needs — the transpile that `cargo xtask ui-defs --check` parses to
    // hold the Rust constants byte-identical, and the screen host test below.
    // console_ui is a multi-file Flash module: console_ui.flash re-exports its
    // palette / tags / screen siblings through relative imports. flashc
    // transpiles one file at a time, so compose the generated .zig into a single
    // directory where each `@import("palette.zig")` sibling resolves — the same
    // per-stage WriteFiles composition the Flash toolchain uses for its own
    // std/selfhost modules. lib/console_ui/*.flash is the source of truth.
    const console_ui_dir = b.addWriteFiles();
    const console_ui_files = [_][]const u8{ "palette", "tags", "screen", "console_ui" };
    var console_ui_screen_src: std.Build.LazyPath = undefined;
    for (console_ui_files) |name| {
        const gen = addFlashSource(b, b.fmt("lib/console_ui/{s}.flash", .{name}));
        const dest = console_ui_dir.addCopyFile(gen, b.fmt("{s}.zig", .{name}));
        if (std.mem.eql(u8, name, "screen")) console_ui_screen_src = dest;
    }

    // The user_layout (user-space virtual address layout) and task_layout
    // (TaskStruct/CoreContext extern-struct layouts) Flash modules were reached
    // only through kernel modules that have since left the link; flashos-abi
    // now owns those facts natively for every Rust consumer, and the assembly
    // reads them from the hand-written arch/aarch64/asm_defs_common.inc. Nothing
    // in the kernel root's import graph pulls either module in, so they carried
    // zero symbols and are dropped here; their .flash files stay on disk.

    // The pipe / file / fdtable / vfs Zig adapters were export-less `pub fn`
    // pass-throughs over their Rust owners in crates/kernel; with the last
    // Flash/Zig importer gone, nothing in the kernel root's import graph reached
    // them, so they carried zero symbols into the link and are dropped here.
    // Their .zig files are left on disk for now.

    // The block-device, SDHCI-command and VideoCore-mailbox call-site adapters
    // were export-less forwarders over their Rust owners in crates/kernel. With
    // the last Flash/Zig importer gone (block_dev's was virt EMMC2), nothing in
    // the kernel root's import graph reached them, so they carried zero symbols
    // and are dropped here alongside the other retired adapters. Their .flash
    // files stay on disk until the shared source deletion.

    // USB descriptor adapter. Rust owns the byte-exact descriptor set and
    // SETUP decode; the named module preserves the DWC2 driver's API.

    // Bulk-IN TX ring adapter. Rust owns the bounded ring arithmetic while
    // the DWC2 driver retains preemption policy and MMIO FIFO writes.


    // The kernel-log ring's BSS storage moved into crates/kernel (utilc's
    // device seam owns the static now that every consumer is Rust and the ELF
    // carries no GOT), so the last Flash kernel module and its start.zig
    // force-import are both gone. Its .flash source stays on disk for now.

    // The sha256, shadow and perm call-site adapters were orphaned forwarders
    // over their Rust owners in crates/kernel: the crypto primitives, the
    // /etc/shadow parser + rewrite, and the Unix permission check all live on
    // the Rust side with their tests. Their last syscall-layer consumer ported,
    // so none is imported or linked any more; they are dropped here. The .flash
    // files stay on disk until the shared source deletion.

    // pwfile — /etc/passwd parser. Its Rust owner drives the kernel path now, so
    // the module no longer enters the kernel link; the Flash source is retained
    // only to feed its standalone host test below (retired with the source).
    const pwfile_src = addFlashSource(b, "src/pwfile.flash");


    // The console adapter was another export-less pass-through and is dropped
    // with the pipe/file/fdtable/vfs group above. The scheduler adapter
    // (src/sched.zig) is dropped too: its only live contribution was the
    // cross-language storage `export var current/task/nr_tasks/next_pid`, which
    // moves into crates/kernel/src/sched.rs now that every consumer is Rust and
    // the kernel ELF carries no GOT (so the storage has no low-half relocation
    // hazard). Its zombify-and-wake `pub fn` had no reachable importer. Both
    // .zig files are left on disk for now.

    // The cwd-aware path-resolution adapter was another orphaned forwarder:
    // the pure joinResolve implementation and its tests are Rust-owned in
    // crates/kernel, and its sys_chdir / sys_openFile / execveKernel consumers
    // ported, so nothing imports it any more. Dropped with the group above.

    // Temporary source-level facade used by the still-Flash rpi4b EMMC2 and
    // USB drivers. The VideoCore transaction itself is Rust-owned; this
    // module only forwards their existing method-shaped calls to C symbols.


    // The remaining Flash interrupt controller is virt GICv3. The rpi4b
    // GICv2 path is Rust-owned, and so is the sampler its trace seam feeds.


    if (board == .rpi4b) {
        // ---- armstub (EL3→EL1 shim, separate tiny ELF linked at .text=0) ----
        const armstub_mod = b.createModule(.{
            .root_source_file = b.path("armstub/src/root.zig"), // empty — real code is in armstub8.S
            .target = target,
            .optimize = optimize,
            // Match the kernel's frame-pointer policy under -Dtrace; harmless
            // otherwise (this module is asm-only). null = leave it alone.
            .omit_frame_pointer = if (trace) false else null,
        });
        const armstub = b.addExecutable(.{
            .name = "armstub8.elf",
            .root_module = armstub_mod,
        });
        armstub_mod.addAssemblyFile(b.path("armstub/src/armstub8.S"));
        armstub_mod.addIncludePath(b.path("armstub/src"));
        armstub.setLinkerScript(b.path("armstub/src/linker.ld"));
        armstub.entry = .disabled; // _start defined in armstub8.S
        armstub.link_z_max_page_size = 0x1000;
        armstub.link_gc_sections = false;
        armstub.bundle_compiler_rt = false;

        const objcopy_armstub = b.addSystemCommand(&.{
            "aarch64-elf-objcopy",
        });
        objcopy_armstub.addArtifactArg(armstub);
        objcopy_armstub.addArg("-O");
        objcopy_armstub.addArg("binary");
        const armstub_bin = objcopy_armstub.addOutputFileArg("armstub8.bin");
        const install_armstub_bin = b.addInstallFileWithDir(armstub_bin, .prefix, "armstub8.bin");

        const install_armstub_elf = b.addInstallArtifact(armstub, .{});

        const armstub_step = b.step("armstub", "Build armstub8.bin");
        armstub_step.dependOn(&install_armstub_elf.step);
        armstub_step.dependOn(&install_armstub_bin.step);

        b.default_step.dependOn(armstub_step);
    }

    // ---- clean: blow away cache + outputs. ----
    const clean = b.addSystemCommand(&.{ "sh", "-c", "rm -rf .zig-cache zig-out" });
    const clean_step = b.step("clean", "Remove .zig-cache and zig-out");
    clean_step.dependOn(&clean.step);

    // Host-side unit tests. One test target per surviving Zig module under
    // test; Rust-owned module tests run through `cargo xtask test` above.
    const test_step = b.step("test", "Run host-side unit tests");
    test_step.dependOn(hygiene_step);

    // grep match core — pure windowed substring matcher with ASCII case-fold.
    // No externs, no stubs, no SVC. /bin/grep carries its own matcher now; this one
    // survives for the editor's ctrl-W search and keeps its host coverage until the
    // editor ports.

    // console_ui screen — panel / kv / cursor renderer host coverage. The
    // test blocks live in the Flash source; compile the generated screen.zig
    // from the composed console_ui directory so its sibling import resolves.
    _ = addHostTest(b, test_step, .{ .src = "lib/console_ui/screen.flash", .src_lazy = console_ui_screen_src });

    // flibc gapbuf.zig — pure editing core host coverage (gap insert/delete/
    // moveGap/grow, segment line index, cursor motions, viewport scroll). The
    // interactive loop the editor builds on it lives in tools/edit.flash and is
    // Pi-only (no QEMU stdin), so these host tests are the correctness proof. A
    // standalone module like grep_match — not part of the flibc aggregate, so it
    // adds no footprint to existing boot binaries. The generated source is shared
    // with edit.elf's module (gapbuf_gen, declared at the edit wiring above). No
    // stubs, no imports.

    // virt DTB parser — pure big-endian FDT decode + bounds guards.
    // The handoff entry (`fromHandoff`) reads the `dtb_pa` extern and the
    // linear map, so it stays kernel-only; the tests build a `Dtb` over a
    // hand-written blob and exercise findNode/getProp/findReg/findInterrupt
    // plus the corrupt-length guard. Imports only std → no stubs.
    // src/board/virt/dtb.flash's 4 host tests retired with the virt driver
    // leaves: the parser they cover is not built or run anywhere. Recorded in
    // the port's behaviour manifest; the source is still there to test again if
    // virt is revived.

    // vanilla single-module test targets — shared stubs, no named imports.
    // wait_queue, pipe, console, and fdtable are Rust-owned now; their
    // host coverage moved to the crates/kernel unit suites. Only the Flash
    // modules that still consume them through the thin .zig shims keep host
    // targets here.

    // Scheduler and utility host coverage lives with the Rust implementation.

    // pwfile.zig — /etc/passwd parser host coverage. Pure
    // name/uid lookups shared by sys_passwd (kernel), /bin/login, and
    // fsh's whoami builtin; pins the 5-field format against
    // user_space/etc/passwd.
    _ = addHostTest(b, test_step, .{ .src = "src/pwfile.flash", .src_lazy = pwfile_src });

    // build_initramfs.zig — newc encoder host coverage. Pins the
    // mode/uid/gid byte offsets shared with the kernel parser
    // (src/initramfs.zig); an encoder/parser drift here would be a silent
    // permission bypass.
    _ = addHostTest(b, test_step, .{ .src = "scripts/build_initramfs.zig" });

    // Final pass banner. Zig's build runner is silent on a fully-green test
    // step (counts only surface with `--summary all`), so wire a last system
    // command that depends on every test run added above — it executes only
    // after they all pass — and prints one green "<N> tests passed" line. The
    // file list it counts is host_test_srcs, populated by addHostTest, so the
    // number tracks the build graph and never drifts. A filtered run prints a
    // count-free banner instead (only a subset ran).
    {
        const argv = b.allocator.alloc([]const u8, 3 + host_test_n) catch @panic("OOM");
        argv[0] = "sh";
        argv[1] = "scripts/test_tally.sh";
        argv[2] = host_test_filter orelse "";
        for (host_test_srcs[0..host_test_n], 0..) |src, i| argv[3 + i] = src;
        const tally = b.addSystemCommand(argv);
        // Depend on the hygiene checks + every test run already attached to
        // test_step, so the banner is the last thing printed.
        for (test_step.dependencies.items) |dep| tally.step.dependOn(dep);
        test_step.dependOn(&tally.step);
    }
}
