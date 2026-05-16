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
    imports: []const struct {
        name: []const u8,
        mod: *std.Build.Module,
    } = &.{},
};

fn addHostTest(b: *std.Build, step: *std.Build.Step, cfg: HostTest) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(cfg.src),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    if (cfg.stubs) |s| m.addObject(s);
    for (cfg.imports) |imp| m.addImport(imp.name, imp.mod);
    const t = b.addTest(.{ .root_module = m });
    step.dependOn(&b.addRunArtifact(t).step);
    return m;
}

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });
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

    // User-space virtual address layout (text/data/heap/stack bases +
    // per-region permission bits). Kernel-only consumer for now —
    // src/fork.zig (prepare_move_to_user) and src/mm_user.zig
    // (map_page, do_data_abort) share the constants. Same module-level
    // exposure pattern as syscall_defs_mod.
    const user_layout_mod = b.createModule(.{
        .root_source_file = b.path("src/user_layout.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TaskStruct/CoreContext/etc. layout module. Already implicitly
    // imported by kernel-root modules via `@import("task_layout.zig")`,
    // but the v0.3.0 named modules (wait_queue, pipe) need
    // an explicit named import to keep task_layout.zig from being
    // pulled into two sibling named modules through relative paths
    // (which Zig 0.16 rejects as "file exists in two modules").
    const task_layout_mod = b.createModule(.{
        .root_source_file = b.path("src/task_layout.zig"),
        .target = target,
        .optimize = optimize,
    });

    // WaitQueue API (v0.3.0). Named module so both kernel and
    // host-test builds reach it via `@import("wait_queue")` — the host
    // test wiring at the bottom of this file mirrors this for the
    // pipe.zig test root.
    const wait_queue_mod = b.createModule(.{
        .root_source_file = b.path("src/wait_queue.zig"),
        .target = target,
        .optimize = optimize,
    });
    wait_queue_mod.addImport("task_layout", task_layout_mod);

    // Anonymous-pipe module (v0.3.0). Pulls in wait_queue for
    // the blocking read/write paths; kernel-only for now (future work
    // generalises to a tagged ?*File once the FS lands).
    const pipe_mod = b.createModule(.{
        .root_source_file = b.path("src/pipe.zig"),
        .target = target,
        .optimize = optimize,
    });
    pipe_mod.addImport("wait_queue", wait_queue_mod);
    pipe_mod.addImport("task_layout", task_layout_mod);

    // Initramfs parser module (v0.4.0). Pure-data newc cpio
    // walker with linker-provided section bounds; no external imports
    // needed in freestanding (the host-test build flips a comptime
    // branch onto fixture globals — see src/initramfs.zig).
    const initramfs_mod = b.createModule(.{
        .root_source_file = b.path("src/initramfs.zig"),
        .target = target,
        .optimize = optimize,
    });

    // File handle module (v0.4.0). Owns the open_files
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

    // VFS dispatch layer (v0.4.0). 1-bit superblock tag +
    // two-slot mount table; imports `file` for the File type its
    // vtable signatures reference. Host-test wiring for vfs.zig lives
    // at the bottom of this file.
    const vfs_mod = b.createModule(.{
        .root_source_file = b.path("src/vfs.zig"),
        .target = target,
        .optimize = optimize,
    });
    vfs_mod.addImport("file", file_mod);

    // Initramfs VFS backend (v0.4.0). Thin wrapper turning
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

    // Block-device abstraction (v0.4.0). Single global
    // `sd_dev` vtable that the FAT32 backend reads + writes
    // through; the board layer (src/board/<board>/emmc2.zig)
    // populates `read_fn` / `write_fn` post-init. No tests
    // (pure data + one extern struct).
    const block_dev_mod = b.createModule(.{
        .root_source_file = b.path("src/block_dev.zig"),
        .target = target,
        .optimize = optimize,
    });

    // SDHCI command encoder + CSD parser (v0.4.0).
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

    // VideoCore mailbox — property-tag message construction + parsing
    // (v0.4.0). Pure data; the rpi4b board side
    // (src/board/rpi4b/mailbox.zig) wraps it with the MMIO doorbell so
    // the EMMC2 driver can read the firmware-set base clock and derive
    // a safe SDHCI divider. Host tests build a separate test-only
    // Module from the same source.
    const mailbox_mod = b.createModule(.{
        .root_source_file = b.path("src/mailbox.zig"),
        .target = target,
        .optimize = optimize,
    });

    // FAT32 on-disk layout decode + cluster/FAT/dir helpers (v0.4.0).
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

    // FAT32 VFS backend (v0.4.0). Wraps fat32.zig's
    // on-disk decode in the real VfsOps vtable; replaces the earlier
    // fat32_stub. read + write paths live since v0.4.0.
    const fat32_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/fat32_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    fat32_backend_mod.addImport("fat32", fat32_mod);
    fat32_backend_mod.addImport("vfs", vfs_mod);
    fat32_backend_mod.addImport("file", file_mod);
    fat32_backend_mod.addImport("block_dev", block_dev_mod);

    // Console RX layer (v0.3.0). 256-byte ring + WaitQueue
    // backing sys_readConsole. Same named-module wiring as wait_queue
    // / pipe so the kernel build and the host-test build share one
    // task_layout Module instance.
    const console_mod = b.createModule(.{
        .root_source_file = b.path("src/console.zig"),
        .target = target,
        .optimize = optimize,
    });
    console_mod.addImport("wait_queue", wait_queue_mod);
    console_mod.addImport("task_layout", task_layout_mod);

    // Scheduler module (v0.3.0). Promoted from a relative-path
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
    sched_mod.addImport("pipe", pipe_mod);
    sched_mod.addImport("file", file_mod);

    // ---- kernel executable ----
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/start.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false, // keep symbols so `populate-syms` can nm the ELF
        .unwind_tables = .none,
    });
    const kernel = b.addExecutable(.{
        .name = "kernel8.elf",
        .root_module = kernel_mod,
    });

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

    kernel_mod.addOptions("build_options", build_options);
    kernel_mod.addImport("syscall_defs", syscall_defs_mod);
    kernel_mod.addImport("user_layout", user_layout_mod);
    kernel_mod.addImport("task_layout", task_layout_mod);
    kernel_mod.addImport("wait_queue", wait_queue_mod);
    kernel_mod.addImport("pipe", pipe_mod);
    kernel_mod.addImport("console", console_mod);
    kernel_mod.addImport("sched", sched_mod);
    kernel_mod.addImport("initramfs", initramfs_mod);
    kernel_mod.addImport("file", file_mod);
    kernel_mod.addImport("vfs", vfs_mod);
    kernel_mod.addImport("initramfs_backend", initramfs_backend_mod);
    kernel_mod.addImport("fat32_backend", fat32_backend_mod);
    kernel_mod.addImport("fat32", fat32_mod);
    kernel_mod.addImport("block_dev", block_dev_mod);
    kernel_mod.addImport("sdhci_cmd", sdhci_cmd_mod);
    kernel_mod.addImport("mailbox", mailbox_mod);

    // ---- hello.elf — payload for [TEST] exec-elf ----
    // Built as a standalone aarch64-freestanding ET_EXEC, staged into
    // the initramfs at /test/hello.elf (v0.4.0). The
    // exec-elf scenario opens it via sys_openFile, reads it into an
    // EL0 buffer, and hands the bytes to sys_exec — the v0.3.0
    // kernel-rodata .incbin embedding + .text.user bridge slots are
    // retired.
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
    // through to a one-segment ELF that fits inside sys_exec's
    // PAGE_SIZE snapshot cap.
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

    // ---- pid1.elf — the ELF-loaded PID 1 (v0.4.0) ----
    // Replaces the v0.3.0 user_init.o blob. Instead of compiling
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
    // loaded by kernel_process directly, not through sys_exec, so it
    // is NOT bound by sys_exec's PAGE_SIZE snapshot cap — prepare_
    // move_to_user_elf walks the PT_LOAD page by page.
    const pid1_mod = b.createModule(.{
        .root_source_file = b.path("user_space/init_main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    pid1_mod.addImport("syscall_defs", syscall_defs_mod);
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

    // ---- initramfs.cpio (v0.4.0) ----
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
    const initramfs_arcs = [_][]const u8{
        "sbin/init",
        "test/flibc_demo.elf",
        "test/hello.elf",
        "test/stackbomb.elf",
    };

    const cpio_cmd = b.addRunArtifact(initramfs_encoder);
    const initramfs_bin = cpio_cmd.addOutputFileArg("initramfs.cpio");
    cpio_cmd.addDirectoryArg(cpio_stage.getDirectory());
    for (initramfs_arcs) |arc| cpio_cmd.addArg(arc);

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
    // the populated table. We expose this as its own step so the default
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

    // ---- deploy: copy artifacts + RPi firmware to the SD card. ----
    // Mirrors the old `make deploy` recipe; tweak the env-var defaults below
    // for a different mount point or firmware tree. Pi-only — references
    // armstub8.bin and BCM2711 firmware blobs.
    if (board == .rpi4b) {
        const deploy = b.addSystemCommand(&.{
            "sh", "-c",
            \\set -eu
            \\: "${SD_BOOT:=/Volumes/FLASH}"
            \\: "${FIRMWARE:=$HOME/rpi_firmware}"
            \\rm -rf "$SD_BOOT"/*
            \\cp zig-out/kernel8.img zig-out/armstub8.bin config.txt "$SD_BOOT/"
            \\cp "$FIRMWARE/bcm2711-rpi-4-b.dtb" "$SD_BOOT/"
            \\cp "$FIRMWARE/start4.elf" "$SD_BOOT/"
            \\cp "$FIRMWARE/fixup4.dat" "$SD_BOOT/"
            \\mkdir -p "$SD_BOOT/overlays"
            \\cp "$FIRMWARE/overlays/miniuart-bt.dtbo" "$SD_BOOT/overlays/"
            \\sync
            \\diskutil eject "$SD_BOOT"
        });
        deploy.step.dependOn(all_step);
        const deploy_step = b.step(
            "deploy",
            "Copy kernel8.img, armstub8.bin, config.txt and RPi firmware to $SD_BOOT (default /Volumes/FLASH)",
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
        // SD-card backing image for QEMU's raspi4b SDHCI peripheral
        // (v0.4.0). scripts/make_test_disk.sh emits a
        // deterministic 64 MiB zero-filled file at zig-out/test_sd.img;
        // both raspi4b QEMU steps below depend on it and pass it via
        // `-drive if=sd,file=...,format=raw`. virt steps do NOT take
        // the flag — QEMU's `-M virt` rejects `if=sd` because the
        // machine has no SDHCI peripheral.
        const make_test_disk_cmd = b.addSystemCommand(&.{
            "sh", "scripts/make_test_disk.sh",
        });

        const qemu_cmd = b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-M",
            "raspi4b",
            "-display",
            "none",
            "-serial", "null", // PL011 (UART4) → discarded
            "-serial", "stdio", // Mini-UART (UART1) → host stdio
            "-kernel", "zig-out/kernel8.img",
            "-drive", "if=sd,file=zig-out/test_sd.img,format=raw",
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
        // exits 0 on `14/14 passed` (with the expected free-page-checkpoint
        // counts), exits 1 on `ERROR CAUGHT`, count drift, or timeout.
        // Same QEMU args as `run`. raspi4b is slow (~5–8 min); the
        // 720s timeout matches the historical bash-watchdog ceiling.
        const test_rpi4b_cmd = b.addSystemCommand(&.{
            "scripts/run_qemu_test.sh",
            "720",
            "qemu-system-aarch64",
            "-M",       "raspi4b",
            "-display", "none",
            "-serial",  "null",
            "-serial",  "stdio",
            "-kernel",  "zig-out/kernel8.img",
            "-drive",   "if=sd,file=zig-out/test_sd.img,format=raw",
        });
        test_rpi4b_cmd.step.dependOn(&install_kernel_img.step);
        test_rpi4b_cmd.step.dependOn(&make_test_disk_cmd.step);

        const test_rpi4b_step = b.step("test-rpi4b", "Boot raspi4b in QEMU and assert 14/14 passed");
        test_rpi4b_step.dependOn(&test_rpi4b_cmd.step);
    }

    if (board == .virt) {
        const qemu_virt_cmd = b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-M",         "virt,gic-version=3",
            "-cpu",       "cortex-a72",
            "-m",         "1G",
            "-nographic", // PL011 → host stdio (no separate -serial needed)
            "-kernel",    "zig-out/kernel8.img",
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
            "-M",         "virt,gic-version=3",
            "-cpu",       "cortex-a72",
            "-m",         "1G",
            "-nographic",
            "-kernel",    "zig-out/kernel8.img",
        });
        test_virt_cmd.step.dependOn(&install_kernel_img.step);

        const test_virt_step = b.step("test-virt", "Boot virt in QEMU and assert 14/14 passed");
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
    const stubs_obj = b.addObject(.{
        .name = "host_stubs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/host_stubs.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const test_step = b.step("test", "Run host-side unit tests");

    // Shared task_layout module — see kernel-build comment above for
    // why the v0.3.0 named modules must share a single Module instance.
    const task_layout_test_mod = b.createModule(.{
        .root_source_file = b.path("src/task_layout.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    // Vanilla single-module test targets — shared stubs, no named imports.
    _ = addHostTest(b, test_step, .{ .src = "src/page_alloc.zig", .stubs = stubs_obj });
    _ = addHostTest(b, test_step, .{ .src = "src/elf.zig", .stubs = stubs_obj });

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
    const pipe_stubs_obj = b.addObject(.{
        .name = "host_stubs_pipe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/host_stubs_pipe.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    _ = addHostTest(b, test_step, .{
        .src = "src/pipe.zig",
        .stubs = pipe_stubs_obj,
        .imports = &.{
            .{ .name = "wait_queue", .mod = wq_test_mod },
            .{ .name = "task_layout", .mod = task_layout_test_mod },
        },
    });

    // console.zig — ring + WaitQueue host coverage (v0.3.0).
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

    // sched.zig — pure-helper host coverage (v0.3.0). sched.zig
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
    // sched.zig imports `file` for the do_wait_impl reap plumbing
    // (v0.4.0); sched_stubs_obj already provides the
    // get_free_page / free_page / preempt_* externs file.zig needs.
    const file_sched_mod = b.createModule(.{
        .root_source_file = b.path("src/file.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    file_sched_mod.addImport("task_layout", task_layout_test_mod);
    _ = addHostTest(b, test_step, .{
        .src = "src/sched.zig",
        .stubs = sched_stubs_obj,
        .imports = &.{
            .{ .name = "task_layout", .mod = task_layout_test_mod },
            .{ .name = "pipe", .mod = pipe_sched_mod },
            .{ .name = "file", .mod = file_sched_mod },
        },
    });

    // initramfs.zig — newc cpio parser (v0.4.0). Pure data
    // parser with no externs in host builds — the shared stubs_obj is
    // linked for parity with the other test targets, not because the
    // module needs it.
    _ = addHostTest(b, test_step, .{
        .src = "src/initramfs.zig",
        .stubs = stubs_obj,
    });

    // file.zig — File handle helpers (v0.4.0). Same
    // shape as pipe.zig: dedicated per-target stub so the bump
    // allocator's get_free_page / free_page don't clash with the
    // page_alloc test target's real allocator. The stub additionally
    // ships a typed `current: ?*TaskStruct` (instead of the shared
    // host_stubs.zig's `?*anyopaque`) so future initramfs/file tests
    // can reach into `current.open_files` directly — see
    // post_mortem_v0.3.0.md for why this is a new per-target stub
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
        .imports = &.{.{ .name = "task_layout", .mod = task_layout_test_mod }},
    });

    // vfs.zig — VFS dispatch layer (v0.4.0). vfs.zig imports the
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
        .imports = &.{.{ .name = "file", .mod = file_test_mod }},
    });

    // sdhci_cmd.zig — pure-data SDHCI command encoder + CSD parser
    // (v0.4.0). No externs, no fixture state.
    _ = addHostTest(b, test_step, .{ .src = "src/sdhci_cmd.zig" });

    // mailbox.zig — pure-data VideoCore property-tag builder + parser
    // (v0.4.0). No externs; the MMIO doorbell lives in
    // src/board/rpi4b/mailbox.zig.
    _ = addHostTest(b, test_step, .{ .src = "src/mailbox.zig" });

    // fat32.zig — FAT32 on-disk layout decode (v0.4.0).
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
}
