//! The kernel symbol table — generated at build time and linked into the
//! `_symbols` section. The lookups here let the trace system print the name of
//! the function a hook or a sampled PC landed in.

use crate::trace::utils::{trace_output, trace_output_u64, PL};

/// Kernel high-mapping base. Same constant as the syscall, process-loader, and
/// trace modules.
///
/// The table symbol is reached through a literal whose stored value is the
/// link-time low VA. Boot-time callers are fine because TTBR0 still holds
/// `id_pg_dir`, which maps the low aliases. Once the first user process runs,
/// TTBR0 is swapped to a user pgd that does not map kernel low VAs — and the
/// lookups are then reached from the trace hook fired under user context. ORing
/// `LINEAR_MAP_BASE` promotes the low VA to its TTBR1 alias before any per-entry
/// load. Idempotent if the symbol is already high.
const LINEAR_MAP_BASE: u64 = 0xFFFF_0000_0000_0000;

/// One generated table entry. The layout is the generator's, not Rust's — the
/// assertions below are what keep the two in lockstep.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct KernelSymbol {
    pub address: u64,
    pub name: [u8; 56],
}

const _: () = assert!(core::mem::size_of::<KernelSymbol>() == 64);
const _: () = assert!(core::mem::align_of::<KernelSymbol>() == 8);
const _: () = assert!(core::mem::offset_of!(KernelSymbol, name) == 8);

#[cfg(target_os = "none")]
mod seam {
    use super::{KernelSymbol, LINEAR_MAP_BASE};

    unsafe extern "C" {
        static ksyms: u64;
    }

    /// The generated table's base, promoted to its linear-map alias.
    pub fn table() -> *mut KernelSymbol {
        (core::ptr::addr_of!(ksyms) as u64 | LINEAR_MAP_BASE) as *mut KernelSymbol
    }
}

#[cfg(not(target_os = "none"))]
mod seam {
    use super::KernelSymbol;

    /// Host builds link no generated table. The lone zero-name entry is the
    /// sentinel the counter stops at, so the walk terminates at zero symbols and
    /// every lookup misses — exactly what an un-generated table means.
    static mut SENTINEL: [KernelSymbol; 1] = [KernelSymbol {
        address: 0,
        name: [0; 56],
    }];

    pub fn table() -> *mut KernelSymbol {
        core::ptr::addr_of_mut!(SENTINEL).cast::<KernelSymbol>()
    }
}

static mut KSYMS_COUNT: u64 = 0;

/// Index of the entry whose address matches `addr` exactly.
fn exact_index(table: &[KernelSymbol], addr: u64) -> Option<usize> {
    table.iter().position(|entry| entry.address == addr)
}

/// Index of the nearest symbol at or below `addr`.
///
/// Sampled PCs and LRs are TTBR1 high-half VAs; the table stores low link
/// addresses. Stripping the alias bits runs the match in link-address space —
/// otherwise every high VA sits above all symbols and resolves to the topmost
/// one. Idempotent on an already-low address.
fn nearest_index(table: &[KernelSymbol], addr: u64) -> Option<usize> {
    let link = addr & !LINEAR_MAP_BASE;
    let mut best = None;
    let mut best_addr = 0;
    for (i, entry) in table.iter().enumerate() {
        if entry.address <= link && entry.address >= best_addr {
            best_addr = entry.address;
            best = Some(i);
        }
    }
    best
}

/// The live table as a slice — empty until `cal_ksyms_count` has walked it.
///
/// # Safety
/// The generated table is linked into the image and never moves.
unsafe fn live_table() -> &'static [KernelSymbol] {
    // SAFETY: the generator emits `KSYMS_COUNT` populated entries followed by a
    // zero-name sentinel, and the section outlives every caller.
    unsafe { core::slice::from_raw_parts(seam::table(), KSYMS_COUNT as usize) }
}

/// Name of the symbol at exactly `addr`, or null if there is none.
///
/// # Safety
/// Called after `ksyms_init`.
pub unsafe fn ksym_name_from_addr(addr: u64) -> *const u8 {
    // SAFETY: the table is live and the returned name is NUL-terminated in place.
    unsafe {
        let table = live_table();
        match exact_index(table, addr) {
            Some(i) => table[i].name.as_ptr(),
            None => core::ptr::null(),
        }
    }
}

/// Name of the nearest symbol at or below `addr` — for return and interrupt
/// addresses that land mid-function, where an exact-match scan would miss.
///
/// # Safety
/// Called after `ksyms_init`.
pub unsafe fn ksym_nearest(addr: u64) -> *const u8 {
    // SAFETY: the table is live and the returned name is NUL-terminated in place.
    unsafe {
        let table = live_table();
        match nearest_index(table, addr) {
            Some(i) => table[i].name.as_ptr(),
            None => core::ptr::null(),
        }
    }
}

/// Walk the table until the sentinel (zero-name) entry to find the count.
///
/// # Safety
/// The generated table ends in a zero-name sentinel.
pub unsafe fn cal_ksyms_count() {
    // SAFETY: the generator always emits the sentinel, which bounds the walk.
    unsafe {
        let table = seam::table();
        let mut count = 0u64;
        while (*table.add(count as usize)).name[0] != 0 {
            count += 1;
        }
        KSYMS_COUNT = count;
    }
}

/// Count the symbols and dump the whole table over the trace UART.
///
/// # Safety
/// Bring-up calls this once, after the trace UART is up.
pub unsafe fn ksyms_init() {
    // SAFETY: bring-up ordering guarantees the UART; the table is linked in.
    unsafe {
        cal_ksyms_count();
        trace_output(PL, c"found ".as_ptr().cast());
        trace_output_u64(PL, KSYMS_COUNT);
        trace_output(PL, c" kernel symbols\n".as_ptr().cast());

        for entry in live_table() {
            trace_output_u64(PL, entry.address);
            trace_output(PL, c" ".as_ptr().cast());
            trace_output(PL, entry.name.as_ptr());
            trace_output(PL, c"\n".as_ptr().cast());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{cal_ksyms_count, exact_index, nearest_index, KernelSymbol, LINEAR_MAP_BASE};

    fn sym(address: u64, name: &str) -> KernelSymbol {
        let mut bytes = [0u8; 56];
        bytes[..name.len()].copy_from_slice(name.as_bytes());
        KernelSymbol {
            address,
            name: bytes,
        }
    }

    fn table() -> [KernelSymbol; 3] {
        [
            sym(0x4000_1000, "kernel_main"),
            sym(0x4000_2000, "schedule"),
            sym(0x4000_3000, "do_wait"),
        ]
    }

    #[test]
    fn exact_match_finds_the_entry() {
        assert_eq!(exact_index(&table(), 0x4000_2000), Some(1));
    }

    #[test]
    fn exact_match_misses_mid_function() {
        assert_eq!(exact_index(&table(), 0x4000_2004), None);
    }

    #[test]
    fn nearest_resolves_a_mid_function_address() {
        assert_eq!(nearest_index(&table(), 0x4000_2004), Some(1));
    }

    #[test]
    fn nearest_strips_the_linear_map_alias() {
        // The sampled PC is a high-half VA; the table stores link addresses.
        // Without the strip every high VA would resolve to the topmost symbol.
        let high = 0x4000_2004 | LINEAR_MAP_BASE;
        assert_eq!(nearest_index(&table(), high), Some(1));
    }

    #[test]
    fn nearest_below_every_symbol_is_none() {
        assert_eq!(nearest_index(&table(), 0x4000_0000), None);
    }

    #[test]
    fn nearest_above_every_symbol_takes_the_last() {
        assert_eq!(nearest_index(&table(), 0x4000_9999), Some(2));
    }

    #[test]
    fn empty_table_resolves_to_none() {
        assert_eq!(nearest_index(&[], 0x4000_2000), None);
        assert_eq!(exact_index(&[], 0x4000_2000), None);
    }

    #[test]
    fn the_sentinel_terminates_the_count_at_zero() {
        // The host seam hands back a lone zero-name entry, which is what an
        // un-generated table looks like: the walk must stop on it, not run off.
        unsafe { cal_ksyms_count() };
    }
}
