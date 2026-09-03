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
(terminal, rc), `cmd/` (echo, cat). Three architectures via Limine: `amd64` first and furthest,
`arm64` and `riscv64` booting the same `kmain` on QEMU's `virt` board since
September 2026. `docs/PORTS.md` says where each port stands.

About 50,700 lines of Odin. The linked kernel is ~1.6 MB debug, and the six
embedded user images are ~300 KB.

## 2. Where things stand

The machine boots and brings up memory, a namespace, a scheduler and a
preempting timer. It publishes `#c` at `/dev`, `#s` at `/srv` and `#b` at
`/bin`. It then runs about 1550 checks against itself and idles.

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
    kernel/env              a process can keep variables where its children find them
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

- **No `segattach` by class and address.** Every core the bootloader lists
  runs, a wake kicks an idle core, and a panic stops every other core. An unmap
  reaches every core's TLB, a run shared under `RFMEM` grows and shrinks in
  every holder, and `segalloc` has Plan 9's shared class. `docs/SMP.md` and
  `docs/USER.md` are the account. What a program still cannot do is ask where
  its memory goes, which is the first of the divergences `docs/USER.md` lists
  after the shared class.

And the rest, each named in the code it is missing from. **Something that
exists and is merely incomplete is not here.** Section 6 has those, because a
gap with a design question attached is work rather than orientation.

- **No FPU state across a note delivery.** `notify` registers a handler,
  `noted` resumes or dies, and `notepg` posts to a note group, so a note is a
  signal a whole job can be sent. `RFNOTEG` acts now: a child forked with it
  is a group of one. What a delivery still does not carry is floating-point
  state, which is `Ureg`'s edge in Plan 9 too. See `docs/USER.md`.
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
`NOTE_POLL` ticks. A *faulting* process hangs up its own descriptors now. A
reaper thread releases the group of anything whose thread left, so a client
parked on a server that faulted is answered rather than abandoned.

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
| `docs/SCHED.md` | `kernel/sched/` — the switch, priorities, the tick, placement | Adding a thread state, a priority rule, or a core class |
| `docs/SMP.md` | `kernel/smp.odin`, the lock words, the per-core state, the switch that holds a lock across itself | Touching a lock, a wait, the trap tail, or anything a second core changes the meaning of |
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
| `docs/ENV.md` | `kernel/env/` — `#e` at `/env`, one group per process, the root that means whoever asks | Reading or setting a variable, adding a per-process device, or wondering what `rfork(RFENVG)` copies |
| `docs/RC.md` | `apps/rc/` — the shell: the grammar by hand, a walked tree, forks that carry on from a node | Adding a builtin, a redirection, or a word form; writing a tool the shell runs; or wondering why a shell script is the slowest line in the user suite |
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
odin run build.odin -file -out:.vectra-build -- run --arch=arm64 --serial=file
odin run build.odin -file -out:.vectra-build -- check --arch=riscv64
```

`--arch` selects the architecture for every target, `check` type-checks the
kernel and the six programs for one architecture without linking, and a
change to anything under `kernel/arch/` or to `main.odin` wants all three
checked. The two ports boot the same firmware pair QEMU ships for their
boards, and the riscv64 firmware prints about twelve hundred lines of its
own before Limine: `grep -a '^\['` on the serial log finds the kernel's.

**QEMU presents four cores by default, and the kernel starts every one.**
`--smp=N` changes the count, and `--smp=1` is the uniprocessor control: the
same boot, with `smp: one core` where the bring-up and its checks would be.
The one-core boot is the one every self-test before `verify_smp` was written
against, so a check that fails only at `--smp=4` is a check the cores broke.

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
| The stubs and the FPU hold are `.S` files clang assembles | `arch/amd64/isr.S`, `syscall_entry.S`, `gdt.S`, `fpu_hold.S` and `ap.S` keep the AT&T text the blocks had, with a single `$` for an immediate now that no template substitutes operands. `build.odin` assembles each with `clang -target x86_64-unknown-elf -c` and links the objects beside `vectra.o`. The list is a row of the per-arch table. A `.globl` there is a `foreign` declaration in Odin, unchanged. A template's label reaches LLVM without its colon in this compiler, so a loop in a template assembles to nothing: that is why the FPU hold is a file. |
| The error-code vector list is written twice | Once as an assembler `.if` in `isr.S` and once as `vector_has_error_code` in `idt.odin`. They cannot share a definition — one is consumed at build time, the other at run time — and if they disagree every field in `Trap_Frame` reads as the one next door. `idt.odin` says so beside the Odin half. |
| An unoptimised build spills every temporary | Debug builds keep nothing in a register across an instruction boundary. This is not a curiosity: a test written to verify that FXSAVE preserves XMM passed with the FXSAVE removed, because the values it was checking were on the stack the whole time. Anything that must observe *register* state has to pin it with inline asm and hold it there — see `fpu_hold` in `kernel/sched/verify.odin`. |
| A missing EOI stops the timer silently | The local APIC delivers nothing further at or below that priority. There is no error, no fault, and no bit anywhere saying so — it looks exactly like a timer that was never armed. Any loop waiting on the tick count needs a liveness bound, or a one-line bug hangs the boot with the last line printed being the timer coming up successfully. |
| A freed object reads as a valid one | The slab allocator writes its free-list link over the first field and leaves the rest. A `Mount_Point` freed one reference early still reports zero members, which is exactly what a correctly dissolved one reports — so the obvious use-after-free check passes whether or not the bug is there. Testing a lifetime bug means testing the *reference count*, or forcing the block to be reused first. |
| The LAPIC coalesces what it cannot deliver | Ticks that arrive while interrupts are masked do not queue up. Raising the timer from 1 kHz to 20 kHz over a lock-heavy workload delivered about 1.4× as many interrupts, not 20×. Anything that expects a preemption *rate* has to account for how much of the time interrupts are actually on. |
| A voluntary switch is not a preemption | Making a layer block often does not make its narrow races reachable. A sleeping session lock took `kernel/verify_vfs.odin` from ~1,000 context switches a run to ~110,000, and caught not one additional mutation — every added switch is at a lock boundary, and a two-instruction read-modify-write window is not. Only a timer, or a second core, interleaves two threads at an arbitrary instruction. |
| Refilling a slice on dispatch is not scheduling | `Thread.ticks_left` reset on every dispatch is indistinguishable from resetting it every slice, right up until something blocks. A thread that parks hundreds of times a second then never reaches the end of a slice, never decays, and outranks the thread doing steady work for ever. Decay has to measure CPU consumed, which means carrying the remainder across a block. |
| `int $8` is not a double fault | A software interrupt to an error-code vector does **not** push an error code, so it lands on a stub that assumes one was pushed. Never test `#DF` that way. Provoke a real one by faulting on a bad stack. |
| `proc "sysv"` is amd64's alone | The compiler refuses it on the other two targets. Every procedure the assembly enters or the bootloader calls is `proc "c"`, which is the same convention on amd64 and the native one elsewhere. |
| The ports' templates are bytes | The checker knows the general instructions and not the system ones. `msr daifset`, the barriers, `tlbi`, `brk`, `svc`, `ecall`, `ebreak`, `sfence.vma` and a read of `sp` are `#byte` sequences with the register pinned to `x0` or `a0`. clang is the oracle: assemble the mnemonic in a scratch `.s`, read the bytes back with `llvm-objdump`. |
| A `foreign` symbol the image defines is undefined | Declaring `vectra_syscall_dispatch` with `foreign` in an arch package, when `kernel/user` exports it, left the linker with no definition. The ports take the dispatcher as a pointer through `arch.set_syscall_dispatcher`. |
| `ecall` from supervisor mode never reaches the kernel | It is the SBI's door, and no delegation changes that. The riscv64 yield is an `ebreak` with the vector in `a7`. |
| riscv64 links need `-z norelro` and the small-data sections placed | `ld.lld` otherwise carves a read-only segment for the GOT out of `.data` and starts `.bss` mid-page, which `build.odin` refuses; and `.sdata`/`.sbss` left unplaced become a segment of their own. |
| The riscv64 firmware publishes ACPI or a device tree, not both | The clock rate is a device tree property and nothing else says it. `build.odin` boots the `virt` board with `acpi=off`. |

**No vendored runtime shim.** The neighbouring `odin-os` project hand-maintains
a copy of `base:runtime` that must track the compiler. Current Odin ships
`runtime-os_specific_freestanding`, so Vectra builds against **stock
`base:runtime`**. Do not reintroduce a shim.

## 6. Where to go next

**This section is only forward.** What was built and why is in section 2 and in
the documents it points at.

**Next, in order:**

1. **A command line, and a disk to keep it on.** `docs/SHELL.md` is the plan:
   Plan 9's process ABI for programs (arguments, an environment device,
   `stat`, `dirread`, a current directory, string statuses, a heap in
   ring 3), then `rc` and the first tools in Odin, `#p`, a `virtio-blk`
   driver over PCI on every board, a FAT server so the host and the guest
   share `build/esp`, a filesystem of Vectra's own after it, and an `init`
   that ends the boot at a prompt.
2. **A MADT parse.** It retires both of the I/O APIC's assumptions, and the
   same table lists the cores SMP will need to start. Worth doing when one of
   those two becomes a reason rather than a tidiness.

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

**Deferred, with the reason written down: priority inheritance.** A lock hands
off to the best *waiter*. But a low-priority *holder* still delays a
high-priority waiter while it holds. This only matters under a realtime thread,
and Vectra runs none.

9front does not do it either: its QLocks are strict FIFO, and its EDF
scheduler's one "inherited deadline" field is dead code. Vectra already has more
than 9front here. Its `Mutex` hands off to the best waiter rather than in
arrival order, and a woken thread gets Plan 9's decay boost. Decay bounds the
inversion window rather than leaving it open. It waits for a realtime scheduler,
and `docs/SCHED.md` records the 9front model.

**One uncaught mutation is now reachable.** `docs/DRAW.md` section 8 records
that `rfork` copying a device segment is inert, because nothing forks a process
that holds one. The compositor is the process that would, and a worker per
window is the shape that would make it fork. It also pays 4 MB per window at
that moment, because `fork_segments` copies a run eagerly where Plan 9 copies
on write.

### Standing gaps

None are left. This section carried fifteen at its fullest, and each is now
either closed or deferred with a reason above. A closed gap belongs in the
design doc that argues the fix and in the commit that made it. It does not
belong on a forward list, so the retirements were pruned rather than struck through. `git log` and
the `See ...` pointer each one left behind are the record. What is left to do is
in "Next, in order" at the top and in "Smaller things" below.

### SMP, what is left of it

The cores run, and the list this section carried is empty. The bootloader
starts the cores, and `kernel/smp.odin` brings each one through the same
steps `kmain` took. A wake kicks an idle core awake, and a panic stops every
core. The process table has a lock, the log has one too, and the physical
allocator has the one it always needed. An unmap reaches every core's TLB.

`verify_smp` proves thirty-six things about all of that on every boot.
`docs/SMP.md` records how each item closed, which one was closed already, and
which lock came out of a control. A second thread in a process is a second
process under `RFMEM` here. It now shares a run as it grows and shrinks, and
`docs/USER.md` argues that under the run that grows.

The one-core flake is still there. About one boot in eight at `--smp=4`
fails a userland heap bracket by one object, before the cores start, in the
way the notes in `docs/TESTING.md` describe for a detached worker collected
late. It was not seen at `--smp=1` this session and was not chased.

### Smaller things worth doing when convenient

- Make `check_base_revision()` a hard stop rather than a warning.
- `servers/kbdfs` has its own copy of the scancode translation and it answers
  bytes, so the arrow keys reach `/dev/cons` and not `/kbd`. Nothing consumes
  `/kbd` for them yet, which is why this is a note rather than an item.
- An arm64 `cpu_class` that reads the three tiers from the core-id registers.
  The placement policy and the capacity-scaled slice are built and tested,
  and every core answers `.Performance` until this is written.

### The ports, what is left of them

Both ports boot `kmain` whole, and `docs/PORTS.md` section 4 has the table.
What is open, in order:

1. **The ring 3 test programs are Odin now**, in `kernel/user/programs`,
   one build per program per architecture, and every port passes all 874
   of the user suite's checks with them. A check that fails on one port
   and not another is a port bug with a name, and `docs/PORTS.md` section
   4 lists the four that were.
2. **The read/write lock race is closed.** `[ FAIL ] a reader was queued
   behind no writer` was `sync.wunlock` letting go of the wait lock between
   readers, and the ports hit it one boot in eight where amd64 never had.
   `docs/SYNC.md` records it. The one arm64 hang in the user phase seen
   before the fix has not been seen since, over seventeen boots across the
   two ports, and is presumed the same bug until it recurs.
3. **The riscv64 clock rate** comes from the device tree, which the
   firmware publishes only with ACPI off. `build.odin` says so on the QEMU
   line, and a machine that offers only ACPI needs the RHCT read instead.
4. **A stop that cannot be masked.** Neither port has an NMI, so a panic's
   stop reaches a core inside a spinlock late.

## 7. File map

One line per file, and only what the name does not say. The `docs/` tree is
section 3's table and is not repeated here.

```
build.odin              Build driver: user programs, kernel, ESP, QEMU, and
                        the ELF-to-VECTRA02 converter
tests/abi/              /bin/abitest: the process ABI exercised from ring 3,
                        which the user suite spawns with three arguments
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
  link_arm64.ld         The same layout for aarch64
  link_riscv64.ld       The same, with the small-data sections placed
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
  smp.odin              The other cores: the release, the arrival, and kmain
                        again from where a core diverges
  verify_smp.odin       Every core ticks, work spreads, a wake crosses cores
  arch/
    arch_amd64.odin     The architecture interface, bound to amd64
    arch_arm64.odin     The same names, bound to arm64
    arch_riscv64.odin   The same names, bound to riscv64
    neutral/            What every architecture spells the same way: the trap
                        kinds, the page flags, the paging constants, the
                        console kinds, the core classes. One copy, imported by
                        all three
    amd64/frame.odin    What kernel/user may read out of a frame, and put in
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
    arm64/cpu.odin      DAIF, barriers, the system registers, as bytes
    arm64/vectors.S     The sixteen-entry table and the tail
    arm64/traps.odin    The dispatcher: GIC ids, svc immediates and classes
    arm64/paging.odin   Stage 1 tables; two base registers, one root
    arm64/early.odin    The TTBR0 window onto the PL011, before the VMM
    arm64/gic.odin      GICv2: distributor, CPU interface, SGIs
    arm64/timer.odin    The generic timer, re-armed in the acknowledge
    arm64/context.odin  A new thread's first frame, and the AP switch
    arm64/percpu.odin   What one core keeps behind TPIDR_EL1
    arm64/frame.odin    The frame's public face for arm64
    riscv64/cpu.odin    sstatus, the CSRs by number, ebreak with a vector
    riscv64/vectors.S   The one entry stvec names, and the sscratch dance
    riscv64/traps.odin  The dispatcher: causes, PLIC sources, the mailbox
    riscv64/paging.odin Sv48
    riscv64/sbi.odin    Timer, IPI and console through the firmware
    riscv64/early.odin  The firmware console, and the device tree's one word
    riscv64/plic.odin   Sources, contexts, claim and complete
    riscv64/timer.odin  The tick through the SBI, and the IPI mailbox
    riscv64/context.odin, percpu.odin, frame.odin  As arm64's
  boot/limine/          Protocol bindings, base revision tag, request delimiters
  drivers/
    uart/uart.odin      The serial console, polled: a 16550 behind ports or
                        in memory, a PL011, or the firmware's own
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
  env/
    env.odin            `#e` at /env: a group of variables per process, the
                        root that resolves to the caller, and what rfork's
                        RFENVG and RFCENVG do to a group
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
    programs/           The ring 3 test programs, one Odin package built once
                        per program into a page-sized blob the kernel embeds
    path.odin           A process's current directory, and cleanname
    args.odin           A program's arguments, copied in and staged onto its stack
    program.odin        The programs' marks, cells and blobs, and
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
                        worker per parked request, and the Tflush that reaches
                        that worker; and Spin, the first ring 3 lock
    fid.odin            The fid table five servers had each written, with a
                        lock, a walk, an attach and an EBADF guard
    sys_<arch>.odin     The door, as its bytes, one per architecture
    heap.odin           A first-fit heap over segalloc, behind context.allocator
    main.odin           startup, args, Bio: what a tool starts with
    link_user.ld        A ring 3 program's layout, aligned so every change of
                        permission gets its own page
  libfmt/print.odin     print, fprint and bio_print over core:fmt, apart from
                        libuser so a page-sized program never links fmt
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
  rc/                   Plan 9's shell: lex, parse, tree, word, exec, builtin,
                        var, status, input, main, and rcmain in the image;
                        docs/RC.md
cmd/
  echo/main.odin        The first two tools, because a pipeline needs two ends
  cat/main.odin
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
