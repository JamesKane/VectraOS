# ADR-0010: Notes and exit strings

Status: accepted, 2026-10-01. Changes `thread_interrupt`, `task_kill`, `task_info` and the `EXIT` packet (01 §3, §4.4).

## Context

VectraOS is Plan 9 evolved, in standard C (00 §1). Plan 9 has two kernel mechanisms for ending and interrupting processes, and both carry strings:

- **Exit strings.** `exits(char*)`. The empty string is success, and anything else is the reason. A parent reads it in a `Waitmsg`, and rc keeps it as `$status`.
- **Notes.** Notes are strings of up to `ERRMAX` (128) bytes, posted by writing `/proc/n/note` or `notepg`, or by the kernel itself (`interrupt`, `hangup`, `sys: write on closed pipe`, `sys: trap: …`). A process that has called `notify` handles a note and answers `noted(NCONT)` or `noted(NDFLT)`. A process that hasn't is killed, and the note becomes its exit string.

The code has neither:

- A task's exit status is an `int64_t` (`abi/vx/abi.h`). A kill is a negative number. So the reason for a failure is lost before any shell sees it.
- `thread_interrupt` carries one `uint64_t`, and fails with `BAD_STATE` unless the task has an in-task exception handler. Only the musl back end installs one. So a native program can be killed, but not interrupted.
- POSIX signals were built beside this, not on it: masks and delivery in the back end, sending through `posixd`.

The C dialect is not the reason. `exits(char*)`, `notify` and `noted` are plain C APIs.

## Decision

- **A task ends with an exit string:** UTF-8, at most 128 bytes, and empty for success.
  - `task_kill(task, msg, len, id)` takes the string. `vx_exits(msg)`, and `vx_exit_str` for a slice, are `task_kill` on the caller's own task. A task whose last thread exits ends with the empty string. (Amended 2026-10-02: the argument order and names as built.)
  - The kernel writes the string itself when it kills a task, in Plan 9's words: `sys: trap: fault read addr=0x… pc=0x…`, `sys: trap: illegal instruction`.
  - `task_info` returns the string. The `EXIT` packet's `value` is 0 for success and its length otherwise, so a supervisor such as `svcd` reads the string only on a failure.
- **A note is a string of at most 128 bytes, queued per task and delivered by the kernel.**
  - `thread_interrupt(task, thread, note, len)` replaces the `uint64_t` value. Thread 0 means any thread, which is what a process-directed note uses.
  - Up to eight notes are queued, as now. A note posted to a full queue fails with `SHOULD_WAIT`.
  - Delivery works as 01 §9 and step 1b already do. A blocked call ends with `ERR_INTERRUPTED`, and the thread is diverted to the in-task handler. The exception record now carries the note's text.
- **With no handler, a note ends the task, with the note as its exit string.** This replaces `BAD_STATE`. Every native program can now be interrupted, and a killed one says why.
- **vx-rt gains Plan 9's API in standard C:** `vx_notify(handler)`. The handler gets the note and the `vx_exception` it came in, and returns `VX_NCONT` or `VX_NDFLT` where Plan 9's calls `noted`, so the FP/SIMD state saved around it is restored before the thread goes on (`lib/vx-rt/note.c`). A fault reaches the handler too, as a note in Plan 9's words. A native program's `vx_main` returns its exit string, as `exits` takes one. A note never interrupts a ring submission: the existing rule that blocks interrupts for the few instructions of a submit still applies.
- **A note interrupts a 9P call.** The client sends `Tflush` for the request in flight, as Plan 9's `devmnt` does, and the call ends with `ERR_INTERRUPTED`. This needs `Tflush` and per-request reply offsets in vx-9p (a known gap in [docs/milestones/known-gaps.md](../milestones/known-gaps.md)), so it lands with them.
- **POSIX signals are built on notes, as 9front's APE builds them.**
  - `kill` posts a note.
  - The back end's note handler maps the note to a signal through one table. That table names the signals Plan 9 already has notes for (`interrupt` SIGINT, `hangup` SIGHUP, `alarm` SIGALRM, `sys: write on closed pipe` SIGPIPE, `sys: trap: …` SIGSEGV, SIGILL, SIGFPE), and spells the rest `posix: SIGTERM` and so on.
  - Masks, pending sets, `SA_RESTART` and handlers stay in the back end, as step 3d built them.
  - `SIGKILL` is `task_kill` with `killed`.
  - Stopping is not a note: it stays `thread_suspend` (ADR-0011).
- **POSIX exit codes map to exit strings, as APE's do.** `exit(0)` is the empty string, and `exit(n)` is the decimal `n`. `wait` turns a decimal string back into `WEXITSTATUS`, a string the note table knows into `WTERMSIG`, and anything else into exit status 1.

## Consequences

- The syscall count stays at 61: two calls change their arguments and none is added. (ADR-0012 later added `task_exec`, the 62nd.) The task object grows by 128 bytes for the exit string, plus the note queue (8 × 128 bytes).
- rc-style `$status` becomes possible: the shell keeps the string, and a pipeline's statuses are joined with `|`.
- `svcd` logs why a service died, not just a number.
- This changes the kernel ABI, so it comes before more code is built on the integer status. It also unblocks two items in [the known gaps](../milestones/known-gaps.md), SIGPIPE and SIGHUP from `ptyd`, which are now notes the kernel or `ptyd` posts.
