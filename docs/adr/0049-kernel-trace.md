# ADR-0049: the kernel's trace

Status: proposed, 2026-10-08 (M7 step 7a1). Design: docs/20 §4.

## Context

M7's budgets are latencies spread across processes (20 §1, §9): a frame late because a server waited on a page. Nothing records what the kernel did and when. Fuchsia's ktrace and 9front's `/proc/trace` are the prior art (20 §2).

## Decision

1. **One syscall, `trace_configure(resource, op, data, len)`**, with `START` (categories, ring size, oneshot or circular), `STOP`, `REWIND`, `RINGS` (a read-only handle to the rings' VMO) and `MARK` (16 bytes of text from user space).
2. **A Resource handle with `VX_RIGHT_TRACE`** may call it, as one with `VX_RIGHT_PAGER` may make pagers: svcd gives procfs a duplicate of the root Resource with that right alone. The root's MANAGE works too. Nothing else does.
3. **One ring per CPU in one VMO**, each a header page (`vx_trace_ring`: head, drops with first and last time, the counter's frequency) then fixed 32-byte records (`vx_trace_record`: cycle counter, kind, CPU, thread, two words). The writer is the CPU itself with interrupts off, so a ring needs no lock. Oneshot drops and counts what does not fit; circular overwrites the oldest.
4. **Stopping waits for no CPU to be mid-record:** each CPU sets a flag before it reads the mask and clears it after, so once the mask is clear and every flag has been seen clear, nothing is being written. Equivalent to Fuchsia's IPI barrier, with no IPI.
5. **A thread is named `task id << 12 | its id in the task`** in 32 bits, so a reader needs no table; the kernel's own threads are 0.
6. **Probes are a macro:** one relaxed load of the mask and a branch, arguments evaluated past it, compiled into every kernel. Categories `sched`, `ipc`, `irq`, `vm`, `futex`, `syscall`, `mark` (and `sample`, 7a3); kinds in `abi/vx/abi.h`.
7. **Kernel addresses never appear in records:** channels get trace ids at creation, a futex is named by its user address, a pager's VMO by its pager key.
8. **Flows (7a2) are computed, not carried:** a CALL and its REPLY name the same flow, a hash of the pair's lower endpoint id and the `txid`; a ring's header carries the kernel's `session` id, so a ring's client and server derive a request's flow from it and the submission's `user_data`. Spans are the processes' (lib/vx-prof), merged by procfs as `VX_TK_SPAN` (64), never written by the kernel.

## Consequences

- procfs is the one reader (`/proc/trace`, 7a1b), a broad grant (ADR-0029).
- Flows (7a2) fill CALL and REPLY's second word, the txid in 7a1.
- The ABI grows a right, a syscall and two records; `libvx`'s exports do not change (the wrapper is vx-rt's, procfs's alone).
