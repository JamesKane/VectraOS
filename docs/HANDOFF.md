# Vectra — session handoff

Read this first when you pick the project up in a new session. It records what
the code cannot tell you on its own. That is where things stand, how to build
and run it, what the toolchain costs, and what to do next.

**It does not explain any subsystem.** The reasoning behind each one lives in
its own document, beside the code. Section 3 is the index, and a claim made
here that wants a *why* is a pointer to one of them.

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

Layout — `kernel/` (arch, mem, sched, vfs, drivers), `sys/` (libodin, libuser,
libdraw, vectra9), `servers/` (ramfs, consrv, kbdfs, eiafs, intuition), `apps/`
(terminal). Primary arch `x86_64` via Limine, with stubs for `aarch64` and
`riscv64`.

About 50,700 lines of Odin. The linked kernel is ~1.6 MB debug, and the six
embedded user images are ~300 KB.

## 2. Where things stand

The machine boots and brings up memory, a namespace, a scheduler and a
preempting timer. It publishes `#c` at `/dev`, `#s` at `/srv` and `#b` at
`/bin`. It then runs about 1540 checks against itself and idles.

**What it can do**, and which document says why:

| | What works | Read |
|---|---|---|
| The wire | 9P2000.L, in-process and over bytes, several requests in flight, `Tflush` | `VECTRA9.md`, `TRANSPORT.md` |
| The namespace | bind/mount with before/after/replace, unions, a private table per process | `NAMESPACE.md` |
| The console | `/dev/cons` is a real terminal: a line typed at the keyboard or the serial port is edited, echoed, and handed to a parked reader | `DEVFS.md` |
| The hardware | every device behind `#c` is a file — `/dev/fb` the screen's memory, `/dev/scancode` the untranslated keyboard, `/dev/eia0` the port. A raw stream is *diverted* while held, and given back on the last close | `DEVFS.md` |
| Services | `/srv` names a running service, mountable anywhere in a namespace, postable from ring 3, and its connection comes down when the last mount and the name are both gone | `SRV.md`, `PIPE.md` |
| Processes | ring 3, a namespace and a descriptor group of its own, `spawn`, `rfork` by Plan 9's flag word, `exec` in place, notes a handler catches, `segalloc` for memory no file serves | `USER.md` |
| Ring 3 servers | five of them, on a runtime with a serve loop, a concurrent one with a worker per parked request, and the tree's first ring 3 lock | `RUNTIME.md` |
| The screen | a draw server with six verbs, a window per session with pixels of its own, a compositor, a desktop, window chrome, four `ctl` lines, and a `cons` and `consctl` per window with a line discipline of its own | `DRAW.md` |
| Typing | one discipline (`sys/libedit`) worn by the server that cooks a window's lines and by the program that draws them and echoes, with a cursor the arrow keys and `^A`/`^E` move | `DRAW.md` |
| Runes | a key with no character arrives as Plan 9's private-space rune in UTF-8 (`sys/libkey` names them, `core:unicode/utf8` encodes them) through a `/dev/cons` that stayed bytes | `DRAW.md`, `KBD.md` |

**The screen is the part with the most recent work in it.**
`servers/intuition` holds `/dev/fb` and maps it with `segattach`. It owns every
pixel while it does, so the console draws into a shadow copy and blits that back
on the last close.

Each window is a run of anonymous memory from `segalloc`. A draw is therefore a
store, and `flush` is the damage mark that walks it onto the glass. Windows
overlap, and stacking order is a list of its own. A window that closes gives
back what it covered out of the store below, which is why there is no expose
event.

A window is a raised plinth with a sunken screen in it. The chrome vocabulary
is `sys/libdraw` and the palette is `sys/libpal`, and ring 0 and ring 3 both
read them. `move`, `size`, `raise` and `name` are `ctl` lines rather than verbs.
The window in front wears the lit copper.

**And the keyboard reaches the window in front.** A window serves a `cons`. A
client binds its own window's directory over `/dev` before everything else, so
it opens plain `/dev/cons` and gets the window's. That is `rio`'s
`filsysmount`, one bind shorter.

It is also why the draw server does not touch `/dev/scancode`. `rio` reads a
cooked keyboard too, and the translation belongs to `servers/kbdfs`, one
process further out.

**And each window cooks its own lines.** The draw server writes `rawon` and
takes the characters. So the erase keys and the line under construction belong
to a window rather than to the machine. `^W` is there, which `/dev/cons` still
does not have. A window has a `consctl` of its own for the raw mode a client
may want instead.

**And the window that draws is the one that echoes.** `apps/terminal` takes its
own window raw and cooks the line itself, because a person has to see the
characters as they arrive and only the half that owns the pixels can show them.
That is every Plan 9 program that draws its own text -- `vt`, `con`, `ssh`,
`sam` all write `rawon` -- and it is why there is no read anywhere that answers
a line which is not finished. `sys/libedit` is the one set of rules both halves
wear.

`docs/DRAW.md` owns all of it, section by section, with the controls each claim
was measured against.

**The order these arrived in matters in exactly one way**, and it is worth
knowing before reading any document. Each one unblocked the next, and none of
them could have come earlier:

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
    an rfork                and one process can become two -- so a server can
                            wait on two things at once
    a raw device            and the hardware itself is a file: the screen at an
                            offset a process may seek
    a tap                   and a stream is owned rather than copied: whoever
                            holds the file stands where the kernel stood
    a release               and what a posting built comes down whole
    a note handler          and a note is a signal rather than a kill
    an exec                 and a process becomes another program in place
    a serve mux             and a userland server answers concurrently
    a kbdfs, an eiafs       and a kernel driver runs as a program, both ways
    a draw server           and the screen speaks in verbs, checked on the glass
    a terminal              and a program consumes two services at once
    segalloc                and a program holds memory no file serves
    a compositor            and a window's pixels are its own, and survive
                            being covered
    a window's cons         and the keyboard reaches the window in front,
                            through a namespace rather than a protocol
    a line per window       and the editing belongs to a window rather than
                            to the machine, so a moving focus cannot steal
                            half a line
    an echo                 and the half that draws is the half that holds
                            the line, which is the only arrangement that can
                            show a character before it is a line
    a cursor                and a character goes in where it is rather than
                            at the end, with a caret under it saying where
    a rune                  and a key with no character can arrive at all,
                            which is what the arrow keys were waiting for
    an unmap                and a page can stop being reachable, so a run can
                            change size and a window grow past its birth

### Reading a boot log

`just run` prints one `[ ok ]` line per subsystem, each a self-test on the
machine that will run it. `docs/TESTING.md` is the discipline behind them.
Three things about a boot are worth knowing before you read one:

- **Some numbers move on every run, and that is the design.** The LAPIC
  calibration, the preemption round counts, the lock acquisitions, and the
  operation count under a fixed tick budget are measured rather than asserted.
  `just release` does the same thousand ticks of work and reports about fifty
  thousand operations. `docs/TESTING.md` says why measuring in ticks is the
  right way round.
- **`9p ... payload checks` reports readers spoiled by a shared buffer, and
  that is a pass.** It is a control that runs every boot: the wrong arrangement
  is still expressible, and a failure to corrupt would be the failure.
- **Untagged lines are output, not status.** They are the self-tests writing
  through the paths they are testing — a line to `/dev/cons`, a line a ring 3
  program printed, bytes that went out the wire. The console echo leaves an
  erase sequence after one of them that a terminal consumes and a file capture
  keeps.

### What does not exist

The one that shapes everything after it:

- **No SMP.** `Cpu` is per-core and `MAX_CPUS` is 8, but only core 0 ever
  starts. There is no IPI, no AP trampoline and no lock word. Section 6 has
  what it would take.

And the rest, each named in the code it is missing from. **Something that
exists and is merely incomplete is not here.** Section 6 has those, because a
gap with a design question attached is work rather than orientation.

- **No group fan-out for notes.** `notify` registers a handler and `noted`
  resumes or dies, so a note is a signal. `Process.note_group` inherits and
  nothing posts to a group, which is Plan 9's `postnote` to a group rather than
  to a pid. `RFNOTEG` is recorded and inert for the same reason, and it is the
  one flag in `rfork`'s word that is. No FPU state crosses a delivery.
- **No flush that reaches a worker.** `serve_mux` forks a worker per parked
  read, and a `Tflush` cancels the request on the wire but not the worker. It
  has teeth now, and `docs/DRAW.md` section 13 has the boot that found them.
  A read with a deadline abandons a worker per attempt, and abandoned ones
  accumulate until the pool is spent. A flushed worker also still replies,
  carrying the flushed tag, which the wire drops and counts. A client that
  reused that tag first would not. The cancel belongs in `sys/libuser`.
- **No allocator in ring 3**, and no way for one process to wait on two
  descriptors — it forks instead, which is Plan 9's answer.
- **No ACPI.** The I/O APIC's address and the ISA-to-GSI mapping are assumed
  rather than read from a MADT. Both are right on every PC and neither is
  discovered.
- **No interrupt on the serial line.** `devfs.cons_input` polls it once a tick,
  and the keyboard shows the shape a replacement takes.
- **No condition variable as such**, because `sync.Rendez` is one. Do not go
  looking for a second thing.
- **No halt.** `kmain` ends with `sched.exit`, so the machine idles.

**A note still lands with bounded lag** rather than instantly. A loop or a
parked sleep costs a tick, and a read waiting on a device costs up to
`NOTE_POLL` ticks. A *faulting* process holds its descriptors until `destroy`
collects it.

### Three decisions that shape everything downstream

All three are argued in `docs/VECTRA9.md`, which is the thing to read before
touching the protocol or the namespace.

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

This file is orientation, and it explains nothing. Everything that says *why* a
subsystem is the shape it is lives beside the code it describes, one document
per directory:

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
| `docs/DEVFS.md` | `kernel/devfs/` — `#c` at `/dev`, the console device, the line discipline, the `ctl` convention, the raw framebuffer and the screen's divert | Adding a device file, adding a `ctl` file, writing a server whose reads park, wondering why `/dev/cons` has two locks, or asking who owns the glass |
| `docs/SRV.md` | `kernel/srv/` — `#s` at `/srv`, posting, the id that is not a slot | Publishing a service, mounting one by name, or writing a directory that changes |
| `docs/DRAW.md` | The draw protocol, written before its code, and everything the screen grew after it: the window, the compositor, the chrome vocabulary and the one palette (`sys/libdraw`, `sys/libpal`) | Building the draw server, its client library, the fb mapping, or anything that draws in either ring |
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
just debug        # boot halted; `just gdb` in another shell (no gdb here: see below)
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

**There is no gdb on this machine, and lldb attaches fine.** `lldb
build/vectra.elf -o 'gdb-remote localhost:1234'` reaches a `just debug` boot
with symbols and line numbers. QEMU's `-s` flag opens the same stub without
halting, so a boot loop can run with it open and leave a wedged machine
standing to be read. `docs/TESTING.md` describes reading one.

**The explicit `-out:` is mandatory.** Without it `odin run` names the driver
binary after the script and drops `./build` directly on top of the `build/`
output directory. This bit once already.

Verified toolchain on this machine: Odin `dev-2026-09:a2fb372b7`, clang and
LLD 21.0.0 (both from `~/.swiftly/bin`), QEMU 11.1.0.

**clang is new and required.** It assembles the five `.S` files the kernel
links. It has to target `x86_64-unknown-elf`, which the Swift toolchain's
does.

Homebrew moved Odin from `dev-2026-08` to `dev-2026-09` under a running
session on 2 September 2026. The two constraints below about inline assembly
are what that cost. No `just` installed — use `make`. No
`xorriso`, no loop devices, no `sudo` required. Pillow is **not** currently
installed, so `make font` will not run until it is. The two generated font
files are checked in, and nothing else needs Python.

**UEFI firmware is the neighbouring `odin-os` checkout's `ovmf_x64.fd` when
it is there, and it is there again as of September 2026.** `run_qemu` looks
for that combined image first. Failing that, it loads the
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
| Inline `asm` is a template, checked against encoding tables | Since Odin `dev-2026-09` an `asm` block is `asm(params) -> (results) [bindings] { instructions }`: Intel operand order, `%reg` for a physical register, `[base + disp]:T` for memory, labels local to the block. The compiler type-checks every instruction, and refuses a block that reads an input no instruction names or leaves an output unwritten. Three consequences are written where they bite. `in`, `out`, `hlt` and `syscall` are `#byte` sequences, because the assembler has no operand form for the first two and models the last two as never falling through. An input a byte sequence consumes is tied to a dropped output, which is the one use that costs no instruction. And anything that defines a symbol, needs its own label's address, or is entered by the CPU is a `.S` file, not a block. |
| The stubs, the FPU hold and the program blobs are `.S` files clang assembles | `arch/amd64/isr.S`, `syscall_entry.S`, `gdt.S`, `fpu_hold.S` and `user/programs_amd64.S` keep the AT&T text the blocks had, with a single `$` for an immediate now that no template substitutes operands. `build.odin` assembles each with `clang -target x86_64-unknown-elf -c` and links the objects beside `vectra.o`. The list is a row of the per-arch table. A `.globl` there is a `foreign` declaration in Odin, unchanged. A template's label reaches LLVM without its colon in this compiler, so a loop in a template assembles to nothing: that is why the FPU hold is a file. |
| The error-code vector list is written twice | Once as an assembler `.if` in `isr.S` and once as `vector_has_error_code` in `idt.odin`. They cannot share a definition — one is consumed at build time, the other at run time — and if they disagree every field in `Trap_Frame` reads as the one next door. `idt.odin` says so beside the Odin half. |
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

**This section is only forward.** What was built and why is in section 2 and in
the documents it points at.

**Next, in order:**

1. **A MADT parse.** It retires both of the I/O APIC's assumptions, and the
   same table lists the cores SMP will need to start. Worth doing when one of
   those two becomes a reason rather than a tidiness.

2. **A union listing whose cookie is not a position.** One `readdir` call
   holds the mount head for reading now, so the list holds still inside a
   call. Between two calls the cookie still names a position in a list a
   `bind` may have moved. `kernel/srv` is the worked example of the fix. See
   the standing gap below.

**Deferred, with the reason written down: `segfree`.** The last of Plan 9's
three segment calls frees the pages under a range and keeps the segment. The
pages read as zero on the next touch, which is demand paging. Vectra zeroes
at the call, and a run is a short list of contiguous pieces. A fault in a
program ends the program, which `docs/USER.md` argues at length.

A hole a touch refills changes the fault rule and the run's shape. A hole a
touch faults on is a contract nothing wants. Nothing calls it, on Plan 9 or
here, and `segbrk` and `segdetach` cover every give-back a caller today can
act on. So it waits for a caller that needs the pages back and the addresses
kept.

**Deferred, with the reason written down: a font with more than 128 glyphs.**
`sys/libedit` drops every rune it does not act on, because `sys/libfont` is an
8x16 table of 7-bit characters. This file used to say the fix was "a wider
table", and that is not Plan 9's shape: a `.font` there is a text file of rune
ranges pointing at separate subfont files, loaded lazily and LRU-cached. The
real work is a file format, a loader, and the first data this system reads at
runtime rather than bakes into its image. Nothing in the tree needs a
non-ASCII glyph yet, so it waits for something that does.

**One uncaught mutation is now reachable.** `docs/DRAW.md` section 8 records
that `rfork` copying a device segment is inert, because nothing forks a process
that holds one. The compositor is the process that would, and a worker per
window is the shape that would make it fork. It also pays 4 MB per window at
that moment, because `fork_segments` copies a run eagerly where Plan 9 copies
on write.

### Standing gaps

Each of these exists and is incomplete, rather than absent, and each is named
in the code it lives in. What makes them work rather than orientation is the
design question attached to each.

- ~~**A read/write sleeping lock.**~~ Retired. `kernel/sync/rwlock.odin` is
  Plan 9's `RWlock` rule for rule, served in arrival order, and
  `Namespace.lock` and `Mount_Point.lock` are it, taken where `chan.c` takes
  `pg->ns` and `Mhead.lock`. A union search holds the mount head for reading
  across its messages, a `bind` waits for it, and `Mount_Point.generation` is
  gone. The design questions had Plan 9's answers: arrival order, and yes, a
  waiting writer blocks an arriving reader. See `docs/SYNC.md`.
- **Priority inheritance.** A lock or a rendezvous goes to the best *waiter*,
  but a low-priority *holder* still delays a high-priority waiter for as long
  as it holds. It has not bitten, because nothing runs at realtime. Plan 9
  never had it either, which is an argument about cost rather than about
  correctness.
- **A worker per blocked request.** `devfs` holds a worker for the length of
  every parked read, so at most three reads of `/dev/cons` may park at once. A
  fourth stalls the connection until a byte arrives. Plan 9 gives every request
  a thread. See `docs/DEVFS.md`.
- **A union listing whose cookie is not a position.** `readdir` over a union is
  index-based, and documented as undefined if something rebinds part-way
  through. `kernel/srv` is the worked example of the fix: a monotonic id, and a
  cookie that means `resume after this one` however the table moved. See
  `docs/SRV.md`.
- ~~**An interrupt context `sync.can_sleep` knows about.**~~ Retired. The trap
  dispatcher brackets every top half with an interrupt-depth counter, `arch`
  exposes it as `in_interrupt`, and `can_sleep` reads both it and the spinlock
  count. A park in an interrupt handler is a named stop now, not a silent hang.
  `kernel/verify_sync.odin` raises a probe interrupt and checks `can_sleep` is
  false on its stack. See `docs/SYNC.md`.
- ~~**A process that cannot be stopped from outside.**~~ Retired. `user.end`
  sets Plan 9's `procctl` word on the process and wakes it. The door and the
  tick both read the word before any handler, so the process ends at its
  next boundary whatever it registered. `user.stop` is that and the
  collection. `destroy` still refuses a running process, and rightly. See
  `docs/USER.md`.
- ~~**A flaky heap check in the draw server's teardown.**~~ Retired. The
  `leaked 1` was a `Mount_Point` from a dead process's namespace, and the
  draw server's teardown was only where timing first put it. `unload` took a
  process's descriptor table with a test-then-release while the reaper thread
  took it with an exchange, so a process that faulted or was noted could have
  its table released twice: the second release, running after the first had
  given the pool slot back, closed the chans of whichever process had been
  handed that slot since. `unload` now takes the table with the same
  exchange. Found by looping the boot under host load with a per-procedure
  heap reading, which is the shape of hunt `docs/TESTING.md` argues for; the
  race took one boot in forty here, and hung the machine outright when its
  window was widened on purpose. `heap_stats` also reads under the heap lock
  now, because a snapshot taken class by class with interrupts on could
  report a heap that never existed.
- ~~**A boot that stops in the draw server's tests, one in thirty or so.**~~
  Retired. The wire's reader thread parked for ever on a pipe the counted
  release had already zeroed. `wire_release` cleared the pipe's pin before
  closing the posted end, so when the far process was already gone that
  close was the last one and reclaimed the slot -- after waking the reader,
  but before the reader ran to re-read the flag the wake was about. It
  parked again on a pipe that looked open, and the test's `unmount_path`
  parked in `wire_join` behind it. The pin now outlives the close, and
  `unpin` reclaims after the join, when nothing parked is left to wake. See
  `docs/PIPE.md`. Found by looping the boot under host load with QEMU's gdb
  stub open, then walking every kernel thread's saved trap frame from lldb
  once a boot wedged; `docs/TESTING.md` describes the walk. The wire
  self-test had the same shape and parked its scripted server's thread on
  every boot, unreported; `wire_down` joins before its last close now.
- ~~**Three more parks with no bound, of the shape above, found by review
  and not yet reproduced.**~~ Retired. `kernel/verify_wire.odin`'s posted
  scenes reach all three from a scripted far side. Two were real and are
  fixed. `remove` closes its own chan before it drops the name's stake, and
  `wire_flush` waits with a bound and poisons the wire when it runs out. The
  third was a review false alarm, and the scene says so.

  `srv.mount` also answers `ENXIO` for a pipe end with no wire now, which
  the document claimed and the pipe device never did. See `docs/PIPE.md`.
- ~~**The reaper's test-then-exchange.**~~ Retired. The pid is the
  generation. Every collector names the process it saw. `collect` reads the
  pid again after its claim, and gives back a claim on a slot that changed
  tenants. `hangup_dead` puts a table it took from a newborn
  straight back. On one core nothing runs between the two exchanges, which is the
  sentence a second core retires. See `docs/USER.md`.
- ~~**A system call with `IF` still set for four instructions.**~~ Retired.
  `arch.syscall_masks_interrupts` reads `SFMASK` and confirms `IF` is one of
  the bits it clears, and the syscall self-test checks it. The control that removed `IF` from `SFMASK` fails the check, and on one boot
  it doubled into a `#DF`, the bug the check guards against. See
  `docs/TESTING.md`.
- ~~**A killed process holds its descriptors until something reaps it.**~~
  Retired. A reaper thread parked on `exit_rendez` releases the descriptor
  group of anything whose thread has gone, so a faulted server hangs up and the
  client parked on it is answered. The record stays for a parent's `wait`,
  which is Plan 9's `pexit`. See `docs/USER.md`.
- **The address bump never comes down.** `segbrk` and `segdetach` are built,
  so a run can change size and go back whole. A detached run's addresses are
  never handed out again, because `Process.map_next` is a bump rather than a
  search. That is address space rather than memory, and the cheaper of the
  two to leak. `segfree` is deferred above, with its reason.
- **A free list for fids and `/srv` ids.** Both counters are monotonic and
  therefore finite: four billion opens per session, two billion posts. Pids left this list. They are 64-bit, never reused on purpose, and
  now the generation every collector checks against, so a reset is exactly
  what they must never get.

### SMP, when it is wanted

The shapes are already right. `Cpu` is per-core, `Resume` is per-thread and
lives on that thread's stack, and every mount-table, namespace and heap
mutation is inside a `sync.Spinlock`.

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

### Smaller things worth doing when convenient

- ~~A stack backtrace on the panic screen.~~ Retired. The kernel keeps no
  frame pointer, so there is no `rbp` chain to follow. The panic screen scans
  the stack for values in the kernel's own text and prints them as probable
  return addresses, each line marked `maybe`. `kernel/verify_sync.odin` scans
  the live stack from a chain of calls and checks it finds them, because the
  display itself only shows on a real fault. See `kernel/panic.odin`.
- Make `check_base_revision()` a hard stop rather than a warning.
- `servers/kbdfs` has its own copy of the scancode translation and it answers
  bytes, so the arrow keys reach `/dev/cons` and not `/kbd`. Nothing consumes
  `/kbd` for them yet, which is why this is a note rather than an item.
- ~~An idle-time reaper for *threads*.~~ Retired. The idle thread reaps, so a
  dead thread's stack comes back within a tick of its exit with nothing
  spawning. The self-tests still call `sched.reap()` by hand before a heap
  reading, on purpose. A bracket that depends on the idle thread's turn is
  not a bracket. `kernel/sched/verify.odin` says so beside the check.
- Teach `arch_arm64.odin` / `arch_riscv64.odin` the paging, trap and scheduling
  interfaces. `cpu_class` is the one that pays off immediately — a big.LITTLE
  part reporting three classes makes the capacity arithmetic do real work.

## 7. File map

One line per file, and only what the name does not say. The `docs/` tree is
section 3's table and is not repeated here.

```
build.odin              Build driver: user programs, kernel, ESP, QEMU, and
                        the ELF-to-VECTRA02 converter
justfile / Makefile     Thin wrappers over build.odin
boot/
  limine.conf           Limine config, staged to /EFI/BOOT/
  limine/               Vendored Limine 12.6.1 UEFI binaries
kernel/
  main.odin             kmain, Limine requests, boot survey, memory bring-up
  splash.odin           Boot chassis: plinth, copper bar, well, lamps
  log.odin              Kernel log; serial + screen, with early-line replay
  panic.odin            The panic screen, and the trap handler behind it
  link_amd64.ld         Static-PIE layout; orders .limine_requests, exports
                        the __text/__rodata/__data segment bounds
  verify_sync.odin      The sleeping lock on its own terms
  verify_rendez.odin    The sleep queue: the clock, the park, the condition
  verify_flush.odin     Tflush against a server that will not finish -- the
                        stubborn one is the test
  verify_payload.odin   A payload buffer per request slot, with a shared-buffer
                        control that has to corrupt
  verify_vfs_mnt.odin   The namespace over a transport with workers
  verify_vfs.odin       The namespace under five threads, two servers
  verify_space.odin     Address spaces: one address, two meanings
  verify_wire.odin      The wire against a scripted server across a real pipe:
                        out-of-order replies, a stale reply, a poisoning
  arch/
    arch_amd64.odin     The architecture interface, bound to amd64
    arch_arm64.odin     Stub
    arch_riscv64.odin   Stub
    amd64/cpu.odin      Port I/O, control regs, MSRs, CPUID, EFER, SSE
    amd64/paging.odin   Page table format: entry bits, encode/decode, TLB
    amd64/gdt.odin      GDT, TSS, and the interrupt stack table
    amd64/idt.odin      IDT, the 256 entry stubs, dispatch, fault reporting
    amd64/pic.odin      Legacy 8259s: remapped clear of the exceptions, masked
    amd64/ioapic.odin   The register window, and one redirection entry per line
    amd64/lapic.odin    Local APIC, the timer that preempts, EOI
    amd64/pit.odin      Channel 2 as a ruler, to measure the LAPIC against
    amd64/context.odin  A new thread's first saved state, and a core's class
    amd64/percpu.odin   What one core keeps behind GS, and the two MSRs
    amd64/syscall.odin  SYSCALL/SYSRET: the four registers that arm them, and
                        the naked stub that finds a stack with nothing to trust
  boot/limine/          Protocol bindings, base revision tag, request delimiters
  drivers/
    uart/uart.odin      16550 serial, polled
    fb/fb.odin          Surface, clipping, gradients, brushed fill, and the
                        painter that walks libdraw's chrome onto a surface
    fb/palette.odin     The kernel's aliases for sys/libpal
    console/            Framebuffer text console, drawing from sys/libfont
    kbd/kbd.odin        PS/2 scancodes: the top half that may not park, the
                        ring, the bottom half that may, and the raw hook with
                        first refusal
    kbd/verify.odin     The state machine, the raw hook's stale-shift arc, and
                        one interrupt the 8042 was asked to raise
  mem/
    mem.odin            Region/Boot_Memory types, HHDM, alignment, mem.init
    pmm.odin            Bitmap physical page allocator, and the zeroed run an
                        anonymous segment is cut from
    vmm.odin            Page table walk, kernel address space, translate
    heap.odin           Slab allocator + Odin's context.allocator
    space.odin          One page table tree per process, and the kernel half
                        every one of them shares
  vfs/
    lock.odin           What guards what, in what order, and the lock that went
    vfs.odin            Server on either transport, the #name device table,
                        rpc, and the counted release a server can carry
    chan.odin           Chan and its refcounting, the file operations, a read
                        with a deadline
    mount.odin          The mount table, bind/unmount, union member lists
    namespace.odin      Namespace, rfork semantics, teardown
    walk.odin           attach, walk1, cross_mounts, `..`, resolve, open_path
    readdir.odin        Union directory reads, and the member-index cookie
                        kernel/srv shows how to retire
    fidtab.odin         The fid table every server here uses, and no lock
    static.odin         A read-only server over a node table
    root.odin           `#/`, an instance of it, and the boot namespace
    verify.odin         Two real servers, and a union over them
  sched/
    thread.odin         Thread, Cpu, priorities, decay and boost, slice scaling
    queue.odin          Per-level FIFOs and the pick
    sched.odin          init, spawn, block/ready/unpark, reschedule, and the
                        tick that also drains sync's deadlines
    verify.odin         A cooperative half and a preemptive half
  sync/
    spin.odin           The lock that masks: the interrupt flag, nesting handled
    wait.odin           Wait queues, scheduler hooks, priority-ordered service
    sleep.odin          The lock that parks: Mutex, handoff rather than retry
    rendez.odin         Waiting for a condition, with or without a deadline
  mnt/
    mnt.odin            A 9P connection with several requests in flight: the
                        tag pool, the payload buffer per slot, the work queue
    serve.odin          The workers, and where Rflush's ordering rule lives
    wire.odin           The same client over bytes: frames down a Wire_IO,
                        replies matched by tag, and the poison for a server
                        that breaks framing
  pipe/
    pipe.odin           Two ends, a byte ring per direction, and the ends as
                        chans that park
    serve9.odin         A posted end turned into a mountable server: the wire
                        build, the handshake deadline, the pin, and the
                        counted release that gives all of it back
    verify.odin         Bytes across, a reader and a writer parked and woken,
                        EOF and EPIPE out the right sides
  devfs/
    devfs.odin          `#c` at /dev: the node table, the handler, the abort
                        hook, /dev/consctl, and the worker count that bounds
                        parked readers
    cons.odin           The console device: two sinks out, a line discipline
                        and a ring in, and two locks of different kinds
    fbdev.odin          /dev/fb as the screen's memory at an offset, /dev/fbctl
                        as its geometry, and the shadow surface the console
                        draws into while something else holds the glass
    tap.odin            /dev/scancode and /dev/eia0: each owns its stream while
                        held open, and gives it back on the last close
    verify.odin         The real /dev: a read that parks through a character, a
                        line edited, a mode that reverts with its file, pixels
                        read off the screen, and each stream diverted and
                        given back
  srv/
    srv.odin            `#s` at /srv: the table, post and remove, mounting by
                        name, the id a fid binds instead of a slot, and the
                        name's stake a removal releases
    verify.odin         Published, mounted, removed under its own mount, and a
                        listing paced across a removal
  user/
    user.odin           A process: a space, segments, a namespace forked from
                        the kernel's, a descriptor group, and the fault handler
                        that ends one rather than the machine
    segment.odin        The frames behind one mapping, refcounted, in two
                        shapes: a frame list, and a base with an extent
    fdtable.odin        The fd table as a refcounted group: the take/advance
                        borrow discipline, and the release-once exit rule
    rfork.odin          Plan 9's fork: the flag word, the per-kind segment copy
                        rule, and the child built before it can run
    syscall.odin        Behind the door: the calling convention, the calls, the
                        note check the door runs first, and the two copies that
                        judge a pointer from ring 3
    notify.odin         The note handler: the frame pushed onto the user stack,
                        and the noted that resumes or dies
    exec.odin           A new image built in a fresh space, committed only when
                        whole, and the syscall frame rewritten to return into it
    image.odin          Both image formats, the segment judge, the loader, and
                        `#b` at /bin
    spawn.odin          What a child inherits, the wait that parks by pid, and
                        the reaper that collects a detached orphan
    program.odin        The programs the assembler bakes into the image, and
                        the marks they write to say they ran
    verify.odin         The largest self-test in the tree, and the one the boot
                        log's untagged lines come from. Every claim in section
                        2's process and screen rows is checked here
sys/
  abi/abi.odin          The system call ABI, included by both sides of the door
  libodin/format.odin   Allocation-free formatting (Sink)
  libodin/tally.odin    Checks counted and the first failure kept
  vectra9/
    proto.odin          Message kinds, Qid, the 57 bodies, the Msg union
    codec.odin          Encode/decode over a bounds-checked cursor; dirents
    errors.odin         Codec Error and protocol Errno, kept separate
    session.odin        Session, Transport, Handler; in-process and loopback
    verify.odin         Both transports agree, and every kind round-trips
  libuser/
    sys.odin            The calls from ring 3, the loop helpers every
                        byte-moving caller needs, and the child-first teardown
    ring.odin           The byte ring a forked reader publishes through
    serve.odin          post and serve; serve_mux, the concurrent loop with a
                        worker per parked request; and Spin, the first ring 3
                        lock
    fid.odin            The fid table five servers had each written, with a
                        lock, a walk, an attach and an EBADF guard
    link_user.ld        A ring 3 program's layout, aligned so every change of
                        permission gets its own page
  libdraw/draw.odin     The draw protocol's encoding: the six verbs, the put
                        half a client batches with, the get half the server
                        decodes with
  libdraw/text.odin     Text as a library over blit: the atlas layout, and the
                        consumed-count return that pumps a long line through
  libdraw/chrome.odin   The chassis vocabulary as rectangles, worn by both
                        rings. What composes them is the caller's
  libpal/palette.odin   The system palette, once, for both privilege levels
  libfont/font_data.odin  GENERATED -- the one 8x16 font table
  libposix/             Empty
servers/
  ramfs/main.odin       The first compiled server: two files, one writable,
                        serving this program's own segments back
  consrv/main.odin      An rfork'd reader parked on /dev/cons, a concurrent
                        serve loop, and a shared ring under two locks
  kbdfs/main.odin       The kernel's scancode state machine rebuilt in ring 3
                        over /dev/scancode, served cooked on /kbd
  eiafs/main.odin       /dev/eia0 served raw both ways, and the first Twrite
                        that reaches hardware
  intuition/main.odin   The draw server and the compositor: /new and a numbered
                        directory per window, six verbs on each window's data
                        file, a desktop, a frame, and four ctl lines
apps/
  terminal/main.odin    Lines in from /dev/cons, glyphs out through a /srv/draw
                        mount of its own -- the tree's first ring 3 mount
tools/
  genfont.py            TTF -> font_data.odin
  ste-lint.py           The ASD-STE100 checker; `build.odin -- lint` runs it
.claude/skills/
  asd-ste100/           The controlled-language skill this tree writes under
docs/
  *.md                  Section 3's table
  *.png                 Milestone screenshots, and the boot the README leads
                        with
```
