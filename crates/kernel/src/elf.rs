//! ELF64 header and program-header validation for the EL0 loader.
//!
//! Record layouts and constants live in `flashos-abi`; this module owns the
//! safe byte decoding and the loader-specific address-range policy.

pub use flashos_abi::elf::{
    ELF_MAGIC, ELFCLASS64, ELFDATA2LSB, EM_AARCH64, ET_EXEC, EV_CURRENT, Ehdr, MAX_PHDRS, PF_R,
    PF_W, PF_X, PT_LOAD, Phdr,
};
use flashos_abi::user::{DATA_BASE, STACK_LOW};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParseError {
    BadMagic,
    NotElf64,
    NotLittleEndian,
    NotExecutable,
    NotAarch64,
    BadVersion,
    BadEntry,
    EntryOutOfBounds,
    PhoffOutOfBounds,
    TooManyPhdrs,
    MemszOverflow,
    VaddrOutOfBounds,
}

/// Decode and validate an ELF64 executable header.
pub fn parse_ehdr(blob: &[u8]) -> Result<Ehdr, ParseError> {
    if blob.len() < size_of::<Ehdr>() {
        return Err(ParseError::BadMagic);
    }

    let mut ident = [0; 16];
    ident.copy_from_slice(&blob[..16]);
    let header = Ehdr {
        e_ident: ident,
        e_type: read_u16(blob, 16),
        e_machine: read_u16(blob, 18),
        e_version: read_u32(blob, 20),
        e_entry: read_u64(blob, 24),
        e_phoff: read_u64(blob, 32),
        e_shoff: read_u64(blob, 40),
        e_flags: read_u32(blob, 48),
        e_ehsize: read_u16(blob, 52),
        e_phentsize: read_u16(blob, 54),
        e_phnum: read_u16(blob, 56),
        e_shentsize: read_u16(blob, 58),
        e_shnum: read_u16(blob, 60),
        e_shstrndx: read_u16(blob, 62),
    };

    if header.e_ident[..4] != ELF_MAGIC {
        return Err(ParseError::BadMagic);
    }
    if header.e_ident[4] != ELFCLASS64 {
        return Err(ParseError::NotElf64);
    }
    if header.e_ident[5] != ELFDATA2LSB {
        return Err(ParseError::NotLittleEndian);
    }
    if header.e_type != ET_EXEC {
        return Err(ParseError::NotExecutable);
    }
    if header.e_machine != EM_AARCH64 {
        return Err(ParseError::NotAarch64);
    }
    if header.e_version != EV_CURRENT {
        return Err(ParseError::BadVersion);
    }
    if header.e_entry >= DATA_BASE {
        return Err(ParseError::EntryOutOfBounds);
    }
    if header.e_phnum > MAX_PHDRS {
        return Err(ParseError::TooManyPhdrs);
    }

    let table_size = u64::from(header.e_phentsize) * u64::from(header.e_phnum);
    let table_end = header
        .e_phoff
        .checked_add(table_size)
        .ok_or(ParseError::PhoffOutOfBounds)?;
    if table_end > blob.len() as u64 {
        return Err(ParseError::PhoffOutOfBounds);
    }

    Ok(header)
}

/// Decode and validate one program header at an explicit byte cursor.
pub fn parse_phdr_at(blob: &[u8], cursor: u64) -> Result<Phdr, ParseError> {
    let start = usize::try_from(cursor).map_err(|_| ParseError::PhoffOutOfBounds)?;
    let end = start
        .checked_add(size_of::<Phdr>())
        .ok_or(ParseError::PhoffOutOfBounds)?;
    if end > blob.len() {
        return Err(ParseError::PhoffOutOfBounds);
    }

    let header = Phdr {
        p_type: read_u32(blob, start),
        p_flags: read_u32(blob, start + 4),
        p_offset: read_u64(blob, start + 8),
        p_vaddr: read_u64(blob, start + 16),
        p_paddr: read_u64(blob, start + 24),
        p_filesz: read_u64(blob, start + 32),
        p_memsz: read_u64(blob, start + 40),
        p_align: read_u64(blob, start + 48),
    };

    if header.p_type == PT_LOAD {
        let file_end = header
            .p_offset
            .checked_add(header.p_filesz)
            .ok_or(ParseError::PhoffOutOfBounds)?;
        if file_end > blob.len() as u64 {
            return Err(ParseError::PhoffOutOfBounds);
        }

        let memory_end = header
            .p_vaddr
            .checked_add(header.p_memsz)
            .ok_or(ParseError::MemszOverflow)?;
        if memory_end > STACK_LOW {
            return Err(ParseError::VaddrOutOfBounds);
        }
    }

    Ok(header)
}

pub struct PhdrIterator<'a> {
    blob: &'a [u8],
    cursor: u64,
    stride: u64,
    remaining: u16,
}

impl PhdrIterator<'_> {
    pub fn next_header(&mut self) -> Result<Option<Phdr>, ParseError> {
        if self.remaining == 0 {
            return Ok(None);
        }
        let header = parse_phdr_at(self.blob, self.cursor)?;
        self.cursor = self.cursor.wrapping_add(self.stride);
        self.remaining -= 1;
        Ok(Some(header))
    }
}

pub fn iterate_phdrs(blob: &[u8], header: Ehdr) -> PhdrIterator<'_> {
    PhdrIterator {
        blob,
        cursor: header.e_phoff,
        stride: u64::from(header.e_phentsize),
        remaining: header.e_phnum,
    }
}

fn read_u16(blob: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([blob[offset], blob[offset + 1]])
}

fn read_u32(blob: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        blob[offset],
        blob[offset + 1],
        blob[offset + 2],
        blob[offset + 3],
    ])
}

fn read_u64(blob: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes([
        blob[offset],
        blob[offset + 1],
        blob[offset + 2],
        blob[offset + 3],
        blob[offset + 4],
        blob[offset + 5],
        blob[offset + 6],
        blob[offset + 7],
    ])
}

const _: () = assert!(size_of::<Ehdr>() == 64 && size_of::<Phdr>() == 56);

use core::mem::size_of;

#[cfg(test)]
mod tests {
    use super::*;
    use flashos_abi::user::STACK_TOP;

    const EHSIZE: usize = size_of::<Ehdr>();
    const PHENTSIZE: usize = size_of::<Phdr>();

    fn write_u16(buffer: &mut [u8], offset: usize, value: u16) {
        buffer[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
    }

    fn write_u32(buffer: &mut [u8], offset: usize, value: u32) {
        buffer[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }

    fn write_u64(buffer: &mut [u8], offset: usize, value: u64) {
        buffer[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
    }

    fn write_ehdr(buffer: &mut [u8], entry: u64, phoff: u64, phnum: u16) {
        buffer[..EHSIZE].fill(0);
        buffer[..4].copy_from_slice(&ELF_MAGIC);
        buffer[4] = ELFCLASS64;
        buffer[5] = ELFDATA2LSB;
        buffer[6] = 1;
        write_u16(buffer, 16, ET_EXEC);
        write_u16(buffer, 18, EM_AARCH64);
        write_u32(buffer, 20, EV_CURRENT);
        write_u64(buffer, 24, entry);
        write_u64(buffer, 32, phoff);
        write_u16(buffer, 52, EHSIZE as u16);
        write_u16(buffer, 54, PHENTSIZE as u16);
        write_u16(buffer, 56, phnum);
    }

    #[allow(clippy::too_many_arguments)]
    fn write_phdr(
        buffer: &mut [u8],
        offset: usize,
        segment_type: u32,
        flags: u32,
        file_offset: u64,
        file_size: u64,
        memory_size: u64,
        virtual_address: u64,
    ) {
        buffer[offset..offset + PHENTSIZE].fill(0);
        write_u32(buffer, offset, segment_type);
        write_u32(buffer, offset + 4, flags);
        write_u64(buffer, offset + 8, file_offset);
        write_u64(buffer, offset + 16, virtual_address);
        write_u64(buffer, offset + 24, virtual_address);
        write_u64(buffer, offset + 32, file_size);
        write_u64(buffer, offset + 40, memory_size);
        write_u64(buffer, offset + 48, 0x1000);
    }

    #[test]
    fn parse_ehdr_accepts_minimal_valid_header() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, 0x1000, 0, 0);
        let header = parse_ehdr(&buffer).unwrap();
        assert_eq!(header.e_type, ET_EXEC);
        assert_eq!(header.e_machine, EM_AARCH64);
        assert_eq!(header.e_entry, 0x1000);
    }

    #[test]
    fn parse_ehdr_rejects_truncated_blob_as_bad_magic() {
        assert_eq!(parse_ehdr(&[0; EHSIZE - 1]), Err(ParseError::BadMagic));
    }

    #[test]
    fn parse_ehdr_rejects_flipped_magic() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, 0x1000, 0, 0);
        buffer[1] = b'X';
        assert_eq!(parse_ehdr(&buffer), Err(ParseError::BadMagic));
    }

    #[test]
    fn parse_ehdr_rejects_elfclass32() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, 0x1000, 0, 0);
        buffer[4] = 1;
        assert_eq!(parse_ehdr(&buffer), Err(ParseError::NotElf64));
    }

    #[test]
    fn parse_ehdr_rejects_big_endian() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, 0x1000, 0, 0);
        buffer[5] = 2;
        assert_eq!(parse_ehdr(&buffer), Err(ParseError::NotLittleEndian));
    }

    #[test]
    fn parse_ehdr_rejects_et_dyn() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, 0x1000, 0, 0);
        write_u16(&mut buffer, 16, 3);
        assert_eq!(parse_ehdr(&buffer), Err(ParseError::NotExecutable));
    }

    #[test]
    fn parse_ehdr_rejects_x86_64() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, 0x1000, 0, 0);
        write_u16(&mut buffer, 18, 62);
        assert_eq!(parse_ehdr(&buffer), Err(ParseError::NotAarch64));
    }

    #[test]
    fn parse_ehdr_rejects_bad_version() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, 0x1000, 0, 0);
        write_u32(&mut buffer, 20, 0);
        assert_eq!(parse_ehdr(&buffer), Err(ParseError::BadVersion));
    }

    #[test]
    fn parse_ehdr_rejects_entry_at_data_base() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, DATA_BASE, 0, 0);
        assert_eq!(parse_ehdr(&buffer), Err(ParseError::EntryOutOfBounds));
    }

    #[test]
    fn parse_ehdr_rejects_too_many_program_headers() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, 0x1000, 0, MAX_PHDRS + 1);
        assert_eq!(parse_ehdr(&buffer), Err(ParseError::TooManyPhdrs));
    }

    #[test]
    fn parse_ehdr_rejects_program_header_table_overrun() {
        let mut buffer = [0; EHSIZE];
        write_ehdr(&mut buffer, 0x1000, EHSIZE as u64, 2);
        assert_eq!(parse_ehdr(&buffer), Err(ParseError::PhoffOutOfBounds));
    }

    #[test]
    fn iterate_phdrs_decodes_two_load_segments() {
        let mut buffer = [0; EHSIZE + 2 * PHENTSIZE + 0x1000];
        write_ehdr(&mut buffer, 0x1000, EHSIZE as u64, 2);
        write_phdr(
            &mut buffer,
            EHSIZE,
            PT_LOAD,
            PF_R | PF_X,
            (EHSIZE + 2 * PHENTSIZE) as u64,
            0x100,
            0x100,
            0,
        );
        write_phdr(
            &mut buffer,
            EHSIZE + PHENTSIZE,
            PT_LOAD,
            PF_R | PF_W,
            (EHSIZE + 2 * PHENTSIZE + 0x100) as u64,
            0x80,
            0x200,
            DATA_BASE,
        );

        let header = parse_ehdr(&buffer).unwrap();
        let mut iterator = iterate_phdrs(&buffer, header);
        let first = iterator.next_header().unwrap().unwrap();
        assert_eq!(
            (first.p_type, first.p_flags, first.p_filesz, first.p_vaddr),
            (PT_LOAD, PF_R | PF_X, 0x100, 0)
        );
        let second = iterator.next_header().unwrap().unwrap();
        assert_eq!(
            (
                second.p_type,
                second.p_flags,
                second.p_filesz,
                second.p_memsz,
                second.p_vaddr
            ),
            (PT_LOAD, PF_R | PF_W, 0x80, 0x200, DATA_BASE)
        );
        assert_eq!(iterator.next_header(), Ok(None));
    }

    #[test]
    fn iterate_phdrs_rejects_load_file_range_overrun() {
        let mut buffer = [0; EHSIZE + PHENTSIZE];
        let buffer_len = buffer.len() as u64;
        write_ehdr(&mut buffer, 0x1000, EHSIZE as u64, 1);
        write_phdr(
            &mut buffer,
            EHSIZE,
            PT_LOAD,
            PF_R,
            buffer_len,
            0x1000,
            0x1000,
            0,
        );
        let mut iterator = iterate_phdrs(&buffer, parse_ehdr(&buffer).unwrap());
        assert_eq!(iterator.next_header(), Err(ParseError::PhoffOutOfBounds));
    }

    #[test]
    fn iterate_phdrs_ignores_non_load_file_bounds() {
        let mut buffer = [0; EHSIZE + PHENTSIZE];
        write_ehdr(&mut buffer, 0x1000, EHSIZE as u64, 1);
        write_phdr(
            &mut buffer,
            EHSIZE,
            4,
            0,
            u32::MAX.into(),
            u32::MAX.into(),
            u32::MAX.into(),
            0,
        );
        let mut iterator = iterate_phdrs(&buffer, parse_ehdr(&buffer).unwrap());
        assert_eq!(iterator.next_header().unwrap().unwrap().p_type, 4);
    }

    #[test]
    fn iterate_phdrs_rejects_memory_size_overflow() {
        let mut buffer = [0; EHSIZE + PHENTSIZE];
        write_ehdr(&mut buffer, 0x1000, EHSIZE as u64, 1);
        write_phdr(
            &mut buffer,
            EHSIZE,
            PT_LOAD,
            PF_R,
            EHSIZE as u64,
            0,
            0x2000,
            u64::MAX - 0xfff,
        );
        let mut iterator = iterate_phdrs(&buffer, parse_ehdr(&buffer).unwrap());
        assert_eq!(iterator.next_header(), Err(ParseError::MemszOverflow));
    }

    #[test]
    fn iterate_phdrs_rejects_mapping_above_stack_low() {
        let mut buffer = [0; EHSIZE + PHENTSIZE];
        write_ehdr(&mut buffer, 0x1000, EHSIZE as u64, 1);
        write_phdr(
            &mut buffer,
            EHSIZE,
            PT_LOAD,
            PF_R,
            EHSIZE as u64,
            0,
            0x1000,
            STACK_TOP,
        );
        let mut iterator = iterate_phdrs(&buffer, parse_ehdr(&buffer).unwrap());
        assert_eq!(iterator.next_header(), Err(ParseError::VaddrOutOfBounds));
    }
}
