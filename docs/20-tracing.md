# 20 — Tracing and profiling: design notes

_Design notes, 2026-10-07. **Non-binding** as design: each part becomes binding through the ADR its milestone row names. **Binding as schedule:** M7 step 7a (§9) is added to the milestones ([M7](milestones/M7.md)). This note moves PMU sampling from M14 to M7, which amends 04 §6 and 05 §12. Prior art (§2) was read in `../fuchsia` and `../9front` on 2026-10-07._

## 1. The gap

05 §9 specifies a profiler for **one process at a time**:
- cycle-counter zones (`lib/vx-prof`, built: one ring per thread since 6d6b);
- PMU counters and overflow sampling through `pmu_configure` (M14);
- `/proc/N/prof/` files;
- one timeline in `dbg`.

ADR-0041 adds CPU time sampled on a 10 ms tick.

That covers a monolithic program. It does not cover this system, where almost every operation crosses processes. An app's `read` goes:

```
app → 9Px ring → fsd → block ring → drv-nvme → IRQ
```

A frame goes:

```
app → /wsys → winsrv → displayd
```

When a frame takes 30 ms, the time went somewhere in that chain, and per-process zones cannot say where. What is missing:

1. **Kernel events:** context switches, wake-ups and who caused them, channel calls and donation, IRQs, page faults and pager waits, futex waits.
2. **Flows:** a request followed from client to server and on to the next server, across channels and rings.
3. **Off-CPU time:** why a thread was not running, and what woke it.
4. **Whole-machine sampling, kernel included.** `pmu_configure` takes one task, and QEMU under TCG has no PMU at all.
5. **Contention and memory:** time spent waiting on locks; heap and commit over time.
6. **A flight recorder:** the last few seconds, available after a hitch has already happened.
7. **Regression checks.** 00 §8 says its budgets are "enforced in CI" from M2 to M5. `./build bench` does not exist, so none of them is enforced.

PMU sampling is also scheduled too late. M14 comes after Pixels, GPU and Audio, the three milestones that most need a profiler.

## 2. Prior art

**Fuchsia's ktrace** is the model for the kernel side.
- **One ring per CPU.** Each ring has a single writer, which writes with interrupts off and takes no lock. The read and write counters share one 64-bit atomic (`zircon/kernel/lib/ktrace/ktrace.cc:92-110`; `lib/spsc_buffer/include/lib/spsc_buffer/spsc_buffer.h:36-46, 374-382`).
- **Stop needs no lock.** Writes are disabled, then an IPI to every CPU ensures any write in progress has finished (`ktrace.cc:275-303`).
- **Dropped records are counted**, not lost silently (`lib/percpu_writer/include/lib/percpu_writer/buffer.h:26-40`).
- **A disabled probe costs one load and a bit test**, against a category mask (`include/lib/ktrace.h:67-84, 1004-1029`).
- **Scheduler events.** The context-switch record names the CPU, the outgoing thread's state, and both threads. The wake-up record names the waker (`include/kernel/scheduler_inline.h:229-258`).
- **Flows across a channel need no coordination.** A message's flow id is hashed from the lower of the two endpoint ids and the transaction id, so sender and receiver compute the same id independently (`object/channel_dispatcher.rs:172-200`).
- **User space** has the same shape: a provider's buffer is a shared VMO, and a 16-byte FIFO carries only control (`trace-provider/include/lib/trace-provider/provider.h:29-76`).
- **Sampling.** The PMU handler records the interrupted PC, kernel or user (`arch/arm64/perf_mon.cc:853-904`). A separate timer sampler walks user frame pointers into per-CPU buffers (`lib/thread_sampler/thread_sampler.cc:204-260`).

**Take** all of the above. **Leave** FXT: its self-describing, interned-string format is built for a general trace format shared with outside viewers. Our records are fixed-size and described by `.schema` (rule 2, rule 10).

**9front shows how small this can be.**
- **One ring, one file.** `#p/trace` is a ring of 16-byte records (pid, event type, time), and `/proc/trace` reads it (`sys/include/trace.h:1-24`; `sys/src/9/port/devproc.c:77-78, 274-290, 888-908`).
- **The disabled probe is a nil function pointer** (`proc.c:489-491`, `edf.c:154`).
- **Tracing is per process.** `echo trace > /proc/n/ctl` turns it on, and `event` adds a user mark (`devproc.c:1551-1557, 1622-1625`).
- **Profiling rides the clock tick.** `kprof` charges the tick's kernel PC to a histogram (`portclock.c:157`, `devkprof.c:31-51`), and `/proc/n/profile` does the same for user PCs (`segment.c:1137-1150`). This works on any machine, with no PMU.

**Take:** procfs as the reader, per-process enabling, user marks, and sampling on the tick.

## 3. The model in one paragraph

The kernel writes **fixed-size event records** into **one ring per CPU**. Each ring is a VMO that only the kernel writes and that `procfs` maps read-only. Processes write their own records, zones plus new spans and marks, into the **per-thread rings `vx-prof` already has**. Both kinds of record are stamped with the same cycle counter. **Flow ids**, which both ends compute from what they already share, link a request across channels, 9Px rings and class rings. `procfs` merges every ring into one stream at `/proc/trace`, as 9front's `/proc/trace` does, and `dbg` draws that stream on the timeline it already has. Sampling rides ADR-0041's tick everywhere, and the PMU's overflow interrupt where there is a PMU. A **flight recorder** keeps the cheap categories running in circular mode, so the last seconds are always there.

## 4. The kernel side

### 4.1 Rings and control

- **One ring per CPU.** The size is set when tracing starts (default 1 MiB per CPU). The writer is the CPU itself, with interrupts off, so it needs no lock.
- **Overflow.** `oneshot` mode stops writing when a ring is full; `circular` mode overwrites the oldest records. Either way, drops are counted in the ring's header with the first and last dropped time, as in Fuchsia's `percpu_writer`.
- **`trace_configure(resource, op, data, len)`**, one new syscall, shaped like `cpu_configure` (ADR-0020):
  - `op` is `START` (a category mask, ring size and mode), `STOP` (IPI barrier, as Fuchsia), `REWIND` or `RINGS` (returns a read-only handle to the rings' VMO).
  - `resource` must be the root `Resource` or one `svcd` minted for tracing. Only `procfs` holds it.
- **Probes** are a macro: a compile-time gate, then one relaxed load of the category mask and a branch. Arguments are evaluated only past both checks. Probes are compiled into every kernel; a disabled one costs nothing measurable (§8).

### 4.2 The record

A record is 32 bytes. Its layout goes in `/proc/trace/.schema`, and every field is binary (rule 2):

```
uint64 time        cycle counter (/sys/clock/info gives the frequency)
uint16 kind        the event, below
uint16 cpu
uint32 tid         the kernel's thread id (/proc/N/threads), 0 in interrupt context
uint64 a, b        per kind
```

Fixed records cost some space, and buy a writer that never sizes anything and a reader that seeks. A sample's stack is the one variable part (§6). It follows its header as `b` further records of 4 PCs each (`kind=STACK`).

### 4.3 Categories and events

| Category | Events (a, b) | Why |
|---|---|---|
| `sched` | `SWITCH` (out tid and its state; in tid), `WAKE` (woken tid, by tid), `BLOCK` (port, futex, channel, pager; the object's id) | Off-CPU time, who waits for whom |
| `ipc` | `CALL`/`REPLY` (channel id, flow), `DONATE`/`RETURN` (scheduling context, server tid), `PORT` (packet delivered, key) | Requests across processes; 6d6c2's donation made visible |
| `irq` | `IRQ_IN`/`IRQ_OUT` (vector), `TIMER` (deadline, leeway) | Driver latency; rule 5's timers |
| `vm` | `FAULT` (address, kind: lazy zero, pager, copy on write, protection), `PAGER_WAIT`/`PAGER_DONE` (VMO, offset), `COMMIT` (VMO, pages, at decommit as well) | `fsd`'s supply deadlines; lazy memory (ADR-0046) |
| `futex` | `WAIT`/`WOKEN` (key, wait time) | Lock contention, `vx_lock_t` and pthreads alike |
| `syscall` | `SYS_IN`/`SYS_OUT` (number, status) | Heavy; off unless asked for |
| `sample` | `SAMPLE` (PC, source: tick or counter) and its `STACK` records | §6 |
| `mark` | `MARK` (from user space, `vx_trace_mark`, as 9front's `event`) | Annotations from scripts and tests |

## 5. Flows

A flow id is 64 bits. Each end computes it from what both already share, as Fuchsia does, so nothing extra is sent:

| Crossing | Flow id from | Written by |
|---|---|---|
| A channel call | The lower of the two endpoint ids, and the call's `txid` | The kernel, at `CALL` and `REPLY` |
| A 9Px request over a ring | The ring session's id (the client and server share it), the tag, and a per-tag generation count | `lib/vx-9p`'s client (`client.c`) and its server frameworks (`server.c`, `ring_server.c`): a `SPAN` record at request and reply |
| A class ring request (block, net, accel) | The ring session's id and the slot's sequence number (a block write already carries one, 01 §7.4) | `lib/vx-ring/session.c`, once, for every class |

A span is a new kind of `vx-prof` record. It sits beside zones in the same per-thread rings:

```
struct vx_prof_record (version 3, 32 bytes):
  uint64 start, end     cycle counter
  uint32 id             zone or 9Px message type
  uint32 thread
  uint64 flow           0 for a plain zone
```

The 9Px and ring frameworks write spans automatically, so **every server is traced without any code of its own**. `fsd`, `envd` and the drivers get request spans for free. A server can add a zone inside a span for detail.

`dbg` joins flows into chains. The read in §1 shows as one arrow from the app's span, through `fsd`'s span and the block span, to `drv-nvme`'s IRQ. 05 §6.4's "following requests across processes" is this chain shown in the debugger, and it becomes possible in M7 instead of M14.

## 6. Sampling

- **On the tick, everywhere.** While tracing with `sample` on, ADR-0041's busy tick runs at the sampling rate (default 1 kHz, at most 10 kHz) instead of 10 ms. It records the interrupted PC, kernel or user, and walks the frame-pointer chain: up to 64 frames, user frames read with the fault-safe copies (LDTR on arm64, 6c5), stopping at the first unmapped one. An idle CPU stays tickless and produces no samples (01 §8). This works under QEMU TCG, which has no PMU, and on every machine.
- **On counter overflow, where there is a PMU** (hardware, and KVM's virtual PMU): `pmu_configure` as 05 §9 specifies, moved from M14 to M7. Counter overflow samples cycles, cache misses or branch misses, using the same record and walk as the tick.
- **Whole machine or one task.** With the trace resource, `procfs` samples every CPU. Through `/proc/N/prof/ctl`, a user samples only tasks they hold `INSPECT` on. The kernel then filters by task as it records, so one user never sees another's PCs.
- **Symbols.** User PCs resolve through `vx-debug`'s index, by way of the loader's list of objects (6f1a), which is one reason this belongs after M6. Kernel PCs resolve through `kernel.elf`'s index.

## 7. The files and the tools

```
/proc/trace/
    ctl        start sched,ipc,irq,vm,futex,sample · rate 1000 · size 4M · circular · stop · rewind · mark TEXT
    events     merged records, oldest first, every CPU ring and every traced process's ring
    status     ndb: categories, mode, per-ring records and drops, first and last drop
    .schema    the record kinds and fields
/proc/N/prof/
    ctl        zones on · spans on · sample 1000 · count cycles,cache-misses · stop      (05 §9, extended)
    zones      as today, version 3 records
    samples    this task's samples
    counters   one ndb record per thread
```

- **Who may read.** `/proc/trace` shows every process's activity, which makes it a **broad grant** (D22, ADR-0029). The adm group (group 0) has it, the grant settings can give it to a program, and an agent never gets it. `/proc/N/prof` needs `INSPECT` on task N, as it does today.
- **`trace`**, a command like 9front's `trace(1)`. `trace -c sched,ipc -t 2s` captures a trace. `trace -p` prints the records as text, one ndb record each, for scripts and agents (rule 10). `trace -s` summarises: the slowest flows, the longest blocks with what woke them, and CPU time per process.
- **`dbg`'s timeline** (M7, 05 §9) gets a track per CPU and per thread, flow arrows, IRQ and fault markers, and sample flame graphs over any selected range.
- **The flight recorder.** `svcd` can start the trace at boot in `circular` mode with `sched`, `ipc` and `irq`, if the configuration asks (`vx.trace=flight` on the command line, or `/cfg`). Several things then use it:
  - a crash directory (05 §5) gets the last 2 s as `trace`;
  - `trace -f` saves what is in the rings now;
  - `winsrv` may save it when a frame misses its deadline (M7).

  It is off by default until §8's overhead budget is met.
- **Saved traces** are the `events` stream in a file, with the `status` record at the front. `dbg` opens one as it opens a live trace. Two saves can be compared with `trace -d`.
- **`./build bench`** (00 §8, 04 §3) reads its timestamps from traces. A budget is the time between two events, or a flow's length, so the harness and a person debugging a regression use the same measurements.

## 8. Budgets

| Operation | Target |
|---|---|
| A disabled kernel probe | One load and one predictable branch; no measurable change to 01 §12's microbenchmarks |
| An enabled kernel event | < 30 ns |
| A span written by the 9Px framework, enabled | < 30 ns, as 05 §10's zone budget (< 20 ns) plus the flow |
| Flight recorder (`sched`, `ipc`, `irq`, circular) | < 1% on `./build bench`'s workloads |
| Sampling at 1 kHz on every CPU | < 1% (05 §10 sets 4 kHz on one task) |
| `trace -s` over 2 s of a busy desktop | < 1 s |

## 9. Where it lands

**After the runtime work, first in M7**, as step 7a. Three reasons:
- **It needs M6.** It uses threads and their rings (6d), donation (6d6c2), lazy memory (6e1e2), and the loader's object list (6f1a) to resolve samples in shared libraries.
- **M7 builds `winsrv`, `displayd`, `vxui` and the 00 §8 budgets** for frames, keypresses and terminal throughput. Those are multi-process latency problems from the first day.
- **M7 already brings `dbg`'s GUI and its timeline.** Building the timeline over whole-system data costs little more than building it over zones alone.

| Step | Content | ADR |
|---|---|---|
| 7a1 | Kernel trace rings, `trace_configure`, the `sched`, `ipc`, `irq`, `vm`, `futex`, `syscall` and `mark` categories; `/proc/trace`; `trace -p` | The kernel's trace (proposed with the step) |
| 7a2 | Flows: channel flow ids in the kernel, `vx-prof` version 3 spans, spans in `lib/vx-9p` and `lib/vx-ring`; `trace -s` | — |
| 7a3 | Sampling: on the tick everywhere, `pmu_configure` with counters and overflow sampling where a PMU exists, kernel and user stacks, symbols through the loader's list | The ADR for `pmu_configure` (05 §9's syscall) |
| 7a4 | The flight recorder and crash directories' `trace`; contention (futex waits per key, held to a caller's site); heap and commit (`vx_heap`'s classes and `COMMIT` events) in `/proc/N/heap` | — |
| 7a5 | `./build bench` over traces: 00 §8's budgets from M2 to M5 enforced at last, and M7's as they become measurable | — |

**Later rows**, not placed in milestones.md:
- **M8 GPU:** `accel` (ADR-0018) gets timestamp queries and a submission flow, so each GPU submission appears as a span on a GPU track. Mesa's own trace points are mapped onto `mark`.
- **M14:** keeps the parity work in 05 §6 and §12. It loses PMU sampling, which moves here.
- **M10 Swarm:** a remote node's `/proc/trace` is a mount (05 §8). Clock offsets between nodes, so that two machines' traces can be joined, come with the swarm's NTP.

## 10. Open questions

1. **One stream or two.** Should `procfs` merge kernel and process rings into one `events` file, or serve them apart and leave the merge to the reader? Merging in `procfs` keeps tools simple. Serving them apart keeps `procfs` from copying every record.
2. **Sampled allocation stacks.** Fuchsia's memory sampler samples allocations at Poisson intervals. Should `vx_heap` do the same? Is per-class counting enough for M7?
3. **Export.** Should a host converter write the Chrome trace JSON that Perfetto opens? It is an output format at the edge, not a layer (rule 13). It is also a tool to keep up for a viewer the system does not need.
4. **A user-visible flight recorder.** Should Settings offer "record the last minute" as a trusted-path toggle, so users can attach a trace to a bug report without opening a shell?
