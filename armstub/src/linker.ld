/*
 * armstub8 link script: place .text at address 0 (the firmware drops the
 * stub there and jumps to it). Mirrors the original Makefile invocation
 * `aarch64-elf-ld --section-start=.text=0 -o armstub8.elf armstub8.o`.
 */

ENTRY(_start)

SECTIONS
{
    . = 0;
    .text : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data : { *(.data .data.*) }
    .bss : { *(.bss .bss.*) *(COMMON) }
}
