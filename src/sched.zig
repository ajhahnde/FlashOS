// Transitional adapter for the Rust-owned scheduler.
//
// Historical scheduler functions are provided by crates/klib with their
// original C symbols. The shared globals stay defined here for the surviving
// Flash/Zig direct loads. Only sys_kill calls a scheduler helper through a
// named module, so this adapter also preserves that source API until the
// syscall module moves to Rust.

const layout = @import("task_layout");

pub const TaskStruct = layout.TaskStruct;
const NR_TASKS: usize = 64;

// Keep the cross-language storage in the Zig-linked image while Flash/Zig
// consumers still access these globals directly. Defining them inside the Rust
// archive makes those consumers materialize a low-half GOT pointer, which is
// unmapped after TTBR0 switches to a user page table. Rust owns every mutation
// rule and reaches this same storage through direct extern symbols.
export var current: ?*TaskStruct = null;
export var task: [NR_TASKS]?*TaskStruct = [_]?*TaskStruct{null} ** NR_TASKS;
export var nr_tasks: i32 = 1;
export var next_pid: i32 = 1;

extern fn fos_sched_zombify_and_wake_parent(task: *TaskStruct) void;

pub fn zombify_and_wake_parent(target: *TaskStruct) void {
    fos_sched_zombify_and_wake_parent(target);
}
