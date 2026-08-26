# Vectra — session handoff

Written 2026-08-26, revised the same day after Milestones 1, 2 and 3. Read this first
when picking the project up in a new session; it records the things the code cannot tell you on its own — what was
decided and why, what cost time, and what is deliberately missing.

---

## 1. What Vectra is

A modular operating system in Odin. Two ideas define it:

- **Plan 9-inspired structure.** Per-process namespaces, private mount tables,
  and a synthetic file protocol (Vectra9 / 9P2000.L) through which *every*
  system service — drivers, network stack, graphics, IPC, thread state — is a
  file tree behind a message-passing endpoint. POSIX is a translation runtime on
  top of that, never a set of hardwired syscalls.
- **"Cyberpunk Workstation 1994" UX.** Heavy skeuomorphic bevels, brushed dark
  magnesium over deep slate, amber/cyan/phosphor accents, copper trim, a
  software dirty-rect compositor, and tracker-synthesised relay clicks.

Target layout — `kernel/` (arch, mem, sched, vfs, drivers), `sys/` (libodin,
libposix, Vectra9), `servers/` (devfs, netfs, intuition), `apps/` (terminal,
filemgr, tracker). Primary arch `x86_64` via Limine, with clean abstractions for
`aarch64` and `riscv64`.

## 2. Where things stand

**Milestone 6 is done: the namespace is safe under threads.**

Milestone 0 boots it. Milestone 1 gave it a PMM, its own page tables and a heap
behind `context.allocator`. Milestone 2 gave it a GDT, TSS, IDT and a panic
screen. Milestone 3 added `sys/vectra9/` — the whole 9P2000.L message set, a
codec, and the session/transport boundary. Milestone 4 added `kernel/vfs/`, the
namespace that uses it. Milestone 5 added `kernel/sched/` and the local APIC
timer under it. Milestone 6 locks the namespace against the threads Milestone 5
made possible, and proves it with five threads walking, listing, reading and
rebinding the same namespace at once. About 14,000 lines of Odin; the linked
image is ~592 KB debug, ~237 KB release.

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
[  ok  ] sched preemption 11 checks passed -- 3 threads preempted, none starved (17728177-18134560 rounds), decayed to 5, 3 fpu accumulators intact
[  ok  ] vfs 33 concurrency checks passed -- 3822 namespace operations across 5 threads, 625 rebinds under them in 1058 ms, heap balanced
[  ok  ] boot complete -- idling
```

The last line is the one that moves between builds, on purpose: `just release`
does the same thousand ticks of work and reports about fifty thousand
operations. See "Measuring a concurrency test in ticks" below for why that is
the right way round.

**The design is written down in `docs/VECTRA9.md`, and it is the thing to read
before touching the protocol or the namespace.** Three decisions in it shape
everything downstream, all three taken deliberately:

1. **The wire is 9P2000.L and nothing is added to it.** No new message, no extra
   field, no private version string. When a service needs an operation 9P does
   not have, the answer is a *file* — a `ctl` that takes a line of text.
2. **Servers speak decoded messages; only the transport knows about bytes.**
   Neither the caller nor the handler can tell which transport it has.
3. **The namespace is the full Plan 9 model** — `bind`/`mount` with
   before/after/replace, union directories, per-process mount tables copied or
   shared on fork.

### The switch

There is one context-switch mechanism and one place that performs it. The
assembly tail in `kernel/arch/amd64/idt.odin` is the only code in Vectra that
reloads `rsp` from something other than a `pop`, and it does that for a
preemption, a voluntary yield and an ordinary interrupt return without knowing
which it has:

```
    thread A ---- int $0x81 -----+
                                 |
    timer -------- vector 0x20 --+--> trap tail --> reschedule --> thread B
                                 |     (fxsave)      (policy)       (fxrstor)
    fault --------- vector n ----+                                  (rsp swap)
```

A handler is handed the state it interrupted and returns the state to resume. If
those are the same, nothing happened. If they are different, that was a context
switch. The saved state — `arch.Resume`, a `Trap_Frame` pointer and a 512-byte
FXSAVE image — lives on the switching thread's own stack, so nothing about it is
per-CPU and none of it is a global.

**Priority is dynamic, following Plan 9.** Sixteen levels; highest non-empty
wins and rotates within itself. A thread that burns a whole slice without
blocking drops a level, floored at 1. A thread that blocks and is woken is
lifted to its base plus one, capped below the realtime range. That is the entire
anti-starvation mechanism, which is why there is not a second one, and it is
visible in the boot line: three compute-bound threads start at 8 and are at 5 by
the time the test ends.

**The core's *class* is a first-class input, on a machine that has one class.**
`arch.cpu_class` reports a class and a capacity, and a time slice is
`QUANTUM_TICKS * 1024 / capacity` — equal work per round rather than equal time,
so a thread on a half-speed core gets twice the ticks. On amd64 that is always
`.Performance` at 1024 and the arithmetic is a no-op. It is there now because
retrofitting capacity-awareness into a scheduler is a rewrite and adding a
number to a struct is not, and because arm64 will report three classes.

### The self-tests, and what they cost to make honest

Two halves. The cooperative half runs **before** the timer is armed, on purpose:
a cooperative scheduler is deterministic, so a failure there is reproducible,
and adding an asynchronous interrupt source to a scheduler not yet shown to
switch correctly makes every subsequent bug two bugs. The preemptive half then
runs three threads that never yield, with the boot thread as a fourth.

Six negative controls, all of which now fail the run they should:

| Mutation | First failure |
|---|---|
| `reschedule` never switches | `every cooperative worker finished` |
| enqueue at the head, not the tail | `every cooperative worker finished` |
| lowest priority picked first | `both priority workers finished` |
| no decay on a full slice | `burning full slices decayed the workers below their base` |
| no boost on wake | `waking boosts it above its base` |
| no FXSAVE/FXRSTOR in the trap tail | `preemption preserved every worker's floating-point registers` |

**Two of those took a second attempt, and both are worth knowing about.**

The FPU check was written first as four floating-point accumulators in an
ordinary Odin loop. It passed with the FXSAVE removed. The disassembly said why:
an unoptimised build spills every temporary to the stack after each instruction,
so the values were sitting on the thread's own stack, which is preserved by
construction, and nothing was being tested. It is now `fpu_hold` — a single asm
block that fills xmm0..xmm3 and spins *inside itself* until told to stop, so
those registers are live across every preemption the worker takes.

The seventh control — removing the EOI from the tick handler — did not fail. It
**hung**, with the last thing printed being the timer coming up successfully.
`verify_preemption` was waiting on the tick count with no bound, so a timer that
stopped stopped the boot. It now checks liveness instead: every 20 million times
round the spin, the tick count has to have moved. A self-test that hangs is
worse than one that fails — it says nothing, in the place hardest to attach a
debugger to.

### What preemption cost elsewhere

**The heap has a lock.** `kernel/sync` is that lock: on one core with no SMP,
"nothing else can run" and "interrupts are off" are the same statement, so
`Spinlock` is a name for the interrupt flag with the nesting handled. There is
no lock *word* yet and that is deliberate — a second core needs one, and every
site that will need it has already been found and wrapped. `alloc`, `free` and
`resize` take it; `resize` calls `alloc`, which is why it nests.

**`kernel/vfs` has one now too — five of them, and the interesting part is that
they do not all behave the same way.** See the next section.

### Locking the namespace

`kernel/vfs/lock.odin` is the whole discipline in one file. Five locks, and they
divide into two kinds with opposite rules:

| Lock | Guards | Held across a 9P message? |
|---|---|---|
| `Namespace.lock` | `root`, the mount table, `refs` | **never** |
| `object_lock` (global) | `Chan.refs`, `Mount_Point.refs`, `Mount_Point.members` | **never** |
| `Server.lock` | the session: fid and tag counters, one message in flight, a borrowed reply's lifetime | **always** |
| `Static_Tree.lock` | one server's own fid table and directory buffer | (server side) |
| `device_lock` (global) | the `#name` table | never |

**The session lock has to be held across the message; the bookkeeping locks must
never be.** That is not a style preference. `Rread.data` and `Rreaddir.data`
point into the server's own storage — the static server's `dirbuf`, a node's
string in `.rodata` — and "valid until the server's next message" used to be
safe because nothing could interrupt the caller between the reply and the copy.
Preemption ended that. So `rpc` returns a guard and the reply is only valid
until it is released:

```odin
e, g := rpc(c.server, &request, &reply)
defer rpc_end(g)
```

Every caller takes the guard, including the ones whose replies borrow nothing,
so there is no second entry point to reach for and no judgement about which
replies borrow. The same lock is what makes a fid mean something: `alloc_fid` is
a plain increment, and two threads that both read the counter before either
writes it both walk to `newfid`.

The other direction is enforced rather than documented. `kernel/sync`'s lock
*is* the interrupt flag, so a bookkeeping lock held across a message becomes a
hang the first time a transport blocks — a bug that would not appear until the
transport changed, months from the code that caused it. `vfs` counts its own
lock nesting and `rpc` refuses with `EDEADLK` if it is not zero. A negative
control that moves one clone inside the namespace lock fails four checks
immediately.

**Two bugs that predate threads came out of this.** `Chan.union_head` was a bare
pointer to a `Mount_Point`, and unmounting freed it — reachable with one thread
and a directory held open across an `unmount`. Mount points are reference
counted now, and `unmount` dissolves rather than deletes: the members go, the
struct survives until the last chan lets go, and a chan holding an empty mount
point behaves like one that was never in a union.

The second is `Mount_Point.generation`, and it is the one the self-test found on
its own. A union searched by index while a member is removed from the *front*
shifts every later member down, and a walker resuming at index 1 skips the entry
that used to be there — so a file that never moved comes back `ENOENT`. Plan 9
does not have this problem because it read-locks the mount head for the whole
union search; it can, because its locks sleep. Vectra's cannot. The counter
replaces the lock: a search that finds nothing is only believed if the list is
the same one it started on.

### Measuring a concurrency test in ticks

`kernel/verify_vfs.odin` runs five threads for a fixed number of *ticks*, not a
fixed number of rounds, and that distinction was worth a rewrite.

The first version ran a fixed round count. It failed correctly under `just run`
with the session lock removed — and passed under `just release`, every time. The
optimised kernel does the same 3,600 operations in a thirteenth of the ticks, so
it got a thirteenth of the preemptions and tested itself thirteen times less
thoroughly. What finds a race is not how much work happens, it is how often a
thread is interrupted in the middle of some. Both builds now get the same
thousand ticks; the fast one simply gets more done between them, and the control
fails in both.

Making the run tick-driven also lengthened the churn thread's share of it from
a sixth to all of it, which is what surfaced the `generation` bug above.

**Three of five mutations are caught. The two that are not are the more
interesting half**, and the file says so rather than filing it as a gap:

| Mutation | Result |
|---|---|
| remove `Server.lock` | caught — both listers, in both builds |
| free a referenced `Mount_Point` | caught — the reference count check |
| hold a namespace lock across a message | caught — `EDEADLK`, four checks |
| drop `cross_mounts`' reference to a member | **not caught** |
| unlocked chan reference counts | **not caught** |

Both uncaught windows are a few instructions wide, and catching one means
landing a timer interrupt inside about thirty instructions out of the twenty
thousand a round takes *and* having another thread free that exact object first.
Fifty thousand operations against seven thousand rebinds found neither. Turning
the tick rate up barely helps: at 20 kHz only about 1.4× as many ticks are
actually *delivered*, because every lock here is the interrupt flag and this
layer holds one for most of its instructions. **A uniprocessor Vectra thread
doing file I/O is very nearly non-preemptible**, which is exactly why the narrow
races are nearly unreachable now and will be ordinary on a second core.

**What still does not exist.** No userland and no address-space switching — a
thread grows an `^Address_Space` and `reschedule` grows one comparison when
there is one. No SMP: `Cpu` is per-core and `MAX_CPUS` is 8, but only core 0 is
ever brought up, and there is no IPI, no AP trampoline and no lock word. No
`/srv`. No `Tflush` service, though the scheduler it was waiting for now exists.
No sleep or timed wait — `block` and `ready` are the only blocking primitives.
No `swapgs`, no per-CPU state behind GS. `kmain` ends by calling `sched.exit`,
so the machine idles rather than halting.

## 3. Build and run

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

## 4. Toolchain constraints — the expensive ones

These were each found the hard way. Changing any of them will break the build in
ways whose error messages do not point back here.

| Constraint | Why |
|---|---|
| `-no-thread-local` | Odin otherwise emits `STT_TLS` symbols with no `PT_TLS` segment; `ld.lld` refuses the image. Per-CPU state must go through `GS` explicitly. |
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
| `int $8` is not a double fault | A software interrupt to an error-code vector does **not** push an error code, so it lands on a stub that assumes one was pushed. Never test `#DF` that way; provoke a real one by faulting on a bad stack. |

**No vendored runtime shim.** The neighbouring `odin-os` project hand-maintains
a copy of `base:runtime` that must track the compiler. Current Odin ships
`runtime-os_specific_freestanding`, so Vectra builds against **stock
`base:runtime`**. Do not reintroduce a shim.

## 5. Decisions made, and what would reverse them

- **Limine 12.6.1, base revision 6.** Vendored UEFI binaries only (x64, aa64,
  riscv64, ia32) in `boot/limine/`; no BIOS stage, no `limine` deploy tool,
  because Vectra boots UEFI everywhere. `kmain` reports the granted revision.
- **Paging pinned to 4-level** (`min_mode = max_mode = 4LVL` in
  `paging_mode_request`). Limine would otherwise hand us 5-level on capable
  hardware, moving the canonical hole and changing every table walk. Adding
  5-level support should be a deliberate edit to that request.
- **Base revision 6's HHDM is restrictive** — only usable,
  bootloader-reclaimable, executable, framebuffer, reserved-mapped, ACPI
  reclaimable and ACPI NVS regions are mapped. **The VMM must respect this.**
  `check_base_revision()` currently only *warns* on a mismatch; make it a hard
  stop as soon as anything dereferences an HHDM address.
- **`arch` is the only CPU-facing import** the portable kernel may use.
  Per-architecture bindings are selected by `#+build` tag
  (`arch_amd64.odin`, `arch_arm64.odin`, `arch_riscv64.odin`); the latter two
  are stubs that exist so a port is filling in blanks, not editing call sites.
- **Inline asm, no nasm.** Odin's `asm(...)` with LLVM AT&T templates and
  register constraints covers port I/O, control registers and MSRs. Verified by
  disassembly.
- **The framebuffer `Surface` is the shared drawing type.** The boot splash, the
  future panic screen, and `intuition`'s off-screen window buffers are all
  Surfaces, so a bevel drawn at boot and one on a titlebar are the same code.
  `kernel/drivers/fb/palette.odin` is the single source of colour truth.
- **Console font is host-rasterised.** `tools/genfont.py` bakes PTMono at 13px
  (exactly 8×16) into `kernel/drivers/console/font_data.odin`. Serviceable, but
  a hand-drawn bitmap face is the right long-term answer for the amber terminal.
- **The logger replays.** Lines emitted before the framebuffer exists are
  buffered (16 × 128 bytes, static) and drawn by `attach_screen()` when the
  console attaches, so screen and serial agree line-for-line.

Memory, added in Milestone 1:

- **`arch` owns the page table *encoding*; `kernel/mem` owns the *walk*.** This
  is where the "only CPU-facing import" rule landed for paging. `arch` supplies
  `table_index`, `level_size`, `leaf_encode`, `branch_encode`, `entry_flags` and
  friends; `vmm.odin` implements the descend-and-allocate loop once against
  them. The walk genuinely is not amd64-specific — aarch64's stage-1 tables and
  riscv64's Sv39/Sv48 are the same radix tree, nine bits at a stride — so a port
  supplies an encoding rather than a second walker.
- **Bitmap PMM, not a free list.** A free list has to live in the pages it
  tracks, so one stray write corrupts the allocator itself; and contiguous
  multi-page allocation, which page tables and large heap blocks both need, is a
  run search over a bitmap versus a linear walk over a list. The cost is a scan,
  bounded by a rotating hint and by skipping fully-taken bytes eight frames at a
  time.
- **The bitmap indexes from physical zero**, holes included, so `phys /
  PAGE_SIZE` is the index with nothing to subtract. Hole frames are born taken
  and never freed. It is 15 KiB on this machine.
- **Frame 0 is reserved forever.** Base revision 6 lets the firmware call the
  page at physical zero usable. Handing it out costs the one thing that makes a
  null dereference announce itself.
- **Bootloader-reclaimable memory is *not* reclaimed.** It is 39 MiB and worth
  having, but at the end of `mem.init` the kernel is still standing on three
  things inside it: the stack `kmain` is running on, every Limine response, and
  the memory map itself. `pmm_reclaim` is written and ready; it becomes callable
  once the scheduler is on a kernel stack of its own and anything wanted from
  the responses has been copied out.
- **All 256 higher-half top-level entries are pre-populated** at VMM init. A
  kernel mapping made after a user address space is created must appear in that
  address space too, and if the top-level entry did not exist at copy time it
  never will. Costs 1 MiB, paid once; buys never having to propagate a kernel
  mapping by hand. This is most of the "269 tables" in the boot log.
- **The kernel image is mapped a segment at a time**, with the permissions the
  linker script implies — text read-execute, rodata read-only, data read-write
  and no-execute — and `CR0.WP` is set, so they bind on supervisor writes too.
  Verified by reading the entries back out of the live tables, not by trusting
  the code that wrote them.
- **The direct map rounds outward; the PMM rounds inward.** Different jobs: the
  PMM must never hand out a frame that is partly somebody else's, and the direct
  map must never fail to map a page a structure straddles.
- **NX, global pages and 1 GiB leaves are all detected, not assumed.**
  `enable_paging_features` reads CPUID and records what took; `leaf_encode`
  silently drops a bit whose feature is off, so callers can ask unconditionally.
  On `-cpu qemu64` NX and PGE are present and 1 GiB pages are not, hence the
  2 MiB largest leaf in the boot log.
- **The framebuffer is added to the region list by hand if the map omitted it.**
  Base revision 6 guarantees the framebuffer is direct-mapped; it does not
  guarantee the firmware described it as a memory map entry. Getting that wrong
  kills the machine on the first character drawn after the CR3 switch — with the
  console being the thing that would have reported it.
- **Slab classes are 16 B … 2 KiB, powers of two**, one page per slab, free
  objects threaded through their own first eight bytes. Every allocation carries
  a 16-byte header immediately below the returned pointer holding a magic, the
  class (or "large"), the page count and the offset back to the block start.
  That header is what makes `free` a constant-time dispatch with no lookup
  structure, and what makes over-aligned allocation possible at all.
- **`free` checks the magic and clears it.** A pointer that did not come from
  `alloc` is ignored rather than acted on, and a double free fails the check
  instead of putting the same object on a free list twice. Leaking is the
  cheaper outcome.
- **`-default-to-nil-allocator` stays in the build.** `context.allocator` is
  installed at the very end of `kmain`, so an accidental allocation during early
  boot still returns nil and fails at its use, rather than quietly succeeding
  against a heap that does not exist yet.

Traps, added in Milestone 2:

- **Traps come up before the framebuffer**, immediately after the serial port
  and the base revision check. Everything after that point is code that faults
  while it is being written, and a fault before it is a triple fault with
  nothing to show for it. The consequence is that the fault stacks have to be
  static `.bss` arrays rather than PMM pages — which is the right trade, because
  it is memory bring-up above all that this needs to be able to debug.
- **The selector layout is fixed by SYSCALL/SYSRET**, not by taste. `SYSCALL`
  takes CS from `STAR[47:32]` and SS from that plus 8; `SYSRET` to 64-bit code
  takes CS from `STAR[63:48]` plus 16 and SS from plus 8. Hence kernel code then
  kernel data, and user code32 then user data then user code64 — with the
  code32 slot present purely as a placeholder. Renumbering these later does not
  break the build, it breaks the first system call.
- **Three vectors get interrupt stacks of their own**: the double fault (IST1),
  NMI (IST2) and the machine check (IST3). The double fault is the one that
  matters — a fault that happens *because* the stack is bad has nowhere to push
  its frame, and that is a triple fault. Verified by provoking one.
- **All 256 vectors are installed, not just the 32 exceptions.** A stray
  interrupt on a vector with no descriptor is a `#GP`, and a `#GP` with no
  handler is a double fault, so the cheapest way to make a stray interrupt say
  "vector 39 arrived and nobody was expecting it" is to give every vector a stub.
- **The stubs are generated by the assembler, not written out or code-generated
  into a file.** `.rept` emits 256 of them and `.balign 16` makes each exactly
  sixteen bytes whether or not it pushed a dummy error code, so `idt_init` finds
  the nth by multiplying. That alignment is load-bearing: it is what turns a
  table of 256 function pointers into one label and a shift.
- **The legacy PICs are remapped *and* masked** before anything could call
  `sti`. Masking alone is not enough — a spurious IRQ 7 can still get through,
  and unremapped it arrives as a **page fault** with a garbage error code and a
  stale CR2, which the panic screen would then report with total confidence.
- **A trap handler returns a bool: resume, or stop.** The only thing that ever
  resumes today is the breakpoint the boot self-test arms for itself, and that
  narrowness is deliberate — a stray `#BP` from anywhere else still panics.
- **The panic screen's body text is amber, not red.** The alarm is carried by
  the red band, the `[ FAIL ]` tags and the FAULT lamp; the report itself is
  mostly hex that has to be read carefully, and a wall of red is the worst way
  to present it.
- **The panic path reports what was *mapped* at CR2, not just the address.**
  "nothing is mapped there" and "mapped read-only and you wrote to it" are
  different bugs that produce the same CR2, and `mem.permissions` already knew
  how to tell them apart.

Vectra9, added in Milestone 3. The full argument is in `docs/VECTRA9.md`; these
are the load-bearing bits:

- **Nothing is added to the wire.** The version string is `9P2000.L` and a stock
  Linux `v9fs` client must be able to mount a Vectra server. Extensions are
  files, not messages. The payoff is not interoperability for its own sake — it
  is that the protocol stops being a design surface, because the answer to "what
  messages does my subsystem need" is always the same nine.
- **Servers speak decoded messages.** The transport is the only thing that knows
  bytes exist. Rejected alternatives, both defensible: marshal everywhere (one
  code path, but two memcpys and a parse on every read of every file, in a
  system where thread state *is* a file), and a typed device vtable with 9P only
  for remote servers, which is what Plan 9 itself does (faster still, but two
  interfaces to keep in step and a server that cannot move between kernel and
  userland without a rewrite).
- **A decoded message borrows its buffer.** Strings and slices inside a `Msg`
  point into whatever it was decoded from. This is what makes an `Rread` of
  4 KiB free to pass around, and it is the rule most likely to be broken. Odin
  cannot express the lifetime, so it is stated at the top of `proto.odin` and
  nowhere else.
- **`Twalk` bounds names at sixteen, so they live inline.** That is the only
  reason a `Msg` is a stack value; the `#assert` on `size_of(Msg)` is there to
  stop it quietly becoming something else.
- **Codec errors and protocol errors are separate types.** `Error` means the
  bytes are wrong and no reply can be built. `Errno` means the request was
  well-formed and the answer is no. Merging them would let a corrupt message be
  answered as though it had been understood.
- **The codec latches errors; `libodin.Sink` saturates.** Opposite choices, both
  right: a truncated log line beats no log line, and a truncated 9P message is a
  protocol violation the far end would blame on itself.
- **`decode` bounds the cursor by the message's declared size, not the buffer.**
  A body that reads past its own message is then a malformed message rather than
  a short buffer, and every accessor gets that for free. A declared size larger
  than the buffer is refused outright — that is the classic way a codec is
  talked into reading past the end of a packet.
- **Where Plan 9 has an answer, Vectra takes it.** Four questions that were open
  in the first draft of the design are settled in `VECTRA9.md` section 7, each
  against what Plan 9's source actually does rather than what is remembered
  about it: a fid is a number and never a pointer (`Chan.fid` is a `ulong`, and
  the table lookup is what makes a fid a capability); the root is an ordinary
  in-kernel server, as `devroot` is a real device rather than a special case in
  `namec`; `Tflush` needs a tag-indexed pool of in-flight requests and `Rflush`
  is the barrier, which is what `mountio` and lib9p between them implement; and
  a union `create` goes to the first `Create`-flagged member and **does not fall
  through** if it fails, exactly as `createdir` refuses to.
- **`Encoded_Loopback` is a test instrument that is also the skeleton of a real
  transport.** It does every step a pipe transport would except crossing an
  address space, so writing that transport is replacing two copies with reads
  and writes — and meanwhile it is how the boot self-test proves a handler
  cannot tell which transport it is behind.

## 6. Known warts

- **The trap stub saves general-purpose registers only.** No `FXSAVE`, so a
  handler that *returns* into code with live SSE state would corrupt it. Panics
  never return, and the only resuming path today is a breakpoint the kernel
  raised on itself, so this is fine now and is the first thing that has to grow
  the day anything resumes arbitrary code — a debugger, or a page fault that
  fixes up and retries.
- **No `swapgs` in the entry path.** Correct today, because nothing runs at
  CPL 3. It becomes wrong the moment userland does, and the fix has to land in
  the same tail that the point above rewrites.
- **The panic screen has no backtrace.** It reports the faulting instruction and
  the register state but cannot walk the stack; that needs frame pointers kept
  deliberately or unwind tables retained. It is the largest single thing missing
  from an otherwise complete fault report.
- **Nothing uses Vectra9 yet.** The codec is verified but no server implements
  a handler and no client holds a session, so the layer has only ever talked to
  itself. The first real server will find things the self-test cannot.
- **`Session.alloc_fid` is a monotonic counter.** It runs out after four billion
  opens without ever reusing one. The right fix is a free list fed by `Tclunk`,
  not a wider counter.
- **The transport is synchronous.** `Transport.call` returns with the reply
  filled in, so a client can never have two requests outstanding — which makes
  tags decorative and `Tflush` unreachable. Both become real with the scheduler,
  and that is when the async entry point has to be designed.
- **No locking anywhere in `kernel/mem`.** Single CPU, single thread, and now —
  since the IDT exists — interrupts that are still never enabled. The PMM's
  bitmap and the heap's free lists both need a lock before the first AP comes up
  or the first interrupt handler allocates.
- **Slabs are never returned to the PMM.** Reclaiming one means proving every
  object in it is free, which means per-slab occupancy counts and a
  partial/full/empty chain per class. The fix belongs in `slab_grow`/`slab_free`,
  not in the callers.
- **`map_at` refuses to map over an existing mapping** rather than splitting a
  large page. Nothing yet needs to, and making it an error means that when
  something does, it says so instead of silently doing the wrong half of it.
- **The framebuffer is mapped write-back, not write-combining.** That needs PAT
  setup. It will matter to the compositor and does not matter yet.
- **1 MiB goes to higher-half page tables** at boot, most of it never touched.
  Deliberate — see section 5 — but it is the largest single line item in the
  kernel's own footprint.
- **OVMF is borrowed from `../odin-os/ovmf/ovmf_x64.fd`.** `build.odin` hard-codes
  that path and dies if it is missing. Vectra should vendor its own firmware, and
  will need `AAVMF`/`RISCV_VIRT` equivalents before the other arches can boot.
- **QEMU's vvfat is read-write, so OVMF writes `NvVars` into `build/esp/`.**
  Harmless, but it means the staged ESP is not byte-reproducible.
- **`arm64` and `riscv64` are stubs, and are falling further behind.**
  `build.odin` has their rows filled in and the vendored bootloaders are
  present, but there are no `link_arm64.ld` / `link_riscv64.ld` scripts, and
  `arch_amd64.odin` has now grown both the paging interface *and* the trap
  interface that the other two do not declare.
- **Memory-map entry count varies run to run** (27, 31, 33) with OVMF/vvfat. Not
  a bug; do not chase it.

## 7. Where to go next

The scheduler was the thing blocking everything else, and the namespace it
exposed is now locked. What is left divides cleanly into "needs a sleeping lock"
and "needs userland".

**A sleeping lock is the next structural piece, and two things now want it.**
`Server.lock` is held across a whole 9P message, which is correct and also the
reason no transport can block yet: the reply to an out-of-process request
arrives on an interrupt, and the lock that is waiting for it has interrupts
masked. The first transport that crosses an address space and a sleeping lock
arrive together or neither does. Plan 9's union walk wants the same thing for a
different reason — `Mount_Point.generation` exists because a read lock could not
be held across the search.

**Then, in roughly this order:**

1. **A sleep queue and timed waits.** `block` and `ready` are the only blocking
   primitives, so nothing can wait for a duration or for a device. A tick-keyed
   list on `Cpu`, drained by `on_tick`, is most of it — and it is what a
   sleeping lock is built out of.
2. **`Tflush`.** Section 7.3 of `VECTRA9.md` pins the shape and the scheduler
   it was waiting for now exists: a tag-indexed pool of in-flight requests,
   `Rflush` after the original's fate is decided, never an error reply.
3. **A first real device server.** `devfs` with `/dev/cons` over the console
   driver, which makes the whole path from a name to a byte on screen exist end
   to end. `static.odin` is the wrong shape only because it is read-only.
4. **`/srv`**, which needs a thread on each side of a transport and therefore
   needed the scheduler.
5. **Userland.** A thread grows an `^Address_Space`, `reschedule` grows one
   comparison, and the GDT already has the selectors laid out for
   SYSCALL/SYSRET. `swapgs` and per-CPU state behind GS belong to this step and
   are cheaper to build with it than after it.

**SMP, when it is wanted.** The shapes are already right: `Cpu` is per-core,
`Resume` is per-thread and lives on that thread's stack, and every mount-table,
namespace and heap mutation is inside a `sync.Spinlock`. What is missing is a
lock word in that struct, an AP trampoline, IPIs, and a placement policy for
`enqueue` — which is where `eligible` and the class/capacity fields stop being
inert. Two things become urgent the moment a second core runs: `Chan.refs` and
`Mount_Point.refs` want atomic increments rather than a global lock, and
`vfs.lock_depth` has to become per-CPU state. Both are named where they live.

**Smaller things worth doing when convenient:**

- A stack backtrace on the panic screen. Everything else a fault report wants to
  say is already there.
- Make `check_base_revision()` a hard stop rather than a warning.
- A free list for fids. `alloc_fid` is monotonic and therefore finite: four
  billion opens per session, never reused.
- `reap` only runs from `spawn` and from the self-test, so a dead thread's stack
  comes back at the next spawn rather than when it exits. Fine now; an idle-time
  reaper is the fix. The vfs concurrency test has to call `sched.reap()` by hand
  before it measures the heap, which is the smell.
- `readdir` over a union is still index-based and still documented as undefined
  if the union is rebound mid-listing — the cookie names a position in a list
  that moved. `walk` no longer has that property (see `Mount_Point.generation`);
  a listing could get the same treatment if it ever matters.
- Teach `arch_arm64.odin` / `arch_riscv64.odin` the paging, trap and scheduling
  interfaces. `cpu_class` is the one that pays off immediately — a big.LITTLE
  part reporting three classes makes the capacity arithmetic do real work.

## 8. File map

```
build.odin              Build driver: compile, link, stage ESP, run QEMU
justfile / Makefile     Thin wrappers over build.odin
boot/
  limine.conf           Limine config (new-style), staged to /EFI/BOOT/
  limine/               Vendored Limine 12.6.1 UEFI binaries + VERSION + README
kernel/
  main.odin             kmain, Limine requests, boot survey, memory bring-up
  verify_vfs.odin       The namespace under five threads: 33 checks, two servers
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
    lock.odin           What guards what, in what order, and the borrow rule
    vfs.odin            Server, the #name device table, the guarded RPC pair
    chan.odin           Chan, refcounting, open/read/write/stat/clone
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
    sched.odin          init, spawn, block/ready, reschedule, the tick
    verify.odin         The boot self-test: cooperative half and preemptive half
  sync/spin.odin        The one lock type: the interrupt flag, nesting handled
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
tools/genfont.py        TTF -> font_data.odin
docs/
  HANDOFF.md            This file
  VECTRA9.md            The protocol and namespace design -- sections 1-4 are
                        sys/vectra9/, section 5 is kernel/vfs/, section 7 is
                        why four arguments are over
  milestone0-boot.png   Milestone 0 screenshot -- it boots
  milestone1-memory.png Milestone 1 screenshot -- PMM, VMM, heap
  panic-screen.png      Milestone 2 screenshot -- a deliberate #PF, reported
```
