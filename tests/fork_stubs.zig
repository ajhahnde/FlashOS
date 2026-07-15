// No-op fd-table stand-in shared by the fork and sched host tests. The real fd
// table is Rust-owned (crates/kernel); these targets only need its bulk ops to
// link, and their behaviour is covered by the crates/kernel oracle.

const layout = @import("task_layout");
const TaskStruct = layout.TaskStruct;

pub fn dupAll(_: *TaskStruct, _: *TaskStruct) void {}
pub fn closeAll(_: *TaskStruct) void {}
