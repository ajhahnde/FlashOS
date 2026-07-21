# 5. Console I/O: One API, Three Channels

FlashOS separates the interactive user console from kernel diagnostics and
function tracing. On a Raspberry Pi 4B, three physical/logical channels are in
play.

| Channel | Role |
| :------ | :--- |
| Mini-UART on GPIO 14/15 | kernel diagnostics and fallback user console |
| USB-C CDC-ACM gadget | preferred interactive user console after enumeration |
| PL011 on GPIO 8/9 | out-of-band function-entry trace stream |

## One input ring

Mini-UART RX interrupts and the USB gadget both feed the 256-byte input ring in
`crates/kernel/src/console.rs`. A process reading a console descriptor blocks
on a wait queue when no byte is ready. The IRQ/device path wakes the reader
after inserting input.

This keeps busy loops out of EL0 and gives both transports the same syscall
semantics.

## Output routing

User output goes to USB once the CDC-ACM gadget is configured and otherwise
falls back to Mini-UART. Kernel diagnostics always stay on Mini-UART. A USB
disconnect therefore cannot hide a kernel panic or bring-up message.

The console is represented by the same tagged descriptor table used for pipes
and files. Unified `read`, `write`, `close`, and `dup2` syscalls dispatch by
descriptor kind in `crates/kernel/src/fdtable.rs` and
`crates/kernel/src/sys.rs`.

## Raw and cooked interaction

The current userland stack supplies key decoding and line editing in
`crates/flibc/`. `fsh` uses readline, history, and completion. Full-screen
programs such as `less` and `edit` use raw key decoding and the alternate
screen. The kernel provides byte transport and console-mode syscalls; policy
and rendering remain in EL0.

## Testing without a human

The runtime harness can inject deterministic console input through a
test-only syscall enabled by the selftest build. The `console-echo` scenario
then validates blocking read and echo behavior. Production images do not use
that path for ordinary input.

Under QEMU, `run qemu` connects Mini-UART to host stdio because the emulated
Pi does not provide the real USB device-mode data path. USB enumeration and
replug behavior are accepted on real Pi hardware.

> [!TIP]
> Kernel faults appear only on Mini-UART. For hardware fault diagnosis use the
> Mini-UART capture path even if the normal interactive session uses USB-C.

Next, we see how timer interrupts move the CPU between runnable tasks.
