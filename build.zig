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

// Native Zig build for the FlashOS kernel (RPi4, AArch64).
//
// Layout:
//   * src/start.zig      — root that comptime-imports every kernel module
//   * src/*.S            — boot/entry/sched/timer/etc. assembly
//   * user_space/init.zig — user-space PID 1 image (linked into .text.user)
//   * src/linker.ld      — link script wrapping the user image with
//                          user_start / user_end
//
// The build produces:
//   * kernel8.img — raw binary loaded by the GPU bootloader
//   * armstub8.bin — small EL3→EL1 bootstrap shim
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

    // ---- user-space image (compiled separately so we can match its
    // object file from the linker script as `*user_init*.o`) ----
    const user_init = b.addObject(.{
        .name = "user_init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user_space/init.zig"),
            .target = target,
            .optimize = optimize,
        }),
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

        const run_step = b.step("run", "Run Flash in QEMU (raspi4b)");
        run_step.dependOn(&install_kernel_img.step); // depends on kernel8.img
        run_step.dependOn(&qemu_cmd.step);
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

        const run_virt_step = b.step("run-virt", "Run FlashOS in QEMU (virt)");
        run_virt_step.dependOn(&install_kernel_img.step);
        run_virt_step.dependOn(&qemu_virt_cmd.step);
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
