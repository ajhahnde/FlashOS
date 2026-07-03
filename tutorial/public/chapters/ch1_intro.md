# Chapter 1: What is FlashOS

Placeholder — scaffold milestone (M1). Full content lands in M2.

```flash
// hello.flash - the smallest Flash program: write a line, then exit.
use flibc

link "flibc_start"
link "flibc_mem"

export fn main(_ usize, _ argv) noreturn {
    msg := "Hello from FlashOS!\n"
    _ = flibc.sys.write_fd(1, msg.ptr, msg.len)
    flibc.exit()
}
```
