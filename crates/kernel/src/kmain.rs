//! Kernel bring-up and the idle loop -- the kernel root.
//!
//! `_start` (arch/aarch64/boot.S) enters `kernel_main`, the patchable trampoline
//! in src/trace/patchable_trampolines.S, which reaches [`kernel_main_impl`] here
//! through the C-ABI export in `crates/klib`. Core 0 walks the bring-up sequence
//! and falls into the PID-0 idle loop; the secondary cores park at the `id != 0`
//! gate and never run any of it.
//!
//! Boot status lines render through `flashos_console_ui` -- the one place a
//! bracket tag or an ANSI color is spelled. [`boot_sink`] binds the Mini-UART as
//! the sink, so each bring-up step logs as `boot.ok(...)` / `.skip(...)` /
//! `.warn(...)`. Restyle the whole boot log by editing that crate, not here.
//! Cosmetic -- none of these lines are grepped by the boot contract. (The
//! userspace contract markers still hand-roll the `[ OK ]` form; migrating them
//! onto console_ui is a follow-up.)
//!
//! Board drivers are reached by direct call into this crate. The bring-up
//! sequence still crosses a C symbol only where assembly owns the other side
//! (`irq_init_vectors`, `schedule`, the patchable trampolines).

/// The kernel's high-half (TTBR1) linear-map base.
#[cfg(any(test, target_os = "none"))]
const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;

/// Strip the linear-map base off a kernel address, yielding the PA.
///
/// Idempotent, and that matters: the image is *linked* at its load PAs but *runs*
/// mapped high, so a PC-relative reference to a linker symbol lands on the high
/// alias while the symbol itself names a PA. Masking converts one and leaves the
/// other alone, so it is correct whichever the reference produced.
#[cfg(any(test, target_os = "none"))]
const fn kva_to_pa(addr: u64) -> u64 {
    addr & !LINEAR_MAP_BASE
}

/// The block-I/O smoke check's target LBA and its sector pattern. Gated to the
/// builds that can reach it: the boot-as-test target image, and the host suite
/// that exercises the pattern.
#[cfg(any(test, all(target_os = "none", feature = "boot-selftest")))]
mod smoke {
    /// Scratch LBA for the EL1 block-I/O smoke check. Retargeted from LBA 34_816
    /// to LBA 2064: the single-partition format_sd.sh means the old 34_816 falls
    /// inside the FAT32 data region and would collide with user files once the
    /// disk fills in. LBA 2064 sits in the FAT32 reserved-sector window
    /// (partition start LBA 2048 + 16 = 17th reserved sector, between the BPB at
    /// LBA 2048 and FAT1 around LBA 2080), which no FAT32 driver reads or writes.
    /// The 16-sector offset matches the BPB's `reserved_sec_cnt = 32` window
    /// minus the first BPB sector and the FSInfo at LBA 2049 -- well clear of
    /// both. One-constant permanent fix.
    pub const EMMC2_BLOCK_LBA: u32 = 2064;

    /// One byte of the smoke pattern. Offset-dependent, so a driver that returns
    /// a shifted, stale, or zeroed sector fails the compare instead of matching
    /// by accident.
    pub const fn pattern_byte(offset: usize) -> u8 {
        ((offset + 0x42) & 0xFF) as u8
    }

    /// Fill `buf` with the smoke pattern.
    pub fn fill_pattern(buf: &mut [u8; 512]) {
        let mut i = 0;
        while i < buf.len() {
            buf[i] = pattern_byte(i);
            i += 1;
        }
    }
}

#[cfg(target_os = "none")]
pub use target::{kernel_main_impl, kernel_process};

#[cfg(target_os = "none")]
mod target {
    use crate::utilc::{main_output, main_output_char, MU, PL};
    use crate::{block_dev, fat32_backend, fdtable, initramfs_backend, page_alloc, rpi4b_irq};
    use core::ptr::{addr_of, addr_of_mut};
    use flashos_console_ui as console_ui;

    use super::kva_to_pa;

    /// `copy_process` clone flag: a kernel thread needs no user stack page.
    const KTHREAD: u64 = 1;

    /// VideoCore AUX interrupt -- the Mini-UART's RX line.
    const VC_AUX_IRQ: u32 = 125;
    /// Non-secure physical timer interrupt -- the scheduler tick.
    const NS_PHYS_TIMER_IRQ: u32 = 30;

    mod seam {
        use flashos_abi::task::TaskStruct;

        unsafe extern "C" {
            /// Published by the scheduler. Read here only from the PID-1 kernel
            /// thread, which runs on the kernel pgd -- never from user context.
            pub static mut current: *mut TaskStruct;

            /// PA marker emitted by the board linker script: the page just past
            /// the kernel image and its reserved regions (the page tables on
            /// rpi4b). Read at boot so the page allocator never returns a PA that
            /// overlaps the kernel image.
            pub static _kernel_pa_end: u8;

            pub fn delay(ticks: u64);
            pub fn get_el() -> u32;
            pub fn irq_init_vectors();
            pub fn irq_enable();
            /// The patchable trampoline in src/trace/patchable_trampolines.S,
            /// which reaches `copy_process_impl`.
            pub fn copy_process(clone_flags: u64, fn_ptr: u64, arg: u64) -> i32;
            pub fn generic_timer_init();
            pub fn hwrng_init() -> i32;
            pub fn sched_init();
            pub fn schedule();
            pub fn prepare_move_to_user_elf(blob_addr_kva: u64, blob_size: u64) -> i32;
            pub fn sys_call_table_relocate();
            #[cfg(feature = "boot-selftest")]
            pub fn dump_free_count() -> u64;
        }
    }

    /// Cross-core boot synchronization. Single-core today: the secondaries park
    /// at the `id != 0` gate, so only core 0 ever advances this.
    #[no_mangle]
    pub static mut state: u32 = 0;

    /// console_ui sink bound to the Mini-UART boot console. Byte-at-a-time so the
    /// slice-based renderers meet the kernel's NUL-terminated output without a
    /// buffer -- and without growing the tight per-task kernel stack.
    fn boot_sink(bytes: &[u8]) {
        for &byte in bytes {
            // SAFETY: every caller runs after mini_uart_init on core 0, and the
            // send is a bounded MMIO poll that allocates nothing.
            unsafe { main_output_char(MU, byte) };
        }
    }

    /// EL1-side block-I/O smoke check. Writes a deterministic pattern to
    /// [`EMMC2_BLOCK_LBA`], reads it back through the same vtable, byte-compares.
    /// Emits `[PASS] emmc2-block` on match and `[FAIL] emmc2-block` (with a short
    /// reason tag) otherwise. Both buffers live on the kernel stack -- no page
    /// allocation, no shift to the free-page baseline. scripts/run_qemu_test.sh
    /// greps for `[FAIL] emmc2-block` and fails the run if present; the EL0
    /// scenario tally is unaffected because this runs before PID 1 is forked.
    ///
    /// # Safety
    /// The EMMC2 driver is up and bring-up owns the block device exclusively.
    #[cfg(feature = "boot-selftest")]
    #[inline(never)]
    unsafe fn run_emmc2_smoke() {
        use super::smoke::{fill_pattern, EMMC2_BLOCK_LBA};
        use console_ui::tags;

        let mut write_buf = [0u8; 512];
        let mut read_buf = [0u8; 512];
        fill_pattern(&mut write_buf);

        boot_sink(tags::TEST_MARK);
        boot_sink(b"emmc2-block\n");

        // SAFETY: bring-up owns the device; both buffers outlive the calls.
        if unsafe { crate::rpi4b_emmc2::write_block(EMMC2_BLOCK_LBA, &write_buf) } != 0 {
            boot_sink(tags::FAIL_MARK);
            boot_sink(b"emmc2-block (write)\n");
            return;
        }
        // SAFETY: as above.
        if unsafe { crate::rpi4b_emmc2::read_block(EMMC2_BLOCK_LBA, &mut read_buf) } != 0 {
            boot_sink(tags::FAIL_MARK);
            boot_sink(b"emmc2-block (read)\n");
            return;
        }
        if read_buf != write_buf {
            boot_sink(tags::FAIL_MARK);
            boot_sink(b"emmc2-block (mismatch)\n");
            return;
        }
        boot_sink(tags::PASS_MARK);
        boot_sink(b"emmc2-block\n");
    }

    /// Run by PID 1; returns to entry.S and does a kernel_exit 0.
    ///
    /// PID 1 is ELF-loaded: `/sbin/init` is the `pid1.elf` artifact baked into
    /// the embedded initramfs. Its bytes (already TTBR1-mapped, no allocation) go
    /// to `prepare_move_to_user_elf`, the same loader the exec-elf / flibc test
    /// payloads use.
    ///
    /// Keeps its bare symbol name: [`kernel_main_impl`] hands this address to
    /// `copy_process`, and the trace symbol table resolves PID 1's entry by it.
    ///
    /// # Safety
    /// Reached only as a kernel thread from `copy_process`, with a live current
    /// task and the initramfs mounted.
    #[no_mangle]
    pub unsafe extern "C" fn kernel_process() {
        let Ok(Some(entry)) = initramfs_backend::locate_production(b"/sbin/init") else {
            // SAFETY: the literal is NUL-terminated and is not retained.
            unsafe {
                main_output(
                    MU,
                    c"PID 1: /sbin/init missing from initramfs\n"
                        .as_ptr()
                        .cast(),
                )
            };
            return;
        };

        // Pre-install stdio as console fds before handing control to EL0. Console
        // slots are refcount-exempt shared singletons (ptr = null, kind =
        // console), so the three installs allocate no page and leave the
        // free-page baseline untouched. fork() inherits them via dup_all;
        // execve() preserves them. User space sees fd 0/1/2 already wired to the
        // Mini-UART.
        // SAFETY: bring-up published the current task before forking PID 1.
        let cur = unsafe { addr_of!(seam::current).read() };
        for _ in 0..3 {
            // SAFETY: `cur` is live and a console slot carries no backend pointer.
            unsafe { fdtable::install(cur, fdtable::Kind::Console, core::ptr::null_mut()) };
        }

        let blob_kva = entry.data.as_ptr() as u64;
        // SAFETY: the blob is TTBR1-mapped for the kernel's lifetime.
        let err = unsafe { seam::prepare_move_to_user_elf(blob_kva, entry.data.len() as u64) };
        if err < 0 {
            // SAFETY: the literal is NUL-terminated and is not retained.
            unsafe { main_output(MU, c"PID 1: ELF load failed\n".as_ptr().cast()) };
        }
    }

    /// Core 0's bring-up sequence, split out of [`kernel_main_impl`] and kept out
    /// of the inliner's reach: reflowing a root full of small emitters moves
    /// `_kernel_pa_end` by a page, and the rpi4b boot test does not catch that
    /// shift, because `mem_map_reserve_below` is a no-op on this board.
    ///
    /// # Safety
    /// Runs exactly once, on core 0, before any other core is released.
    #[inline(never)]
    unsafe fn bring_up(id: u64) {
        let boot = console_ui::logger(boot_sink);

        // Page allocator bitmap zeroed first so anything later in bring-up can
        // hit get_free_page without a lazy-init branch.
        // SAFETY: single-core bring-up owns the bitmap.
        unsafe { page_alloc::mem_map_init() };
        // Reserve the PAs occupied by the kernel image so get_free_page never
        // hands out a page overlapping `.text` / `.data` / `.bss` / the page
        // tables. On rpi4b the kernel sits below the pool, so this is a no-op --
        // it stays because the marker, not the board, is the contract.
        //
        // `_kernel_pa_end` names a PA, but a PC-relative reference to it resolves
        // to the high alias, which is >= every pool address and would reserve the
        // entire pool. Hence kva_to_pa: the allocator compares against PAs, so a
        // PA is what it must be handed.
        // SAFETY: the linker places the marker inside the image, so taking its
        // address is a PC-relative reference within the mapped kernel.
        unsafe {
            page_alloc::mem_map_reserve_below(kva_to_pa(addr_of!(seam::_kernel_pa_end) as u64))
        };

        // Mini-UART first so the boot status lines land on the same cable (pin
        // 14/15) as the exception handler's "ERROR CAUGHT" output.
        // SAFETY: bring-up owns the UART MMIO and the GPIO pins it claims.
        unsafe { crate::rpi4b_uart::mini_uart_init() };
        boot.ok(b"Mini-UART init");

        // Startup banner right after the console comes up, so the log reads
        // chronologically: core 0 is the first thing running, before any of the
        // subsystem bring-up below.
        console_ui::tagged(boot_sink, console_ui::OK);
        boot_sink(b"Boot core ");
        // SAFETY: the UART is up and the core id is a single digit.
        unsafe { main_output_char(MU, id as u8 + b'0') };
        boot_sink(b" (EL");
        // SAFETY: get_el reads CurrentEL, which is always readable at EL1.
        unsafe { main_output_char(MU, seam::get_el() as u8 + b'0') };
        boot_sink(b")\n");

        // SAFETY: bring-up owns the PL011 MMIO.
        unsafe { crate::trace::pl011_uart::pl011_uart_init() };
        boot.ok(b"PL011 UART init");

        // SAFETY: loads VBAR_EL1 with the vector table linked into the image.
        unsafe { seam::irq_init_vectors() };
        boot.ok(b"IRQ vectors init");

        // Board-specific GIC bring-up: GICv3 needs ICC_*_EL1 + a per-core
        // redistributor wakeup. The Pi's GICv2 inlines to nothing.
        // SAFETY: forwarded bring-up ordering.
        unsafe { crate::rpi4b_irq::board_irq_init() };

        // SAFETY: the distributor is up and `id` is the running core.
        unsafe { rpi4b_irq::enable_interrupt_gic(VC_AUX_IRQ, id as u32) };
        boot.ok(b"GIC init");

        // USB-OTG gadget bring-up (DWC2). The device MMIO at 0xFE980000 is
        // already device-mapped by boot.S, so this needs no page allocator. Fails
        // soft where there is no DWC2 device path -- bounded waits return -1 and
        // the polled console simply never enumerates. Serviced from the PID-0
        // idle loop below.
        // SAFETY: forwarded bring-up ordering.
        let usb_level = if unsafe { crate::rpi4b_usb::init() } < 0 {
            console_ui::Level::Skip
        } else {
            console_ui::Level::Ok
        };
        boot.status(usb_level, b"USB DWC2 init");

        // SAFETY: the trace UART is up.
        unsafe { crate::trace::ksyms::ksyms_init() };
        boot.ok(b"KSYMS init");

        // SAFETY: runs once, before any user pgd replaces the identity map.
        unsafe { seam::sys_call_table_relocate() };
        boot.ok(b"Syscall table relocate");

        // SAFETY: the trace UART is up and the entry table is mapped.
        unsafe { crate::trace::trace_main::trace_init() };
        boot.ok(b"Trace init");

        // SAFETY: the linker-placed page tables are still mapped.
        unsafe { crate::trace::utils::trace_output_kernel_pts(PL) };
        boot.ok(b"Kernel trace -> PL011");

        // VFS root mount bring-up. initramfs_backend only sets pointers -- no
        // get_free_page -- so it slots in ahead of the free-page baseline emit
        // without shifting it. The FAT32 /mnt mount is wired later, after the
        // EMMC2 driver has wired `block_dev::SD_DEV` (fat32_backend::init issues
        // block reads).
        // SAFETY: one-time bring-up owns the superblock.
        unsafe { initramfs_backend::init() };
        boot.ok(b"Initramfs mount (/)");

        // Block-device bring-up. Graceful degradation (log + continue) is the
        // contract for the rpi4b driver, which can fail on a missing SD card. The
        // smoke check below exercises the BlockDev vtable end-to-end and proves
        // init() wired the callback pair.
        // SAFETY: forwarded bring-up ordering.
        let emmc2_ok = unsafe { crate::rpi4b_emmc2::init() } >= 0;
        boot.status(
            if emmc2_ok {
                console_ui::Level::Ok
            } else {
                console_ui::Level::Skip
            },
            b"EMMC2 init",
        );
        if emmc2_ok {
            // Pre-PID-1 block-device smoke -- part of the boot-as-test path,
            // compiled out entirely so a clean boot stays quiet.
            #[cfg(feature = "boot-selftest")]
            // SAFETY: the driver is up and bring-up owns the device.
            unsafe {
                run_emmc2_smoke()
            };

            // FAT32 /mnt mount -- needs the callback pair wired just above by the
            // EMMC2 driver. Fails soft: a blank/bad disk leaves the mount slot
            // null and /mnt/* resolves to ENOENT.
            // SAFETY: `SD_DEV` is this crate's own BSS record, so its address is a
            // PC-relative reference here -- not the GOT-resolved low address the
            // retired Flash adapter used to hand in.
            if unsafe { fat32_backend::init(addr_of_mut!(block_dev::SD_DEV)) } < 0 {
                boot.skip(b"FAT32 mount (no volume)");
            } else {
                boot.ok(b"FAT32 mount (/mnt)");
                // Permission overlay: init() parsed PERMS.TAB into the backend's
                // table. A mounted volume without a parseable overlay is the loud
                // anti-brick announcement: /mnt runs on defaults (shadow floored
                // 0600 root:root) until the operator reseeds the overlay file.
                if !fat32_backend::overlay_ok() {
                    boot.warn(b"/mnt overlay missing - defaults active, shadow floored");
                }
            }
        }

        // Entropy source bring-up. Seeds the fallback generator from CNTPCT
        // (readable from reset -- independent of the generic-timer IRQ setup
        // below) and self-tests it. A stuck source would mint the same salt for
        // every credential, so the failure is announced loudly rather than
        // degraded silently. The announce line tees into the kernel log ring,
        // where [TEST] rng asserts it later. Allocates nothing.
        // SAFETY: forwarded bring-up ordering; reads CNTPCT only.
        if unsafe { seam::hwrng_init() } < 0 {
            boot.warn(b"HWRNG: self-test failed (constant output)");
        } else {
            boot.ok(b"HWRNG init");
        }

        // Boot-time free-page baseline. Logged before any task is created so the
        // user-space dumps later in the trace can be compared against this
        // absolute reference.
        #[cfg(feature = "boot-selftest")]
        // SAFETY: single-core bring-up serializes the bitmap scan.
        unsafe {
            let _ = seam::dump_free_count();
        };

        // SAFETY: core 0 owns the gate until it releases the secondaries.
        unsafe { addr_of_mut!(state).write_volatile(0) };
    }

    /// The kernel root, reached from the `kernel_main` trampoline through the
    /// C-ABI export in `crates/klib`.
    ///
    /// # Safety
    /// Entered once per core from the boot path, with the MMU on and the identity
    /// map live.
    pub unsafe fn kernel_main_impl(id: u64) {
        // Core 0 initializes the Mini-UART and handles its interrupts.
        if id == 0 {
            // SAFETY: core 0 runs bring-up exactly once.
            unsafe { bring_up(id) };
        }

        // Single core for now.
        while id != 0 {}

        // SAFETY: a bounded busy wait.
        unsafe { seam::delay(30000) };

        // Generic timer and timer IRQ (the vectors are already loaded on core 0).
        // SAFETY: the vectors are installed and the distributor is up.
        unsafe {
            seam::generic_timer_init();
            rpi4b_irq::enable_interrupt_gic(NS_PHYS_TIMER_IRQ, id as u32);
            seam::irq_enable();
        }

        // Let the next core run.
        // SAFETY: the only writer until the secondaries are released.
        unsafe {
            let gate = addr_of_mut!(state);
            gate.write_volatile(gate.read_volatile() + 1);
        }

        loop {
            // SAFETY: a plain gate read; the secondaries never advance it today.
            if id != 0 || unsafe { addr_of!(state).read_volatile() } != 1 {
                continue;
            }
            // SAFETY: runs once, before any task is created.
            unsafe { seam::sched_init() };
            // Create PID 1; kernel threads don't need a user stack page.
            let entry = kernel_process as *const () as u64;
            // SAFETY: `entry` is a live kernel function and the scheduler is up.
            let res = unsafe { seam::copy_process(KTHREAD, entry, 0) };
            if res <= 0 {
                // SAFETY: the literal is NUL-terminated and is not retained.
                unsafe { main_output(MU, c"fork error\n".as_ptr().cast()) };
            }
            loop {
                // Idle-path UART RX poll (PID 0) -- a defensive backstop. The AUX
                // RX interrupt is the primary drain and reaches handle_irq on real
                // hardware; this only catches a byte left between IRQ slots.
                // SAFETY: the idle loop holds no lock and both polls are bounded.
                unsafe {
                    crate::rpi4b_uart::poll_rx_into_console();
                    crate::rpi4b_usb::poll();
                    seam::schedule();
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::smoke::{fill_pattern, pattern_byte, EMMC2_BLOCK_LBA};
    use super::{kva_to_pa, LINEAR_MAP_BASE};
    use crate::page_alloc::MALLOC_START;

    /// The reservation trap, pinned. `_kernel_pa_end` resolves to its high alias
    /// at runtime; handing that to `mem_map_reserve_below` unmasked reserves the
    /// whole pool, because every pool PA is below it. Boot then reaches
    /// `free_pages: 0` and `fork error`.
    #[test]
    fn kernel_pa_end_high_alias_converts_to_a_pa_below_the_pool() {
        // The rpi4b marker's link value, as the linker script places it.
        let pa = 0x1a_7000u64;
        let high_alias = LINEAR_MAP_BASE | pa;

        assert!(
            high_alias > MALLOC_START,
            "unmasked, the alias would reserve every pool page"
        );
        assert_eq!(kva_to_pa(high_alias), pa);
        assert!(
            kva_to_pa(high_alias) <= MALLOC_START,
            "the reservation must stay a no-op on rpi4b"
        );
    }

    #[test]
    fn kva_to_pa_is_idempotent() {
        // The call site cannot know which form the reference produced, so masking
        // an already-low address must not corrupt it.
        let pa = 0x1a_7000u64;
        assert_eq!(kva_to_pa(pa), pa);
        assert_eq!(kva_to_pa(kva_to_pa(LINEAR_MAP_BASE | pa)), pa);
    }

    #[test]
    fn pattern_is_offset_dependent() {
        // A shifted, stale, or zeroed sector must not compare equal.
        assert_eq!(pattern_byte(0), 0x42);
        assert_eq!(pattern_byte(1), 0x43);
        assert_ne!(pattern_byte(0), pattern_byte(1));
    }

    #[test]
    fn pattern_wraps_at_byte_width() {
        // 0x42 + 190 = 0x100 -- the first wrap stays in range instead of panicking.
        assert_eq!(pattern_byte(190), 0x00);
        assert_eq!(pattern_byte(191), 0x01);
    }

    #[test]
    fn fill_covers_the_whole_sector() {
        let mut buf = [0u8; 512];
        fill_pattern(&mut buf);
        for (i, &byte) in buf.iter().enumerate() {
            assert_eq!(byte, pattern_byte(i), "byte {i} not filled");
        }
    }

    #[test]
    fn fill_is_deterministic() {
        let mut first = [0u8; 512];
        let mut second = [0xFFu8; 512];
        fill_pattern(&mut first);
        fill_pattern(&mut second);
        assert_eq!(first, second);
    }

    // The asserts guard compile-time constants on purpose; keep them runnable
    // tests for the named failure messages rather than const asserts.
    #[allow(clippy::assertions_on_constants)]
    #[test]
    fn scratch_lba_stays_in_the_fat32_reserved_window() {
        // The retarget's whole point: LBA 2064 must sit between the BPB at 2048
        // and FAT1 near 2080, or the smoke check corrupts user files.
        assert!(EMMC2_BLOCK_LBA > 2048, "would clobber the BPB");
        assert!(EMMC2_BLOCK_LBA < 2080, "would clobber FAT1");
    }
}
