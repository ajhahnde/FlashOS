//! ELF64 header records.
//!
//! Layouts ported from `src/elf.flash`; the parser itself (validation,
//! `iterate_phdrs`) stays with that module and moves in its own stage. Scope is
//! deliberately narrow — ELF64, little-endian, AArch64, ET_EXEC only.

use core::mem::{align_of, offset_of, size_of};

pub const ELF_MAGIC: [u8; 4] = [0x7F, b'E', b'L', b'F'];
pub const ELFCLASS64: u8 = 2;
pub const ELFDATA2LSB: u8 = 1;
pub const EV_CURRENT: u32 = 1;
pub const ET_EXEC: u16 = 2;
pub const EM_AARCH64: u16 = 183;

pub const PT_LOAD: u32 = 1;

pub const PF_X: u32 = 1 << 0;
pub const PF_W: u32 = 1 << 1;
pub const PF_R: u32 = 1 << 2;

/// Bound on the program-header count. Real AArch64 ET_EXEC binaries use 4-6; 16
/// is a generous ceiling that still bounds the blast radius of a malicious header.
pub const MAX_PHDRS: u16 = 16;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Ehdr {
    pub e_ident: [u8; 16],
    pub e_type: u16,
    pub e_machine: u16,
    pub e_version: u32,
    pub e_entry: u64,
    pub e_phoff: u64,
    pub e_shoff: u64,
    pub e_flags: u32,
    pub e_ehsize: u16,
    pub e_phentsize: u16,
    pub e_phnum: u16,
    pub e_shentsize: u16,
    pub e_shnum: u16,
    pub e_shstrndx: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Phdr {
    pub p_type: u32,
    pub p_flags: u32,
    pub p_offset: u64,
    pub p_vaddr: u64,
    pub p_paddr: u64,
    pub p_filesz: u64,
    pub p_memsz: u64,
    pub p_align: u64,
}

// ---------------------------------------------------------------------------
// Layout assertions. These are not our numbers to choose — they are the ELF64
// spec's, and the loader reads them straight out of a file on disk.
// ---------------------------------------------------------------------------

const _: () = {
    assert!(size_of::<Ehdr>() == 64);
    assert!(align_of::<Ehdr>() == 8);
    assert!(offset_of!(Ehdr, e_ident) == 0);
    assert!(offset_of!(Ehdr, e_type) == 16);
    assert!(offset_of!(Ehdr, e_machine) == 18);
    assert!(offset_of!(Ehdr, e_version) == 20);
    assert!(offset_of!(Ehdr, e_entry) == 24);
    assert!(offset_of!(Ehdr, e_phoff) == 32);
    assert!(offset_of!(Ehdr, e_shoff) == 40);
    assert!(offset_of!(Ehdr, e_flags) == 48);
    assert!(offset_of!(Ehdr, e_ehsize) == 52);
    assert!(offset_of!(Ehdr, e_phentsize) == 54);
    assert!(offset_of!(Ehdr, e_phnum) == 56);
    assert!(offset_of!(Ehdr, e_shentsize) == 58);
    assert!(offset_of!(Ehdr, e_shnum) == 60);
    assert!(offset_of!(Ehdr, e_shstrndx) == 62);

    assert!(size_of::<Phdr>() == 56);
    assert!(align_of::<Phdr>() == 8);
    assert!(offset_of!(Phdr, p_type) == 0);
    assert!(offset_of!(Phdr, p_flags) == 4);
    assert!(offset_of!(Phdr, p_offset) == 8);
    assert!(offset_of!(Phdr, p_vaddr) == 16);
    assert!(offset_of!(Phdr, p_paddr) == 24);
    assert!(offset_of!(Phdr, p_filesz) == 32);
    assert!(offset_of!(Phdr, p_memsz) == 40);
    assert!(offset_of!(Phdr, p_align) == 48);
};

#[cfg(test)]
mod tests {
    use super::*;

    /// The header the loader must accept: the first 64 bytes of a real AArch64
    /// ET_EXEC binary. Reading it back through `Ehdr` is what the loader does, so
    /// a field at the wrong offset shows up here as a wrong value, not a crash.
    #[test]
    fn ehdr_reads_back_a_real_aarch64_exec_header() {
        let mut raw = [0u8; 64];
        raw[..4].copy_from_slice(&ELF_MAGIC);
        raw[4] = ELFCLASS64;
        raw[5] = ELFDATA2LSB;
        raw[6] = EV_CURRENT as u8;
        raw[16..18].copy_from_slice(&ET_EXEC.to_le_bytes());
        raw[18..20].copy_from_slice(&EM_AARCH64.to_le_bytes());
        raw[20..24].copy_from_slice(&EV_CURRENT.to_le_bytes());
        raw[24..32].copy_from_slice(&0x1000u64.to_le_bytes());
        raw[32..40].copy_from_slice(&64u64.to_le_bytes());
        raw[54..56].copy_from_slice(&56u16.to_le_bytes());
        raw[56..58].copy_from_slice(&4u16.to_le_bytes());

        let eh: Ehdr = unsafe { core::mem::transmute(raw) };
        assert_eq!(eh.e_ident[..4], ELF_MAGIC);
        assert_eq!(eh.e_ident[4], ELFCLASS64);
        assert_eq!(eh.e_type, ET_EXEC);
        assert_eq!(eh.e_machine, EM_AARCH64);
        assert_eq!(eh.e_version, EV_CURRENT);
        assert_eq!(eh.e_entry, 0x1000);
        assert_eq!(eh.e_phoff, 64);
        assert_eq!(eh.e_phentsize as usize, size_of::<Phdr>());
        assert_eq!(eh.e_phnum, 4);
    }

    /// `e_phentsize` in a real binary is exactly `size_of::<Phdr>()`; the loader
    /// strides the program-header table by it.
    #[test]
    fn phdr_reads_back_a_pt_load_segment() {
        let mut raw = [0u8; 56];
        raw[..4].copy_from_slice(&PT_LOAD.to_le_bytes());
        raw[4..8].copy_from_slice(&(PF_R | PF_X).to_le_bytes());
        raw[8..16].copy_from_slice(&0u64.to_le_bytes());
        raw[16..24].copy_from_slice(&0u64.to_le_bytes());
        raw[32..40].copy_from_slice(&0x200u64.to_le_bytes());
        raw[40..48].copy_from_slice(&0x200u64.to_le_bytes());
        raw[48..56].copy_from_slice(&0x1000u64.to_le_bytes());

        let ph: Phdr = unsafe { core::mem::transmute(raw) };
        assert_eq!(ph.p_type, PT_LOAD);
        assert_eq!(ph.p_flags, PF_R | PF_X);
        assert_eq!(ph.p_vaddr, 0);
        assert_eq!(ph.p_filesz, 0x200);
        assert_eq!(ph.p_memsz, 0x200);
        assert_eq!(ph.p_align, 0x1000);
    }
}
