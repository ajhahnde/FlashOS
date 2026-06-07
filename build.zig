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

// Native Zig build for the FlashOS kernel (AArch64; rpi4b + virt boards).
//
// Layout:
//   * src/start.zig                   — root, comptime-imports every kernel module
//   * src/*.S                         — boot/entry/sched/timer/etc. assembly
//   * src/board/<board>/*             — per-board driver bag + linker script
//   * user_space/init_main.zig        — pid1.elf root, staged into the initramfs
//   * src/board/<board>/linker.ld     — per-board link script (.initramfs section)
//
// The build produces:
//   * kernel8.img — raw binary loaded by the GPU bootloader (or QEMU `-kernel`)
//   * armstub8.bin — small EL3→EL1 bootstrap shim (rpi4b only)
//
// Optional `populate-syms` step runs nm on the linked ELF, regenerates
// src/symbol_area.S via scripts/generate_syms.zig, then relinks so the
// trace/ksyms machinery has a real symbol table to look up.

const Board = enum { rpi4b, virt };

// Host-test wiring helper. Covers all three call patterns the suite
// uses (shared-stub leaf, shared-stub + named imports, per-target stub
// + imports) and returns the created test Module so a caller can reuse
// it as a named-import target downstream — e.g. wait_queue's test
// module is also pipe's "wait_queue" import.
const HostTest = struct {
    src: []const u8,
    stubs: ?*std.Build.Step.Compile = null,
    extra_stubs: []const *std.Build.Step.Compile = &.{},
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

fn addHostTest(b: *std.Build, step: *std.Build.Step, cfg: HostTest) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(cfg.src),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    if (cfg.stubs) |s| m.addObject(s);
    for (cfg.extra_stubs) |s| m.addObject(s);
    for (cfg.imports) |imp| m.addImport(imp.name, imp.mod);
    const t = b.addTest(.{
        .root_module = m,
        .use_llvm = if (host_tests_use_llvm) true else null,
        .filters = if (host_test_filter) |f| &.{f} else &.{},
    });
    step.dependOn(&b.addRunArtifact(t).step);
    return m;
}

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    // Default .ReleaseSmall keeps the kernel inside its symbol/image
    // budget, but it also compiles out the integer-overflow and
    // bounds-check traps: a missed overflow becomes silent UB instead of a
    // panic. Deliberate ceiling — arithmetic on untrusted input carries
    // explicit checks at the source (the ELF p_vaddr/p_memsz range+wrap
    // guards in src/elf.zig, the clusterLba fail-closed guard in
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

    // Expose the active board to Zig source via @import("build_options").
    // src/board.zig switches on this at comptime to alias each driver
    // module to the right `src/board/<board>/*.zig`.
    const build_options = b.addOptions();
    build_options.addOption(Board, "board", board);

    // Project version, single-sourced from build.zig.zon (.version). Flows to
    // fsh via build_options so the homescreen banner never hardcodes it: a
    // release bumps build.zig.zon and the shell line follows automatically.
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    // Opt-in fork tracing: prints a `created pid N at <kva>` line on every
    // fork. Off by default so normal and CI boots read clean; flip on with
    // `-Dverbose-fork` when debugging the scheduler / process lifecycle.
    const verbose_fork = b.option(
        bool,
        "verbose-fork",
        "Print a 'created pid N at <kva>' line on every fork (debug)",
    ) orelse false;
    build_options.addOption(bool, "verbose_fork", verbose_fork);

    // CI auto-login seed (default OFF — secure by default). PID 1 (pid1.elf)
    // injects `flash\nflash\n` into the console RX ring before exec'ing
    // /bin/login so the unattended QEMU boot watchdog authenticates with no
    // interactive typist (run_qemu_test.sh feeds QEMU `</dev/null`). On real
    // hardware that seed must NOT fire — the boot has to stop at the `login:`
    // prompt and demand a password — so the injection is gated on this flag
    // and `zig build deploy` (which omits it) ships a kernel that requires a
    // real login. The watchdog steps build with `-Dci-login-seed=true`; a
    // forgotten flag fails loud (the boot hangs at `login:` → watchdog
    // timeout) rather than silently shipping an open shell. The login path
    // itself is identical either way — only the pre-seed differs.
    const ci_login_seed = b.option(
        bool,
        "ci-login-seed",
        "Seed flash/flash into the console before /bin/login for the unattended QEMU watchdog (CI only; never for hardware deploys)",
    ) orelse false;
    build_options.addOption(bool, "ci_login_seed", ci_login_seed);

    // In-kernel self-test harness gate (default OFF). When set, PID 1 runs
    // the [TEST] scenario suite + tally before handing off to /bin/login —
    // the boot-as-test path the QEMU watchdog (run_qemu_test.sh) asserts
    // (28 scenarios, 32 free-page checkpoints). Default OFF so `zig build
    // deploy` / `run` produce a clean boot straight to the login prompt with
    // no test wall. The watchdog/CI builds pass `-Dboot-selftest=true`
    // alongside `-Dci-login-seed=true`; a forgotten flag fails loud (no
    // scenarios → watchdog guard mismatch) rather than silently shipping an
    // unvalidated boot. Comptime-gated, so a `-Dboot-selftest=true` build is
    // byte-identical to the pre-gate harness build (the boot contract and
    // free-page checkpoints never move when the flag is on).
    const boot_selftest = b.option(
        bool,
        "boot-selftest",
        "Run the in-kernel [TEST] self-test harness at PID 1 (CI/validation builds); default OFF for a clean boot",
    ) orelse false;
    build_options.addOption(bool, "boot_selftest", boot_selftest);

    // Statistical kernel profiler (default OFF — the released kernel carries
    // zero of it). With -Dtrace the timer/IRQ entry threads the saved
    // exception frame to a frame-pointer-walking sampler that prints a
    // symbolized kernel backtrace at tick boundaries. Two things flip
    // together off this one flag: the C-preprocessor macro FLASHOS_TRACE
    // (added to the kernel module below, so entry.S inserts the one
    // `mov x0, sp` that hands the frame to handle_irq) and a Zig comptime
    // gate (so the sampler code is only compiled in). Default build: no
    // macro, no sampler — entry.S and every kernel symbol are byte-identical
    // to a non-trace build, so the boot contract and symbol table never move.
    const trace = b.option(
        bool,
        "trace",
        "Build the kernel with the statistical FP-walk profiler (prints a symbolized backtrace at each tick; off by default, zero footprint when off)",
    ) orelse false;
    build_options.addOption(bool, "trace", trace);

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

    // ---- hygiene checks (trailing space, hard tabs, lowercase hex) ----
    const hygiene_step = b.step("check-hygiene", "Fail on whitespace or hex-literal regressions");

    const whitespace_check = b.addSystemCommand(&.{ "sh", "scripts/check_whitespace_hygiene.sh" });
    hygiene_step.dependOn(&whitespace_check.step);

    const hex_check = b.addSystemCommand(&.{ "sh", "scripts/check_hex_hygiene.sh" });
    hygiene_step.dependOn(&hex_check.step);

    // Shared syscall ID constants — single source of truth for the
    // kernel-side dispatch table (src/sys.zig) and the user-side
    // wrappers (user_space/kernel_tests.zig). Exposed as a named module
    // because Zig 0.16 forbids `@import` reaching outside the importing
    // module's root directory.
    const syscall_defs_mod = b.createModule(.{
        .root_source_file = b.path("lib/syscall_defs.zig"),
        .target = target,
        .optimize = optimize,
    });

    // console_ui — shared terminal look (status tags, ANSI palette, the
    // boot-success marker, and the line/stage/banner renderers). Pure and
    // target-agnostic (no .target, like shadow_mod): the one source compiles
    // into every console-drawing binary — the kernel boot log and the
    // userspace tools — so the whole system restyles from a single file.
    // Output is routed through a caller-supplied Sink, so it depends on
    // neither kernel internals nor flibc. Added to consumers below
    // (kernel_mod, fsh_mod); unused until a call site @imports it, so staging
    // it leaves every image byte-identical.
    const console_ui_mod = b.createModule(.{
        .root_source_file = b.path("lib/console_ui/console_ui.zig"),
    });

    // User-space virtual address layout (text/data/heap/stack bases +
    // per-region permission bits). Kernel-only consumer for now —
    // src/fork.zig (prepare_move_to_user_elf) and src/mm_user.zig
    // (map_page, do_data_abort) share the constants. Same module-level
    // exposure pattern as syscall_defs_mod.
    const user_layout_mod = b.createModule(.{
        .root_source_file = b.path("src/user_layout.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TaskStruct/CoreContext/etc. layout module. Already implicitly
    // imported by kernel-root modules via `@import("task_layout.zig")`,
    // but the named modules (wait_queue, pipe) need
    // an explicit named import to keep task_layout.zig from being
    // pulled into two sibling named modules through relative paths
    // (which Zig 0.16 rejects as "file exists in two modules").
    const task_layout_mod = b.createModule(.{
        .root_source_file = b.path("src/task_layout.zig"),
        .target = target,
        .optimize = optimize,
    });

    // WaitQueue API. Named module so both kernel and
    // host-test builds reach it via `@import("wait_queue")` — the host
    // test wiring at the bottom of this file mirrors this for the
    // pipe.zig test root.
    const wait_queue_mod = b.createModule(.{
        .root_source_file = b.path("src/wait_queue.zig"),
        .target = target,
        .optimize = optimize,
    });
    wait_queue_mod.addImport("task_layout", task_layout_mod);

    // Anonymous-pipe module. Pulls in wait_queue for
    // the blocking read/write paths; kernel-only for now (future work
    // generalises to a tagged ?*File once the FS lands).
    const pipe_mod = b.createModule(.{
        .root_source_file = b.path("src/pipe.zig"),
        .target = target,
        .optimize = optimize,
    });
    pipe_mod.addImport("wait_queue", wait_queue_mod);
    pipe_mod.addImport("task_layout", task_layout_mod);

    // Initramfs parser module. Pure-data newc cpio
    // walker with linker-provided section bounds; no external imports
    // needed in freestanding (the host-test build flips a comptime
    // branch onto fixture globals — see src/initramfs.zig).
    const initramfs_mod = b.createModule(.{
        .root_source_file = b.path("src/initramfs.zig"),
        .target = target,
        .optimize = optimize,
    });

    // File handle module. Owns the open_files
    // lifetime helpers (alloc / unref / fdAlloc / fdGet / fdClose /
    // dupAll / closeAll). Imports task_layout for TaskStruct + File
    // (which lives in task_layout.zig to break the circular import
    // with the typed `open_files: [_]?*File` slot).
    const file_mod = b.createModule(.{
        .root_source_file = b.path("src/file.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_mod.addImport("task_layout", task_layout_mod);

    const fdtable_mod = b.createModule(.{
        .root_source_file = b.path("src/fdtable.zig"),
        .target = target,
        .optimize = optimize,
    });
    fdtable_mod.addImport("task_layout", task_layout_mod);
    fdtable_mod.addImport("pipe", pipe_mod);
    fdtable_mod.addImport("file", file_mod);

    // VFS dispatch layer. 1-bit superblock tag +
    // two-slot mount table; imports `file` for the File type its
    // vtable signatures reference. Host-test wiring for vfs.zig lives
    // at the bottom of this file.
    const vfs_mod = b.createModule(.{
        .root_source_file = b.path("src/vfs.zig"),
        .target = target,
        .optimize = optimize,
    });
    vfs_mod.addImport("file", file_mod);
    // vfs.zig re-exports the shared Dirent ABI type for the
    // readdir vtable signature.
    vfs_mod.addImport("syscall_defs", syscall_defs_mod);

    // Initramfs VFS backend. Thin wrapper turning
    // initramfs.zig's locate/read/seek into a VfsOps vtable — kept
    // separate from initramfs.zig so the parser stays VFS-agnostic
    // and host-testable in isolation.
    const initramfs_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/initramfs_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    initramfs_backend_mod.addImport("initramfs", initramfs_mod);
    initramfs_backend_mod.addImport("vfs", vfs_mod);
    initramfs_backend_mod.addImport("file", file_mod);

    // Block-device abstraction. Single global
    // `sd_dev` vtable that the FAT32 backend reads + writes
    // through; the board layer (src/board/<board>/emmc2.zig)
    // populates `read_fn` / `write_fn` post-init. No tests
    // (pure data + one extern struct).
    const block_dev_mod = b.createModule(.{
        .root_source_file = b.path("src/block_dev.zig"),
        .target = target,
        .optimize = optimize,
    });

    // SDHCI command encoder + CSD parser.
    // Named module so the rpi4b BCM2711 EMMC2 driver
    // (src/board/rpi4b/emmc2.zig) can `@import("sdhci_cmd")`
    // for the CMD0..ACMD41 encodings and parseCsdV2. Host tests at the
    // bottom of this file build a separate test-only Module from the
    // same source — pure data, no shared state.
    const sdhci_cmd_mod = b.createModule(.{
        .root_source_file = b.path("src/sdhci_cmd.zig"),
        .target = target,
        .optimize = optimize,
    });

    // VideoCore mailbox — property-tag message construction + parsing.
    // Pure data; the rpi4b board side
    // (src/board/rpi4b/mailbox.zig) wraps it with the MMIO doorbell so
    // the EMMC2 driver can read the firmware-set base clock and derive
    // a safe SDHCI divider. Host tests build a separate test-only
    // Module from the same source.
    const mailbox_mod = b.createModule(.{
        .root_source_file = b.path("src/mailbox.zig"),
        .target = target,
        .optimize = optimize,
    });

    // USB descriptor set + SETUP decode (DWC2 gadget). Pure data; the
    // rpi4b board side (src/board/rpi4b/usb.zig) imports it as
    // "usb_descriptors". Host tests build a separate test-only Module
    // from the same source.
    const usb_descriptors_mod = b.createModule(.{
        .root_source_file = b.path("src/usb_descriptors.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Bulk-IN TX byte-ring for the DWC2 CDC-ACM gadget. Pure
    // data + logic; src/board/rpi4b/usb.zig imports it as "usb_tx_ring"
    // and keeps only the MMIO FIFO push. Host tests build a separate
    // test-only Module from the same source.
    const usb_tx_ring_mod = b.createModule(.{
        .root_source_file = b.path("src/usb_tx_ring.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Kernel-log byte-ring (overwrite-oldest) backing dmesg. Pure
    // data + logic; src/utilc.zig tees main_output into it and src/sys.zig
    // snapshots it for sys_klog_read — both reach the one `klog` global
    // through this single named module. Imports syscall_defs for KLOG_SIZE
    // (the ring capacity is ABI-shared with userland dmesg). Host tests
    // build a separate test-only Module from the same source.
    const klog_ring_mod = b.createModule(.{
        .root_source_file = b.path("src/klog_ring.zig"),
        .target = target,
        .optimize = optimize,
    });
    klog_ring_mod.addImport("syscall_defs", syscall_defs_mod);

    // sha256 — SHA-256 / HMAC / PBKDF2 / constant-time compare.
    // Target-agnostic (no .target) so both the freestanding kernel and the
    // host-side gen_shadow tool import the one source. Pure, no imports.
    //
    // Always ReleaseSmall, even in Debug kernel builds: sys_authenticate
    // runs the PBKDF2 → HMAC → SHA-256 chain on the per-task kernel stack
    // (the 4 KiB TaskStruct page, ~2.4 KiB usable), and Debug-mode frames
    // (no register allocation, 256-byte compress W-array + value-copied
    // hasher states per level) overflow that budget — the overflow lands in
    // the TaskStruct tail and silently corrupts the credential fields.
    // ReleaseSmall keeps the deepest chain comfortably inside the page (and
    // makes the boot-path KDF an order of magnitude faster under QEMU TCG).
    // The module is pure wrapping arithmetic (+%), so no Debug safety
    // checks are lost that the host-test target (its own Debug module)
    // doesn't still run.
    const sha256_mod = b.createModule(.{
        .root_source_file = b.path("src/sha256.zig"),
        .optimize = .ReleaseSmall,
    });
    // shadow — /etc/shadow line parser + hex decoder. Pure.
    const shadow_mod = b.createModule(.{
        .root_source_file = b.path("src/shadow.zig"),
    });
    // perm — Unix discretionary access check. Pure decision
    // function (checkAccess) shared by the syscall-layer enforcement
    // sites; the truth-table host test below is the gate.
    const perm_mod = b.createModule(.{
        .root_source_file = b.path("src/perm.zig"),
    });
    // overlay — FAT32 permission-overlay parser. Pure parse +
    // lookup consumed by fat32_backend (PERMS.TAB -> per-file mode/uid/gid).
    const overlay_mod = b.createModule(.{
        .root_source_file = b.path("src/overlay.zig"),
    });
    // pwfile — /etc/passwd parser. Pure name/uid lookups shared
    // by the kernel (sys_passwd authorization), /bin/login, and fsh's
    // whoami builtin.
    const pwfile_mod = b.createModule(.{
        .root_source_file = b.path("src/pwfile.zig"),
    });

    // FAT32 on-disk layout decode + cluster/FAT/dir helpers.
    // Pure data-shape module — no VFS / file / page
    // imports; takes the BlockDev vtable by runtime pointer so the
    // host tests can swap in an in-memory fake.
    // fat32_backend.zig consumes this module to wire the real VfsOps.
    const fat32_mod = b.createModule(.{
        .root_source_file = b.path("src/fat32.zig"),
        .target = target,
        .optimize = optimize,
    });
    fat32_mod.addImport("block_dev", block_dev_mod);

    // FAT32 VFS backend. Wraps fat32.zig's
    // on-disk decode in the real VfsOps vtable; replaces the earlier
    // fat32_stub.
    const fat32_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/fat32_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    fat32_backend_mod.addImport("fat32", fat32_mod);
    fat32_backend_mod.addImport("vfs", vfs_mod);
    fat32_backend_mod.addImport("file", file_mod);
    fat32_backend_mod.addImport("block_dev", block_dev_mod);
    // Permission overlay: PERMS.TAB parse + lookup.
    fat32_backend_mod.addImport("overlay", overlay_mod);

    // Console RX layer. 256-byte ring + WaitQueue
    // backing the unified console read. Same named-module wiring as wait_queue
    // / pipe so the kernel build and the host-test build share one
    // task_layout Module instance.
    const console_mod = b.createModule(.{
        .root_source_file = b.path("src/console.zig"),
        .target = target,
        .optimize = optimize,
    });
    console_mod.addImport("wait_queue", wait_queue_mod);
    console_mod.addImport("task_layout", task_layout_mod);

    // Scheduler module. Promoted from a relative-path
    // import to a named module so sys.zig can `@import("sched")` and call
    // the pure helpers (pick_next_running / refill_counters /
    // zombify_and_wake_parent) without re-declaring extern signatures.
    // Imports pipe + task_layout because sched.zig consumes both
    // (pipe.closeAll in do_wait_impl; TaskStruct from task_layout).
    const sched_mod = b.createModule(.{
        .root_source_file = b.path("src/sched.zig"),
        .target = target,
        .optimize = optimize,
    });
    sched_mod.addImport("task_layout", task_layout_mod);
    sched_mod.addImport("fdtable", fdtable_mod);

    // Pure cwd-aware path-resolution helper. Hosts
    // joinResolve, the single non-recursive `.` / `..` collapse shared
    // by sys_chdir, sys_openFile, and execveKernel. Pure — no imports,
    // no externs — so the freestanding kernel module and the host-test
    // module reach the same source through this single named module.
    const path_mod = b.createModule(.{
        .root_source_file = b.path("src/path.zig"),
        .target = target,
        .optimize = optimize,
    });

    const execve_mod = b.createModule(.{
        .root_source_file = b.path("src/execve.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Kernel-build imports for execveKernel (path-resolve + PT_LOAD stream).
    // The host-test build (build.zig below) wires src/execve.zig with no
    // imports; the comptime is_kernel guard keeps these out of host analysis.
    execve_mod.addImport("task_layout", task_layout_mod);
    execve_mod.addImport("vfs", vfs_mod);
    execve_mod.addImport("user_layout", user_layout_mod);
    execve_mod.addImport("path", path_mod);
    // Permission gate: exec-intent check + the EACCES constant.
    execve_mod.addImport("perm", perm_mod);
    execve_mod.addImport("syscall_defs", syscall_defs_mod);

    // ---- kernel executable ----
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/start.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false, // keep symbols so `populate-syms` can nm the ELF
        .unwind_tables = .none,
        // NOTE: -Dtrace deliberately does NOT force -fno-omit-frame-pointer.
        // src/boot.S uses x29 as a scratch LR stash during early boot, and the
        // per-task kernel stack is only ~2.4 KiB; reserving x29 as a frame
        // pointer kernel-wide corrupts the boot and trips a safety panic (it
        // wild-branches under ReleaseSmall). The sampler therefore walks the
        // FP chain best-effort (whatever frames LLVM kept) and always emits
        // the leaf PC, which needs no frame pointer.
        .omit_frame_pointer = null,
    });
    const kernel = b.addExecutable(.{
        .name = "kernel8.elf",
        .root_module = kernel_mod,
    });
    kernel.step.dependOn(hygiene_step);

    const asm_files = [_][]const u8{
        "src/boot.S",
        "src/entry.S",
        "src/utils.S",
        "src/mm.S",
        "src/sched.S",
        "src/irq.S",
        "src/generic_timer.S",
        "src/symbol_area.S",
        "src/trace/hook.S",
        "src/trace/patchable_trampolines.S",
    };
    for (asm_files) |path| {
        kernel_mod.addAssemblyFile(b.path(path));
    }
    // Board-specific assembly: per-board boot quirks (and any future
    // timer init etc.) live under src/board/<board>/. virt additionally
    // ships a Linux arm64 image header so UEFI/GRUB can identify the
    // kernel binary in Phase B; rpi4b's firmware loads kernel8.img raw
    // and does not expect the header.
    const board_asm_files: []const []const u8 = if (board == .virt)
        &.{ "image_header.S", "boot_quirks.S" }
    else
        &.{"boot_quirks.S"};
    for (board_asm_files) |path| {
        kernel_mod.addAssemblyFile(b.path(b.fmt("src/board/{s}/{s}", .{ @tagName(board), path })));
    }
    // The kernel .S files use `#include "asm_defs.inc"`. The bridge
    // header pulls in `board_asm_defs.inc` from the active board's
    // directory — added below so the per-board layout resolves.
    kernel_mod.addIncludePath(b.path("src"));
    kernel_mod.addIncludePath(b.path(b.fmt("src/board/{s}", .{@tagName(board)})));

    // -Dtrace: define FLASHOS_TRACE for the C-preprocessed .S files (the .S
    // extension routes them through clang's preprocessor, the same path that
    // resolves their #include "asm_defs.inc"). entry.S keys its one extra
    // `mov x0, sp` on this; absent the macro that instruction is not emitted,
    // so the default kernel image is byte-identical.
    if (trace) kernel_mod.addCMacro("FLASHOS_TRACE", "1");

    kernel_mod.addOptions("build_options", build_options);
    kernel_mod.addImport("syscall_defs", syscall_defs_mod);
    kernel_mod.addImport("user_layout", user_layout_mod);
    kernel_mod.addImport("task_layout", task_layout_mod);
    kernel_mod.addImport("wait_queue", wait_queue_mod);
    kernel_mod.addImport("pipe", pipe_mod);
    kernel_mod.addImport("fdtable", fdtable_mod);
    kernel_mod.addImport("console", console_mod);
    kernel_mod.addImport("sched", sched_mod);
    kernel_mod.addImport("execve", execve_mod);
    kernel_mod.addImport("path", path_mod);
    kernel_mod.addImport("initramfs", initramfs_mod);
    kernel_mod.addImport("file", file_mod);
    kernel_mod.addImport("vfs", vfs_mod);
    kernel_mod.addImport("initramfs_backend", initramfs_backend_mod);
    kernel_mod.addImport("fat32_backend", fat32_backend_mod);
    kernel_mod.addImport("fat32", fat32_mod);
    kernel_mod.addImport("block_dev", block_dev_mod);
    kernel_mod.addImport("sdhci_cmd", sdhci_cmd_mod);
    kernel_mod.addImport("mailbox", mailbox_mod);
    kernel_mod.addImport("usb_descriptors", usb_descriptors_mod);
    kernel_mod.addImport("usb_tx_ring", usb_tx_ring_mod);
    kernel_mod.addImport("klog_ring", klog_ring_mod);
    kernel_mod.addImport("sha256", sha256_mod);
    kernel_mod.addImport("shadow", shadow_mod);
    kernel_mod.addImport("perm", perm_mod);
    // sys_passwd authorization: uid -> login-name lookup against
    // /etc/passwd (the same parser /bin/login and fsh's whoami import).
    kernel_mod.addImport("pwfile", pwfile_mod);
    // console_ui: shared terminal look for the boot log. Staged but not yet
    // @imported by any kernel source, so the kernel image stays byte-identical
    // until the migration call sites land.
    kernel_mod.addImport("console_ui", console_ui_mod);

    // ---- hello.elf — payload for [TEST] exec-elf ----
    // Built as a standalone aarch64-freestanding ET_EXEC, staged into
    // the initramfs at /test/hello.elf. The exec-elf scenario opens it
    // via sys_openFile, reads it into an EL0 buffer, and hands the
    // bytes to sys_exec.
    const hello_mod = b.createModule(.{
        .root_source_file = b.path("tools/hello_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    const hello = b.addExecutable(.{
        .name = "hello.elf",
        .root_module = hello_mod,
    });
    hello.pie = false; // ET_EXEC, not ET_DYN — the loader rejects PIE.
    hello.bundle_compiler_rt = false;
    // Tiny p_align so LLD doesn't pad the file out to a page-sized
    // offset — the ELF loader caps blob_size at PAGE_SIZE because it
    // snapshots the blob into one kernel page. p_vaddr is still
    // 0x1000-aligned via the linker script's `. = 0x100000`, which is
    // what FlashOS's page-grain mapper actually requires; p_align only
    // governs the ELF spec's `p_vaddr ≡ p_offset (mod p_align)` rule,
    // and the kernel loader does not enforce p_align.
    hello.link_z_max_page_size = 0x80;
    hello.link_z_common_page_size = 0x80;
    // Custom linker script: stock LLD output splits .eh_frame_hdr /
    // .eh_frame into a separate LOAD segment ahead of .text, which
    // pushes .text to a non-page-aligned VA. The script collapses to
    // a single R+X PT_LOAD and discards the unwind / dyn metadata.
    hello.setLinkerScript(b.path("tools/hello_linker.ld"));
    hello.entry = .disabled; // ENTRY(_start) lives in the linker script

    // ---- stackbomb.elf — payload for [TEST] stack-overflow ----
    // Same recipe as hello.elf, swapping the source for a payload that
    // recurses without termination. The kernel's do_data_abort detects
    // the guard-zone fault, prints a kernel-side diagnostic and zombies
    // the task; the parent's sys_wait reaps it so the per-process page
    // balance returns to baseline (which is what the harness verifies).
    const stackbomb_mod = b.createModule(.{
        .root_source_file = b.path("tools/stackbomb_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    stackbomb_mod.addImport("user_layout", user_layout_mod);
    const stackbomb = b.addExecutable(.{
        .name = "stackbomb.elf",
        .root_module = stackbomb_mod,
    });
    stackbomb.pie = false;
    stackbomb.bundle_compiler_rt = false;
    stackbomb.link_z_max_page_size = 0x80;
    stackbomb.link_z_common_page_size = 0x80;
    // The hello linker script is a generic single-PT_LOAD layout —
    // reuse it verbatim. If the two payloads ever need different
    // section discards or VA bases, fork into tools/stackbomb_linker.ld.
    stackbomb.setLinkerScript(b.path("tools/hello_linker.ld"));
    stackbomb.entry = .disabled;

    // ---- flibc — userland mini-libc, ELF-demo dependency ----
    // Userland mini-libc: SVC wrappers, printf/puts on sys_writeConsole,
    // bump allocator over sys_brk/sbrk, fork/wait/exit/execve. Exposed
    // as a named module so ELF demos (and future fsh / coreutils
    // payloads) can `addImport("flibc", flibc_mod)` and stay one
    // `@import` deep. Pulls in syscall_defs for the SVC IDs — same
    // module the kernel and the kernel_tests user-side wrappers consume.
    const flibc_mod = b.createModule(.{
        .root_source_file = b.path("user_space/lib/flibc/flibc.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    flibc_mod.addImport("syscall_defs", syscall_defs_mod);

    // ---- flibc_demo.elf — payload for [TEST] flibc ----
    // Same recipe as hello.elf / stackbomb.elf, swapping the source for
    // a flibc-driven body: printf("flibc hello %d\n", 42), malloc 32 B,
    // pattern write+verify, exit. The forked linker script
    // (tools/flibc_demo_linker.ld) folds .rodata / .data / .bss into the
    // single R+X PT_LOAD so flibc's state-free heap design carries
    // through to a one-segment ELF that once fit inside the retired
    // loader's PAGE_SIZE snapshot cap.
    const flibc_demo_mod = b.createModule(.{
        .root_source_file = b.path("tools/flibc_demo_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    flibc_demo_mod.addImport("flibc", flibc_mod);
    const flibc_demo = b.addExecutable(.{
        .name = "flibc_demo.elf",
        .root_module = flibc_demo_mod,
    });
    flibc_demo.pie = false;
    flibc_demo.bundle_compiler_rt = false;
    flibc_demo.link_z_max_page_size = 0x80;
    flibc_demo.link_z_common_page_size = 0x80;
    flibc_demo.setLinkerScript(b.path("tools/flibc_demo_linker.ld"));
    flibc_demo.entry = .disabled;

    // ---- argv_echo.elf — payload for [TEST] execve ----
    // Same recipe as flibc_demo.elf, but its entry is the flibc _start
    // argc/argv shim (user_space/lib/flibc/start.zig) rather than a bespoke
    // _start, and it carries a 4 KiB .rodata PAD so the linked ELF crosses
    // one page — proving sys_execve's PT_LOAD streaming path loads payloads
    // the long-retired PAGE_SIZE snapshot cap could not. The shim lives
    // in its own module (not flibc/process.zig) because flibc.zig re-exports
    // process into every flibc program, and Zig 0.16 rejects two _start
    // exports in one compilation; argv_echo opts in via addImport below plus
    // the `comptime _ = @import("flibc_start")` in argv_echo_elf.zig.
    const flibc_start_mod = b.createModule(.{
        .root_source_file = b.path("user_space/lib/flibc/start.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    // Freestanding memcpy / memset / strlen for payloads that actually
    // exercise execvp / the tokenizer / per-arg length scans — LLVM
    // lowers those loops to libcalls that bundle_compiler_rt=false leaves
    // unprovided. Opt-in (imported only by fsh / echo / cat), so the
    // payloads that dodge the idiom (argv_echo, flibc_demo) stay lean.
    const flibc_mem_mod = b.createModule(.{
        .root_source_file = b.path("user_space/lib/flibc/mem.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const argv_echo_mod = b.createModule(.{
        .root_source_file = b.path("tools/argv_echo_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    argv_echo_mod.addImport("flibc", flibc_mod);
    argv_echo_mod.addImport("flibc_start", flibc_start_mod);
    const argv_echo = b.addExecutable(.{
        .name = "argv_echo.elf",
        .root_module = argv_echo_mod,
    });
    argv_echo.pie = false;
    argv_echo.bundle_compiler_rt = false;
    argv_echo.link_z_max_page_size = 0x80;
    argv_echo.link_z_common_page_size = 0x80;
    argv_echo.setLinkerScript(b.path("tools/argv_echo_linker.ld"));
    argv_echo.entry = .disabled;

    // ---- fsh.elf — the FlashOS shell (/bin/fsh) ----
    // Same recipe as argv_echo.elf (flibc _start argc/argv shim entry,
    // pie=false, ReleaseSmall, strip, own single R+X PT_LOAD linker
    // script — no PAD; fsh need not cross a page). fsh.zig imports the
    // pure tokenizer (user_space/fsh/tokenize.zig) as a sibling file;
    // that module is host-tested separately in the test section below.
    // Staged into the initramfs at /bin/fsh and exec'd by the PID-1
    // hand-off after the harness tally; the boot watchdog keys on fsh's
    // `[ OK ] Reached target Shell.` marker as the success signal. (The in-harness
    // [TEST] fsh scenario is disabled — see user_space/kernel_tests.zig.)
    const fsh_mod = b.createModule(.{
        .root_source_file = b.path("user_space/fsh/fsh.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    fsh_mod.addImport("flibc", flibc_mod);
    fsh_mod.addImport("flibc_start", flibc_start_mod);
    // whoami builtin: uid -> login-name lookup against
    // /etc/passwd via the same parser the kernel and /bin/login use.
    fsh_mod.addImport("pwfile", pwfile_mod);
    // console_ui: shared terminal look for the homescreen/prompt. fsh renders
    // its homescreen banner through it, fed the build_options version below.
    fsh_mod.addImport("console_ui", console_ui_mod);
    // build_options carries the project version (from build.zig.zon) into the
    // homescreen banner — single source, no hardcoded version in fsh.
    fsh_mod.addOptions("build_options", build_options);
    // fsh is the first payload to actually exercise execvp + the
    // tokenizer's @memcpy, so LLVM lowers those to memcpy / strlen
    // libcalls; flibc_mem supplies the freestanding providers.
    fsh_mod.addImport("flibc_mem", flibc_mem_mod);
    const fsh = b.addExecutable(.{
        .name = "fsh.elf",
        .root_module = fsh_mod,
    });
    fsh.pie = false;
    fsh.bundle_compiler_rt = false;
    fsh.link_z_max_page_size = 0x80;
    fsh.link_z_common_page_size = 0x80;
    fsh.setLinkerScript(b.path("tools/fsh_linker.ld"));
    fsh.entry = .disabled;

    // ---- echo.elf / cat.elf — minimal coreutils ----
    // Same recipe as fsh.elf (flibc _start shim,
    // flibc_mem, pie=false, ReleaseSmall, strip) over a shared
    // single-PT_LOAD linker script. Staged at /bin/echo and /bin/cat;
    // exercised interactively via fsh (the `echo hi | cat` acceptance).
    // The coreutil set also carries ls / meminfo / forkbomb.
    const echo_mod = b.createModule(.{
        .root_source_file = b.path("tools/echo_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    echo_mod.addImport("flibc", flibc_mod);
    echo_mod.addImport("flibc_start", flibc_start_mod);
    echo_mod.addImport("flibc_mem", flibc_mem_mod);
    const echo = b.addExecutable(.{
        .name = "echo.elf",
        .root_module = echo_mod,
    });
    echo.pie = false;
    echo.bundle_compiler_rt = false;
    echo.link_z_max_page_size = 0x80;
    echo.link_z_common_page_size = 0x80;
    echo.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    echo.entry = .disabled;

    const cat_mod = b.createModule(.{
        .root_source_file = b.path("tools/cat_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    cat_mod.addImport("flibc", flibc_mod);
    cat_mod.addImport("flibc_start", flibc_start_mod);
    cat_mod.addImport("flibc_mem", flibc_mem_mod);
    // EACCES-aware diagnostic: cat names the permission denial.
    cat_mod.addImport("syscall_defs", syscall_defs_mod);
    const cat = b.addExecutable(.{
        .name = "cat.elf",
        .root_module = cat_mod,
    });
    cat.pie = false;
    cat.bundle_compiler_rt = false;
    cat.link_z_max_page_size = 0x80;
    cat.link_z_common_page_size = 0x80;
    cat.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    cat.entry = .disabled;

    // ---- ls.elf — directory-listing coreutil ----
    // The first consumer of sys_readdir (slot 37): loops readdir(path, i)
    // 0.. and writes each basename (a trailing '/' for DT_DIR) to fd 1.
    // Same recipe as echo / cat (flibc _start shim, flibc_mem, pie=false,
    // ReleaseSmall, strip, shared coreutil_linker.ld). Staged at /bin/ls;
    // exercised by `ls /bin` in FSH_SCRIPT + [TEST] readdir in the stage-
    // closing commit.
    const ls_mod = b.createModule(.{
        .root_source_file = b.path("tools/ls_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    ls_mod.addImport("flibc", flibc_mod);
    ls_mod.addImport("flibc_start", flibc_start_mod);
    ls_mod.addImport("flibc_mem", flibc_mem_mod);
    const ls = b.addExecutable(.{
        .name = "ls.elf",
        .root_module = ls_mod,
    });
    ls.pie = false;
    ls.bundle_compiler_rt = false;
    ls.link_z_max_page_size = 0x80;
    ls.link_z_common_page_size = 0x80;
    ls.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    ls.entry = .disabled;

    // ---- dmesg.elf — kernel-log dumper coreutil ----
    // The consumer of sys_klog_read (slot 38): one snapshot of the kernel
    // log ring (src/klog_ring.zig) written to fd 1, so the boot log is
    // readable over the USB-C console without the Mini-UART adapter. Same
    // recipe as ls / cat / echo (flibc _start shim, flibc_mem, pie=false,
    // ReleaseSmall, strip, shared coreutil_linker.ld). Staged at /bin/dmesg;
    // Pi-interactive surface — the CI harness asserts the ring + syscall
    // directly via [TEST] klog, the way meminfo / forkbomb stay out of the
    // FSH_SCRIPT.
    const dmesg_mod = b.createModule(.{
        .root_source_file = b.path("tools/dmesg_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    dmesg_mod.addImport("flibc", flibc_mod);
    dmesg_mod.addImport("flibc_start", flibc_start_mod);
    dmesg_mod.addImport("flibc_mem", flibc_mem_mod);
    const dmesg = b.addExecutable(.{
        .name = "dmesg.elf",
        .root_module = dmesg_mod,
    });
    dmesg.pie = false;
    dmesg.bundle_compiler_rt = false;
    dmesg.link_z_max_page_size = 0x80;
    dmesg.link_z_common_page_size = 0x80;
    dmesg.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    dmesg.entry = .disabled;

    // ---- meminfo.elf / forkbomb.elf — demo coreutils ----
    // meminfo is the standalone /bin form of fsh's `free` built-in (one
    // sys_dump_free line); forkbomb is a capped (N=16) fork/reap leak
    // detector that never approaches OOM. Both print via the legacy slot-0
    // console write and are Pi-interactive only — kept out of the CI
    // FSH_SCRIPT (meminfo's live value breaks the baseline count; forkbomb
    // must not approach exhaustion while OOM still panics today). Same
    // recipe as echo / cat / ls.
    const meminfo_mod = b.createModule(.{
        .root_source_file = b.path("tools/meminfo_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    meminfo_mod.addImport("flibc", flibc_mod);
    meminfo_mod.addImport("flibc_start", flibc_start_mod);
    meminfo_mod.addImport("flibc_mem", flibc_mem_mod);
    const meminfo = b.addExecutable(.{
        .name = "meminfo.elf",
        .root_module = meminfo_mod,
    });
    meminfo.pie = false;
    meminfo.bundle_compiler_rt = false;
    meminfo.link_z_max_page_size = 0x80;
    meminfo.link_z_common_page_size = 0x80;
    meminfo.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    meminfo.entry = .disabled;

    const forkbomb_mod = b.createModule(.{
        .root_source_file = b.path("tools/forkbomb_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    forkbomb_mod.addImport("flibc", flibc_mod);
    forkbomb_mod.addImport("flibc_start", flibc_start_mod);
    forkbomb_mod.addImport("flibc_mem", flibc_mem_mod);
    const forkbomb = b.addExecutable(.{
        .name = "forkbomb.elf",
        .root_module = forkbomb_mod,
    });
    forkbomb.pie = false;
    forkbomb.bundle_compiler_rt = false;
    forkbomb.link_z_max_page_size = 0x80;
    forkbomb.link_z_common_page_size = 0x80;
    forkbomb.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    forkbomb.entry = .disabled;

    // ---- sysinfo.elf — one-shot system summary coreutil ----
    // First consumer of the console_ui screen-layer kv() renderer (the
    // full-screen-navigation scaffold): prints the FlashOS version, the
    // logged-in user, and the free-page count as aligned key/value rows, then
    // exits. Imports console_ui for kv(), pwfile for the uid -> name lookup, and
    // build_options for the version (single-sourced from build.zig.zon). Same
    // recipe as ls / meminfo (flibc _start shim, flibc_mem, pie=false,
    // ReleaseSmall, strip, shared coreutil_linker.ld). Staged at /bin/sysinfo;
    // kept out of the CI FSH_SCRIPT like meminfo (its free-page value is live).
    const sysinfo_mod = b.createModule(.{
        .root_source_file = b.path("tools/sysinfo_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    sysinfo_mod.addImport("flibc", flibc_mod);
    sysinfo_mod.addImport("flibc_start", flibc_start_mod);
    sysinfo_mod.addImport("flibc_mem", flibc_mem_mod);
    sysinfo_mod.addImport("pwfile", pwfile_mod);
    sysinfo_mod.addImport("console_ui", console_ui_mod);
    sysinfo_mod.addOptions("build_options", build_options);
    const sysinfo = b.addExecutable(.{
        .name = "sysinfo.elf",
        .root_module = sysinfo_mod,
    });
    sysinfo.pie = false;
    sysinfo.bundle_compiler_rt = false;
    sysinfo.link_z_max_page_size = 0x80;
    sysinfo.link_z_common_page_size = 0x80;
    sysinfo.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    sysinfo.entry = .disabled;

    // ---- less.elf — full-screen text pager ----
    // First interactive consumer of the navigation scaffold: takes over the
    // console with console_ui.screen (alt-screen + panelTop title bar), reads
    // keys through flibc.readKey's VT100 decoder, and scrolls a single named
    // file with the pure flibc.Pager core. A proof of the full-screen loop the
    // way sysinfo proved the print-and-exit kv() renderer. Imports flibc +
    // console_ui only (no pwfile / build_options). Same recipe as ls / sysinfo
    // (flibc _start shim, flibc_mem, pie=false, ReleaseSmall, strip, shared
    // coreutil_linker.ld). Staged at /bin/less; kept out of the CI FSH_SCRIPT
    // like sysinfo (interactive; the free-page baseline must stay deterministic).
    const less_mod = b.createModule(.{
        .root_source_file = b.path("tools/less_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    less_mod.addImport("flibc", flibc_mod);
    less_mod.addImport("flibc_start", flibc_start_mod);
    less_mod.addImport("flibc_mem", flibc_mem_mod);
    less_mod.addImport("console_ui", console_ui_mod);
    const less = b.addExecutable(.{
        .name = "less.elf",
        .root_module = less_mod,
    });
    less.pie = false;
    less.bundle_compiler_rt = false;
    less.link_z_max_page_size = 0x80;
    less.link_z_common_page_size = 0x80;
    less.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    less.entry = .disabled;

    // ---- login.elf — credential gate + session supervisor ----
    // PID-1 execs /bin/login instead of /bin/fsh: it prompts for a username
    // (echoed) + password (echo suppressed via SYS_SET_CONSOLE_MODE), has the
    // kernel verify against the active shadow (sys_authenticate), then runs
    // the session as a child — the child drops privilege (setgid + setuid)
    // per /etc/passwd and execs the user's shell while login stays root,
    // waits, reaps, and re-prompts (the logout lifecycle). Same coreutil
    // recipe as dmesg / ls; imports syscall_defs for the echo mode bit and
    // pwfile for the /etc/passwd lookup.
    const login_mod = b.createModule(.{
        .root_source_file = b.path("tools/login_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    login_mod.addImport("flibc", flibc_mod);
    login_mod.addImport("flibc_start", flibc_start_mod);
    login_mod.addImport("flibc_mem", flibc_mem_mod);
    login_mod.addImport("syscall_defs", syscall_defs_mod);
    login_mod.addImport("pwfile", pwfile_mod);
    const login = b.addExecutable(.{
        .name = "login.elf",
        .root_module = login_mod,
    });
    login.pie = false;
    login.bundle_compiler_rt = false;
    login.link_z_max_page_size = 0x80;
    login.link_z_common_page_size = 0x80;
    login.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    login.entry = .disabled;

    // ---- passwd.elf — interactive password change ----
    // `passwd [user]` collects the current + new password (kernel echo
    // off) and calls sys_passwd; the KDF + splice-safe shadow rewrite
    // live in the kernel. Same coreutil recipe as login; imports pwfile
    // for the uid -> own-login-name default and syscall_defs for EACCES.
    const passwd_bin_mod = b.createModule(.{
        .root_source_file = b.path("tools/passwd_elf.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    passwd_bin_mod.addImport("flibc", flibc_mod);
    passwd_bin_mod.addImport("flibc_start", flibc_start_mod);
    passwd_bin_mod.addImport("flibc_mem", flibc_mem_mod);
    passwd_bin_mod.addImport("syscall_defs", syscall_defs_mod);
    passwd_bin_mod.addImport("pwfile", pwfile_mod);
    const passwd_bin = b.addExecutable(.{
        .name = "passwd.elf",
        .root_module = passwd_bin_mod,
    });
    passwd_bin.pie = false;
    passwd_bin.bundle_compiler_rt = false;
    passwd_bin.link_z_max_page_size = 0x80;
    passwd_bin.link_z_common_page_size = 0x80;
    passwd_bin.setLinkerScript(b.path("tools/coreutil_linker.ld"));
    passwd_bin.entry = .disabled;

    // ---- pid1.elf — the ELF-loaded PID 1 ----
    // Replaces the user_init.o blob. Instead of compiling
    // user_space/init.zig into the kernel object and wrapping it in
    // linker.ld's user_start / user_end, PID 1 is now a standalone
    // aarch64-freestanding ET_EXEC staged into the initramfs at
    // /sbin/init. kernel_process locates that entry and hands its
    // bytes to prepare_move_to_user_elf — the same ELF loader the
    // exec-elf / stackbomb / flibc test payloads travel.
    //
    // Recipe mirrors hello.elf (pie=false, strip, ReleaseSmall, tiny
    // p_align so LLD doesn't page-pad the file). The forked linker
    // script tools/pid1_linker.ld folds .rodata / .data / .bss into
    // the single R+X PT_LOAD. Unlike the test payloads pid1.elf is
    // loaded by kernel_process directly at boot, so there is no
    // snapshot cap on its size — prepare_move_to_user_elf walks the
    // PT_LOAD page by page.
    const pid1_mod = b.createModule(.{
        .root_source_file = b.path("user_space/init_main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    pid1_mod.addImport("syscall_defs", syscall_defs_mod);
    // pid1 reads build_options for the CI auto-login seed gate (see the
    // ci-login-seed option above). Off by default → the shipped boot stops
    // at `login:`; the watchdog builds with the flag for unattended auth.
    pid1_mod.addOptions("build_options", build_options);
    const pid1 = b.addExecutable(.{
        .name = "pid1.elf",
        .root_module = pid1_mod,
    });
    pid1.pie = false;
    pid1.bundle_compiler_rt = false;
    pid1.link_z_max_page_size = 0x80;
    pid1.link_z_common_page_size = 0x80;
    pid1.setLinkerScript(b.path("tools/pid1_linker.ld"));
    pid1.entry = .disabled;

    // ---- /etc/shadow generator ----
    // Host tool: runs the kernel's PBKDF2 (src/sha256.zig) over fixed test
    // credentials to emit a deterministic /etc/shadow, staged into the
    // initramfs below. Reusing the kernel KDF guarantees the baked verifier
    // matches what sys_authenticate recomputes at login. Output is a pure
    // function of the in-tool constants, so the kernel image stays byte-
    // reproducible (Pi hash baseline).
    const gen_shadow_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_shadow.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    gen_shadow_mod.addImport("sha256", sha256_mod);
    const gen_shadow = b.addExecutable(.{
        .name = "gen_shadow",
        .root_module = gen_shadow_mod,
    });
    const gen_shadow_cmd = b.addRunArtifact(gen_shadow);
    const shadow_file = gen_shadow_cmd.addOutputFileArg("shadow");
    // Install a copy at zig-out/shadow so the deploy step (a literal-path
    // shell script, like its kernel8.img reference) can seed the real SD
    // card with the same bytes the initramfs and the QEMU image carry.
    const install_shadow = b.addInstallFileWithDir(shadow_file, .prefix, "shadow");

    // ---- initramfs.cpio ----
    // newc cpio archive embedded into the kernel image via the
    // .initramfs section (linker.ld on both boards). Stages the
    // real payloads: pid1.elf at /sbin/init (kernel_process ELF-loads
    // it as PID 1), and the three test ELFs at /test/*.elf (the
    // exec-elf / stack-overflow / flibc scenarios open + read + exec
    // them via the file syscalls instead of the retired .text.user
    // bridge slots).
    //
    // The cpio_stage WriteFiles step collects each ELF under a stable
    // arc name ("sbin/init", "test/hello.elf", …); the encoder below
    // walks a fixed, lexicographically-sorted arc list and reads bytes
    // from the staged directory, so the archive layout never depends
    // on filesystem walk order. src/initramfs.zig canonicalises the
    // emitted "./<arc>" prefix to "/<arc>" so locate("/sbin/init")
    // matches.
    //
    // Step 10 replaced the previous addSystemCommand cpio(1) block
    // (bsdcpio on macOS, GNU cpio on Linux) with the hand-rolled Zig
    // encoder at scripts/build_initramfs.zig. The old block stamped
    // host-clock mtime + non-zero inode at byte 12, so two clean
    // builds produced different kernel8.img sha256 sums and blocked
    // Pi-hash baseline refresh. The encoder fixes mtime / uid / gid /
    // nlink / mode and assigns monotonic ino, making the archive a
    // pure function of file contents + name list.
    const cpio_stage = b.addNamedWriteFiles("initramfs_stage");
    _ = cpio_stage.addCopyFile(pid1.getEmittedBin(), "sbin/init");
    _ = cpio_stage.addCopyFile(hello.getEmittedBin(), "test/hello.elf");
    _ = cpio_stage.addCopyFile(stackbomb.getEmittedBin(), "test/stackbomb.elf");
    _ = cpio_stage.addCopyFile(flibc_demo.getEmittedBin(), "test/flibc_demo.elf");
    _ = cpio_stage.addCopyFile(argv_echo.getEmittedBin(), "test/argv_echo.elf");
    _ = cpio_stage.addCopyFile(cat.getEmittedBin(), "bin/cat");
    _ = cpio_stage.addCopyFile(dmesg.getEmittedBin(), "bin/dmesg");
    _ = cpio_stage.addCopyFile(echo.getEmittedBin(), "bin/echo");
    _ = cpio_stage.addCopyFile(forkbomb.getEmittedBin(), "bin/forkbomb");
    _ = cpio_stage.addCopyFile(fsh.getEmittedBin(), "bin/fsh");
    _ = cpio_stage.addCopyFile(less.getEmittedBin(), "bin/less");
    _ = cpio_stage.addCopyFile(ls.getEmittedBin(), "bin/ls");
    _ = cpio_stage.addCopyFile(meminfo.getEmittedBin(), "bin/meminfo");
    _ = cpio_stage.addCopyFile(sysinfo.getEmittedBin(), "bin/sysinfo");
    _ = cpio_stage.addCopyFile(b.path("user_space/fsh/fshrc"), "etc/fshrc");
    _ = cpio_stage.addCopyFile(login.getEmittedBin(), "bin/login");
    _ = cpio_stage.addCopyFile(passwd_bin.getEmittedBin(), "bin/passwd");
    _ = cpio_stage.addCopyFile(b.path("user_space/etc/passwd"), "etc/passwd");
    _ = cpio_stage.addCopyFile(shadow_file, "etc/shadow");

    const initramfs_encoder = b.addExecutable(.{
        .name = "build_initramfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/build_initramfs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // Arc names sorted lexicographically — the encoder writes them in
    // argv order, so this list is the single source of truth for the
    // archive's entry order and therefore its sha256. Keep sorted.
    //
    // Each arc carries its newc mode: binaries are 0o100755
    // (the dropped-privilege shell must still exec them), config files
    // are 0o100644 (world-readable), and /etc/shadow is 0o100600 so the
    // VFS permission layer holds the "non-root read → EACCES" line.
    // This list is the single policy source; the encoder just stamps
    // what it is told.
    const initramfs_arcs = [_]struct { arc: []const u8, mode: u32 }{
        .{ .arc = "bin/cat", .mode = 0o100755 },
        .{ .arc = "bin/dmesg", .mode = 0o100755 },
        .{ .arc = "bin/echo", .mode = 0o100755 },
        .{ .arc = "bin/forkbomb", .mode = 0o100755 },
        .{ .arc = "bin/fsh", .mode = 0o100755 },
        .{ .arc = "bin/less", .mode = 0o100755 },
        .{ .arc = "bin/login", .mode = 0o100755 },
        .{ .arc = "bin/ls", .mode = 0o100755 },
        .{ .arc = "bin/meminfo", .mode = 0o100755 },
        .{ .arc = "bin/passwd", .mode = 0o100755 },
        .{ .arc = "bin/sysinfo", .mode = 0o100755 },
        .{ .arc = "etc/fshrc", .mode = 0o100644 },
        .{ .arc = "etc/passwd", .mode = 0o100644 },
        .{ .arc = "etc/shadow", .mode = 0o100600 },
        .{ .arc = "sbin/init", .mode = 0o100755 },
        .{ .arc = "test/argv_echo.elf", .mode = 0o100755 },
        .{ .arc = "test/flibc_demo.elf", .mode = 0o100755 },
        .{ .arc = "test/hello.elf", .mode = 0o100755 },
        .{ .arc = "test/stackbomb.elf", .mode = 0o100755 },
    };

    const cpio_cmd = b.addRunArtifact(initramfs_encoder);
    const initramfs_bin = cpio_cmd.addOutputFileArg("initramfs.cpio");
    cpio_cmd.addDirectoryArg(cpio_stage.getDirectory());
    for (initramfs_arcs) |e| cpio_cmd.addArg(b.fmt("{s}:{o}", .{ e.arc, e.mode }));

    // Stage the cpio next to a directory the assembler can `-I` so
    // tools/initramfs.S's `.incbin "initramfs.cpio"` resolves
    // regardless of CWD — same pattern hello_elf.S / stackbomb_elf.S
    // / flibc_demo_elf.S use above.
    const initramfs_bin_stage = b.addNamedWriteFiles("initramfs_bin_stage");
    _ = initramfs_bin_stage.addCopyFile(initramfs_bin, "initramfs.cpio");
    kernel_mod.addAssemblyFile(b.path("tools/initramfs.S"));
    kernel_mod.addIncludePath(initramfs_bin_stage.getDirectory());

    kernel.setLinkerScript(b.path(b.fmt("src/board/{s}/linker.ld", .{@tagName(board)})));
    kernel.entry = .disabled; // _start lives in boot.S
    kernel.link_z_max_page_size = 0x1000;
    kernel.link_gc_sections = false;

    const install_kernel_elf = b.addInstallArtifact(kernel, .{});

    // ELF → raw binary using the system aarch64-elf-objcopy.
    const objcopy_kernel = b.addSystemCommand(&.{
        "aarch64-elf-objcopy",
    });
    objcopy_kernel.addArtifactArg(kernel);
    objcopy_kernel.addArg("-O");
    objcopy_kernel.addArg("binary");
    const kernel_img = objcopy_kernel.addOutputFileArg("kernel8.img");
    const install_kernel_img = b.addInstallFileWithDir(kernel_img, .prefix, "kernel8.img");

    const kernel_step = b.step("kernel", "Build kernel8.img");
    kernel_step.dependOn(&install_kernel_elf.step);
    kernel_step.dependOn(&install_kernel_img.step);

    // ---- aggregate / default ----
    // The default `all` step bundles per-board artifacts. armstub and
    // the SD-card deploy are Pi-specific (BCM2711 EL3→EL1 shim,
    // bcm2711-rpi-4-b.dtb / start4.elf), so they live in the
    // `if (board == .rpi4b)` arm below.
    const all_step = b.step("all", "Build everything (default)");
    all_step.dependOn(kernel_step);
    b.default_step.dependOn(all_step);

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

        all_step.dependOn(armstub_step);
    }

    // ---- optional: regenerate symbol_area.S from the linked kernel ELF ----
    // Two-pass workflow: build kernel once, run nm | generate_syms.zig to
    // overwrite src/symbol_area.S, then re-run `zig build` to relink with
    // the populated table. Exposed as its own step so the default
    // build stays single-pass.
    // `grep -v 'compiler_rt\.'` drops the namespaced compiler-rt aliases
    // (e.g. `compiler_rt.aarch64_outline_atomics.__aarch64_cas16_acq_rel`,
    // 59+ chars) that overflow generate_syms.zig's fixed-width entry.
    // The short alias (`__aarch64_cas16_acq_rel`) sits at the same
    // address and survives the filter, so trace coverage is unchanged —
    // only the redundant long name is dropped.
    const populate = b.addSystemCommand(&.{
        "sh", "-c",
        "aarch64-elf-nm -n " ++
            "\"$1\" | sort | grep -v '\\$' | grep -v 'compiler_rt\\.' | " ++
            "zig run scripts/generate_syms.zig",
        "--",
    });
    populate.addArtifactArg(kernel);
    const populate_step = b.step(
        "populate-syms",
        "Regenerate src/symbol_area.S from the current kernel ELF (run `zig build` again afterwards)",
    );
    populate_step.dependOn(&populate.step);
    populate_step.dependOn(kernel_step);

    // ---- deploy: copy artifacts + RPi firmware to the SD card. ----
    // Mirrors the old `make deploy` recipe; tweak the env-var defaults below
    // for a different mount point or firmware tree. Pi-only — references
    // armstub8.bin and BCM2711 firmware blobs.
    if (board == .rpi4b) {
        const deploy = b.addSystemCommand(&.{
            "sh", "-c",
            \\set -eu
            \\: "${SD_BOOT:=/Volumes/BOOT}"
            \\: "${FIRMWARE:=firmware}"
            \\# Refuse to wipe anything that is not a mounted FAT volume: a typo'd
            \\# SD_BOOT (e.g. /Volumes or $HOME) must never reach the rm -rf below.
            \\if ! mount | grep -q " on $SD_BOOT (msdos"; then
            \\    echo "error: $SD_BOOT is not a mounted FAT32 volume — refusing to wipe it" >&2
            \\    exit 1
            \\fi
            \\rm -rf "$SD_BOOT"/*
            \\cp zig-out/kernel8.img zig-out/armstub8.bin config.txt "$SD_BOOT/"
            \\cp "$FIRMWARE/bcm2711-rpi-4-b.dtb" "$SD_BOOT/"
            \\cp "$FIRMWARE/start4.elf" "$SD_BOOT/"
            \\cp "$FIRMWARE/fixup4.dat" "$SD_BOOT/"
            \\mkdir -p "$SD_BOOT/overlays"
            \\cp "$FIRMWARE/overlays/miniuart-bt.dtbo" "$SD_BOOT/overlays/"
            \\# Re-seed the FAT32 roundtrip test files: the wipe above removed
            \\# them, and the in-kernel fs-roundtrip scenario needs both present
            \\# to run its write/verify phases (8.3 names; see scripts/format_sd.sh).
            \\dd if=/dev/zero of="$SD_BOOT/ROUNDTR.DAT" bs=4096 count=1 2>/dev/null
            \\dd if=/dev/zero of="$SD_BOOT/ROUNDTR.MAG" bs=1 count=1 2>/dev/null
            \\rm -f "$SD_BOOT"/._ROUNDTR* 2>/dev/null || true
            \\# 0-byte EMPTY.TXT for [TEST] fs-empty-write: the first write
            \\# must allocate this file's first cluster (fat32_backend.write
            \\# step 0). Stays 0 bytes until that scenario writes it.
            \\: > "$SD_BOOT/EMPTY.TXT"
            \\rm -f "$SD_BOOT"/._EMPTY* 2>/dev/null || true
            \\# Identity seeds: the writable shadow (the boot login
            \\# reads it first; passwd rewrites it) + the permission overlay
            \\# that keeps it 0600 root:root. Same bytes as the QEMU image.
            \\cp zig-out/shadow "$SD_BOOT/SHADOW"
            \\cp user_space/etc/perms.tab "$SD_BOOT/PERMS.TAB"
            \\rm -f "$SD_BOOT"/._SHADOW "$SD_BOOT"/._PERMS* 2>/dev/null || true
            \\sync
            \\diskutil eject "$SD_BOOT"
        });
        deploy.step.dependOn(all_step);
        deploy.step.dependOn(&install_shadow.step);
        const deploy_step = b.step(
            "deploy",
            "Copy kernel8.img, armstub8.bin, config.txt and RPi firmware to $SD_BOOT (default /Volumes/BOOT)",
        );
        deploy_step.dependOn(&deploy.step);
    }

    // ---- clean: blow away cache + outputs. ----
    const clean = b.addSystemCommand(&.{ "sh", "-c", "rm -rf .zig-cache zig-out" });
    const clean_step = b.step("clean", "Remove .zig-cache and zig-out");
    clean_step.dependOn(&clean.step);

    // ---- run targets — board-specific QEMU machines ----
    // `zig build -Dboard=rpi4b run` boots on `-M raspi4b` (Pi 4 model);
    // `zig build -Dboard=virt run-virt` boots on `-M virt`. Each step
    // is only registered for its board; calling `run` with virt or
    // `run-virt` with rpi4b yields a "step not found" error.
    if (board == .rpi4b) {
        // SD-card backing image for QEMU's raspi4b SDHCI peripheral.
        // scripts/make_test_disk.sh emits a
        // deterministic 64 MiB zero-filled file at zig-out/test_sd.img;
        // both raspi4b QEMU steps below depend on it and pass it via
        // `-drive if=sd,file=...,format=raw`. virt steps do NOT take
        // the flag — QEMU's `-M virt` rejects `if=sd` because the
        // machine has no SDHCI peripheral.
        const make_test_disk_cmd = b.addSystemCommand(&.{
            "sh", "scripts/make_test_disk.sh",
        });
        // Identity seeds: the generated shadow (same bytes as the
        // initramfs /etc/shadow) lands at ::/SHADOW, the permission
        // overlay at ::/PERMS.TAB — so the rpi4b QEMU target exercises
        // the writable-shadow + overlay path end to end. LazyPath args
        // also give this step its dependency on gen_shadow.
        make_test_disk_cmd.addFileArg(shadow_file);
        make_test_disk_cmd.addFileArg(b.path("user_space/etc/perms.tab"));

        const qemu_cmd = b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-M",
            "raspi4b",
            "-display",
            "none",
            "-serial", "null", // PL011 (UART4) → discarded
            "-serial", "stdio", // Mini-UART (UART1) → host stdio
            "-kernel", "zig-out/kernel8.img",
            "-drive",  "if=sd,file=zig-out/test_sd.img,format=raw",
        });
        // qemu reads zig-out/kernel8.img via a literal path string, so
        // the install step must finish before qemu launches. Without
        // this dependency, a clean tree (post `zig build clean`) races
        // qemu against the install and qemu sees no kernel image. The
        // same race exists for test_sd.img → depend on make_test_disk_cmd.
        qemu_cmd.step.dependOn(&install_kernel_img.step);
        qemu_cmd.step.dependOn(&make_test_disk_cmd.step);

        const run_step = b.step("run", "Run Flash in QEMU (raspi4b)");
        run_step.dependOn(&install_kernel_img.step); // depends on kernel8.img
        run_step.dependOn(&qemu_cmd.step);

        // Self-validating QEMU run: the watchdog tails the serial log,
        // exits 0 on `[ OK ] Reached target Shell.` (with no `[FAIL]` / `ERROR CAUGHT` and
        // the expected free-page-checkpoint counts), exits 1 on
        // `ERROR CAUGHT`, any `[FAIL]`, count drift, or timeout.
        // Same QEMU args as `run`. raspi4b is slow (~5–8 min); the
        // 720s timeout matches the historical bash-watchdog ceiling.
        const test_rpi4b_cmd = b.addSystemCommand(&.{
            "scripts/run_qemu_test.sh",
            "720",
            "qemu-system-aarch64",
            "-M",
            "raspi4b",
            "-display",
            "none",
            "-serial",
            "null",
            "-serial",
            "stdio",
            "-kernel",
            "zig-out/kernel8.img",
            "-drive",
            "if=sd,file=zig-out/test_sd.img,format=raw",
        });
        test_rpi4b_cmd.step.dependOn(&install_kernel_img.step);
        test_rpi4b_cmd.step.dependOn(&make_test_disk_cmd.step);

        const test_rpi4b_step = b.step("test-rpi4b", "Boot raspi4b in QEMU and assert the boot reaches the fsh prompt");
        test_rpi4b_step.dependOn(&test_rpi4b_cmd.step);
    }

    if (board == .virt) {
        const qemu_virt_cmd = b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-M",
            "virt,gic-version=3",
            "-cpu",
            "cortex-a72",
            "-m",
            "1G",
            "-nographic", // PL011 → host stdio (no separate -serial needed)
            "-kernel",
            "zig-out/kernel8.img",
        });
        // Same install-before-launch ordering as the rpi4b branch.
        qemu_virt_cmd.step.dependOn(&install_kernel_img.step);

        const run_virt_step = b.step("run-virt", "Run FlashOS in QEMU (virt)");
        run_virt_step.dependOn(&install_kernel_img.step);
        run_virt_step.dependOn(&qemu_virt_cmd.step);

        // Self-validating QEMU run for virt — same contract as
        // `test-rpi4b`. virt boots in seconds; 60s is generous.
        const test_virt_cmd = b.addSystemCommand(&.{
            "scripts/run_qemu_test.sh",
            "60",
            "qemu-system-aarch64",
            "-M",
            "virt,gic-version=3",
            "-cpu",
            "cortex-a72",
            "-m",
            "1G",
            "-nographic",
            "-kernel",
            "zig-out/kernel8.img",
        });
        test_virt_cmd.step.dependOn(&install_kernel_img.step);

        const test_virt_step = b.step("test-virt", "Boot virt in QEMU and assert the boot reaches the fsh prompt");
        test_virt_step.dependOn(&test_virt_cmd.step);
    }

    // ---- iso: GRUB-EFI rescue ISO for VMware Fusion / UEFI hosts ----
    // virt-only — Pi has no use for an EFI ISO since the GPU bootloader
    // chain expects a raw kernel8.img + RPi firmware. Calling
    // `zig build -Dboard=rpi4b iso` triggers the failure branch with a
    // clear message, matching the workflow doc's acceptance criterion.
    const iso_step = b.step("iso", "Build flashos.iso (board=virt only)");
    if (board == .virt) {
        const make_iso = b.addSystemCommand(&.{"scripts/make_iso.sh"});
        make_iso.step.dependOn(&install_kernel_img.step);
        iso_step.dependOn(&make_iso.step);
    } else {
        const iso_fail = b.addSystemCommand(&.{
            "sh", "-c", "echo 'iso target requires -Dboard=virt' >&2; exit 1",
        });
        iso_step.dependOn(&iso_fail.step);
    }

    // Host-side unit tests. One test target per kernel module under test
    // — the module file IS the test root, so its inline `test "…"` blocks
    // land in `builtin.test_functions`. The shared `tests/host_stubs.zig`
    // object satisfies the kernel module's `extern fn` HW-side
    // dependencies at link time. The natural alternative — a single test
    // root that imports `src/start.zig` — fails to link because
    // `start.zig` transitively pulls in assembly-only externs
    // (`set_pgd`, `ret_from_fork`, `ksyms_init`, …) that no host stub
    // can satisfy.
    const host_alloc_obj = b.addObject(.{
        .name = "host_alloc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/host_alloc.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const stubs_obj = b.addObject(.{
        .name = "host_stubs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/host_stubs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const test_step = b.step("test", "Run host-side unit tests");
    test_step.dependOn(hygiene_step);

    // Shared task_layout module — see kernel-build comment above for
    // why the named modules must share a single Module instance.
    const task_layout_test_mod = b.createModule(.{
        .root_source_file = b.path("src/task_layout.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const user_layout_test_mod = b.createModule(.{
        .root_source_file = b.path("src/user_layout.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    // Host-target alias of the pure path module so execve.zig's host
    // build can satisfy its `@import("path")`. The pure
    // joinResolve helper itself is host-tested via the standalone
    // src/path.zig target wired below.
    const path_test_mod = b.createModule(.{
        .root_source_file = b.path("src/path.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    // Host-target alias of the shared ABI file so vfs.zig's host build
    // can satisfy its `@import("syscall_defs")` for the Dirent type
    // Pure comptime constants — no externs, no stubs.
    const syscall_defs_test_mod = b.createModule(.{
        .root_source_file = b.path("lib/syscall_defs.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const fork_stubs_mod = b.createModule(.{
        .root_source_file = b.path("tests/fork_stubs.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    fork_stubs_mod.addImport("task_layout", task_layout_test_mod);

    const host_stubs_fork_mod = b.createModule(.{
        .root_source_file = b.path("tests/host_stubs_fork.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    host_stubs_fork_mod.addImport("task_layout", task_layout_test_mod);

    // execve.zig — argv-block encoder host coverage. Pure
    // layout function, no externs, so no stubs. The returned Module is
    // reused as the fork.zig test target's "execve" import — fork.zig
    // names execve.ArgvBlock in prepare_move_to_user_elf_argv. The
    // `path` import is satisfied even on host because the file
    // top-level @imports the module unconditionally; the kernel-only
    // join site sits behind the comptime is_kernel guard.
    const execve_test_mod = addHostTest(b, test_step, .{
        .src = "src/execve.zig",
        .imports = &.{.{ .name = "path", .mod = path_test_mod }},
    });

    // path.zig — cwd-aware path-resolution host coverage.
    // Pure joinResolve: no externs, no stubs. The freestanding kernel
    // and the host test exercise the same source through the `path`
    // module wired above.
    _ = addHostTest(b, test_step, .{ .src = "src/path.zig" });

    // trace/fp_walk.zig — the -Dtrace sampler's AAPCS64 frame-pointer
    // chain decoder. Pure `walkChain` over a flat stack-page view (no
    // kernel externs), so the FP-record math + the bounds/alignment/
    // monotonic guards are host-verified deterministically. The live
    // sampler only fires on real-Pi async timer ticks, so this is the
    // decode-correctness gate; no stubs, no imports.
    _ = addHostTest(b, test_step, .{ .src = "src/trace/fp_walk.zig" });

    // flibc readline.zig — line-editor state-machine host coverage.
    // Pure `step` transition + `State` buffer; the SVC
    // driver sits behind a comptime `has_driver` gate so the host
    // build never analyses inline asm. No stubs, no imports.
    _ = addHostTest(b, test_step, .{ .src = "user_space/lib/flibc/readline.zig" });

    // flibc execvp.zig — bare-name → `/bin/<name>` resolver host
    // coverage. Pure `resolve` path-build; the SVC driver
    // sits behind the same `has_driver` gate as readline.
    _ = addHostTest(b, test_step, .{ .src = "user_space/lib/flibc/execvp.zig" });

    // fsh tokenize.zig — whitespace splitter + single-`|` split host
    // coverage. Pure `tokenize`: fills a caller argv array
    // from a line + scratch buffer; no externs, no stubs, no SVC.
    _ = addHostTest(b, test_step, .{ .src = "user_space/fsh/tokenize.zig" });

    // flibc keys.zig — VT100 input Decoder host coverage (arrows / ctrl / tab).
    // Pure `Decoder.feed`; the SVC readKey driver sits behind the same
    // has_driver gate as readline. No stubs, no imports.
    _ = addHostTest(b, test_step, .{ .src = "user_space/lib/flibc/keys.zig" });

    // flibc completion.zig — tab-completion core host coverage (parse,
    // hasPrefix, commonPrefixLen). Pure; the readdir-driven gathering lives in
    // readline's driver. No stubs, no imports.
    _ = addHostTest(b, test_step, .{ .src = "user_space/lib/flibc/completion.zig" });

    // console_ui screen.zig — panel / kv / cursor renderer host coverage.
    // Pure Sink emitters; imports palette.zig (sibling) only. No stubs.
    _ = addHostTest(b, test_step, .{ .src = "lib/console_ui/screen.zig" });

    // flibc pager.zig — pure scroll / line-index core host coverage (init line
    // indexing, line slicing, scroll clamping). The screen.enter + readKey
    // driver lives in tools/less_elf.zig. No stubs, no imports.
    _ = addHostTest(b, test_step, .{ .src = "user_space/lib/flibc/pager.zig" });

    // virt DTB parser — pure big-endian FDT decode + bounds guards.
    // The handoff entry (`fromHandoff`) reads the `dtb_pa` extern and the
    // linear map, so it stays kernel-only; the tests build a `Dtb` over a
    // hand-written blob and exercise findNode/getProp/findReg/findInterrupt
    // plus the corrupt-length guard. Imports only std → no stubs.
    _ = addHostTest(b, test_step, .{ .src = "src/board/virt/dtb.zig" });

    const fork_test_mod = addHostTest(b, test_step, .{
        .src = "src/fork.zig",
        .stubs = b.addObject(.{
            .name = "host_stubs_fork",
            .root_module = host_stubs_fork_mod,
        }),
        .imports = &.{
            .{ .name = "task_layout", .mod = task_layout_test_mod },
            .{ .name = "user_layout", .mod = user_layout_test_mod },
            .{ .name = "fdtable", .mod = fork_stubs_mod },
            .{ .name = "execve", .mod = execve_test_mod },
        },
    });
    // fork.zig top-level @imports build_options for the verbose-fork gate;
    // the kernel build gets it via kernel_mod, the host test needs it wired
    // explicitly since this module is built standalone.
    fork_test_mod.addOptions("build_options", build_options);

    const mm_user_stubs_mod = b.createModule(.{
        .root_source_file = b.path("tests/host_stubs_mm_user.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    mm_user_stubs_mod.addImport("task_layout", task_layout_test_mod);
    _ = addHostTest(b, test_step, .{
        .src = "src/mm_user.zig",
        .stubs = b.addObject(.{
            .name = "host_stubs_mm_user",
            .root_module = mm_user_stubs_mod,
        }),
        .imports = &.{
            .{ .name = "task_layout", .mod = task_layout_test_mod },
            .{ .name = "user_layout", .mod = user_layout_test_mod },
        },
    });

    // vanilla single-module test targets — shared stubs, no named imports.
    _ = addHostTest(b, test_step, .{ .src = "src/page_alloc.zig", .stubs = stubs_obj });
    _ = addHostTest(b, test_step, .{
        .src = "src/elf.zig",
        .stubs = stubs_obj,
        .imports = &.{.{ .name = "user_layout", .mod = user_layout_test_mod }},
    });

    // wait_queue is its own test target AND the named module pipe.zig
    // imports — capture the helper's returned Module so the pipe call
    // below can plug it back in as the "wait_queue" import.
    const wq_test_mod = addHostTest(b, test_step, .{
        .src = "src/wait_queue.zig",
        .stubs = stubs_obj,
        .imports = &.{.{ .name = "task_layout", .mod = task_layout_test_mod }},
    });

    // pipe.zig pulls in wait_queue + task_layout as named modules + its
    // own page-allocator stub so it doesn't double-define get_free_page
    // / free_page against the page_alloc test target. stubs_obj is
    // already pulled in transitively via wq_test_mod, so omitting it
    // from `stubs` here keeps the host stubs single-defined.
    _ = addHostTest(b, test_step, .{
        .src = "src/pipe.zig",
        .extra_stubs = &.{host_alloc_obj},
        .imports = &.{
            .{ .name = "wait_queue", .mod = wq_test_mod },
            .{ .name = "task_layout", .mod = task_layout_test_mod },
        },
    });

    // console.zig — ring + WaitQueue host coverage.
    // Same wiring as pipe.zig minus the page allocator (ring is BSS,
    // shared stubs_obj alone suffices). stubs_obj arrives transitively
    // via wq_test_mod, so the helper's `stubs` field stays unset.
    _ = addHostTest(b, test_step, .{
        .src = "src/console.zig",
        .imports = &.{
            .{ .name = "wait_queue", .mod = wq_test_mod },
            .{ .name = "task_layout", .mod = task_layout_test_mod },
        },
    });

    // sched.zig — pure-helper host coverage. sched.zig
    // itself exports current / preempt_disable / preempt_enable /
    // schedule, so the shared stubs_obj would double-define those at
    // link time. Dedicated sched-stub object plugs only the HW-side gap
    // (core_switch_to, set_pgd, irq_*, free_page*, _schedule) plus a
    // null get_free_page for the transitively-imported pipe module.
    const sched_stubs_obj = b.addObject(.{
        .name = "host_stubs_sched",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/host_stubs_sched.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    // Dedicated wait_queue / pipe Modules for the sched test target —
    // can't reuse the helper-built wq_test_mod (which carries stubs_obj)
    // or a pipe equivalent (which would carry pipe_stubs_obj) because
    // either path re-introduces same-symbol collisions against
    // sched_stubs_obj. Hand-build a stub-free chain instead.
    const wq_sched_mod = b.createModule(.{
        .root_source_file = b.path("src/wait_queue.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    wq_sched_mod.addImport("task_layout", task_layout_test_mod);
    const pipe_sched_mod = b.createModule(.{
        .root_source_file = b.path("src/pipe.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    pipe_sched_mod.addImport("wait_queue", wq_sched_mod);
    pipe_sched_mod.addImport("task_layout", task_layout_test_mod);
    // file_sched_mod — same stub-free pattern as pipe_sched_mod above.
    // sched.zig imports `file` for the do_wait_impl reap plumbing;
    // sched_stubs_obj already provides the
    // get_free_page / free_page / preempt_* externs file.zig needs.
    const file_sched_mod = b.createModule(.{
        .root_source_file = b.path("src/file.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    file_sched_mod.addImport("task_layout", task_layout_test_mod);

    const fdtable_sched_mod = b.createModule(.{
        .root_source_file = b.path("src/fdtable.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    fdtable_sched_mod.addImport("task_layout", task_layout_test_mod);
    fdtable_sched_mod.addImport("pipe", pipe_sched_mod);
    fdtable_sched_mod.addImport("file", file_sched_mod);

    _ = addHostTest(b, test_step, .{
        .src = "src/sched.zig",
        .stubs = sched_stubs_obj,
        .imports = &.{
            .{ .name = "task_layout", .mod = task_layout_test_mod },
            .{ .name = "fdtable", .mod = fdtable_sched_mod },
        },
    });

    // initramfs.zig — newc cpio parser. Pure data parser with no externs
    // in host builds — the shared stubs_obj is
    // linked for parity with the other test targets, not because the
    // module needs it.
    _ = addHostTest(b, test_step, .{
        .src = "src/initramfs.zig",
        .stubs = stubs_obj,
    });

    // file.zig — File handle helpers. Same shape as pipe.zig: dedicated
    // per-target stub so the bump
    // allocator's get_free_page / free_page don't clash with the
    // page_alloc test target's real allocator. The stub additionally
    // ships a typed `current: ?*TaskStruct` (instead of the shared
    // host_stubs.zig's `?*anyopaque`) so future initramfs/file tests
    // can reach into `current.open_files` directly — see
    // the post-mortem doc for why this is a new per-target stub
    // file rather than a widening of
    // host_stubs.zig. Both this stub's module and the file.zig test
    // module share `task_layout_test_mod` so the `?*TaskStruct` type
    // matches at link time.
    const file_stubs_mod = b.createModule(.{
        .root_source_file = b.path("tests/host_stubs_initramfs.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    file_stubs_mod.addImport("task_layout", task_layout_test_mod);
    const file_stubs_obj = b.addObject(.{
        .name = "host_stubs_initramfs",
        .root_module = file_stubs_mod,
    });
    _ = addHostTest(b, test_step, .{
        .src = "src/file.zig",
        .stubs = file_stubs_obj,
        .extra_stubs = &.{host_alloc_obj},
        .imports = &.{.{ .name = "task_layout", .mod = task_layout_test_mod }},
    });

    // vfs.zig — VFS dispatch layer. vfs.zig imports the
    // `file` named module for the `File` type its vtable signatures
    // reference; a dedicated stub-free file module (same pattern as
    // file_sched_mod above) shares task_layout_test_mod so the File
    // type matches at link, and vfs_stubs_obj plugs file.zig's
    // get_free_page / free_page / preempt_* externs.
    const file_test_mod = b.createModule(.{
        .root_source_file = b.path("src/file.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    file_test_mod.addImport("task_layout", task_layout_test_mod);

    _ = addHostTest(b, test_step, .{
        .src = "src/fdtable.zig",
        .stubs = file_stubs_obj,
        .extra_stubs = &.{host_alloc_obj},
        .imports = &.{
            .{ .name = "task_layout", .mod = task_layout_test_mod },
            .{ .name = "pipe", .mod = pipe_sched_mod },
            .{ .name = "file", .mod = file_test_mod },
        },
    });
    const vfs_stubs_obj = b.addObject(.{
        .name = "host_stubs_vfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/host_stubs_vfs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    _ = addHostTest(b, test_step, .{
        .src = "src/vfs.zig",
        .stubs = vfs_stubs_obj,
        .extra_stubs = &.{host_alloc_obj},
        .imports = &.{
            .{ .name = "file", .mod = file_test_mod },
            .{ .name = "syscall_defs", .mod = syscall_defs_test_mod },
        },
    });

    // sdhci_cmd.zig — pure-data SDHCI command encoder + CSD parser.
    // No externs, no fixture state.
    _ = addHostTest(b, test_step, .{ .src = "src/sdhci_cmd.zig" });

    // mailbox.zig — pure-data VideoCore property-tag builder + parser.
    // No externs; the MMIO doorbell lives in
    // src/board/rpi4b/mailbox.zig.
    _ = addHostTest(b, test_step, .{ .src = "src/mailbox.zig" });

    // usb_descriptors.zig — byte-exact USB descriptor set + SETUP decode
    // (DWC2 gadget). No externs; pure data + pure functions.
    _ = addHostTest(b, test_step, .{ .src = "src/usb_descriptors.zig" });

    // usb_tx_ring.zig — bulk-IN TX byte-ring (DWC2 gadget).
    // No externs; pure ring arithmetic (push/peek/advance/clear).
    _ = addHostTest(b, test_step, .{ .src = "src/usb_tx_ring.zig" });

    // klog_ring.zig — kernel-log byte-ring (overwrite-oldest) host coverage.
    // Pure ring arithmetic (push / overwrite-oldest / snapshot);
    // imports syscall_defs only for KLOG_SIZE. The returned Module is reused
    // as the utilc.zig test target's "klog_ring" import (utilc tees
    // main_output into the ring), mirroring how wait_queue's test module
    // doubles as pipe's import.
    const klog_ring_test_mod = addHostTest(b, test_step, .{
        .src = "src/klog_ring.zig",
        .imports = &.{.{ .name = "syscall_defs", .mod = syscall_defs_test_mod }},
    });

    // fat32.zig — FAT32 on-disk layout decode.
    // Pure data module: imports only the host-only block_dev Module
    // (BlockDev type), uses an in-memory 64 KiB fake disk built by the
    // inline test fixture. No page-alloc or task-layout externs needed.
    const block_dev_test_mod = b.createModule(.{
        .root_source_file = b.path("src/block_dev.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    _ = addHostTest(b, test_step, .{
        .src = "src/fat32.zig",
        .imports = &.{.{ .name = "block_dev", .mod = block_dev_test_mod }},
    });

    // fat32_backend.zig — FAT32 VFS backend host-test. Asserts the
    // sub-sector splice contract that write():203-208 fulfills. See
    // the comment block at the end of
    // src/fat32_backend.zig for the bug-class link and the
    // ReleaseSmall reproducibility note. Created modules for fat32
    // and vfs because the kernel-side fat32_mod / vfs_mod are wired
    // for aarch64 freestanding, not host.
    const fat32_for_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/fat32.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    fat32_for_backend_mod.addImport("block_dev", block_dev_test_mod);

    const vfs_for_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/vfs.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    vfs_for_backend_mod.addImport("file", file_test_mod);
    vfs_for_backend_mod.addImport("syscall_defs", syscall_defs_test_mod);

    // overlay.zig — FAT32 permission-overlay parser host coverage.
    // Pure parse/lookup truth table — the gate for the /mnt overlay: the
    // fat32_backend wiring (applyOverlay + open lookup) does not ship until
    // every row passes. The returned Module doubles as fat32_backend's
    // "overlay" import below (mirroring the klog_ring/utilc pattern). Pins
    // the format shared with the seed file (user_space/etc/perms.tab) and
    // the deploy / make_test_disk seeding.
    const overlay_test_mod = addHostTest(b, test_step, .{ .src = "src/overlay.zig" });

    _ = addHostTest(b, test_step, .{
        .src = "src/fat32_backend.zig",
        .stubs = vfs_stubs_obj,
        .imports = &.{
            .{ .name = "block_dev", .mod = block_dev_test_mod },
            .{ .name = "fat32", .mod = fat32_for_backend_mod },
            .{ .name = "vfs", .mod = vfs_for_backend_mod },
            .{ .name = "file", .mod = file_test_mod },
            .{ .name = "overlay", .mod = overlay_test_mod },
        },
    });

    _ = addHostTest(b, test_step, .{
        .src = "src/initramfs_backend.zig",
        .stubs = stubs_obj,
        .imports = &.{
            .{ .name = "initramfs", .mod = b.createModule(.{
                .root_source_file = b.path("src/initramfs.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }) },
            .{ .name = "vfs", .mod = vfs_for_backend_mod },
            .{ .name = "file", .mod = file_test_mod },
        },
    });

    // utilc.zig — kernel utility host coverage.
    // Trivial hex/mem helpers; stubs provided for board-specific UARTs.
    const utilc_stubs_obj = b.addObject(.{
        .name = "host_stubs_utilc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/host_stubs_utilc.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    _ = addHostTest(b, test_step, .{
        .src = "src/utilc.zig",
        .stubs = utilc_stubs_obj,
        .imports = &.{
            .{ .name = "task_layout", .mod = task_layout_test_mod },
            // utilc.main_output now tees into the kernel log ring; the host
            // test build needs the same module the kernel build wires.
            .{ .name = "klog_ring", .mod = klog_ring_test_mod },
        },
    });

    // sha256.zig — SHA-256 / HMAC-SHA256 / PBKDF2-HMAC-SHA256 host coverage.
    // Pure compute, no externs, no imports, no allocation. The
    // vector tests (NIST FIPS 180-2, RFC 4231, the published PBKDF2 set,
    // plus std.crypto differentials) are the gate for the authentication
    // work: no kernel consumer of these primitives ships until they pass.
    _ = addHostTest(b, test_step, .{ .src = "src/sha256.zig" });

    // shadow.zig — /etc/shadow line parser + hex decoder. Pure,
    // no imports; pins the format shared by sys_authenticate + gen_shadow.
    _ = addHostTest(b, test_step, .{ .src = "src/shadow.zig" });

    // perm.zig — VFS permission check host coverage. Pure
    // checkAccess truth table (owner/group/other × read/write/exec ×
    // root bypass) — the gate for the permission layer: no enforcement
    // site ships until every row passes.
    _ = addHostTest(b, test_step, .{ .src = "src/perm.zig" });

    // pwfile.zig — /etc/passwd parser host coverage. Pure
    // name/uid lookups shared by sys_passwd (kernel), /bin/login, and
    // fsh's whoami builtin; pins the 5-field format against
    // user_space/etc/passwd.
    _ = addHostTest(b, test_step, .{ .src = "src/pwfile.zig" });

    // build_initramfs.zig — newc encoder host coverage. Pins the
    // mode/uid/gid byte offsets shared with the kernel parser
    // (src/initramfs.zig); an encoder/parser drift here would be a silent
    // permission bypass.
    _ = addHostTest(b, test_step, .{ .src = "scripts/build_initramfs.zig" });

    // hwrng.zig — kernel entropy source host coverage. The pure
    // SplitMix64 mixer is vector- and differential-tested; the kernel glue
    // (fill / hwrng_init) runs against host_stubs' ramping get_sys_count,
    // so the boot self-test + announce path is exercised end-to-end.
    _ = addHostTest(b, test_step, .{
        .src = "src/hwrng.zig",
        .stubs = stubs_obj,
        .imports = &.{.{ .name = "console_ui", .mod = console_ui_mod }},
    });
}
