# Vectra — session handoff

Read this first when you pick the project up in a new session. It records what
the code cannot tell you on its own. That is where things stand, how to build
and run it, what the toolchain costs, and what to do next. **The reasoning
behind each subsystem lives in its own document. Section 3 is the index.**

---

## 1. What Vectra is

A modular operating system in Odin. Two ideas define it:

- **Plan 9-inspired structure.** Per-process namespaces, private mount tables,
  and a synthetic file protocol, Vectra9 over 9P2000.L. *Every* system service
  is a file tree behind a message-passing endpoint, drivers, network stack,
  graphics, IPC and thread state alike. POSIX is a translation runtime on top of
  that, never a set of hardwired syscalls.
- **"Cyberpunk Workstation 1994" UX.** Heavy skeuomorphic bevels, brushed dark
  magnesium over deep slate, amber/cyan/phosphor accents, copper trim, a
  software dirty-rect compositor, and tracker-synthesised relay clicks.

Target layout — `kernel/` (arch, mem, sched, vfs, drivers), `sys/` (libodin,
libposix, Vectra9), `servers/` (devfs, netfs, intuition), `apps/` (terminal,
filemgr, tracker). Primary arch `x86_64` via Limine, with clean abstractions for
`aarch64` and `riscv64`.

**`servers/` has five residents.** `servers/ramfs` serves a file tree.
`servers/consrv` is a console server that *forks* and waits on the keyboard
and its clients at once. `servers/kbdfs` is the kernel's keyboard
translation rebuilt over `/dev/scancode`, and `servers/eiafs` is the serial
port served both ways. `servers/intuition` is the new one: the draw server
`docs/DRAW.md` designed, six verbs over the screen, and the compositor's
future home. The runtime under all five -- `sys/abi`, `sys/libuser`, the
VECTRA02 format, the loader -- is `docs/RUNTIME.md`'s.

`rfork` exists now, by Plan 9's rules. One process becomes two at the call
site, each with its own page tables. Text is shared, and writable data is
shared under `RFMEM`. The stack is a private copy at the same address, and
the descriptor group is shared unless `RFFDG` copies it. Under it, frames
got an owner that can be shared -- the refcounted *segment* -- and the fd
table became a refcounted group. `docs/USER.md` owns the design.

`kernel/devfs` still lives in the kernel, and nothing blocks its move any
more. Every piece of hardware behind `#c` is a file now: `/dev/fb` serves
the screen's memory, `/dev/scancode` the untranslated keyboard, and
`/dev/eia0` the serial port's bytes. A raw stream is *owned* while held
open -- the kernel's own line discipline steps aside -- and given back on
the last close. The port is work now rather than a wait. See section 6.

## 2. Where things stand

The machine boots, and brings up memory, a namespace, a scheduler and a
preempting timer. It publishes `#c` at `/dev`, `#s` at `/srv` and `#b` at
`/bin`, and holds a pipe server ready behind `sys_pipe`. It then runs about
1280 checks against itself and idles.

`/dev/cons` is a real terminal. A line typed at the keyboard or over the serial
port is edited, echoed, and handed to a reader that parked waiting for it. A
keystroke gets there by raising IRQ 1, which is the first interrupt Vectra
receives rather than arms. `/srv` is a directory of running services, and a name
posted there can be mounted anywhere in a namespace.

**The screen itself is a file now.** `/dev/fb` is the raw framebuffer -- the
first device with contents and a size -- and `/dev/fbctl` reports its
geometry. A ring 3 program named `painter` proves the sentence this milestone
was for. It opens `/dev/fb` by name, seeks to a pixel, writes it, and reads
it back, and the self-test checks the glass rather than a counter. No new
system call was needed: `seek` and the 9P offset already carried the position,
and the new ground is a device that honours it. `docs/DEVFS.md` owns the
design.

**So are the input streams.** `/dev/scancode` is the keyboard before
translation and `/dev/eia0` is the serial port before the line discipline,
both Plan 9's names. A tap *diverts* its stream while open, because a copy
would leave two line disciplines fighting one keyboard. The last close
gives it back, which is `consctl`'s revert rule again. A ring 3 process
reads eight raw scancodes into its own page during the boot. The keyboard
driver's half of the seam is one anonymous function pointer with first
refusal.

**A posted service's connection comes down now.** The wire behind a mounted
`/srv` name pinned seven heap objects for the life of the machine, counted
exactly. `vfs.Server` counts its chans and its stakes now. When the last
mount and the name are both gone, the release runs on whichever thread
dropped the last piece. Its hang-up ends the far server through its own
serve loop, and all seven objects come back, measured to zero.
`docs/PIPE.md` owns the design.

**A note is a signal now, not only a kill.** A process registers a handler
with `notify`, and delivery pushes the interrupted frame and the note's
text onto its stack rather than ending it. The handler ends with `noted` --
`NCONT` resumes where the note struck, `NDFLT` takes the death the note
always was. The tick and the door delivered an ending before, and deliver
the handler now. A ring 3 program catches two notes across those boundaries
during the boot and lives, and only the group fan-out is missing.
`docs/USER.md` owns the design.

**A program can replace itself, and an orphan is collected at last.** `exec`
is the seam's other half. A process names a file and becomes that program,
keeping its pid, its descriptors and its namespace, and dropping its old
text, data and stack. The new image is built in a fresh space before the old
one is touched, so a bad file leaves the caller running. On success the
syscall frame is rewritten and the door returns into the new program.

The orphan the handoff kept naming is retired too. `RFNOWAIT` detaches a
child at birth, a dying parent reparents its children to the kernel, and
`reap_orphans` collects a detached process once it ends. `docs/USER.md` owns
both.

**Vectra runs processes, and now a process can become two.** Forty-two enter
ring 3 during the boot, and another process started fifteen of them,
by `spawn` and by `rfork`. One of them then replaced itself with `exec`. A
forked child continues from the instruction after its parent's `syscall`,
on a private copy of the stack. It answers zero where its parent hears a
pid.

The showpiece is `servers/consrv`, and it is the sentence this file kept
for three milestones: **a server that waits on two things at once**. Its
`RFMEM` child parks reading `/dev/cons`, a real device read, while the
parent serves 9P from `/srv/consrv`. The two meet in a producer-consumer
ring in the bss they share. The kernel types a line into the keyboard sink
and reads it back through the mount. Teardown is the note doing the job it
was built for. The parent notes its reader out of the parked read,
collects EINTR, and exits zero only if it heard it.

**A userland server answers concurrently now.** `libuser.serve_mux` forks a
worker per request that would park. So `consrv`'s read of `/line` waits in a
worker of its own, while the main loop answers a walk or a getattr from
another client. The zero-bytes wart is gone: a read of empty `/line` parks
like a device read should. It takes the first lock ring 3 has -- a spinlock
over `lock cmpxchg` -- to serialise the pipe writes, and `RFNOWAIT` reaps
each worker. `docs/RUNTIME.md` owns the design.

**A kernel service runs as a program now.** `servers/kbdfs` reads the raw
scancodes `/dev/scancode` serves, runs `kernel/drivers/kbd`'s translation
byte for byte, and serves the characters it makes on `/kbd`. It is the
userland devfs's first tenant, and it stands where the kernel's keyboard
driver stood, one privilege level out.

Building it found a real bug. A device read drained its bytes before it
checked the flush. A flush racing a keystroke then consumed the byte into a
reply the client gave up on, about one boot in three. Both device-read loops
check the flush first now. `docs/RUNTIME.md` owns the server, `docs/DEVFS.md`
the fix.

**And the port is served both ways now.** `servers/eiafs` opens `/dev/eia0`,
which diverts the wire's bytes to it, and serves them raw on `/eia0`. A
write through the mount goes down the shared descriptor and out the port --
the first userland `Twrite` to reach hardware. The teardown control found
the pattern's hang. A parent that skips the note strands its reader, whose
shared descriptor group keeps the posted pipe open for ever.
`docs/RUNTIME.md` owns the server.

**And the screen speaks in verbs.** `servers/intuition`'s first half is the
draw server, built to `docs/DRAW.md` -- the first document here written
before its code. A client writes a command batch to `/srv/draw`'s `data`
file, and the six verbs draw through `/dev/fb`. One boot write carried a
fill, an image, a load, a blit and a flush, and every claim read back off
the glass. A session is a fid, and a clunk gives its images back.
`sys/libdraw` owns the encoding, and `libuser` grew `seek`.

**And `apps/` has its first resident.** `apps/terminal` consumes two
services at once: lines in from `/dev/cons`, glyphs out through
`/srv/draw`, which it mounts itself -- the tree's first ring 3 mount. It
uploads the console's own font once, from `sys/libfont`. A typed line
comes back as blits out of that atlas, pixel-identical to the kernel's
rendering. The kernel types at it during the boot and reads the glass. A
typed `exit` ends it, and its clunked session gives the image pool back.

**And a program can hold more than its own image.** `segalloc` is the call and
`Segment_Kind.Anon` is what it makes. A run of zeroed, writable, never
executable pages, described by a base and an extent the way a device mapping
already was.

Static `bss` used to be all a program had. The image format bounds a whole
process at 1.5 MB, which is less than one window's pixels. `docs/DRAW.md`
section 10 named this call a milestone before it existed, and named it a memory
question rather than a graphics one. It was.

`segattach` and `segalloc` share one address bump, so a card and a run can
never take the same pages. A forked child inherits the mark along with the
space. `rfork` treats a run as data. It shares one under `RFMEM`, and otherwise
makes a private copy in one allocation, because a run is contiguous at both
ends. That last rule is `dupseg`'s `SG_BSS` case to the line.

**Plan 9 asks for both through one call, and Vectra asks through two.**
9front's `segattach` takes a class name out of a kernel table. `"memory"` is
anonymous, and a driver registers the framebuffer under a name of its own.
`docs/DRAW.md` section 7 refused that table a milestone ago, because a kernel
table of names is a permission story a namespace cannot overrule. A descriptor
names a device because a device is a file, and nothing is the file for memory
no server has. So the second call is that refusal's bill rather than a design
of its own.

`docs/USER.md` owns the design, the controls, and what else Plan 9 has here.

```
-- a program in ring 3 wrote this line
-- a process opened this file by name
-- this line went to /dev/null
-- a process started this one
-- this line went through a posted service
-- a process answered this line
these bytes live in a program's own segments
```

Three objects carry the milestone, all in `kernel/user`. A **segment**
owns the frames behind one mapping, refcounted. Text and `RFMEM` data
therefore map into two spaces with one owner, which is the answer
`mem/space.odin`'s file comment waited for.

An **fd table** is a refcounted group now, shared by default the way Plan
9's fork shares it. Its two invariants are in `fdtable.odin`. A syscall
*takes* a chan reference rather than borrowing a slot. An exit *releases*
the group rather than closing a sibling's files.

The third object is `arch.thread_user_clone`, which copies the door's
saved frame. The door already saved every register in the resumable
layout, so continuing from the call site is a copy with `rax` answered
zero.

The flag word is Plan 9's bit for bit. `RFPROC`, `RFMEM`, `RFFDG`,
`RFCFDG`, `RFNAMEG` and `RFCNAMEG` work. `RFNOTEG` is recorded and inert.
The rest are refused EINVAL rather than skipped. Without `RFPROC` the
namespace and descriptor flags act on the caller in place.

About 46,300 lines of Odin. The linked image is ~1550 KB debug and ~913 KB
release. The six embedded user images (`ramfs`, `consrv`, `kbdfs`,
`eiafs`, `intuition`, `terminal`) are ~275 KB of both.

**What exists, and which document says why:**

| Subsystem | What it is | Read |
|---|---|---|
| `boot/`, `kernel/arch/` | Limine, descriptor tables, traps, the panic screen | `docs/BOOT.md` |
| `kernel/mem/` | PMM, VMM, and a heap behind `context.allocator` | `docs/MEMORY.md` |
| `kernel/sched/` | Threads, priorities, decay, and the LAPIC tick that preempts | `docs/SCHED.md` |
| `kernel/sync/` | The lock that masks, the lock that parks, and waiting for a condition | `docs/SYNC.md` |
| `sys/vectra9/` | The 9P2000.L message set, its codec, and the session and transport boundary | `docs/VECTRA9.md` |
| `kernel/vfs/` | The namespace: chans, the mount table, walking, union listings | `docs/NAMESPACE.md` |
| `kernel/mnt/` | A 9P connection with several requests in flight, `Tflush` over it, and the wire whose far side is bytes | `docs/TRANSPORT.md` |
| `kernel/pipe/` | Two ends, a byte ring per direction, and the glue that makes a posted end a server | `docs/PIPE.md` |
| `kernel/devfs/` | `#c` at `/dev`: the console, its line discipline, `/dev/consctl`, and the raw hardware -- framebuffer, scancodes, wire | `docs/DEVFS.md` |
| `kernel/srv/` | `#s` at `/srv`: services published by name while the machine runs, now from ring 3 too | `docs/SRV.md` |
| `kernel/drivers/kbd/` | PS/2 scancodes, the I/O APIC route, and a top half that may not park | `docs/KBD.md` |
| `kernel/mem/space.odin` | An address space per process, sharing one kernel half | `docs/SPACE.md` |
| `kernel/user/` | Ring 3, the door back in, a process that owns what it opens, the spawn that makes more, the rfork that makes two, the note a handler catches, and the exec that replaces one | `docs/USER.md` |
| `sys/abi`, `sys/libuser`, `servers/` | The shared call numbers, the ring 3 library and serve loop, and the two compiled servers | `docs/RUNTIME.md` |

**The order they arrived in matters in exactly one way**, and it is worth
knowing before reading any of them. Each of these unblocked the next, and none
of them could have come earlier:

    a heap                  a namespace can allocate a chan
    a scheduler             a server can have threads of its own
    a lock that parks       a lock may be held across a 9P message
    a rendezvous            a thread can wait for a condition, or a deadline
    kernel/mnt              a request can be left pending, and flushed
    kernel/devfs            a read can wait for hardware rather than for a test
    kernel/srv              a service can be named after the kernel was built
    the I/O APIC            a device can interrupt, rather than only the timer
    an address space        two threads can mean different memory by one name
    ring 3                  a thread can run where it cannot damage the kernel
    a system call           and can ask the kernel for something anyway
    a process               and what it opens is its own, in its own namespace
    a loader                a program is a file a namespace can name
    spawn                   and a process can start another one, and wait for it
    a posting               and publish what it holds open, as a name in /srv
    a pipe                  two ends a descriptor table can hold, that park
    the wire                and 9P down one, so a process can answer it
    a runtime               and the answerer can be a program a compiler built
    a note                  and what will not stop can be stopped, from outside
    an rfork                and one process can become two, sharing what they
                            choose -- so a server can wait on two things at once
    a raw device            and the hardware itself is a file: the screen at
                            an offset a process may seek
    a tap                   and a stream is owned rather than copied: whoever
                            holds the file stands where the kernel stood
    a release               and what a posting built comes down whole, when
                            the last mount and the name are both gone
    a note handler          and a note is a signal rather than a kill: the
                            kernel pushes a frame, the program catches it
    an exec                 and a process becomes another program in place,
                            keeping its descriptors -- the seam's other half
    a serve mux             and a userland server answers concurrently: a
                            worker per request that parks, the rest inline
    a kbdfs                 and a kernel driver runs as a program: raw
                            scancodes in a file, translated in ring 3
    an eiafs                and the port answers both ways: a ring 3 write
                            through a mount reaches the hardware behind it
    a draw server           and the screen speaks in verbs: a command
                            stream in a file, checked against the glass
    a terminal              and a program consumes both: typed lines come
                            back as glyphs a mount of its own arranged

Everything else about how it got here is in the documents above, beside the
code it explains.

```
[  --  ] Vectra 0.1.0-pre (amd64) entering kmain
[  ok  ] base revision 6 as requested
[  ok  ] traps: cs 0x8, tr 0x30, 256 vectors, #BP round-trip ok
[  ok  ] framebuffer 1280x800 @ 32bpp, pitch 5120 -> 0xffff800080000000
[  --  ] console 149 cols x 36 rows
[  --  ] booted by Limine 12.6.1 via UEFI (64-bit)
[  ok  ] paging 4-level
[  --  ] kernel phys 0x0000000019ea5000 virt 0xffffffff80000000
[  --  ] hhdm offset 0xffff800000000000
[  --  ] memory map: 32 entries spanning 12.7 GiB
[  ok  ] usable 465.0 MiB, reclaimable 40.5 MiB
[  --  ] largest usable region 392.6 MiB at 0x0000000001600000
[  ok  ] pmm 119062 frames free of 123848 tracked, bitmap 15.1 KiB at 0x0000000000001000
[  ok  ] vmm root 0x0000000000005000, mapped 516.3 MiB in 271 tables (1.0 MiB)
[  --  ] vmm nx on, global pages on, largest leaf 2.0 MiB
[  ok  ] heap online -- context.allocator is live
[  ok  ] memory self-test passed -- 1 slab pages, 0 large blocks live
[  ok  ] vectra9 9P2000.L: 57 message kinds round-trip, both transports agree
[  ok  ] namespace: #/ attached as /, 8 conventional directories
[  ok  ] vfs 51 namespace checks passed -- union of 4 names over two servers, 1 mount point, heap balanced
[  ok  ] sched cpu0 performance, capacity 1024/1024, slice 10 ticks, 16 priority levels
[  ok  ] sched 21 scheduler checks passed -- 132 switches, round-robin and priority verified
[  ok  ] ioapic version 0x20, 24 lines, all masked
[  ok  ] lapic timer 1000 Hz -- bus clock 62.5 MHz measured against the PIT, 62525 counts per tick
[  ok  ] sched preemption 11 checks passed -- 3 threads preempted, none starved (17722552-17875335 rounds), decayed to 5, 3 fpu accumulators intact
[  ok  ] sync 14 sleeping lock checks passed -- 2266 acquisitions, 2162 parked and handed back, decayed to 1
[  ok  ] sync 20 sleep queue checks passed -- 12 parked, 12 woken, 25-tick delay took 25 in 2 switches
[  ok  ] 9p 35 Tflush checks passed -- 34 requests, 11 flushed (10 in flight, 1 stale), Rflush held 40 ticks for a stubborn server
[  ok  ] 9p 23 payload checks passed -- 1024 bytes per slot, 4096 delivered to 8 readers, 7 spoiled by a shared buffer, 4 listings at once
[  ok  ] vfs 41 transport checks passed -- 160 reads and 160 listings across 4 threads on 4 workers, msize 4120, a read gave up after 10 ticks
[  ok  ] vfs 34 concurrency checks passed -- 4506 namespace operations across 5 threads, 720 rebinds under them in 1000 ms, nothing serialised, heap balanced
[  ok  ] devfs #c bound at /dev, 8 devices on 4 workers, cooked console, input live
-- this line reached the screen through /dev/consX 
-- these bytes went straight out the wire
[  ok  ] devfs 134 device checks passed -- 8 files under /dev, 49 bytes written to cons, 6 lines cooked over 4 edits, 2 reads parked, a read gave up after 10 ticks
[  ok  ] srv #s bound at /srv, 0 services posted, 32 slots
[  ok  ] srv 82 service checks passed -- 35 posted, 6 listed across 6 passes with one removed under them, 1 mounted, 1 name reserved pending, heap balanced
[  ok  ] pipe #| ready, 8 slots, 2048 bytes per direction
[  ok  ] pipe 37 checks passed -- 8227 bytes crossed, 2 threads parked and woken, heap balanced
[  ok  ] wire 46 checks passed -- 18 frames answered by a thread the kernel cannot call, 9 flushed, 1 stale reply dropped, 2 wires poisoned on purpose
[  ok  ] bin #b bound at /bin, 12 programs as files, formats VECTRA01 and 02
[  ok  ] kbd ps/2 on irq 1 -> vector 0x31, scancode set 1, us layout
[  ok  ] kbd 55 keyboard checks passed -- 48 scancodes translated, 2 interrupts taken, an injected key reached the sink
[  ok  ] space 33 address space checks passed -- 2 spaces sharing one kernel half, 8 tables between them, 133 CR3 reloads, one address two meanings
[  ok  ] syscall armed -- entry at 0xffffffff800272b0, /dev/cons is descriptor 1
-- a program in ring 3 wrote this line
-- a process opened this file by name
-- this line went to /dev/null
-- a process opened this file by name
-- a process started this one
-- a process started this one
-- this line went through a posted service
-- a process answered this line
these bytes live in a program's own segments
-- a process started this one
-- these bytes went through a ring 3 server to the wire
[  ok  ] user 625 userland checks passed -- 41 processes, 14 started by another process, 7467632 preempted rounds, 979 system calls, 11 9P requests answered by a process, a typed line served by a process that forked
[  ok  ] boot complete -- idling
```

**Every line of that is a self-test on the machine that will run it**, and
`docs/TESTING.md` is the discipline behind them. Three of them are worth
knowing about before reading a boot:

- The untagged line is the devfs self-test writing to `/dev/cons`, which is the
  shortest proof that path exists. The echo checks leave an erase sequence after
  it that a terminal consumes and a file capture keeps.
- **Four of those lines carry numbers that move on every run**, and that is the
  design rather than noise. The LAPIC calibration, the preemption round counts,
  the lock acquisitions, and the operation count under a fixed tick budget are
  all measured rather than asserted. `just release` does the same thousand ticks
  of work and reports about fifty thousand operations. `docs/TESTING.md` says
  why measuring in ticks is the right way round.
- `9p 23 payload checks` reports **7 readers spoiled by a shared buffer**, and
  that is a pass. It is a control that runs every boot: the wrong arrangement is
  still expressible, and a failure to corrupt would be the failure.

**What still does not exist.**

The one that shapes everything after it:

- **No SMP.** `Cpu` is per-core and `MAX_CPUS` is 8, but only core 0 ever
  starts. There is no IPI, no AP trampoline and no lock word.

And on the note, half-finished by design:

- **A note reaches a handler now**, but not a group. `notify` registers one
  and `noted` resumes or dies, so a note is a signal rather than only a
  kill. The missing half is the fan-out. `Process.note_group` inherits and
  nothing posts to a group, which is Plan 9's `postnote` to a group rather
  than a pid. And no FPU state crosses a delivery.

And on the new ground itself. `serve_mux` forks a worker per parked read.
A `Tflush` cancels the request on the wire but not the worker, so the worker
polls until its byte arrives or the server shuts down. Flush that reaches the
worker is a refinement, not here yet. A read served inline when the pool is
full parks the main loop -- the stall `kernel/devfs`'s worker count
documents, moved to a userland pool size.

The older ground stands too. A ring 3 program still has no allocator. One
process still cannot wait on two descriptors -- it forks
instead, which is Plan 9's answer. A posted service comes down now, when
the last mount and the name are both gone.

From the milestones before: the seam is cut on the creating side only,
and there is no `exec` that replaces a running image. The note still lands
with bounded lag rather than instantly. A loop or a parked sleep costs a
tick, and a read waiting on a device costs up to `NOTE_POLL` ticks. A
*faulting* process still holds its descriptors until `destroy` collects
it.

And the smaller ones, each named where it lives:

- No ACPI. The I/O APIC's address and the ISA-to-GSI mapping are assumed rather
  than read from a MADT. Both are right on every PC and neither is discovered.
- No interrupt on the serial line. `devfs.cons_input` still polls it once a
  tick, and the keyboard shows the shape a replacement takes.
- Nothing stops a handler from taking a sleeping lock. `sync.can_sleep` counts
  spinlocks and an interrupt handler holds none, so the rule that a top half may
  not park is argued in prose rather than checked. See `docs/KBD.md`.
- No word erase and no cursor inside a line. `^W` and the arrow keys are the two
  a person misses next.
- No read/write sleeping lock, which is the piece `Mount_Point.generation`
  stands in for.
- No enforcement of the `open` flag `vfs.Fid_Table` carries. 9P forbids a walk
  on an open fid and a read on an unopened one, and no server here refuses
  either.
- No condition variable as such, because `sync.Rendez` is one.
- `kmain` ends with a call to `sched.exit`, so the machine idles rather than
  halts.

**The design is written down in `docs/VECTRA9.md`, and it is the thing to read
before touching the protocol or the namespace.** Three decisions in it shape
everything downstream, all three taken deliberately:

1. **The wire is 9P2000.L and nothing is added to it.** No new message, no extra
   field, no private version string. When a service needs an operation 9P does
   not have, the answer is a *file* — a `ctl` that takes a line of text.
   `/dev/consctl` is the first, and `docs/DEVFS.md` has the convention it set.
2. **Servers speak decoded messages. Only the transport knows about bytes.**
   Neither the caller nor the handler can tell which transport it has.
3. **The namespace is the full Plan 9 model** — `bind`/`mount` with
   before/after/replace, union directories, per-process mount tables copied or
   shared on fork.

## 3. The design documents

This file is orientation. Everything that explains *why* a subsystem is the
shape it is lives beside the code it describes, one document per directory:

| Document | Covers | Read it when |
|---|---|---|
| `docs/VECTRA9.md` | The 9P2000.L dialect, the namespace model, `sys/vectra9/` | Touching the protocol, a server, or the mount model. **Read this before anything else.** |
| `docs/BOOT.md` | `boot/`, `kernel/arch/`, traps, the panic screen, the console | Changing the boot order, a descriptor table, or anything the fault path uses |
| `docs/MEMORY.md` | `kernel/mem/` — PMM, VMM, heap | Allocating, mapping, or wondering where 1 MiB went |
| `docs/SCHED.md` | `kernel/sched/` — the switch, priorities, the tick | Adding a thread state, a priority rule, or a second core |
| `docs/SYNC.md` | `kernel/sync/` — spinlocks, sleeping locks, the sleep queue | Taking any lock, or making anything wait |
| `docs/NAMESPACE.md` | `kernel/vfs/` — what guards what, the two transports, and the lock that went | Walking, binding, adding a server, or giving up on a read |
| `docs/TRANSPORT.md` | `kernel/mnt/` — the tag pool, the workers, `Tflush`, the payload buffer, and the wire over bytes | Writing a transport, making a request interruptible, or wondering who owns a reply's bytes |
| `docs/PIPE.md` | `kernel/pipe/` — the byte rings, the ends as chans, and a posted end becoming a server | Moving bytes between processes, or mounting a service a process answers |
| `docs/RUNTIME.md` | `sys/abi`, `sys/libuser`, `servers/ramfs`, the VECTRA02 format, and the user half of `build.odin` | Writing a ring 3 program, growing the library, or touching either image format |
| `docs/SPACE.md` | `kernel/mem/space.odin` — a space per process, and the half of it that is shared | Building a process, mapping something a program may reach, or wondering what the scheduler reloads |
| `docs/USER.md` | `kernel/user/` — ring 3, `syscall`/`sysret`, the per-CPU record behind GS, a process and its namespace | Entering ring 3, adding a system call, copying a pointer in from a program, or wondering what a program may not do |
| `docs/KBD.md` | `kernel/drivers/kbd/` — scancodes, the I/O APIC, and why a handler splits in two | Adding a device that interrupts, routing a line, or wondering why the polling thread is still there |
| `docs/DEVFS.md` | `kernel/devfs/` — `#c` at `/dev`, the console device, the line discipline, the `ctl` convention, the raw framebuffer | Adding a device file, adding a `ctl` file, writing a server whose reads park, or wondering why `/dev/cons` has two locks |
| `docs/SRV.md` | `kernel/srv/` — `#s` at `/srv`, posting, the id that is not a slot | Publishing a service, mounting one by name, or writing a directory that changes |
| `docs/DRAW.md` | The `/dev/draw` protocol design, written before its code | Building the draw server, its client library, or the fb mapping |
| `docs/TESTING.md` | The self-test discipline and the negative controls | Adding a self-test, or trusting one |
| `docs/STYLE.md` | ASD-STE100: the two modes, the seven checked rules, the project dictionary | Writing a comment or a document, or fixing what `build.odin -- lint` names |

Three rules run through all of them and are worth knowing before opening any:

1. **A decoded 9P message borrows its buffer.** Strings and slices inside a
   `Msg` point into whatever it was decoded from. Odin cannot express the
   lifetime, so it is stated in prose and broken by accident. `docs/VECTRA9.md`.
   A transport that runs several requests at once hands each handler the storage
   its reply must be built in, because that rule cannot hold otherwise.
2. **A sleeping lock is never taken inside a spinlock**, and that is checked
   rather than remembered — `sync.can_sleep`. `docs/SYNC.md`.
3. **A self-test that cannot fail proves nothing.** Every milestone ends by
   mutating the code to see which checks notice. `docs/TESTING.md`.

## 4. Build and run

```sh
just run          # build, stage ESP, boot headless, serial on stdio
just gui          # same, with a QEMU window
just debug        # boot halted; `just gdb` in another shell
just release      # -o:speed, bounds checks off
just check        # type-check everything, emit nothing
just font         # regenerate the baked console font
make run          # identical targets, if `just` is absent (it is, here)
```

`build.odin` is the real build system — compile, link, stage, run — and holds
the per-architecture table. `justfile`/`Makefile` are thin wrappers. Invoke the
driver directly as:

```sh
odin run build.odin -file -out:.vectra-build -- run --gfx
```

**The explicit `-out:` is mandatory.** Without it `odin run` names the driver
binary after the script and drops `./build` directly on top of the `build/`
output directory. This bit once already.

Verified toolchain on this machine: Odin `dev-2026-08:8412dc37a`, LLD 21.0.0
(from `~/.swiftly/bin`), QEMU 11.1.0. No `just` installed — use `make`. No
`xorriso`, no loop devices, no `sudo` required. Pillow is **not** currently
installed, so `make font` will not run until it is. The two generated font
files are checked in, and nothing else needs Python.

**UEFI firmware comes from QEMU's own edk2 images now.** The neighbouring
`odin-os` checkout that used to lend `ovmf_x64.fd` is gone from this machine.
`run_qemu` looks for a combined OVMF image first. Failing that, it loads the
split `edk2-x86_64-code.fd` + `edk2-i386-vars.fd` pair beside the QEMU
install as two pflash devices. The vars image is copied to
`build/edk2-vars.fd` because UEFI writes it. The i386 name is not a mistake —
QEMU ships one vars image for both x86 targets.

## 5. Toolchain constraints — the expensive ones

These were each found the hard way. Changing any of them will break the build in
ways whose error messages do not point back here.

| Constraint | Why |
|---|---|
| `-no-thread-local` | Odin otherwise emits `STT_TLS` symbols with no `PT_TLS` segment, and `ld.lld` refuses the image. Per-CPU state must go through `GS` explicitly. |
| `ld.lld`, not `ld` | Apple's linker cannot produce ELF. |
| `-out:.vectra-build` | See above — `./build` collides with `build/`. |
| ESP is a **directory**, not an image | QEMU's vvfat (`-drive format=raw,file=fat:rw:build/esp`) presents it as FAT. This is what makes the build work on macOS, where `losetup`/`mkfs.vfat` do not exist. Same commands work on Linux. |
| `arch.early_init()` runs first | Limine base revision 5+ clears every `cr0`/`cr4`/`EFER` bit the protocol does not require — `CR4.OSFXSR` included. Odin's codegen uses XMM for ordinary struct moves, so the *first* Odin statement after entry faults without SSE re-enabled. |
| `@(link_section = ".limine_requests")` on every request | Since base revision 2 the request delimiters are **binding, not hints**. A request outside the section compiles, links, boots — and its `response` stays nil forever. Silent. |
| EFER.NXE before the first NX mapping | Bit 63 of a page table entry is *reserved*, not ignored, until `EFER.NXE` is set. Install a mapping with it first and the fault comes on first touch, as a reserved-bit #PF, nowhere near the cause. `amd64.enable_paging_features` is what turns it on, and `leaf_encode` drops the bit if it did not take. |
| Segment bounds come from `link_amd64.ld`, not from Odin | `__text_start` … `__data_end` are declared in a bare `foreign { }` block in `kernel/mem/vmm.odin`. They are defined *inside* their output sections in the linker script on purpose: written between sections they become orphans, and ld is free to attach an orphan to whichever segment it likes. |
| `intrinsics` has `mem_zero` and `mem_copy`, but no `mem_set` | There is no fill-with-a-byte intrinsic. The PMM's bitmap fill is a plain loop. `memset`/`memcpy`/`memmove` *are* provided by stock `base:runtime`, which is why the link has no undefined symbols. |
| `proc "naked"`, not `@(naked)` | Odin has no `naked` attribute — it is a *calling convention*. `@(naked)` fails with "Unknown attribute element name", and the suggested `-ignore-unknown-attributes` would silence the error while still emitting a prologue, which corrupts the interrupt frame. |
| `$$` in an inline-asm template | Odin substitutes `$0`, `$1` … for operands, so a literal immediate needs `$$0x10`. Operands passed under the `i` constraint supply their own `$` — `movw $2, %ax` with `u64(0x10)` assembles as `movw $0x10, %ax`. |
| The error-code vector list is written twice | Once as an assembler `.if` inside the stub blob and once as `vector_has_error_code` in Odin. They cannot share a definition — one is consumed at build time, the other at run time — and if they disagree every field in `Trap_Frame` reads as the one next door. They live in the same file for that reason. |
| An unoptimised build spills every temporary | Debug builds keep nothing in a register across an instruction boundary. This is not a curiosity: a test written to verify that FXSAVE preserves XMM passed with the FXSAVE removed, because the values it was checking were on the stack the whole time. Anything that must observe *register* state has to pin it with inline asm and hold it there — see `fpu_hold` in `kernel/sched/verify.odin`. |
| A missing EOI stops the timer silently | The local APIC delivers nothing further at or below that priority. There is no error, no fault, and no bit anywhere saying so — it looks exactly like a timer that was never armed. Any loop waiting on the tick count needs a liveness bound, or a one-line bug hangs the boot with the last line printed being the timer coming up successfully. |
| A freed object reads as a valid one | The slab allocator writes its free-list link over the first field and leaves the rest. A `Mount_Point` freed one reference early still reports zero members, which is exactly what a correctly dissolved one reports — so the obvious use-after-free check passes whether or not the bug is there. Testing a lifetime bug means testing the *reference count*, or forcing the block to be reused first. |
| The LAPIC coalesces what it cannot deliver | Ticks that arrive while interrupts are masked do not queue up. Raising the timer from 1 kHz to 20 kHz over a lock-heavy workload delivered about 1.4× as many interrupts, not 20×. Anything that expects a preemption *rate* has to account for how much of the time interrupts are actually on. |
| A voluntary switch is not a preemption | Making a layer block often does not make its narrow races reachable. A sleeping session lock took `kernel/verify_vfs.odin` from ~1,000 context switches a run to ~110,000, and caught not one additional mutation — every added switch is at a lock boundary, and a two-instruction read-modify-write window is not. Only a timer, or a second core, interleaves two threads at an arbitrary instruction. |
| Refilling a slice on dispatch is not scheduling | `Thread.ticks_left` reset on every dispatch is indistinguishable from resetting it every slice, right up until something blocks. A thread that parks hundreds of times a second then never reaches the end of a slice, never decays, and outranks the thread doing steady work for ever. Decay has to measure CPU consumed, which means carrying the remainder across a block. |
| `int $8` is not a double fault | A software interrupt to an error-code vector does **not** push an error code, so it lands on a stub that assumes one was pushed. Never test `#DF` that way. Provoke a real one by faulting on a bad stack. |

**No vendored runtime shim.** The neighbouring `odin-os` project hand-maintains
a copy of `base:runtime` that must track the compiler. Current Odin ships
`runtime-os_specific_freestanding`, so Vectra builds against **stock
`base:runtime`**. Do not reintroduce a shim.

## 6. Where to go next

The scheduler was the thing that blocked everything else. What it exposed is now
locked and the session lock parks. A thread can wait for a condition or a
deadline, and a request can be left pending and flushed. Milestones 10 through
12 spent all of it. Every primitive a driver needs is not only present but used
by something that is not a self-test.

Processes reproduce two ways now, the console's hardware is all served
raw, and a posted service's connection comes down when nothing holds it.
Nothing blocks the `servers/` devfs port any more, and its teardown story
is written.

**The screen is memory a process holds, and a client draws into a window.**
`servers/intuition` opens `/dev/fb`, attaches it with `segattach`, and every
draw after that is a store rather than a seek and a write. The namespace is
what says which device, and whether a process may have it.

Image zero is the session's window rather than the screen. Every draw moves by
the window's origin and clips to its extent, and `ctl` reports the window's
shape and never the glass's. Two clients hold the same coordinates and mean two
places. **The protocol did not change to make that true**, which is the test
`docs/DRAW.md` section 3 chose the topology to pass.

**And a program can hold more memory than its own image.** `segalloc` answers
with a run of zeroed pages, described by a base and an extent the way a device
mapping already was. That was the piece a window's pixels waited on, and
`docs/DRAW.md` section 10 called it correctly a milestone early: it was not a
graphics question. `docs/USER.md` owns the call.

**Next, in order:**

1. **The graphics half of a window with pixels of its own.** The memory arrived
   and nothing draws into it yet. `servers/intuition` still stores through the
   window's origin straight onto the glass. So an occluded client's draws are
   still lost, and there is still no expose event.

   What that milestone is, now that the memory is not in the way. Each window
   gets a run of its own from `segalloc`. `run_fill` and `run_blit` store into
   that run rather than into the glass. `flush` becomes the damage mark that
   walks the dirty rectangles onto the screen. Stacking then becomes occlusion,
   and a covered client gets told to repaint. The placement policy stops being
   the thing that keeps two clients from overlapping at all.

   Two numbers move together when it happens. `MAX_WINDOWS` is two and
   `SEGALLOC_MAX` is 4 MB, which is exactly two 640 by 800 windows. A third
   window is a raise of both.

   One uncaught mutation belongs to this milestone rather than to the last two.
   `docs/DRAW.md` section 8 records that `rfork` copying a device segment is
   inert because nothing forks a process holding one. It stops being inert the
   day the compositor forks a worker.

2. **A MADT parse.** It retires both of the I/O APIC's assumptions, and the same
   table lists the cores SMP will need to start. Worth doing when one of those
   two becomes a reason rather than a tidiness.

**Standing gaps.** Each of these is something that exists and is incomplete,
rather than something absent. All are named in the code they live in.

- **A read/write sleeping lock.** `Mount_Point.generation` exists only because a
  read lock could not be held across a union search. Plan 9 holds one, because
  its locks sleep. Now that Vectra's can, the retry loop in `walk1_ex` could
  become a read lock and the generation counter could go.

  `Wait_Queue` is the right foundation, and the reader/writer policy is the only
  new thinking. Which of two waiting kinds should `take_best` prefer? Does a
  waiting writer block an arriving reader?
- **Priority inheritance.** A lock or a rendezvous goes to the best *waiter*,
  but a low-priority *holder* still delays a high-priority waiter for as long as
  it holds. It has not bitten, because nothing runs at realtime. It will the
  moment something does. Plan 9 never had it either, which is an argument about
  cost rather than about correctness.
- **A worker per blocked request.** `devfs` holds a worker for the length of
  every parked read, so at most three reads of `/dev/cons` may park at once. A
  fourth stalls the connection until a byte arrives. Plan 9 gives every request
  a thread. See `docs/DEVFS.md`.
- **A union listing whose cookie is not a position.** `readdir` over a union is
  still index-based, and still documented as undefined if something rebinds
  part-way through. `kernel/srv` is the worked example of the fix: a monotonic
  id, and a cookie that means `resume after this one` however the table moved.
  See `docs/SRV.md`.
- **An interrupt context `sync.can_sleep` knows about.** A top half may hold a
  spinlock and may not hold anything that parks. `can_sleep` counts spinlocks
  and a bare handler holds none, so the rule is argued where it should be
  checked. A depth counter the trap dispatcher brackets a handler with would
  turn it into a named stop, the way the spinlock rule already is. It touches
  the scheduler's hot path, so it wants a milestone rather than a patch.
- **A process that cannot be stopped from outside.** It can end itself now, and
  the kernel still cannot end it. `user.destroy` refuses a process that is
  still running, because its thread is translating through the space and
  writing to the frames. The leak is honest rather than absorbed, and
  `user.stats().live` reports it. See `docs/USER.md`.
- **A system call with `IF` still set for four instructions.** `SFMASK` clears
  it, and a control that leaves it set is not caught, because an interrupt
  almost never lands in a four-instruction window. It is the one entry in
  `docs/TESTING.md`'s uncaught cluster that a second CPU has nothing to do
  with.
- **A killed process holds its descriptors until something reaps it.**
  `reap_orphans` runs only from `spawn_path`. A ring 3 server that faults
  mid-request therefore never hangs up its pipe, and the client parked on it
  stays parked. The wire already poisons on hangup, so what is missing is the
  hangup itself.
  A control in `docs/DRAW.md` found it by stopping a boot, and it is the one
  gap here that turns a failed check into a hang.
- **Three of Plan 9's segment calls are missing, and they are one gap.**
  `segfree(va, len)` frees the pages under a range and keeps the segment.
  `segdetach(addr)` takes the segment out of the process. `segbrk(addr, top)`
  grows or shrinks one in place, and 9front's `syssegbrk` answers for `SG_BSS`
  and `SG_SHARED` alone, refusing every other type by name.

  So Vectra gives a run back at exit and at no other moment, and the address
  bump never comes down either. That is address space rather than memory, and
  the cheaper of the two to leak. `segbrk` is the one with a named trigger: a
  window that resizes. See `docs/USER.md`, which reads the three against
  9front.
- **A free list for fids, `/srv` ids, and now pids.** All three counters are
  monotonic and therefore finite: four billion opens per session, two billion
  posts, and a pid space nothing recycles. One fix retires all of them, and
  pids have the strongest claim on never-reuse, so it wants a generation
  rather than a reset.

**SMP, when it is wanted.** The shapes are already right. `Cpu` is per-core,
`Resume` is per-thread and lives on that thread's stack, and every mount-table,
namespace and heap mutation is inside a `sync.Spinlock`.

What is missing is a lock word in that struct, an AP trampoline, IPIs, and a
placement policy for `enqueue`. That last is where `eligible` and the class and
capacity fields stop being inert.

Four things become urgent the moment a second core runs, and all four are named
where they live:

1. `Chan.refs` and `Mount_Point.refs` want atomic increments rather than a
   global lock.
2. `sync.critical_depth` has to become per-CPU state.
3. `sync.Mutex` needs the scheduler to drop its guard *after* the switch. A
   parked thread currently relies on the interrupt mask that travels with it
   through the trap frame.
4. A mask is what stands in for a lock on every wait list, so `Wait_Queue` needs
   a real lock word. `Rendez` then grows the `^Spinlock` that Plan 9's always
   carried, held by the caller across both the condition test and the wake-up.
   The API has its present shape partly so that change will not alter it.

**Smaller things worth doing when convenient:**

- A stack backtrace on the panic screen. Everything else a fault report wants to
  say is already there.
- Make `check_base_revision()` a hard stop rather than a warning.
- `^W` and a cursor inside the line under construction, which is word erase and
  the arrow keys. A larger edit buffer and a position in it, rather than a new
  idea. See `docs/DEVFS.md`.
- Enforce the `open` flag on a fid. 9P forbids a walk on an open fid and a read
  on an unopened one. `vfs.Fid_Table` carries the flag and no server checks it.
  `chan_clone` walks a fid that may already be open, so this has a blast radius
  and wants a milestone rather than a patch.
- An idle-time reaper. `reap` only runs from `spawn` and from the self-tests, so
  a dead thread's stack comes back at the next spawn rather than when it exits.
  That is fine now. Both concurrency self-tests have to call `sched.reap()` by
  hand before measuring the heap, which is the smell.
- Teach `arch_arm64.odin` / `arch_riscv64.odin` the paging, trap and scheduling
  interfaces. `cpu_class` is the one that pays off immediately — a big.LITTLE
  part reporting three classes makes the capacity arithmetic do real work.

## 7. File map

```
build.odin              Build driver: user programs, kernel, ESP, QEMU, and
                        the ELF-to-VECTRA02 converter
justfile / Makefile     Thin wrappers over build.odin
boot/
  limine.conf           Limine config (new-style), staged to /EFI/BOOT/
  limine/               Vendored Limine 12.6.1 UEFI binaries + VERSION + README
kernel/
  main.odin             kmain, Limine requests, boot survey, memory bring-up
  verify_sync.odin      The sleeping lock on its own terms: 14 checks, 2 threads
  verify_rendez.odin    The sleep queue: 20 checks -- the clock, the park, the
                        condition, the order
  verify_flush.odin     Tflush: 35 checks, against a server that will not finish
                        -- abortable and stubborn, and the stubborn one is the
                        test
  verify_payload.odin   A payload buffer per request slot: 23 checks, and a
                        shared-buffer control that runs on every boot and has to
                        corrupt
  verify_vfs_mnt.odin   The namespace over a transport with workers: 41 checks,
                        four threads on one namespace, and a read given up from
                        a path
  verify_vfs.odin       The namespace under five threads: 34 checks, two servers
  verify_space.odin     Address spaces: 33 checks -- two threads, one address,
                        two meanings, and a teardown that stops at the halfway
                        index
  verify_wire.odin      The wire against a scripted server across a real pipe:
                        46 checks -- out-of-order replies, a full pool
                        flushing out, a stale reply, a hangup and a poisoning
  splash.odin           Boot chassis: plinth, copper bar, well, lamps
  log.odin              Kernel log; serial + screen, with early-line replay
  panic.odin            The panic screen, and the trap handler behind it
  link_amd64.ld         Static-PIE layout; orders .limine_requests, exports
                        the __text/__rodata/__data segment bounds
  arch/
    arch_amd64.odin     The architecture interface, bound to amd64
    arch_arm64.odin     Stub
    arch_riscv64.odin   Stub
    amd64/cpu.odin      Port I/O, control regs, MSRs, CPUID, EFER, SSE
    amd64/paging.odin   Page table format: entry bits, encode/decode, TLB
    amd64/gdt.odin      GDT, TSS, and the interrupt stack table
    amd64/idt.odin      IDT, the 256 entry stubs, dispatch, fault reporting
    amd64/pic.odin      Legacy 8259s: remapped clear of the exceptions, masked
    amd64/ioapic.odin   The I/O APIC: the register window, and one redirection
                        entry per line
    amd64/lapic.odin    Local APIC, the timer that preempts, EOI
    amd64/pit.odin      Channel 2 as a ruler, to measure the LAPIC against
    amd64/context.odin  A new thread's first saved state, in ring 0 or ring 3,
                        and what class a core is
    amd64/percpu.odin   What one core keeps behind GS, and the two MSRs that
                        say where it is
    amd64/syscall.odin  SYSCALL and SYSRET: the four registers that arm them,
                        and the naked stub that finds a stack with nothing to
                        trust
  boot/limine/
    limine.odin         Protocol bindings (v12.6.1)
    markers.odin        Base revision tag + request delimiters
  drivers/
    uart/uart.odin      16550 serial, polled
    fb/fb.odin          Surface, clipping, bevels, gradients, brushed fill
    fb/palette.odin     The system palette — single source of colour truth
    console/console.odin  Framebuffer text console
    console/               draws from sys/libfont, the one font table
  mem/
    mem.odin            Region/Boot_Memory types, HHDM, alignment, mem.init
    pmm.odin            Bitmap physical page allocator, and the zeroed run a
                        segment of anonymous memory is cut from
    vmm.odin            Page table walk, kernel address space, translate
    heap.odin           Slab allocator + Odin's context.allocator
    space.odin          One page table tree per process, and the kernel half
                        every one of them shares
  vfs/
    lock.odin           What guards what, in what order, and the lock that went
    vfs.odin            Server on either transport, the #name device table,
                        rpc, and the counted release a server can carry
    chan.odin           Chan, refcounting, open/create/read/write/remove/stat/
                        clone, a read with a deadline, and the server's own
                        count of the chans that name it
    mount.odin          The mount table, bind/unmount, union member lists
    namespace.odin      Namespace, rfork semantics, teardown
    walk.odin           attach, walk1, cross_mounts, `..`, resolve,
                        open_path and create_path
    readdir.odin        Union directory reads and the member-index cookie
                        that kernel/srv shows how to retire
    fidtab.odin         The fid table every server here uses: fid to i32 plus
                        an open flag, and no lock
    static.odin         A read-only server over a node table
    root.odin           `#/`, an instance of it, and the boot namespace
    verify.odin         The boot self-test: 51 checks, two real servers
  sched/
    thread.odin         Thread, Cpu, priorities, decay and boost, slice scaling
    queue.odin          Per-level FIFOs and the pick
    sched.odin          init, spawn, block/ready/unpark, reschedule, the tick
                        that also drains sync's deadlines
    verify.odin         The boot self-test: cooperative half and preemptive half
  drivers/kbd/
    kbd.odin            PS/2 scancodes: the top half that may not park, the
                        ring, the bottom half that may, set 1 for a US
                        layout, and the raw hook with first refusal
    verify.odin         The boot self-test: 55 checks -- the state machine on
                        its own, the raw hook and its stale-shift arc, and
                        one interrupt the 8042 was asked to raise
  mnt/
    mnt.odin            A 9P connection with several requests in flight: the
                        tag pool, the payload buffer per slot, the work queue,
                        and the client's flush
    serve.odin          The workers, and where Rflush's ordering rule lives
    wire.odin           The same client over bytes: frames down a Wire_IO,
                        replies matched by tag, and the poison that answers a
                        server that breaks framing
  pipe/
    pipe.odin           Two ends, a byte ring per direction, blocking reads
                        and writes, and the ends as chans
    serve9.odin         A posted pipe end turned into a mountable server: the
                        wire build, the handshake deadline, the pin, and the
                        counted release that gives all of it back
    verify.odin         The boot self-test: 37 checks -- bytes across, a
                        reader and a writer parked and woken, EOF and EPIPE
                        out the right sides
  devfs/
    devfs.odin          `#c` at /dev: the node table, the handler, the abort
                        hook, /dev/consctl, and the worker count that bounds
                        parked readers
    cons.odin           The console device: two sinks out, a line discipline
                        and a ring in, and two locks of different kinds
    fbdev.odin          The raw framebuffer: /dev/fb as the screen's memory
                        at an offset, /dev/fbctl as its geometry, and the
                        three boundary rules of the first device with a size
    tap.odin            The raw input streams: /dev/scancode and /dev/eia0,
                        each owning its stream while held open and giving
                        it back on the last close
    verify.odin         The boot self-test: 134 checks over the real /dev --
                        a read that parks through a character, a line edited,
                        a mode that reverts when its file closes, pixels
                        written through the mount and read off the screen,
                        and both streams diverted and given back
  srv/
    srv.odin            `#s` at /srv: the table, post and remove, mounting by
                        name, the id a fid binds instead of a slot, the
                        posted chan a mount turns into a server, and the
                        name's stake a removal releases
    verify.odin         The boot self-test: 82 checks -- a service published,
                        mounted, removed under its own mount, a listing paced
                        across a removal, and a pending name refused
                        everything but removal
  user/
    user.odin           A process: a space, segments, a namespace forked
                        from the kernel's, a descriptor group, and the
                        fault handler that ends one rather than the machine
    segment.odin        The frames behind one mapping, refcounted -- what
                        lets rfork map one segment into two spaces, in two
                        shapes: a frame list, and a base with an extent for
                        a card or a run of anonymous memory
    fdtable.odin        The fd table as a refcounted group: the take/advance
                        borrow discipline, and the release-once exit rule
    rfork.odin          Plan 9's fork: the flag word, the per-kind segment
                        copy rule, and the child built before it can run
    syscall.odin        What is behind the door: the calling convention, the
                        twenty-two calls, the note check the door runs first
                        -- deliver a handler or end -- the two copies that
                        judge a pointer from ring 3, and the resolver that
                        answers /srv's descriptor question
    notify.odin         The ring 3 note handler: the frame delivery pushes
                        onto the user stack, and the noted that resumes or
                        dies -- what turns a note into a signal
    exec.odin           A process replaces itself: a new image built in a
                        fresh space, committed only when whole, and the
                        syscall frame rewritten to return into it
    image.odin          Both image formats, the segment judge, the loader
                        that builds either shape of process, and `#b` at
                        /bin serving blobs and compiled images alike
    spawn.odin          A process that starts another one: what a child
                        inherits, the wait that parks for it by pid, and the
                        reaper that collects a detached orphan
    program.odin        The twenty-eight programs the assembler bakes into
                        the image, and the marks they write to say they ran
    verify.odin         The boot self-test: 644 checks -- one process preempted
                        while the kernel works, four refused, four that ask,
                        three that open files by name, a painter that puts
                        pixels on the screen through /dev/fb, a reader that
                        holds raw scancodes in its own page, a parent that
                        raises two children, a poster that publishes a
                        service, a niner the kernel talks to as a 9P client,
                        a compiled ramfs serving its own segments back, three
                        processes ended by notes, one that catches two and
                        one that declines, one that replaces itself, one that
                        forks a child no parent waits for, four that fork, a
                        console server whose /line read parks in a worker,
                        a keyboard translator that turns raw scancodes
                        into characters over a mount, a serial server
                        that puts a ring 3 write on the wire, a draw
                        server whose verbs read back off the glass, one
                        that asks for half a megabyte of memory no file
                        serves and forks to see whose copy is whose, and
                        a terminal typed at through the keyboard sink
  sync/
    spin.odin           The lock that masks: the interrupt flag, nesting handled
    wait.odin           Wait queues, scheduler hooks, priority-ordered service
    sleep.odin          The lock that parks: Mutex, and handoff rather than retry
    rendez.odin         Waiting for a condition, with or without a deadline
sys/
  abi/abi.odin          The system call ABI: numbers, flags and packings,
                        included by both sides of the door
  libodin/
    format.odin         Allocation-free formatting (Sink)
    tally.odin          Checks counted and the first failure kept, which
                        seventeen self-tests had each written out
  vectra9/
    proto.odin          Message kinds, Qid, the 57 bodies, the Msg union
    codec.odin          Encode/decode over a bounds-checked cursor; dirents
    errors.odin         Codec Error and protocol Errno, kept separate
    session.odin        Session, Transport, Handler; in-process and loopback
    verify.odin         The boot self-test
  libuser/
    sys.odin            The calls from ring 3: one wrapper each, the loop
                        helpers every byte-moving caller needs, and the
                        child-first teardown a forked reader ends by
    ring.odin           The byte ring a forked reader publishes through,
                        once a private copy in each of three servers
    serve.odin          post and serve: a 9P server as a loop a program
                        calls, around a vectra9.Handler; serve_mux, the
                        concurrent loop with a worker per parked request;
                        and Spin, the first ring 3 lock
    fid.odin            The fid table five servers had each written, with a
                        lock all of them now have, plus the walk, the
                        attach and the EBADF guard that went with it
    link_user.ld        The layout of a ring 3 program, aligned so every
                        change of permission gets its own page
  libdraw/draw.odin     The draw protocol's encoding, owned once: the six
                        verbs, the put half a client batches with, and the
                        get half the server decodes with
  libdraw/text.odin     Text as a library over blit: the atlas layout, and
                        put_text with its consumed-count return that pumps
                        a long line through in batches
  libfont/font_data.odin  GENERATED -- the one 8x16 font table, imported
                        by the kernel console and linked by ring 3 alike
  libposix/             Empty
servers/
  ramfs/main.odin       The first compiled server: two files, one writable,
                        serving this program's own segments back
  consrv/main.odin      The console server: an rfork'd reader parked on
                        /dev/cons, a concurrent serve loop whose /line reads
                        park in workers, and a shared ring under two locks
  kbdfs/main.odin       The keyboard translator: an rfork'd reader on
                        /dev/scancode, the kernel's scancode state machine
                        rebuilt in ring 3, and /kbd served cooked
  eiafs/main.odin       The serial server: an rfork'd reader on /dev/eia0,
                        the raw bytes served on /eia0, and the first Twrite
                        that reaches hardware
  intuition/main.odin   The draw server, the compositor's first half: six
                        verbs on a data file, a session per fid, and every
                        draw clipped before it touches /dev/fb
apps/
  terminal/main.odin    The first app: lines in from /dev/cons, glyphs out
                        through a /srv/draw mount of its own, the first
                        ring 3 mount in the tree
tools/
  genfont.py            TTF -> font_data.odin
  ste-lint.py           The ASD-STE100 checker; `build.odin -- lint` runs it
.claude/skills/
  asd-ste100/           The controlled-language skill this tree writes under
docs/
  HANDOFF.md            This file: status, build, roadmap, and the index below
  VECTRA9.md            The protocol and namespace design, and what
                        sys/vectra9/ decided while implementing it
  BOOT.md               Limine, arch, traps, the panic screen, the console
  MEMORY.md             PMM, VMM, heap
  SCHED.md              The switch, priorities, decay and boost, the tick
  SYNC.md               Spinlock, sleeping lock, sleep queue, deadlines
  NAMESPACE.md          kernel/vfs: what guards what, and the borrow rule
  TRANSPORT.md          kernel/mnt: the tag pool, the workers, Tflush, and
                        the wire over bytes
  PIPE.md               kernel/pipe: the byte rings, the ends as chans, and a
                        posted end becoming a server
  RUNTIME.md            The userland runtime: sys/abi, sys/libuser, the
                        VECTRA02 format, and servers/ramfs
  SRV.md                kernel/srv: #s at /srv, what a posted service is, and
                        the two decisions a directory that changes needs
  SPACE.md              kernel/mem/space.odin: a space per process, what it
                        owns, and the comparison the scheduler grew
  USER.md               kernel/user: ring 3, the door back in, a process and
                        its own namespace, the note handler, the confused
                        deputy, the exec that replaces a process, and the
                        thirty-four controls
  KBD.md                kernel/drivers/kbd: scancodes, the I/O APIC route, and
                        the constraint that splits a handler in two
  DEVFS.md              kernel/devfs: #c at /dev, the console device, the
                        line discipline, the ctl convention, the raw
                        framebuffer and streams, and the twenty-nine
                        controls the self-test was measured against
  DRAW.md               The /dev/draw design: six verbs over a data file,
                        flush as visibility, and the mapping deferred with
                        its shape written down
  TESTING.md            The self-test discipline, and the negative controls
  STYLE.md              ASD-STE100: the two modes, the checked rules, and the
                        project dictionary
  milestone0-boot.png   Milestone 0 screenshot -- it boots
  milestone1-memory.png Milestone 1 screenshot -- PMM, VMM, heap
  panic-screen.png      Milestone 2 screenshot -- a deliberate #PF, reported
  userland-boot.png     The boot the README leads with: the userland half of
                        the log, and the lines a ring 3 program printed
```
