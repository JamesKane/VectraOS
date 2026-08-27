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

## 2. Where things stand

**Milestone 9 is done, and the namespace is on it.** `Tflush` works, and so does
the transport that made it possible. A payload buffer per request slot lets a
real server sit behind it. A read from a path can be walked away from.

Milestone 0 boots it. Milestone 1 gave it a PMM, its own page tables and a heap
behind `context.allocator`. Milestone 2 gave it a GDT, TSS, IDT and a panic
screen. Milestone 3 added `sys/vectra9/`, which is the whole 9P2000.L message
set, a codec, and the session and transport boundary. Milestone 4 added
`kernel/vfs/`, the namespace that uses it. Milestone 5 added `kernel/sched/` and
the local APIC timer under it.

Milestone 6 locks the namespace against the threads Milestone 5 made possible.
It proves that with five threads that walk, list, read and rebind the same
namespace at once. Milestone 7 makes the one lock held across a 9P message a
*sleeping* lock. That is what an out-of-process transport was waiting for, and
it made the vfs layer preemptible for the first time.

Milestone 8 gives it the other half of the wait. A thread can now wait for a
*condition* rather than for a lock, and it can wait with a deadline. Milestone 9
spends both on the question `docs/VECTRA9.md` left open longest: a 9P transport
that can leave a request pending, and `Tflush` over it.

The last piece of it is a payload buffer per request slot. A reply used to
borrow the server's storage, which one request at a time made safe and eight
made false. Each slot now owns a buffer and the handler is handed it, so a real
server can sit behind several workers. `vfs.static_handler` does, unmodified,
under four threads listing one directory at once.

`kernel/vfs` then moved onto it. A `Server` sits on either transport and nothing
above it knows which. What that cost the namespace was `Server.lock`, and the
lock is gone rather than narrowed. It existed to keep one message in flight per
session, and a reply borrows the caller now. `alloc_fid` is an atomic increment,
which was the lock's other job. What it bought is `chan_read_for`, a read with a
deadline that sends `Tflush` and waits for `Rflush` before it lets the fid go.

About 20,300 lines of Odin. The linked image is ~735 KB debug and ~319 KB
release.

```
[  --  ] Vectra 0.1.0-pre (amd64) entering kmain
[  ok  ] base revision 6 as requested
[  ok  ] traps: cs 0x8, tr 0x30, 256 vectors, #BP round-trip ok
[  ok  ] framebuffer 1280x800 @ 32bpp, pitch 5120 -> 0xffff800080000000
[  --  ] console 149 cols x 36 rows
[  --  ] booted by Limine 12.6.1 via UEFI (64-bit)
[  ok  ] paging 4-level
[  --  ] kernel phys 0x000000001bbb5000 virt 0xffffffff80000000
[  --  ] hhdm offset 0xffff800000000000
[  --  ] memory map: 28 entries spanning 12.7 GiB
[  ok  ] usable 466.9 MiB, reclaimable 39.5 MiB
[  --  ] largest usable region 395.2 MiB at 0x0000000001600000
[  ok  ] pmm 119536 frames free of 123414 tracked, bitmap 15.0 KiB at 0x0000000000001000
[  ok  ] vmm root 0x0000000000005000, mapped 515.4 MiB in 271 tables (1.0 MiB)
[  --  ] vmm nx on, global pages on, largest leaf 2.0 MiB
[  ok  ] heap online -- context.allocator is live
[  ok  ] memory self-test passed -- 1 slab pages, 0 large blocks live
[  ok  ] vectra9 9P2000.L: 57 message kinds round-trip, both transports agree
[  ok  ] namespace: #/ attached as /, 7 conventional directories
[  ok  ] vfs 51 namespace checks passed -- union of 4 names over two servers, 1 mount point, heap balanced
[  ok  ] sched cpu0 performance, capacity 1024/1024, slice 10 ticks, 16 priority levels
[  ok  ] sched 21 scheduler checks passed -- 132 switches, round-robin and priority verified
[  ok  ] lapic timer 1000 Hz -- bus clock 62.5 MHz measured against the PIT, 62537 counts per tick
[  ok  ] sched preemption 11 checks passed -- 3 threads preempted, none starved (16428925-16578328 rounds), decayed to 5, 3 fpu accumulators intact
[  ok  ] sync 14 sleeping lock checks passed -- 2057 acquisitions, 1962 parked and handed back, decayed to 1
[  ok  ] sync 20 sleep queue checks passed -- 12 parked, 12 woken, 25-tick delay took 25 in 2 switches
[  ok  ] 9p 35 Tflush checks passed -- 34 requests, 11 flushed (10 in flight, 1 stale), Rflush held 40 ticks for a stubborn server
[  ok  ] 9p 23 payload checks passed -- 1024 bytes per slot, 4096 delivered to 8 readers, 7 spoiled by a shared buffer, 4 listings at once
[  ok  ] vfs 41 transport checks passed -- 160 reads and 160 listings across 4 threads on 4 workers, msize 4107, a read gave up after 10 ticks
[  ok  ] vfs 34 concurrency checks passed -- 4763 namespace operations across 5 threads, 762 rebinds under them in 1000 ms, nothing serialised, heap balanced
[  ok  ] boot complete -- idling
```

The last line is the one that moves between builds, on purpose. `just release`
does the same thousand ticks of work, and reports about fifty thousand
operations. `docs/TESTING.md` says why that is the right way round.

**What still does not exist.**

- No userland and no address-space switch. A thread grows an `^Address_Space`,
  and `reschedule` grows one comparison, when there is one.
- No SMP. `Cpu` is per-core and `MAX_CPUS` is 8, but only core 0 ever starts.
  There is no IPI, no AP trampoline and no lock word.
- No `/srv`.
- No condition variable as such, because `sync.Rendez` is one.
- No read/write sleeping lock, which is the piece `Mount_Point.generation`
  stands in for.
- No use of `Tflush` from `kernel/vfs`. It exists in `kernel/mnt`. See
  `docs/TRANSPORT.md`.
- No `swapgs`, and no per-CPU state behind GS.
- `kmain` ends with a call to `sched.exit`, so the machine idles rather than
  halts.

**The design is written down in `docs/VECTRA9.md`, and it is the thing to read
before touching the protocol or the namespace.** Three decisions in it shape
everything downstream, all three taken deliberately:

1. **The wire is 9P2000.L and nothing is added to it.** No new message, no extra
   field, no private version string. When a service needs an operation 9P does
   not have, the answer is a *file* — a `ctl` that takes a line of text.
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
| `docs/TRANSPORT.md` | `kernel/mnt/` — the tag pool, the workers, `Tflush`, the payload buffer | Writing a transport, making a request interruptible, or wondering who owns a reply's bytes |
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
(from `~/.swiftly/bin`), QEMU 11.1.0, Python 3 with Pillow (font generation
only). No `just` installed — use `make`. No `xorriso`, no loop devices, no
`sudo` required.

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

The scheduler was the thing that blocked everything else. The namespace it
exposed is now locked. The lock that holds a session across a message sleeps,
and a thread can now wait for a condition or a deadline. Every primitive a
driver needs now exists. What is left is mostly *use* of them.

**A first real device server is the next piece.** `devfs` with `/dev/cons` over
the console driver, which makes the whole path from a name to a byte on screen
exist end to end. `static.odin` is the wrong shape only because it is read-only.
Everything under it is now in place. A server can have workers, a read of it can
be given up on, and a write has somewhere to put its payload.

That server is also the first one whose reads genuinely block. Everything that
waits today waits because a self-test told it to.

**A read/write sleeping lock is the other piece worth wanting.**
`Mount_Point.generation` exists only because a read lock could not be held
across a union search. Plan 9 holds one, because its locks sleep. Now that
Vectra's can, the retry loop in `walk1_ex` could become a read lock, and the
generation counter could go.

`Wait_Queue` is the right foundation. The
reader/writer policy is the only new thinking, and it has two questions. Which
of two waiting kinds should `take_best` prefer? Does a waiting writer block an
arriving reader?

**Priority inheritance is the known gap in what exists.** A lock or a rendezvous
goes to the best waiter, but a low-priority *holder* still delays a
high-priority waiter for as long as it holds. It has not bitten, because nothing
runs at realtime. It will the moment something does. Plan 9 never had it either,
which is an argument about cost rather than about correctness.

**Then, in roughly this order:**
1. **`kernel/vfs` on `kernel/mnt`.** See above. This is what makes `Tflush`
   reachable from a path rather than from a self-test.
2. **A first real device server.** `devfs` with `/dev/cons` over the console
   driver, which makes the whole path from a name to a byte on screen exist end
   to end. `static.odin` is the wrong shape only because it is read-only.
3. **`/srv`**, which needs a thread on each side of a transport and therefore
   needed the scheduler.
4. **Userland.** A thread grows an `^Address_Space`, `reschedule` grows one
   comparison, and the GDT already has the selectors laid out for
   SYSCALL/SYSRET. `swapgs` and per-CPU state behind GS belong to this step and
   are cheaper to build with it than after it.

**SMP, when it is wanted.** The shapes are already right. `Cpu` is per-core,
`Resume` is per-thread and lives on that thread's stack, and every mount-table,
namespace and heap mutation is inside a `sync.Spinlock`.

What is missing is a lock word in that struct, an AP trampoline, IPIs, and a
placement policy for `enqueue`. That last is where `eligible` and the class and
capacity fields stop being inert.

Three things become urgent the moment a second core runs:

1. `Chan.refs` and `Mount_Point.refs` want atomic increments rather than a
   global lock.
2. `sync.critical_depth` has to become per-CPU state.
3. `sync.Mutex` needs the scheduler to drop its guard *after* the switch. A
   parked thread currently relies on the interrupt mask that travels with it
   through the trap frame.

A fourth arrived with the sleep queue. A mask is what stands in for a lock on
every wait list, so `Wait_Queue` needs a real lock word. `Rendez` then grows the
`^Spinlock` that Plan 9's always carried, held by the caller across both the
condition test and the wake-up. The API has its present shape partly so that
change will not alter it. All four are named where they live.

**Smaller things worth doing when convenient:**

- A stack backtrace on the panic screen. Everything else a fault report wants to
  say is already there.
- Make `check_base_revision()` a hard stop rather than a warning.
- A free list for fids. `alloc_fid` is monotonic and therefore finite: four
  billion opens per session, never reused.
- `reap` only runs from `spawn` and from the self-tests, so a dead thread's stack
  comes back at the next spawn rather than when it exits. That is fine now. An
  idle-time reaper is the fix. Both concurrency self-tests have to call `sched.reap()` by
  hand before measuring the heap, which is the smell.
- `sync.Mutex` has no priority inheritance. Handoff goes to the best *waiter*,
  but a low-priority *holder* still delays a high-priority waiter for as long as
  it holds. It is worth wanting when there is a realtime thread that matters.
  Plan 9 never had it either.
- `readdir` over a union is still index-based, and is still documented as
  undefined if something rebinds the union part-way through. The cookie names a
  position in a list that moved. `walk` no longer has that property, thanks to
  `Mount_Point.generation`. A listing could get the same treatment if it ever
  matters.
- Teach `arch_arm64.odin` / `arch_riscv64.odin` the paging, trap and scheduling
  interfaces. `cpu_class` is the one that pays off immediately — a big.LITTLE
  part reporting three classes makes the capacity arithmetic do real work.

## 7. File map

```
build.odin              Build driver: compile, link, stage ESP, run QEMU
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
    amd64/lapic.odin    Local APIC, the timer that preempts, EOI
    amd64/pit.odin      Channel 2 as a ruler, to measure the LAPIC against
    amd64/context.odin  A new thread's first saved state; what class a core is
  boot/limine/
    limine.odin         Protocol bindings (v12.6.1)
    markers.odin        Base revision tag + request delimiters
  drivers/
    uart/uart.odin      16550 serial, polled
    fb/fb.odin          Surface, clipping, bevels, gradients, brushed fill
    fb/palette.odin     The system palette — single source of colour truth
    console/console.odin  Framebuffer text console
    console/font_data.odin GENERATED — do not hand-edit
  mem/
    mem.odin            Region/Boot_Memory types, HHDM, alignment, mem.init
    pmm.odin            Bitmap physical page allocator
    vmm.odin            Page table walk, kernel address space, translate
    heap.odin           Slab allocator + Odin's context.allocator
  vfs/
    lock.odin           What guards what, in what order, and the lock that went
    vfs.odin            Server on either transport, the #name device table, rpc
    chan.odin           Chan, refcounting, open/read/write/stat/clone, and a
                        read with a deadline
    mount.odin          The mount table, bind/unmount, union member lists
    namespace.odin      Namespace, rfork semantics, teardown
    walk.odin           attach, walk1, cross_mounts, `..`, resolve
    readdir.odin        Union directory reads and the member-index cookie
    static.odin         A read-only server over a node table, and its fid table
    root.odin           `#/`, an instance of it, and the boot namespace
    verify.odin         The boot self-test: 51 checks, two real servers
  sched/
    thread.odin         Thread, Cpu, priorities, decay and boost, slice scaling
    queue.odin          Per-level FIFOs and the pick
    sched.odin          init, spawn, block/ready/unpark, reschedule, the tick
                        that also drains sync's deadlines
    verify.odin         The boot self-test: cooperative half and preemptive half
  mnt/
    mnt.odin            A 9P connection with several requests in flight: the
                        tag pool, the payload buffer per slot, the work queue,
                        and the client's flush
    serve.odin          The workers, and where Rflush's ordering rule lives
  sync/
    spin.odin           The lock that masks: the interrupt flag, nesting handled
    wait.odin           Wait queues, scheduler hooks, priority-ordered service
    sleep.odin          The lock that parks: Mutex, and handoff rather than retry
    rendez.odin         Waiting for a condition, with or without a deadline
sys/
  libodin/format.odin   Allocation-free formatting (Sink)
  vectra9/
    proto.odin          Message kinds, Qid, the 57 bodies, the Msg union
    codec.odin          Encode/decode over a bounds-checked cursor; dirents
    errors.odin         Codec Error and protocol Errno, kept separate
    session.odin        Session, Transport, Handler; in-process and loopback
    verify.odin         The boot self-test
  libposix/             Empty
servers/ apps/          Empty
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
  TRANSPORT.md          kernel/mnt: the tag pool, the workers, Tflush
  TESTING.md            The self-test discipline, and the negative controls
  STYLE.md              ASD-STE100: the two modes, the checked rules, and the
                        project dictionary
  milestone0-boot.png   Milestone 0 screenshot -- it boots
  milestone1-memory.png Milestone 1 screenshot -- PMM, VMM, heap
  panic-screen.png      Milestone 2 screenshot -- a deliberate #PF, reported
```
