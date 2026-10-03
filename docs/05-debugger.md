# Phase 5 — The native debugger

_Blueprint v0, 2026-09-30._

## 1. Goals

VectraOS ships a native debugger, `dbg`, at the level of the RAD Debugger. It is built the way Plan 9 built `acid`: the debugger reads and writes files under `/proc`, served over 9Px like everything else.

- **Instant:** starting, attaching, stepping and loading symbols never make the user wait (budgets in §10).
- **Everything a debugger does is a file operation.** Stopping a thread, writing a register, setting a breakpoint and reading memory are `ctl` verbs and file reads. A shell script, an agent and the GUI all use the same verbs (rule 10).
- **Remote for free.** `/proc` on another machine is a mount away, so debugging a program on the tower from the laptop needs no debug server and no second protocol.
- **One path for live and post-mortem.** A crash is saved as a directory shaped like `/proc/N` (§5), and `dbg` opens it with the same code.
- **Built for this system.** `dbg` understands handles, rings, `vx_buffer`s and ndb text as well as it understands C types (§6.4).

## 2. Kernel mechanisms

The kernel adds one right and five syscalls, plus `pmu_configure` for profiling (§9). Everything else is in user space.

- **The `DEBUG` right** on a `Task` handle allows everything below. Without it, a task can be inspected (`INSPECT`) but not stopped or changed.
- **Syscalls:**
  ```
  exception_bind(task_or_thread, port, key)    # debug events arrive at the port as packets
  exception_resume(thread, action)             # continue | step | kill, after an event stopped it
  thread_suspend(thread)  thread_resume(thread) # counted; the basis of stop, start, freeze and thaw
  task_mem_rw(task, ops[], count)              # batched reads and writes of another task's memory (rule 11)
  ```
  `thread_state` already exists. It gets and sets general, FP/SIMD and debug registers, and the single-step flag.
- **Events:** a faulting or trapping thread stays stopped until `exception_resume`. The events are breakpoint, single step, watchpoint, fault, thread start and exit, image mapped and unmapped, and task exit. Faults go first to a debugger that bound with `FIRST_CHANCE`, then to the task's in-task handler if it has one (01 §9), then to its exception port, then to default handling (a POSIX signal, or a crash directory, §5). A debugger that did not ask for first chance never sees the faults an emulator handles itself.
- **Breakpoints on read-only code:** W^X still holds. A `task_mem_rw` write to an executable page gives the target a private copy of that page, as `ptrace` does, and never a writable mapping.
- **Hardware watchpoints** use the debug registers: four per thread on x86_64 (DR0–DR3), and two to sixteen on aarch64 (DBGWVR/DBGWCR), reported in `/proc/N/info`.
- **Real-time threads:** a stopped `realtime` thread releases its budget, and gets it back only through a new admission test when it resumes. A debugger can never make admission control lie.

## 3. The debug tree

`procfs` serves these files next to the ones in 02 §5.1:

```
/proc/42/
    ctl        stop · start · step 3 · freeze 3 · thaw 3 · break 0x4011a0 [if rdi==3] [after 99] · unbreak 0x4011a0
               watch 0x7f001000 8 write · unwatch 0x7f001000 · detach · kill
    events     debug events, one ndb record each:
                 event=break  thread=3 pc=0x4011a0
                 event=fault  thread=3 pc=0x401200 addr=0x0 access=read
                 event=watch  thread=5 pc=0x4013c8 addr=0x7f001000 access=write
                 event=image  op=map base=0x7f2000000000 path=/lib/libvxui.so build-id=3f9a…
                 event=thread op=start thread=6 · event=exit status="sys: trap: fault read addr=0x0 pc=0x401200"
    mem        the address space as a file: seek to an address, read or write
    maps       one ndb record per mapping: base= size= prot= image= offset=
    images     one ndb record per loaded ELF: path= base= build-id=
    threads/3/
        status     state=stopped intent=interactive reason=break pc=0x4011a0
        regs       general registers, binary: the architecture's vx_regs struct, layout in .schema
        regs.ndb   the same registers as one ndb record: rip=0x4011a0 rsp=0x7ffd… (write a tuple to set it)
        fpregs     FP and SIMD registers, binary; fpregs.ndb as text
        ctl        step · resume · freeze · thaw
        sched      intent=realtime period=2.67ms budget=0.5ms ctx=audio/12 threads=3 admitted=yes
                   misses=2 last_miss=1781203.441s overrun=0.08ms     (one ndb record; F-215)
```

- **Breakpoints live in `procfs`, not in the debugger.** `procfs` writes the trap instruction and steps each thread over it on resume. So a shell script can write `break 0x4011a0` and read `events`, and two tools can share one target. **Simple conditions are evaluated in `procfs`:** a comparison of a register, or of a word at a fixed address, with a constant (`break 0x4011a0 if rdi==3`, `break 0x4011a0 if [0x7f001000]>=100`), plus a hit count (`after 99` lets 99 hits go by). A breakpoint in a hot loop then costs a trap and a compare, not a round trip to the debugger. `dbg` compiles a source-level condition to that form whenever it can. Conditions that need more (calls to built-ins, pointer chains, log points) are evaluated by `dbg`, which resumes the thread when they don't match; the watch panel marks such breakpoints as slow.
- **Authority:** `procfs` holds the `DEBUG` right for the tasks in its session, which whoever spawns a process hands it when registering the child (ADR-0011). A client may open `mem`, `regs` and `fpregs` for writing, or use the stopping and changing verbs, only with a capability token that names the task and carries `debug` (02 §3.4).
  - A debugger that launches a program gets that token automatically.
  - Attaching to anything else goes through the approval prompt (03 §8.5), and an agent always needs approval.
  - Debugging a driver also needs `devmgr`'s policy to allow it. A stopped driver cannot corrupt memory, because the IOMMU limits its device to the driver's own buffers (01 §7.4).

## 4. Symbols and sources

- **One debug-info format: DWARF 5,** which clang emits for all first-party code and all ports. `build` compiles everything with `-g -fno-omit-frame-pointer`, and links with `--build-id`.
- **Frame pointers are always on,** so unwinding is a pointer walk and never depends on reading DWARF. The call-frame information in `.eh_frame` is used only for code that has no frame pointers, such as vendored imports.
- **Symbol files are named by build ID.** Release images are stripped, and `build` writes the debug information to `/lib/debug/<build-id>.debug` using `llvm-objcopy` from the pinned LLVM packages. Debug images keep their symbols.
- **The index:** the first time `dbg` loads a symbol file, it converts the DWARF into a flat, memory-mappable index: address to line, name to symbol, types, scopes and inline sites. It saves the index as `/lib/debug/<build-id>.index`, and after that it maps the index and never parses DWARF again. This is the RAD Debugger's approach (its RDI format), and it's what makes large programs load instantly. The index is a cache, not a second debug format. Deleting it loses nothing.
- **Sources:** `build` maps source paths to `/src/<component>/…` with `-ffile-prefix-map`. The user's namespace binds a checkout there (`bind ~/src/vectra /src`). Remotely, it's a mount (`mount 9px+tcp://buildhost/src /src`).

## 5. Crash directories

When a task faults and neither a debugger nor its own handler takes the fault, `procfs`, which holds every process and binds each one's exception port, saves it as a directory with the same shape as `/proc/N`: `info`, `status`, `maps`, `images`, `note` (the fault in Plan 9's words), `threads/*/{status,regs,regs.ndb,fpregs}`, and `mem/`, a file for each writable mapping named by its base address. Read-only pages are not copied, because the images are named by build ID. Then the task ends with the trap's words, as any unhandled fault ends it. vx-rt and the POSIX back end let a fault their handlers decline happen again with no handler, so it reaches `procfs`. User programs go to `$home/lib/crash/<name>.<pid>/`, and system services to `/lib/crash/`; until a file system keeps them, both go to `/tmp/crash/`.

Secrets stay out. VMOs created with `NODUMP` are never written, and allocators that hold keys or tokens use them. `keyd` and `tlsd` are never dumped at all. The user can also have crash directories encrypted to a key in `keyd`.

`dbg $home/lib/crash/hx.42` opens a crash exactly as it would open a live process. Everything works except running and changing the target.

### 5.1 Logs that outlive the machine

A crash directory needs a running system to write it. Some failures leave none: a kernel panic, a hang, and, on the Q8B, a hypervisor that resets the SoC at once on a bad SMMU write, with no dump. AbyssBSD's rule for that board was to stream the logs off it during every test. That becomes two mechanisms:

- **`netlog`**, a service `svcd` starts right after `netd`, when the kernel command line names a host: `vx.netlog=192.168.1.10:6666`. It sends every line of `kmesg` and of the console stream as a UDP datagram, `seq time source text`, so a gap in the sequence numbers shows a lost line. It starts by sending everything `kmesg` holds from boot. On the host, `./build netlog` prints the lines and keeps them in a file per boot. It is plain text and unauthenticated, for bring-up on a bench network, and off unless the command line asks for it.
- **A persistent `kmesg`.** Where a board record names a region that keeps its contents across a warm reset (`kmesg-persist base=… size=… survives=warm`), the kernel keeps `kmesg` there instead of in ordinary memory. Each record carries the boot's id and a checksum. At the next boot, before reusing the region, the kernel checks it and, if it holds a previous boot's log, keeps it. `procfs` then writes it as `/lib/crash/kernel.<boot id>/kmesg`. A panic writes its backtrace there first, before trying any console. Whether a region survives depends on the firmware: `survives=unknown` until a board test shows it. On the Q8B that test is a deliberate bad SMMU write.

Before `netd` is up and with no persistent region, the boot framebuffer is the only witness (01 §7.1).

## 6. `dbg`

`dbg` is a `vxui` app, driven from the keyboard first, with panels you can arrange and tab.

### 6.1 Capabilities (RAD Debugger parity)

| Area | What `dbg` does |
|---|---|
| Targets | Launch or attach to any number of tasks at once, on this node or others; open crash directories |
| Control | Run, stop, step into, over and out, run to cursor, set next statement; freeze and thaw single threads |
| Breakpoints | By source line, function, address or expression; with conditions, hit counts and log messages; hardware watchpoints on data |
| Source view | Source interleaved with disassembly on demand; inline frames; **watch pins** (an expression pinned to a line shows its value in place) |
| Watch | Any number of watch windows, locals, globals and registers, all built on one C23 expression evaluator (§6.2) and view rules (§6.3) |
| Memory | Hex view with live editing, following pointers and data breakpoints |
| Disassembly | x86_64 and aarch64, with symbols and source lines |
| Call stacks | Every thread of every attached task, with inline frames and arguments |
| Modules and threads | Loaded images with their symbol status; threads with intent, state and scheduling budget |
| Output | Debug events, `debug_write` output and log points, in one timeline |
| Visualisers | Bitmaps, geometry (vertex and index buffers), text, and the VectraOS views in §6.4 |

### 6.2 Expressions

The evaluator understands C23 expressions over the target's types from the index: arithmetic, casts, members, indexing, pointer arithmetic, `sizeof`, and calls to a few built-in functions (`strlen`, `memcmp`). It never calls functions in the target, because running target code from a debugger changes the program being debugged.

### 6.3 View rules

A **view rule** says how to show a value. It is written after the expression (`pixels, bitmap:640,360,rgba8`) or set as the default for a type in an ndb file (02 §4.1):

```
# /lib/debug/views.ndb, extended by $home/lib/debug/views.ndb
type=vx_str        view=text:n
type=vx_bytes      view=memory:n
type=vx_buffer     view=buffer
type=vx_sqe        view=sqe
type="struct mesh" view=geometry:verts,vert_count,idx,idx_count
```

The rules are `hex`, `dec`, `bin`, `oct`, `array:N`, `slice:len_field`, `text[:len]`, `memory[:len]`, `disasm`, `bitmap:w,h,format`, `geometry:…`, `ndb`, and the VectraOS rules below. Because the house style passes data as `{pointer, length}` slices (04 §1.1), `slice` makes most first-party types readable without any configuration.

### 6.4 Views that only VectraOS can offer

- **Handles:** a `vx_handle` value shows the kernel object behind it, its rights and badge, taken from `/proc/N/caps`.
- **Buffers:** a `vx_buffer` is drawn as an image, using its format descriptor, and its timeline counter's current value is shown next to it.
- **Rings:** a ring shows its submission and completion queues, with each entry decoded by the protocol's `.schema`: 9Px messages by name, block and network operations by opcode.
- **ndb text:** a text buffer holding ndb records is shown as a table.
- **Following a request across processes:** when a thread steps into `channel_call`, or submits to a ring whose server `dbg` is also attached to, `dbg` can continue in the server thread that picks up the request, then come back when the reply arrives. On a micro-kernel, a request passes through several processes, and this makes it one step.

## 7. Three ways to drive it

- **The GUI,** as above.
- **The command line:** `dbg -c` gives a line-oriented interface with the same commands, for serial consoles and early bring-up. It runs from M4, before the desktop exists.
- **Files:** everything in §3 works from `gsh` directly:
  ```sh
  echo 'break 0x4011a0' > /proc/42/ctl
  read ev < /proc/42/events            # event=break thread=3 pc=0x4011a0
  cat /proc/42/threads/3/regs.ndb
  ```

An agent debugs through the same files, with the approval rules in §3.

## 8. Remote and swarm debugging

- **Another machine:** `import tower /proc /n/tower/proc`, then `dbg /n/tower/proc/42`. Symbols and sources come from `/lib/debug` and `/src` in the debugger's own namespace, so the target machine needs neither.
- **Things that would freeze the local machine** are debugged from a second one: `winsrv`, `displayd`, input drivers, or `svcd`. This is how Plan 9 debugged its file server.
- **The kernel:** until there is something better, the kernel is debugged through QEMU's gdb stub. A later host tool, `gdbfs`, will serve that stub as a `/proc`-shaped tree, so that `dbg` debugs the kernel through the same files (§13).

## 9. Profiling

Measuring comes before optimising, so the profiler is part of `dbg`, not a later add-on. It uses the same `/proc` files and the same timeline.

- **Cycle counters:** user space can always read `rdtsc` or `cntvct_el0`, and `/sys/clock/info` publishes the frequency (02 §5.1). Timing a block of code needs no syscall and no calibration.
- **Instrumentation:** `vx-prof` is a header of two inline functions, `vx_prof_begin(&zone)` and `vx_prof_end(&zone)`. Each writes a cycle-count record into a per-thread ring in a VMO the process shares with `procfs`. A disabled zone costs one predictable branch.
- **Hardware counters:** `pmu_configure(task, events[], count)` programs the performance counters for a task's threads, which the kernel saves and restores on context switch. Programs may read their own counters with `rdpmc` (x86_64) or `PMEVCNTR` (aarch64), as in Casey Muratori's performance-aware programming course. Configuring another task needs `INSPECT` on it.
- **Sampling:** with overflow sampling on, the counter interrupt records the PC and walks the frame-pointer chain, up to 64 frames, into a sample ring. Frame pointers are always on (§4), so this is a pointer walk.
- **Files:**
  ```
  /proc/42/prof/
      ctl        sample cycles 4000 · count instructions,cache-misses,branch-misses · zones on · stop
      counters   one ndb record per thread
      samples    binary sample records; layout in .schema
      zones      binary zone records; layout in .schema
  ```
- **The timeline:** `dbg` shows samples, zones, frame events from `/wsys` and debug events on one timeline, per thread, with flame graphs over any selected range. A remote node's profile is a mount, as with debugging (§8).

## 10. Performance budgets

Measured in CI on T0 under KVM, and on T1 hardware:

| Operation | Target |
|---|---|
| `dbg` cold start to an interactive window | < 150 ms |
| Launch a program and stop at `main`, symbols indexed | < 100 ms |
| Load the index for a 100 MiB DWARF file (mapped, already built) | < 50 ms |
| Build the index for a 100 MiB DWARF file, first time | < 5 s |
| Step over a line, until every panel shows the new state | < 1 frame (8.3 ms at 120 Hz) |
| Refresh 1,000 watch expressions after a step | < 2 ms |
| Attach to a running task over `9px+tcp` on a LAN, stopped and shown | < 50 ms |
| Conditional breakpoint hit that does not match, evaluated in `procfs` | < 5 µs |
| `vx_prof_begin` plus `vx_prof_end` for one zone | < 20 ns |
| Sampling at 4 kHz, overhead on the target | < 1% |

A step is small: one `ctl` write, one `events` read, and pipelined reads of the binary registers and the stack memory, sent back to back without waiting (02 §3.3). Over a local ring, that is a few microseconds.

## 11. Code and imports

| Part | Where | Notes |
|---|---|---|
| Kernel mechanisms | `kernel/obj/`, `kernel/arch/` | The right, five syscalls, debug registers |
| Debug files | `servers/procfs` | Breakpoint management, the files in §3 |
| Crash directories | `servers/svcd` | §5 |
| Profiling zones and sample decoding | `lib/vx-prof/` | First-party; header only for zones |
| DWARF reader, index, unwinder, expression evaluator | `lib/vx-debug/` | First-party; also used by the kernel panic handler's backtraces (symbols only) and by future profilers |
| aarch64 disassembler | `lib/vx-debug/` | First-party: fixed-width encodings, table-driven |
| x86_64 disassembler | `third_party/zydis` | Vendored C (MIT), no dependencies; see §13 |
| The app | `apps/dbg/` | `vxui` |

Rough size: 25–35 kLOC first-party, most of it in the DWARF index, the evaluator and the UI.

## 12. Milestones

The mechanisms and the command line come early, because every later milestone is easier with a debugger (04 §6):

- **M4:** the `DEBUG` right and the five syscalls, the debug files in `procfs` with its simple conditions, crash directories, `lib/vx-debug` (index, unwinder, evaluator), `dbg -c`, `/sys/clock`, and `vx-prof` zones.
- **M7:** `dbg` GUI v0, the first real `vxui` app: source, call stacks, locals, breakpoints, threads and the zone timeline.
- **M14:** full parity with §6: watch pins, view rules, visualisers, the VectraOS views, following requests across processes, `pmu_configure` with sampling and flame graphs, and `gdbfs` for the kernel.

## 13. Open questions

1. **The x86_64 disassembler.** Vendoring Zydis is quick. Writing our own takes longer, but keeps the whole debugger first-party. Start with Zydis, and decide once the aarch64 disassembler shows what a first-party one costs?
2. **Kernel debugging.** Is `gdbfs` over QEMU's stub enough, or does the kernel need its own small debug stub on real hardware, served over the serial console or the network?
3. **The index format.** *Decided by ADR-0017 (2026-10-02): our own, `vxdi`; RDI is not vendored.* The index copies the approach of the RAD Debugger's RDI format. RDI is MIT-licensed C, and its format library is meant to stand alone. Is vendoring it smaller than writing our own index, and would it let `dbg` share tooling with the RAD Debugger? Decide by ADR before M4.
4. **Recording and replaying a task.** Every input a task receives arrives over rings and channels, and hot reload already replays one app's events (03 §6.1). Could `procfs` record all of a task's incoming traffic, with its timestamps, and replay it deterministically, as `rr` does on Linux? What would the non-deterministic sources be (shared memory written by peers, the cycle counter, thread interleaving), and could replay be limited to single-threaded tasks at first?
