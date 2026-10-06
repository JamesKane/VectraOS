# ADR-0036: Note stacks

Status: accepted, 2026-10-06 (proposed 2026-10-05). M6 step 6d2b's change to the ABI (01 §3): a stack per thread for its in-task handler, which POSIX's `sigaltstack` maps onto. No new syscall: two `thread_state` ops and a struct.

## Context

The kernel diverts a thread to its task's in-task handler (exception(2)) by writing the `vx_exception` below the thread's own stack pointer and starting the handler there. If the stack cannot take it, the fault goes on to the exception port: procfs, which saves a crash directory and ends the process.

That loses the one fault a program most wants to catch: running off the end of its stack. Its stack pointer is in the guard page, so there is no room to divert to. On POSIX systems a program that wants to survive it, or report it, sets an alternate signal stack with `sigaltstack` and marks its `SIGSEGV` handler `SA_ONSTACK`, and the kernel delivers the signal there. Swift's crash handler and backtracer (`swift-backtrace`, the Swift port's inventory) do this. So do language runtimes with guard pages (Rust's main-thread guard, Go), and crash reporters generally.

The musl back end could switch to an alternate stack itself before calling a handler. That covers every case but the one that matters, because the switch happens after the kernel has already had to find room on the old stack.

## Decision

1. **`VX_STATE_SET_NOTE_STACK` and `VX_STATE_GET_NOTE_STACK`,** with thread 0, set and read the calling thread's note stack, a `vx_note_stack {base, size}`.
   - Size 0 means none.
   - Otherwise the size is at least `VX_NOTE_STACK_MIN` (2048 bytes, POSIX's `MINSIGSTKSZ` on x86_64), inside user memory (`RANGE` if not).
   - Another thread's cannot be set (`INVALID`): it is the thread's own, as `sigaltstack` is.
2. **The divert:** when a thread has a note stack and its stack pointer is not on it, the kernel diverts it to the top of the note stack. Otherwise, as now, it diverts below its stack pointer. A handler that faults while on the note stack nests below itself there, so the rule needs no state beyond the stack pointer: a handler that leaves by `longjmp` leaves the stack, and the next note finds it free.
3. **Every note uses it,** faults and interrupts alike. The kernel does not know which signal a note will become, nor its handler's flags. The musl back end runs an `SA_ONSTACK` handler on the alternate stack in the cases the kernel did not divert there (a signal delivered as a call returns). A handler without `SA_ONSTACK` may therefore run on the alternate stack when the thread has one, where Linux would use the thread's own. No program is known to rely on that.
4. **Lifetime:** a new thread has none, as POSIX has it for `pthread_create`. `fork`'s thread and `exec`'s are new threads, so they have none. The musl back end sets the forked child's again from its own record, since the child has the parent's memory.
5. **The musl back end:**
   - `sigaltstack` sets the note stack: `ENOMEM` under `MINSIGSTKSZ`, `EPERM` while on it, `SS_AUTODISARM` refused.
   - A handler's `ucontext` carries the registers the note or fault interrupted, and the FP/SIMD state that vx-rt's note entry saved. On x86_64 `fpregs` points at the XSAVE image, whose head is FXSAVE's, as Linux's `_fpstate`; on aarch64 an `fpsimd_context` sits in `__reserved`.
   - What the handler changes there is what the thread resumes with. vx-rt's note handler gets the saved state as a third argument for this.

## Consequences

- The ABI grows by two `thread_state` ops, `vx_note_stack` and `VX_NOTE_STACK_MIN`, and the kernel's thread by two words.
- A stack overflow is catchable in C, by `sigaltstack` and `SA_ONSTACK`, and natively by setting the note stack and binding a handler. ktest covers the native case and ctest the POSIX one.
- The note entry needs room. x86_64 saves 4160 bytes of XSAVE image before any C runs, and aarch64's `ucontext_t` is 4.5 KiB. `SIGSTKSZ` (8 KiB on x86_64, 12 KiB on aarch64) is enough and is what ctest uses. `MINSIGSTKSZ` is enough for the kernel's frame alone; a stack that small overruns its bounds if a handler runs there, as it can on Linux.

## Alternatives

- **Switching stacks in the C library alone:** no ABI change, but a stack overflow still cannot be caught. Rejected for that reason (decided 2026-10-05).
- **A per-task handler stack:** one stack cannot serve two threads faulting at once.
- **Only faults on the note stack, interrupts on the thread's own:** closer to Linux for handlers without `SA_ONSTACK`, but it is one more rule in the kernel for a difference no program is known to see.
- **A flag the kernel keeps while a thread is on its note stack** (Linux's `SS_ONSTACK` state follows the stack pointer too): the stack pointer alone already says it, and `longjmp` out of a handler keeps it true.
