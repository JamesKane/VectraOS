# ADR-0012: task_exec, so exec keeps the task

Status: accepted, 2026-10-01. A new syscall, the 62nd (01 §3).

## Context

In 9front, `exec` replaces a process's memory and keeps everything else: the `Proc`, and so its pid, its parent, its note group, its open files and its namespace (`port/sysproc.c`, `sysexec`). ADR-0011 makes the kernel's task id the pid, so `exec` has to keep the task.

Today it cannot. VectraOS loads programs in user space (01 §9): the parent builds a new task with vx-rt's ELF loader, and the musl back end's `execve` does the same, then ends the old task. So the process moves to a new task id. `posixd` papers over that with `EXEC`, which remaps the pid to the new task. The old task's exit, status 0, is seen by whoever watches it, and `gsh` and `svcd` take it for the program ending. And descriptors cross an `exec` the same way they cross a spawn, through `Tshare`/`Tjoin` tokens and a 10-second window (docs/proto/posix.md).

A loader cannot replace its own address space from inside it: it would unmap the code it runs. So the kernel has to do the swap. Every other part of loading stays in user space.

## Decision

- **`task_exec(scratch, bootstrap, entry, sp)`**: the calling task takes the address space of `scratch`, a task the caller made and filled with the new image and stack (vx-rt's loader, as for a spawn), and goes on as the new program:
  - Its mappings and page tables become `scratch`'s. Its old ones go to `scratch`, which ends with the empty exit string and is torn down.
  - Its handles are all closed, except `bootstrap`, a channel end holding the spawn message. That end is moved to the new program as its first argument, exactly as `thread_start` gives a spawned program its bootstrap channel (01 §3). So the new program starts with exactly what its spawn message names, as any program does: no ambient authority.
  - A new thread starts at `entry` with `sp`, and the calling thread ends, so the thread pointer, the FP/SIMD state and the note queue start fresh. The in-task exception handler is cleared. Exception ports and a debugger's bindings stay, as a 9front debugger stays attached across `exec`.
  - The task keeps its id, its parent and its `EXIT` bindings, which fire only when the task really ends. It takes `scratch`'s name, the new program's.
- **Only a task with one live thread may call it** (`BAD_STATE` otherwise). The musl back end is single-threaded until pthreads (docs/milestones.md). A threaded caller will end its other threads first, as POSIX's `execve` requires.
- **The swap needs no cross-CPU TLB shootdown.** The kernel uses no ASIDs or PCIDs yet (`kernel/arch/*/arch.c`), so loading the new tables drops every cached translation on this CPU, and no other CPU has the old tables loaded, since the task has no other thread. When ASIDs arrive, `task_exec` gives the task a fresh one.
- **What the call replaces:** `posixd`'s `EXEC` remapping, and the false exit 0 that `gsh` and `svcd` see. Descriptors still cross an `exec` as they cross a spawn, joined by token (docs/proto/posix.md): the connections and their fids live in the old program's memory, and handing them to the new program whole is later work, for when the 10-second join window matters.

## Consequences

- The syscall surface is 62 calls. 01 §3 lists `task_exec` beside `task_create`.
- `vx-rt`'s loader gains an `exec` mode: it builds into a scratch task and calls `task_exec` instead of `thread_start`. The spawn message it writes names the caller's own task as `self`.
- `procfs` sees no exit for an `exec`, and has nothing to remap: the pid and the registration simply carry on.
- ktest checks that the task id and an `EXIT` binding survive `task_exec` and the task takes the new program's name, that every other handle is gone, and that a task with two threads is refused. ctest checks that `execve` keeps the pid and the parent.
