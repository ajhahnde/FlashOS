//! Process lifecycle: the scheduler, `fork`/`execve`, the ELF loader, and the
//! wait-queue primitive tasks block on.
pub mod elf;
pub mod execve;
pub mod fork;
pub mod sched;
pub mod wait_queue;
