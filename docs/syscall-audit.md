# V1 syscall audit

This is the V1 audit of croi's system calls against principle 4 (the kernel
is a setup engine) and principle 1 (one mechanism per job). It covers the
154 calls in `user/include/croi/syscall.h` at `f18fe3f`.

The rule applied: **if a job can be done with a ring and a doorbell, the
kernel does not do it.** The kernel keeps what only it can do:
- memory and address spaces;
- threads and scheduling;
- handles and rights, and moving them between processes;
- waking a sleeper;
- hardware access;
- observing and debugging.

Copying bytes between processes is not on that list.

## 1. The shape that results

| Job | Mechanism | Kernel calls on the hot path |
|---|---|---|
| Bulk data, streams, events | One ring format (architecture §3) in a shared VMO | none while both sides are busy |
| Waking the other side of a ring | A counter, bound once to the sleeper's port | one `counter_add` by the waker, one `port_wait` by the sleeper |
| Every wait | A port, drained as a ring (D19); `port_wait` with a deadline and a leeway only when it is empty | none while events are pending |
| Event sources (signals, counters, IRQs, overruns, memory pressure) | `object_bind` to a port, once or persistently | none per event once bound |
| Control (Node protocol) and handle transfer | Channels: `channel_call`, whose message is a batch of Node operations (D18); servers read and reply with `channel_read` and `channel_write` over many channels at once | one per batch |
| Locks | Futex (wait and wake only) | none uncontended |
| Time | vDSO for monotonic; a shared page from the time service for UTC | none |
| Sleeping | `port_wait` on the thread's own port with a deadline and a leeway (principle 10) | one |

**Three changes go beyond deleting calls.** The third is batching (§3).

**`object_bind` (new, by merging five calls).** Today every wait is
one-shot, as in Zircon. Only interrupts bind persistently. todhchai's
dispatcher pays one `wait_async` for every message it receives (survey
§8), and a sleeping ring consumer pays `wait_async` plus `port_wait` per
wakeup. `object_bind(port, items, count)` binds many sources at once; each
item names an object, a key, a trigger and options. It has two modes:
- `ONCE` behaves like today's `wait_async`.
- `PERSISTENT` keeps one coalescing packet that the source re-arms, as
  interrupts already do.

It replaces `object_wait_async`, `interrupt_bind`, `counter_wait_async`,
`thread_bind_overrun_port` and `account_bind_pressure_port`.

**The kernel speaks the ring format where it produces data.**
- `debuglog_read` becomes a read-only ring VMO with a counter. The V3
  `log -f` reads it with no syscalls.
- Trace buffers follow, at V2 with the trace producer.

## 2. Verdicts

Legend: **keep**, **merge** (the call survives under a combined form),
**cut** (with what replaces it).

### Basics and handles

| # | Call | Verdict | Replacement or reason |
|---|---|---|---|
| 0 | null | keep | the null-syscall budget |
| 1 | debug_write | cut | `debuglog_write`; one way to log |
| 2 | thread_exit | keep | |
| 3 | clock_monotonic | cut | vDSO `croi_vdso_clock_monotonic` already reads the counter |
| 4 | nanosleep | cut | `port_wait(own port, deadline)` |
| 5, 6 | test_report, test_profile | merge | one `test(op, …)` call, self-test builds only |
| 10, 211 | handle_close, handle_close_many | merge (D33) | `handle_close(handles, count)` |
| 11, 12 | handle_duplicate, handle_replace | merge (D34) | `handle_duplicate(h, rights, options)`; `CONSUME` replaces |

### Signals, waits and ports

| # | Call | Verdict | Replacement or reason |
|---|---|---|---|
| 20, 85 | object_signal, object_signal_peer | cut | counters; user signals were only ever eventpair kicks |
| 21 | object_wait_one | cut | ports are the only wait (architecture §2) |
| 210 | object_wait_many | cut | ports |
| 22 | object_wait_async | merge | `object_bind` |
| 30 | event_create | cut | counter |
| 84 | eventpair_create | cut | counter; ring peer death is the negotiating channel's PEER_CLOSED |
| 31–33 | port_create, port_queue, port_wait | keep | |
| 34, 212 | port_cancel, port_cancel_key | merge (D32) | one `port_cancel(port, source or 0, key)` |

### Memory

| # | Call | Verdict | Replacement or reason |
|---|---|---|---|
| 40, 45–49, 155 | vmo create, op_range, set_cache_policy, create_physical, create_child, replace_as_executable, create_contiguous | keep | |
| 41, 42 | vmo_read, vmo_write | cut | map; every caller is a setup path (bootfs, ELF, BootData) |
| 43 | vmo_map | cut | legacy, "until VMARs (K7)"; `vmar_map` |
| 44 | vmo_get_size | merge | a `get_info` topic |
| 233 | vmo_set_size | keep | resizable VMOs for Taisce's mapped files |
| 70–76, 244 | vmar allocate, map, unmap, protect, destroy, unmap_handle_close_thread_exit, op_range, map_view | keep | |
| 77 | vmar_map_clock | cut | with clock objects |
| 200, 201 | vmo_get/set_stream_size | cut | with streams |
| 202–208 | pager (7 calls) | keep | reviewed again at V5, when Taisce is the user |
| 240, 241, 243 | account create, set_limit, process_set_account | keep | RSS budgets |
| 242 | account_bind_pressure_port | merge | `object_bind` on the account |
| 235 | system_get_event | cut (D31) | `object_bind` on the root account; its event objects go with events |

### Tasks, exceptions, debugging

| # | Call | Verdict | Replacement or reason |
|---|---|---|---|
| 60–65, 67 | job/process/thread create, start, exit, task_kill | keep | |
| 68 | process_info | merge | a `get_info` topic |
| 78 | object_get_child | keep | ps and the launcher's task tree |
| 86, 103, 104 | get_info, get/set_property | keep | |
| 100–102, 105, 106 | exception channel, get_thread, get_process, thread read/write state | keep | |
| 107, 108 | job_set_policy, job_set_cpu_reservation | keep | |
| 230–232 | process read/write memory, task_suspend | keep | |
| 236 | thread_raise_exception | cut (D30) | nothing raises user exceptions; restored with a debugger that needs it |

### IPC copies

| # | Call | Verdict | Replacement or reason |
|---|---|---|---|
| 80–83 | channel create, write, read, call | keep | control and handle transfer |
| 213–215 | channel write/read/call _etc | cut | one form; rights are narrowed with `handle_duplicate` before sending |
| 87–89 | fifo create, write, read | cut | rings |
| 190–193 | socket create, write, read, set_disposition | cut | byte rings |
| 194–199 | stream (6 calls) | cut | map the VMO |

### Synchronisation and time

| # | Call | Verdict | Replacement or reason |
|---|---|---|---|
| 90, 91 | futex_wait, futex_wake | keep | |
| 92–94 | futex_requeue, wake_single_owner, get_owner | cut | todhchai's Lock and pthreads use wait and wake only |
| 95–97 | timer create, set, cancel | cut | `port_wait` deadlines; an event loop waits for its earliest |
| 216–219 | clock create, read, get_details, update | cut | the time service publishes UTC in a read-only seqlock VMO |
| 160–162 | counter create, add, read | keep | the doorbell and the fence |
| 163 | counter_write | cut | `counter_add` of the difference |
| 164 | counter_wait | cut | ports |
| 165 | counter_wait_async | merge | `object_bind` with a value trigger |
| 170–173 | timeline (4 calls) | cut | a counter; Radharc paces the synthetic vblank itself, and a real display's IRQ thread adds to the counter |

### Drivers, hardware, observability

| # | Call | Verdict | Replacement or reason |
|---|---|---|---|
| 130–132 | resource_create, ioports request/release | keep | |
| 140, 142, 146–148 | interrupt create, ack, set_affinity, msi allocate, msi create | keep | |
| 141 | interrupt_bind | merge | `object_bind` |
| 143 | interrupt_wait | cut | ports (only todhchai's edu test driver used it) |
| 144 | interrupt_destroy | cut | `handle_close` |
| 145 | interrupt_trigger | cut | virtual interrupts are counters |
| 150–154, 156 | iommu, bti create/pin/release_quarantine/set_properties, pmt_unpin | keep | |
| 234 | smc_call | keep | the Q8B's SCM calls |
| 180 | system_powerctl | keep | gains warm boot in V3 |
| 181, 182 | cprng draw, add_entropy | keep | |
| 245 | cpu_set_idle_states | keep | |
| 50, 51 | trace_configure, pmu_configure | keep | |
| 110, 111 | debuglog create, write | keep | |
| 112 | debuglog_read | cut | a read-only ring VMO plus a counter |
| 120, 121 | profile_create, object_set_profile | keep | |
| 122 | thread_bind_overrun_port | merge | `object_bind` on the thread |

### Count

| | Calls |
|---|---|
| Today | 154 |
| Removed by merges (net) | 10 |
| Cut | 53 |
| **After V1** | **91** |

**Progress:** `object_bind` landed (D20): 150 calls. FIFOs, sockets and
streams were cut (D21): 135 calls. The channel `_etc` forms and the
futex extras were cut (D22): 129 calls. Events, signals and the thread
waits were cut (D23): 123 calls. Sleeps, timers and the counter waits
were cut (D25): 117 calls. Clock objects, vmar_map_clock and the
clock_monotonic syscall were cut (D26): 111 calls. Display timelines
were cut (D27): 107 calls. debug_write and vmo_map were cut (D28): 105
calls. interrupt_wait, interrupt_destroy and interrupt_trigger were cut
(D29): 102 calls. thread_raise_exception was cut (D30): 101 calls. system_get_event was
cut (D31): 100 calls. port_cancel_key merged into port_cancel (D32): 99
calls. handle_close_many merged into handle_close (D33): 98 calls.
handle_replace merged into handle_duplicate (D34): 97 calls.

The ceiling in `tools/vx/LocCommand.swift` is lowered with each cut, so it
never rises.

## 3. Batched forms (principle 12, D18)

Where there is one, there will be many. Each hot call takes an array of
its own items and a count, and the single case is an array of one. Calls
on cold paths, such as creating a process, stay single. The array form
replaces the single form; it is not added beside it, so the count in §2
does not change.

| Call | Items | Who sends many |
|---|---|---|
| `handle_close` | handles | process teardown, a dispatcher dropping clients |
| `handle_duplicate` | handle, rights, options (`CONSUME`) | a launcher handing a child its handles |
| `object_bind` | object, key, trigger, options | a dispatcher arming every channel; a driver arming its IRQs and doorbells |
| `port_queue` | packets | a service waking many waiters |
| `port_wait` | out: packets, up to a count | interim, until the port is a ring (D19) |
| `counter_add` | counter, amount | a service completing work on many rings rings every doorbell at once |
| `channel_read` | channel, buffer, handle buffer; out: sizes, status | a server reading every channel its port reported ready |
| `channel_write` | channel, bytes, handles; out: status | a server replying to every request it read |
| `channel_call` | one channel, but the message is a batch of Node operations | every Node client |
| `vmar_map` | VMAR offset, VMO, VMO offset, length, options | spawn mapping a program's segments (spawn → main < 200 µs) |
| `vmar_unmap`, `vmar_protect` | ranges | teardown, the loader's RELRO pass |
| `interrupt_ack` | interrupts | an IRQ thread serving several vectors |

Already arrays today: `bti_pin` (addresses out), `futex_wake` (a count),
`get_info` topics that list koids.

Each failure is reported per item: the call returns how many items it
processed, and each item carries its own status. A call never undoes the
items before a failure.

**Budget, proposed for V2** (where the Node protocol lands, so it lands
with its check): the kernel's cost per item in a batch of 64
`channel_read`s or `object_bind`s is at most a quarter of a single call's.

## 4. What todhchai's userland must change (V2)

Each of these is rewritten as it is lifted in V2, not in V1. From the
survey of todhchai at 527ff94:

| todhchai today | V2 form |
|---|---|
| Six ring formats (TDBR block, TDFR frames, TDNR TCP, TDIR input, TDPR PCM, TDSR audio) with eventpair kicks | The one ring format and `Ring.swift`; the kick becomes a counter bound persistently to the sleeper's port. TDNR's byte rings are the byte-stream mode. |
| Sockets for the pty, terminal, rc pipes and floor stdio (fds 0–2) | Byte rings. stdio is a ring the floor maps at start; `pipe()` makes a ring and its counters. The pty's flow control is ring fullness, not `set_disposition`. |
| Events (Radharc latch, input key repeat, launcher "ready", virtio-gpu IRQ thread, keyring) | Counters |
| `Timer` (app `Loop`, fs commit delay) and ~30 `sleep(until:)` sites | The loop's `port_wait` deadline; sleep is `port_wait` on the thread's port |
| `Handle.wait` (IPC receive, ring sleeps, socket I/O, process end, join) | One port per thread, kept by the floor; waits bind `ONCE` and wait there |
| Dispatcher re-arms with `wait_async` after every message | `object_bind PERSISTENT`, once per channel |
| ~50 `VMO.read`/`write` sites (bootfs, ELF loading, BootData, trace readback, listings) | Mapping; one shared helper replaces the bootfs boilerplate copied into eight programs |
| Timeline (Radharc only) | A counter plus Radharc's own deadline thread |
| Clock objects and the clock page mapped at start | The time service's UTC page, handed to each process at start |
| Node `read`/`write` in 32 KiB channel calls | Unchanged for small I/O; bulk opens a ring (see question 1) |

## 5. Consequences

- **`vx todhchai-check` retires at the first cut.** It boots todhchai's
  binaries on this kernel. From V1 on, the ABI is VectraOS's, and V2 lifts
  the userland onto it.
- **croi's user tests shrink.** `user/test/usertest.c` (6,223 lines)
  tests each call; tests of a cut call go with it.
- **Each cut is its own commit.** It updates the call's design note, its
  tests, `zircon-divergences.md`, the ceiling, and adds a decision entry
  (architecture §2 asks for "each confirmed by an entry in the decision
  log").

## 6. Settled questions

1. **The Node protocol stays on channels, and its messages are batches**
   (D18). Only bulk traffic moves to rings.
2. **Ports become rings** (D19), after the cuts and `object_bind`.
