/*
 * Linux arm64 boot header for board/virt.
 *
 * Layout per Documentation/arm64/booting.rst:
 *   0x00  4B   `b _start_real`        (branch to real boot prologue)
 *   0x04  4B   reserved (0)
 *   0x08  8B   text_offset = 0x80000  (linker pins the kernel at
 *                                       loader_start + 0x80000 =
 *                                       0x40000000 + 0x80000 = 0x40080000;
 *                                       Linux uses 0 here only because it
 *                                       relocates at runtime, which FlashOS does not)
 *   0x10  8B   image_size             (`_image_size`, set by linker.ld
 *                                       to `_end - _image_start`)
 *   0x18  8B   flags = 0xa            (bit1=LE, bit3=4K pages)
 *   0x20  24B  reserved (0)
 *   0x38  4B   magic 'ARM\x64' = 0x644D5241 (LE)
 *   0x3C  4B   pe_header_offset = 0   (no embedded PE header)
 *
 * Total: 64 bytes. The header occupies its own section
 * `.text.boot.header` so the linker script can place it as the very
 * first bytes of the image, before `.text.boot` and the existing
 * `_start` / `_start_real` label pair in src/boot.S.
 */

.section ".text.boot.header"

    b       _start_real             /* 0x00 */
    .long   0                       /* 0x04 */
    .quad   0x80000                 /* 0x08  text_offset */
    .quad   _image_size             /* 0x10  image_size */
    .quad   0xA                     /* 0x18  flags */
    .quad   0                       /* 0x20  reserved */
    .quad   0                       /* 0x28  reserved */
    .long   0                       /* 0x30  reserved */
    .long   0                       /* 0x34  reserved */
    .long   0x644D5241              /* 0x38  magic 'ARM\x64' */
    .long   0                       /* 0x3C  pe_header_offset */
