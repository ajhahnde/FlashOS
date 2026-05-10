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
//   * user_space/init.zig             — user-space PID 1 image (linked into .text.user)
//   * src/board/<board>/linker.ld     — per-board link script wrapping the
//                                       user image with user_start / user_end
//
// The build produces:
//   * kernel8.img — raw binary loaded by the GPU bootloader (or QEMU `-kernel`)
//   * armstub8.bin — small EL3→EL1 bootstrap shim (rpi4b only)
//
// Optional `populate-syms` step runs nm on the linked ELF, regenerates
// src/symbol_area.S via scripts/generate_syms.zig, then relinks so the
// trace/ksyms machinery has a real symbol table to look up.

const Board = enum { rpi4b, virt };

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

    // ---- user-space image (compiled separately so we can match its
    // object file from the linker script as `*user_init*.o`) ----
    const user_init_mod = b.createModule(.{
        .root_source_file = b.path("user_space/init.zig"),
        .target = target,
        .optimize = optimize,
    });
    user_init_mod.addImport("syscall_defs", syscall_defs_mod);
    const user_init = b.addObject(.{
        .name = "user_init",
        .root_module = user_init_mod,
    });

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

    kernel_mod.addObject(user_init);
    kernel_mod.addOptions("build_options", build_options);
    kernel_mod.addImport("syscall_defs", syscall_defs_mod);
    kernel_mod.addImport("user_layout", user_layout_mod);

    // ---- hello.elf — payload for [TEST] exec-elf ----
    // Built as a standalone aarch64-freestanding ET_EXEC, embedded into
    // the kernel image via .incbin in tools/hello_elf.S. The user-side
    // harness reads its kernel-VA + size through bridge u64s baked into
    // .text.user (see user_space/kernel_tests.zig _hello_elf_bridge),
    // so the EL0 caller doesn't need to know the link-time layout.
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

    // Stage the built ELF into a directory the assembler can `-I` so
    // tools/hello_elf.S's `.incbin "hello.elf"` resolves regardless of
    // CWD. addWriteFiles + addIncludePath transitively schedules hello
    // before kernel assembly, satisfying the build dependency without
    // an explicit step ordering.
    const hello_stage = b.addNamedWriteFiles("hello_elf_stage");
    _ = hello_stage.addCopyFile(hello.getEmittedBin(), "hello.elf");
    kernel_mod.addAssemblyFile(b.path("tools/hello_elf.S"));
    kernel_mod.addIncludePath(hello_stage.getDirectory());

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

    const stackbomb_stage = b.addNamedWriteFiles("stackbomb_elf_stage");
    _ = stackbomb_stage.addCopyFile(stackbomb.getEmittedBin(), "stackbomb.elf");
    kernel_mod.addAssemblyFile(b.path("tools/stackbomb_elf.S"));
    kernel_mod.addIncludePath(stackbomb_stage.getDirectory());

    // ---- flibc — userland mini-libc, ELF-demo dependency ----
    // Userland mini-libc: SVC wrappers, printf/puts on sys_writeConsole,
    // bump allocator over sys_brk/sbrk, fork/wait/exit/execve. Exposed
    // as a named module so ELF demos (and future Phase-4 fsh / coreutils
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

    const flibc_demo_stage = b.addNamedWriteFiles("flibc_demo_elf_stage");
    _ = flibc_demo_stage.addCopyFile(flibc_demo.getEmittedBin(), "flibc_demo.elf");
    kernel_mod.addAssemblyFile(b.path("tools/flibc_demo_elf.S"));
    kernel_mod.addIncludePath(flibc_demo_stage.getDirectory());

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
    const populate = b.addSystemCommand(&.{
        "sh", "-c",
        "aarch64-elf-nm -n " ++
            "\"$1\" | sort | grep -v '\\$' | zig run scripts/generate_syms.zig",
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
        const qemu_cmd = b.addSystemCommand(&.{
            "qemu-system-aarch64",
            "-M",
            "raspi4b",
            "-display",
            "none",
            "-serial", "null", // PL011 (UART4) → discarded
            "-serial", "stdio", // Mini-UART (UART1) → host stdio
            "-kernel", "zig-out/kernel8.img",
        });
        // qemu reads zig-out/kernel8.img via a literal path string, so
        // the install step must finish before qemu launches. Without
        // this dependency, a clean tree (post `zig build clean`) races
        // qemu against the install and qemu sees no kernel image.
        qemu_cmd.step.dependOn(&install_kernel_img.step);

        const run_step = b.step("run", "Run Flash in QEMU (raspi4b)");
        run_step.dependOn(&install_kernel_img.step); // depends on kernel8.img
        run_step.dependOn(&qemu_cmd.step);

        // Self-validating QEMU run: the watchdog tails the serial log,
        // exits 0 on `9/9 passed` (with the expected free-page-checkpoint
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
        });
        test_rpi4b_cmd.step.dependOn(&install_kernel_img.step);

        const test_rpi4b_step = b.step("test-rpi4b", "Boot raspi4b in QEMU and assert 9/9 passed");
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

        const test_virt_step = b.step("test-virt", "Boot virt in QEMU and assert 9/9 passed");
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
    // (`set_pgd`, `ret_from_fork`, `user_start`, …) that no host stub
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
    const tested_modules = [_][]const u8{
        "src/page_alloc.zig",
        "src/elf.zig",
    };
    inline for (tested_modules) |src_path| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(src_path),
            .target = b.graph.host,
            .optimize = .Debug,
        });
        test_mod.addObject(stubs_obj);
        const t = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
