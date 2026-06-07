// clear — wipe the terminal for /bin/clear.
//
// The smallest consumer of the console_ui screen layer: a print-and-exit
// coreutil that emits the shared screen-clear sequence (cursor home + erase)
// and leaves. The escape bytes are NOT spelled out here — they live once in
// console_ui.screen.clear so every clear path in the tree (a future /bin/mon
// redraw, a pager repaint, this tool) stays byte-identical; single-sourcing the
// terminal look is the whole point of the console_ui library.
//
// Unlike /bin/less this does not enter the alternate screen: `clear` wipes the
// *current* screen in place, exactly like the Unix coreutil, so the shell
// scrollback is untouched and the next prompt simply paints at the top.
//
// Same coreutil recipe as echo / sysinfo (flibc _start shim, flibc_mem, single
// R+X PT_LOAD via coreutil_linker.ld, stack only — rule 1). Output goes through
// the unified write_fd(1, …) so a `clear` whose stdout was redirected still
// lands on the right sink.

const flibc = @import("flibc");
const console_ui = @import("console_ui");

comptime {
    _ = @import("flibc_start");
    _ = @import("flibc_mem");
}

fn sink(bytes: []const u8) void {
    _ = flibc.sys.write_fd(1, bytes.ptr, bytes.len);
}

export fn main(_: usize, _: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    console_ui.screen.clear(sink);
    flibc.exit();
}
