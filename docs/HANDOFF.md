# Vectra — session handoff

Read this first when you pick the project up in a new session. It records what
the code cannot tell you on its own. That is where things stand, how to build
and run it, what the toolchain costs, and what to do next.

**It does not explain any subsystem.** The reasoning behind each one lives in
its own document, beside the code. Section 3 is the index, and a claim made
here that wants a *why* is a pointer to one of them.

---

## 1. What Vectra is

A modular operating system in Odin. Three ideas define it:

- **Plan 9-inspired structure.** Per-process namespaces, private mount tables,
  and a synthetic file protocol, Vectra9 over 9P2000.L. *Every* system service
  is a file tree behind a message-passing endpoint, drivers, network stack,
  graphics, IPC and thread state alike. POSIX is a translation runtime on top of
  that, never a set of hardwired syscalls.
- **"Cyberpunk Workstation 1994" UX.** Heavy skeuomorphic bevels, brushed dark
  magnesium over deep slate, amber/cyan/phosphor accents, copper trim, a
  software dirty-rect compositor, and tracker-synthesised relay clicks.
- **An agent in the shell.** A model is a file server, the ghost acts
  through the same files a person uses, every application serves a control
  tree, and a namespace is its sandbox. `docs/GHOST.md` is the plan, and it
  is not a second-class citizen of the other two.

Layout — `kernel/` (arch, mem, sched, vfs, mnt, pipe, srv, env, devfs, procfs,
drivers), `sys/` (the ~20 libraries: `libuser`, `vectra9`, `libthread`,
`lib9p`, `libdraw`, `libmui`, `libnet`, `libndb`, `libauth`, `libcrypto`, …),
`servers/` (ramfs, memfs, consrv, kbdfs, eiafs, intuition, netfs, cs, dns,
fatfs, kfs, factotum — a dozen ring 3 file servers), `apps/` (rc, terminal,
filemgr, muidemo, tracker), `cmd/` (about forty tools). Three architectures
via Limine: `amd64` first and furthest, `arm64` and `riscv64` booting the same
`kmain` on QEMU's `virt` board since September 2026. `docs/PORTS.md` says where
each port stands.

About 103,000 lines of Odin. The linked kernel is ~1.6 MB debug, and the
embedded user images (`/bin`, the library, the boot servers) are staged onto
the ESP.

## 2. Where things stand

The machine boots and brings up memory, a namespace, a scheduler and a
preempting timer. It publishes `#c` at `/dev`, `#s` at `/srv`, `#b` at
`/bin`, `#e` at `/env` and `#p` at `/proc`. It then runs its self-tests --
about 1600 checks, the userland suite alone over a thousand -- and idles a
shell on the console with a windowed desktop beside it.

**What it can do**, and which document says why:

| | What works | Read |
|---|---|---|
| The wire | 9P2000.L, in-process and over bytes, several requests in flight, `Tflush` | `VECTRA9.md`, `TRANSPORT.md` |
| The namespace | bind/mount with before/after/replace, unions, a private table per process | `NAMESPACE.md` |
| The console | `/dev/cons` is a real terminal: a line typed at the keyboard or the serial port is edited, echoed, and handed to a parked reader | `DEVFS.md` |
| The hardware | every device behind `#c` is a file — `/dev/fb` the screen's memory, `/dev/scancode` the untranslated keyboard, `/dev/eia0` the port. A raw stream is *diverted* while held, and given back on the last close | `DEVFS.md` |
| Services | `/srv` names a running service, mountable anywhere in a namespace, postable from ring 3, and its connection comes down when the last mount and the name are both gone | `SRV.md`, `PIPE.md` |
| Processes | ring 3, a namespace and a descriptor group of its own, `spawn`, `rfork` by Plan 9's flag word, `exec` in place, notes a handler catches, `segalloc` for memory no file serves, and a user the kernel gates control by | `USER.md` |
| Ring 3 servers | a dozen, on a runtime with a serve loop, and `lib9p` for a server whose reads park: a request is held and answered later by whichever thread has the answer | `RUNTIME.md`, `THREAD.md` |
| Threads | Plan 9's `libthread`: procs for what blocks in the kernel, cooperative threads for what does not, channels and `alt` between them, and a server on it that needs no lock | `THREAD.md` |
| The network | `/net` served by `servers/netfs`: IPv4, ARP, ICMP, UDP and TCP over `virtio-net`, with `cs` and `dns` beside it and `dial` a string away. Two machines on one link ping by name | `FLEET.md`, `NETFS.md` |
| 9P both ways | `exportfs` serves a namespace, `listen` runs it per connection, `srv`/`import` mount another machine's tree, and a flush crosses the wire | `FLEET.md`, `TRANSPORT.md` |
| Users | a person is a key pair; `factotum` holds the private half derived from a passphrase, a Noise IK handshake proves it and seals the stream, `kfs` files have owners and modes, and a private file refuses across the wire while a stranger is refused before 9P | `FLEET.md` |
| The disk | `servers/kfs` (writable, owners and modes) and `servers/fatfs` (the ESP), each a ring 3 file server over `virtio-blk` | `KFS.md`, `FATFS.md`, `DISK.md` |
| The screen | a draw server with six verbs, a window per session with pixels of its own, a compositor, a desktop, window chrome, four `ctl` lines, and a `cons` and `consctl` per window with a line discipline of its own | `DRAW.md` |
| Typing | one discipline (`sys/libedit`) worn by the server that cooks a window's lines and by the program that draws them and echoes, with a cursor the arrow keys and `^A`/`^E` move | `DRAW.md` |
| Runes | a key with no character arrives as Plan 9's private-space rune in UTF-8 (`sys/libkey` names them, `core:unicode/utf8` encodes them) through a `/dev/cons` that stayed bytes | `DRAW.md`, `KBD.md` |
| Crypto and TLS | `core:crypto` compiles and runs freestanding, proven against its RFC vectors on the machine; `sys/libtls` is a TLS 1.3 client -- the key schedule, the record layer, the handshake and the authenticated flight (a certificate chained to a root, its signature, both Finisheds) -- checked against RFC 8448 and a scripted server every boot, and `cmd/tlsclient` dials a scripted TLS server on the machine's own stack every boot, its chain verified against `/lib/tls/roots` | `WEB.md` |

**The screen and the fleet are where the depth is.** The screen is a draw
server that owns `/dev/fb`, a window per session with its own pixels out of
`segalloc`, a compositor that walks damage onto the glass, chrome as `ctl`
lines, and a `cons`/`consctl` per window with its own line discipline -- the
window in front gets the keyboard through a namespace bind, and the half that
draws is the half that cooks and echoes, `rio`'s arrangement. `docs/DRAW.md`
owns all of it. The fleet is the network as files, 9P served as well as
dialled, and a person proved by a Noise handshake -- `docs/FLEET.md` owns
that, and steps 0, 1 and 2 of it are done.

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
    servers/memfs           a program can make a file and find it again
    kernel/procfs           a process can be seen, and ended, by name
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
    a held request          and a server answers later, from whoever has the
                            answer, rather than park a process on it
    copy on write           and a fork costs a page table rather than a copy
    a rendezvous, a semaphore
                            and a program can wait for another with one call
    a thread                and a program is procs for what blocks and threads
                            for what does not, and a server holds no lock
    a card, a stack         and /net is files: a frame, an address, a
                            conversation, a name the database or DNS resolves
    9P both ways            and a machine serves its tree as well as dials
                            another's, so one namespace spans the LAN
    a person                and a key pair proved by a handshake is a user the
                            file server and the kernel both check, so a
                            private file refuses and a stranger is turned away

### Reading a boot log

A boot prints one `[ ok ]` line per subsystem, each a self-test on the
machine that will run it. `docs/TESTING.md` is the discipline behind them.
Three things about a boot are worth knowing before you read one:

- **Some numbers move on every run, and that is the design.** The LAPIC
  calibration, the preemption round counts, the lock acquisitions, and the
  operation count under a fixed tick budget are measured rather than asserted.
  A release build does the same thousand ticks of work and reports about fifty
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
- **No way for one process to wait on two descriptors** — it forks instead,
  which is Plan 9's answer. (A ring 3 heap does exist: `libuser`'s allocator,
  which `factotum`'s argon2id and the shell both lean on.)
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
| `docs/MOUSE.md` | `kernel/drivers/mouse/`, `/dev/mouse` — the packet, the second port, one reader | Reading the pointer, or adding a device on the 8042 |
| `docs/DEVFS.md` | `kernel/devfs/` — `#c` at `/dev`, the console device, the line discipline, the `ctl` convention, the raw framebuffer and the screen's divert | Adding a device file, adding a `ctl` file, writing a server whose reads park, wondering why `/dev/cons` has two locks, or asking who owns the glass |
| `docs/SRV.md` | `kernel/srv/` — `#s` at `/srv`, posting, the id that is not a slot | Publishing a service, mounting one by name, or writing a directory that changes |
| `docs/ENV.md` | `kernel/env/` — `#e` at `/env`, one group per process, the root that means whoever asks | Reading or setting a variable, adding a per-process device, or wondering what `rfork(RFENVG)` copies |
| `docs/RC.md` | `apps/rc/` — the shell: the grammar by hand, a walked tree, forks that carry on from a node | Adding a builtin, a redirection, or a word form; writing a tool the shell runs; or wondering why a shell script is the slowest line in the user suite |
| `docs/CMD.md` | `cmd/` — the tools, `servers/memfs`, `sys/libregex`, and the script that checks them | Writing a tool, adding its line to `tests/tools.rc`, or wanting a file to write to before the disk |
| `docs/PROC.md` | `kernel/procfs/` — `#p` at `/proc`: status, ns, note, ctl, through five doors into the process table | Reading a process from a program, killing one, or printing a namespace |
| `docs/PROCS.md` | The plan for processes and threads, Plan 9's way, and where each of its four steps stands | Wondering why a fork is cheap, what `rendezvous` is for, or what the servers stood on before threads |
| `docs/THREAD.md` | `sys/libthread`, `sys/lib9p` — procs, threads, channels, `alt`, and a server that holds no lock | Writing a program that waits on two things, a server whose reads park, or anything with a channel in it |
| `docs/DRAW.md` | The draw protocol, written before its code, and everything the screen grew after it: the window, the compositor, the chrome vocabulary and the one palette (`sys/libdraw`, `sys/libpal`) | Building the draw server, its client library, the fb mapping, or anything that draws in either ring |
| `docs/WORKBENCH.md` | The plan for a desktop, Amiga's way: a mouse, gadgets, chords from a keys file, a MUI-shaped toolkit whose look is a theme file, and Workbench | Starting any of its four steps, or adding a file a window serves |
| `docs/HARDWARE.md` | The plan for real hardware, the OrangePi 6 Plus: the device tree as files, drivers in ring 3 behind a walker, a device that walks the process's own tables, the GPU and NPU as directories, and the board's facts from the vendor tree | Starting any of its eight steps, adding a driver, or wondering what the kernel does and does not do for a device |
| `docs/SMMU.md` | `kernel/smmu` and the `dma` file, written before their code: the SMMUv3 as QEMU models it, the stream table and context descriptor, the walker list a space carries, the fault stream, the capability check, and `blkfs` in outline | Attaching a device to a process, touching the unmap path on arm64, writing a ring 3 driver with bus mastery, or wondering why a kernel driver's disk answers EIO |
| `docs/DEVTOOLS.md` | The plan for development tools: C and C++ on the build the tree has, a platform library over files, `/proc` whole, debug information as a flat file, a debugger that is a file server, POSIX as mlibc over the calls, and a compiler on the machine | Starting any of its nine steps, adding a language, a library a C program links, or a file the debugger reads |
| `docs/FLEET.md` | The plan for several machines, Plan 9's way: `/net` as files, 9P served as well as dialled, users as key pairs with `factotum` and a Noise handshake, roles as init scripts, root over the network, one tree for three architectures, `cpu`, and a queue that is a directory | Starting any of its six steps, adding a network service, touching who may do what to whom, or adding a fast path that must keep a file fallback |
| `docs/GHOST.md` | The plan for the agent: models as file servers, local and cloud behind one directory, a ghost with seven tools and a namespace for a sandbox, an application contract of three files that `libmui` serves free, the plumber, and MCP both ways | Starting any of its seven steps, making an application scriptable, adding a tool, or touching what the ghost may reach |
| `docs/WEB.md` | The plan for the world beyond the fleet, on the federated protocols people already use: `webfs` and TLS, a store of every body by hash and every link both ways, one message shape for mail, posts, rooms and feeds, a union that is a timeline, `mothra` the reader, mail as the sealed messenger Delta Chat's way, ActivityPub and the AT Protocol, Matrix, and a site from a directory | Starting any of its seven steps, adding a network, touching a key or a token, or wanting the font past 128 glyphs |
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

`build.odin` is the real build system — compile, link, stage, run — and holds
the per-architecture table. **`just` is not installed on this machine**;
`make` wraps the same targets, but invoking the driver directly is what these
notes and the sessions actually use:

```sh
odin run build.odin -file -out:.vectra-build -- run            # build, stage ESP, boot headless, serial on stdio
odin run build.odin -file -out:.vectra-build -- run --gfx      # same, with a QEMU window
odin run build.odin -file -out:.vectra-build -- run --serial=file   # COM1 to build/serial.log, for headless capture
odin run build.odin -file -out:.vectra-build -- check          # type-check everything, emit nothing
odin run build.odin -file -out:.vectra-build -- run --arch=arm64
odin run build.odin -file -out:.vectra-build -- check --arch=riscv64
odin run build.odin -file -out:.vectra-build -- fleet          # two machines on one socket link; drive with scripts/fleet.py
```

`make run`, `make check`, `make release`, `make font` cover the common ones.
`--arch` selects the architecture for every target, `check` type-checks the
kernel and every program for one architecture without linking, and a
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
build/vectra.elf -o 'gdb-remote localhost:1234'` reaches a boot started with
the `debug` target (halted, waiting on :1234) with symbols and line numbers. QEMU's `-s` flag opens
the same stub without halting, so a boot loop can run with it open and leave
a wedged machine standing to be read. `docs/TESTING.md` describes reading one.

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
are what that cost. No `xorriso`, no loop devices, no `sudo` required. Pillow
is installed again, so `tools/genfont.py` (the baked ASCII table) and
`tools/gensubfont.py` (the subfonts past it) both run; their output is
checked in, so a build needs no rasteriser. Nothing else needs Python.

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
| `core:crypto` needs a freestanding backend `build.odin` injects | Its hash, HKDF, AEAD, signature and X.509 packages import `core:sys/info` and `core:sync`, which have no freestanding build, so they will not compile for Vectra as they ship. `ensure_crypto_backend` copies `toolchain/*_backend_freestanding.odin` into the Odin install before every compile, idempotently, so a Homebrew Odin upgrade that wipes it is repaired on the next build. The stubs report "no CPU features", which is why every crypto package selects its portable software path — the one Vectra wants, since a context switch saves SSE but not AVX. The tables cost image budget: `MAX_PROGRAM_FRAMES` in `kernel/user/user.odin` went to 256 so a crypto program loads. |

**No vendored runtime shim.** The neighbouring `odin-os` project hand-maintains
a copy of `base:runtime` that must track the compiler. Current Odin ships
`runtime-os_specific_freestanding`, so Vectra builds against **stock
`base:runtime`**. Do not reintroduce a shim.

## 6. Where to go next

**This section is only forward.** What was built and why is in section 2 and in
the documents it points at.

**Next, in order:**

1. **The desktop.** `docs/WORKBENCH.md` is the plan, and steps 1 to 4
   are done. Input is files, `intuition` has the pointer and gadgets,
   `sys/libmui` is live in a window, and Workbench is the desktop `init`
   starts, driven end to end by the suite, September 2026
   (`docs/workbench-step4-desktop.png`). Step 5 is the rest of the
   platform, in whatever order a reason arrives. See "the order that
   avoids a rewrite" below.
2. **What `docs/THREAD.md` leaves open.** A note handler in `libthread`,
   Plan 9's `threadnotify`, so a proc other than the first can end the
   program and a note can be caught rather than end a proc. A guard page
   under a thread's stack.
3. **A MADT parse.** It retires both of the I/O APIC's assumptions, and the
   same table lists the cores SMP will need to start. The mouse's IRQ 12 is
   one more line assumed rather than read, and may be the reason.
4. **Real hardware.** `docs/HARDWARE.md` is the plan, written before its
   code, for the OrangePi 6 Plus. Its first step needed no board and is
   done, September 2026. The device tree is files. A GICv3 runs beside
   the v2. The SMMU is up with `docs/SMMU.md`'s `dma` file, and
   `servers/blkfs` reads the scratch disk over `mmio`, `dma` and its own
   memory. Both fault proofs are green, and `--no-invalidate` is the
   control that fails one.

   The core-class pinning step 0 lists is checked in the scheduler's own
   test over a fabricated pool. No machine line makes `virt`'s cores two
   tiers yet. The board comes second, and the GPU fifth.
5. **Development tools.** `docs/DEVTOOLS.md` is the plan, written before
   its code. C and C++ enter the build at the object: `sys/libc`, `crt0`
   and a generated `sys/abi/abi.h`, with a C hello, a C++ hello whose
   constructor runs, and a mixed Odin-and-C image, on three
   architectures, and a thread pointer for C thread-local storage saved and
   restored on a switch: step 0, September 2026. A platform library of twenty calls sits over files a program
   can open itself. `/proc` has Plan 9's `mem`, `regs` and `startstop`
   now: step 3, done in September 2026. Every program has a debug file
   beside it, and the kernel names its panic backtrace, with scopes,
   variables and types beside them: step 4, done the same month. A
   debugger runs as a file server, `servers/dbgfs`, with `cmd/db` as its
   line client and `tests/dbg.rc` as the boot self-test's script: step 5,
   first cut, the same month. `apps/debugger` is the window, a `libmui`
   client of the same files: step 6, first cut, the same month. POSIX is
   mlibc over the calls, so that `clang` and `odin` run on the machine:
   `sys/libposix` is the tree's own half of it, files, processes,
   threads and a caught signal over the door, step 7, first cut, the same
   month, with mlibc itself and the compiler on the machine still ahead.
   Step 1 needs nothing before it, and steps 7 and 8 have step 0 under
   them.
6. **The fleet, from step 3.** `docs/FLEET.md` is the plan, and steps 0
   (the network), 1 (9P both ways) and 2 (users, `factotum`, the Noise
   handshake, kfs owners) are done and on the bench. **Step 3 is next:**
   roles as init scripts, root over the network, and one tree that serves
   three architectures, with `cmd/timesync` and the real-time clock. Steps
   4 (`cpu`) and 5 (the fleet's tools, the queue) follow it. Its bench is
   two QEMU machines of two architectures on one laptop, driven by
   `scripts/fleet.py`. The one loose end in step 2 is a permanent person
   stage in that bench (the manual proof is reliable; the scripted one
   flaked on console timing), and `/adm` on writable kfs so `auth newuser`
   can append rather than the build staging the line.
7. **The ghost.** `docs/GHOST.md` is the plan, written before its code.
   A model is a file server with a local engine and a cloud backend
   behind one directory. The ghost runs the API's loop with seven tools
   over files, in a namespace forked with `RFNOMNT` as its sandbox.
   Every application serves `ctl`, `dict` and `event`, and `libmui`
   serves them for free. Its first two steps need nothing but the disk.
8. **The web, from step 0's wire.** `docs/WEB.md` is the plan, written
   before its code, and no protocol is invented. **Step 0 is underway,
   and its TLS 1.3 client is built and proven on the machine.**
   `sys/libtls` is the engine: the key schedule against RFC 8448's own
   secrets, the record layer, the handshake's two hellos, and the
   authenticated flight — a certificate chained to a trust root, its
   CertificateVerify signature, and both Finished MACs — over Odin's
   `core:crypto` (which `build.odin` makes compile freestanding; see
   section 5). `sys/libtls/client.odin` is the transport that reads
   records off a byte stream, reassembles and demultiplexes them, and
   seals the replies; `cmd/tlsclient` runs it over `/net/tcp`, verifying
   the chain against `/lib/tls/roots` and the clock. `tests/crypto`
   proves each brick on-target against a scripted server whose flight is
   deliberately fragmented, and mutates the code to see the checks bite.

   `sys/libtls/server.odin` is the server side of the same handshake,
   enough to answer a client, and `tests/tlssrv` stands one on `/net/tcp`
   so `cmd/tlsclient` itself is proven over a real connection every boot
   (`tests/web.rc`: the dial by this machine's name through `/net/cs`,
   the trust store, the clock and the relay). Proving that found a stack
   bug: a TCP conversation lived on after its last descriptor closed, so
   every test that exited mid-stream kept a slot of the eight until a
   listener could accept nothing. The last close of an opened stream now
   hangs the conversation up, Plan 9's rule, `docs/NETFS.md`.

   **What is left in step 0**, in order: the host's CA bundle staged at
   `/lib/tls/roots` in place of the single test certificate there now;
   and then `servers/webfs`, the HTTP client as files, with the store of
   every body by hash, the link index both ways, and the cookie jar. Then
   step 0's other schemes (Gemini, WebSocket). `webfs` and TLS are built
   once, for this and the ghost's cloud. After step 0: a message is a
   directory on every network, `upas/fs`'s shape, a union of them is the
   timeline, `mothra` reads it all, then mail the Delta Chat way,
   ActivityPub and the AT Protocol, Matrix, and a site from a directory.
   Step 1 owns the font past 128 glyphs, which is done.

### The plans, and the order that avoids a rewrite

Six plans are open at once now: `docs/WORKBENCH.md`, `docs/HARDWARE.md`,
`docs/DEVTOOLS.md`, `docs/FLEET.md`, `docs/GHOST.md` and `docs/WEB.md`.
Each lists its
own steps in its own order-of-dependence table. What that table cannot
show is where one plan's step waits on another's, and those crossings
are what decide the order. This is the graph, and the five places a naive
order builds a thing twice.

**The hubs.** Five pieces are each waited on by steps in more than one
plan, and each is a root that can start now:

    sys/libmui           WORKBENCH 3, DONE. GHOST 2 and 3 and DEVTOOLS 6
                         are all windowed clients of it. The root is built.
    the network          FLEET 0 DONE but for `etherfs` (waits on HARDWARE
                         0's `mmio`/`irq`), FLEET 1 (9P both ways) DONE, and
                         FLEET 2 (users) DONE. `factotum` holds the keys,
                         `sys/libauth` runs Noise IK through it and seals the
                         stream, `srv`/`import`/`exportfs -a` prove who they
                         are, and the bench imports across architectures
                         sealed with a stranger refused. The kernel gives each
                         process a user and each kfs file an owner and modes;
                         `init` names the host owner and it takes, so
                         `exportfs` becomes the client it proved and
                         re-attaches the tree as that user. `cmd/auth`
                         enrols a person (`newuser`), changes a passphrase
                         (`passwd`) and logs one in (`login`, which `exec`s so
                         it becomes the console's own shell). All three of
                         section 4's proofs hold on two machines: `jkane`
                         logs in on one, imports two as themselves, reads a
                         public file and is refused a private one, and cannot
                         kill a host process. `jkane` is staged in `/adm/keys`
                         (passphrase in `cmd/auth`'s source). Left in FLEET 2:
                         nothing required; `/dev/user` and `/adm/users` groups
                         are the only niceties not built.
                         The bench holds both boot lines: two architectures
                         ping by name, a line crosses, `ipconfig` gets an
                         address from the router, and machine one imports
                         machine two's tree and reads its `/proc` across the
                         wire. `dns` and `cs` stand beside the stack;
                         `exportfs`, `listen`, `srv`, `import` and `9fs`
                         serve and mount it. See `docs/NETFS.md`. FLEET 2 is
                         done; FLEET 3 (roles and boot) is next, and GHOST 4
                         and the stack half of HARDWARE 3 read all of this.
    users and factotum   FLEET 2. GHOST 4 needs an identity, and the
                         one-user note in `docs/DRAW.md`, `docs/PROCS.md`
                         and `docs/KFS.md` is written against this.
    /proc, whole         DEVTOOLS 3, DONE. `mem`, `regs`, `fpregs`, `text`,
                         `segment`, `fd`, `wait`, and the words `startstop`,
                         `waitstop`, `hang`, `startsyscall`, `step`. `dbgfs`
                         (DEVTOOLS 5) reads it, after step 4's debug file.
    the font             WEB 1. WORKBENCH 5 lists it deferred, and this
                         file did too. A reader of the world's pages
                         cannot drop runes, so WEB owns it, and it waits
                         on nothing.

**The cross-plan edges**, over and above each plan's own within-itself
order:

    GHOST 2   -> WORKBENCH 3    the application contract is `libmui`'s to serve
    GHOST 3   -> WORKBENCH 4    the ghost's window is a Workbench window
    GHOST 4   -> FLEET 0, 2     the cloud needs the network and an identity
    GHOST 5   -> FLEET 5, HARDWARE 5   a model on the fleet's accelerators
    DEVTOOLS 6 -> WORKBENCH 3   the debugger's window is a `libmui` client
    FLEET 0   ~= HARDWARE 3     one network stack, not two -- see below
    WEB 0     ~= GHOST 4        one HTTP client and one TLS, not two -- see below
    WEB 1     -> WORKBENCH 3    the reader is a `libmui` client
    WEB 1     -> GHOST 2        a click is a plumb message
    WEB 3, 4, 5 -> FLEET 2      every key and token lives in `factotum`
    WEB 6     -> FLEET 1        `httpd` and `gemd` are `listen` services

**The five rewrites to refuse:**

1. **One network stack.** `docs/HARDWARE.md` step 3 and `docs/FLEET.md`
   step 0 both name `etherfs`, `netfs` and `9pserve`, five thousand lines
   of the same servers. Build them once in FLEET against `virtio-net` on
   QEMU, behind an `etherfs` contract a card sits behind. HARDWARE step 3
   then adds the board's card behind that contract and rewrites nothing
   above it. FLEET's own table says as much. This is the reminder to do
   FLEET's network before the board's.
2. **One user model.** "There are no users" is load-bearing in four
   places. `docs/DRAW.md`'s window `ctl` is exclusive because there is
   nobody to own it. `docs/PROCS.md`'s notes go by anybody. `docs/KFS.md`
   writes every file glenda's, and `docs/GHOST.md`'s sandbox is a
   namespace rather than a right. `factotum` (FLEET 2) is the one place
   that ends that. Anything that would fake an owner to move sooner is a
   thing FLEET 2 makes it rewrite.
3. **One toolkit.** `sys/libmui` (WORKBENCH 3) is under the ghost's
   applications, the ghost's window and the debugger's window. A window
   built before it -- a debugger drawn by hand, an application's gadgets
   hand-rolled -- is a window built twice.
4. **One sound path.** `docs/DEVTOOLS.md` step 1 puts the clock, the
   store and sound together, and `docs/HARDWARE.md` step 7 has a board
      codec. Sound belongs in DEVTOOLS 1 behind a file. The board then
   contributes a codec behind the same file, the way the network is one
   stack and two cards.
5. **One HTTP client.** `docs/GHOST.md` step 4 and `docs/WEB.md` step 0
   both name `cmd/tlsclient` and `servers/webfs`, five thousand lines
   of TLS 1.3, X.509 and HTTP. WEB step 0 builds them, with the store
   and the jar the reader needs, and the ghost's cloud backend is their
   second client. A `tlsclient` written for one host first is one
   written twice. **WEB 0 is building them now:** `sys/libtls` and
   `cmd/tlsclient` are the TLS half, built and proven on the machine;
   `servers/webfs`, the HTTP half, is still to come. GHOST 4 waits behind
   both, and rewrites neither.

**The filesystem was not finished, and three plans leaned on the parts
that were missing.** `docs/KFS.md` deferred six things; two of them were
owned by no plan and were the ones GHOST 0 and the DEVTOOLS self-hosting
step each stopped at. Both are done now, as a root of their own:

    files past 4 MB    DONE. A double indirect level takes a file to four
                       gigabytes on the same format -- byte 92 of the inode
                       was spare -- so GHOST 0's weights and DEVTOOLS 8's
                       objects fit. A third level is the same recursion
                       again, when a file wants it.
    rename             DONE. `Trename` moves the entry and keeps the inode,
                       across directories, and `mv` uses it; EXDEV or a
                       server that cannot (memfs) makes `mv` copy. DEVTOOLS
                       7's `libposix` has the real thing to wrap.
    owners, dates      DONE. Owners in FLEET 2; dates from `/dev/time`,
                       which the bootloader's Date-at-Boot starts with no
                       driver and kfs stamps `mtime` from. FLEET 3's
                       `timesync` and an RTC driver later *set* a clock
                       that already exists, rather than each inventing one.
    a journal, a check DONE. Every request that changes kfs is one
                       transaction, its writes held and landed through a
                       forty-block journal all at once, so a stop leaves
                       all of them or none; a mount replays a commit a stop
                       interrupted. `kfs -c` still marks and sweeps for a
                       volume from before, and the boot runs both controls:
                       a leak the check must reclaim, and a commit faked as
                       stopped after its record that replay must finish.
    the cache          DONE. 256 blocks, a megabyte, 32 sets of 8 ways,
                       LRU, on the heap -- was 32 direct-mapped, where an
                       inode block and a data block that shared a residue
                       evicted each other (a probe reads eight of a set
                       twice: 16 disk reads of 16 became 8). Write-back: a
                       commit keeps the cache, since every changed block was
                       written and each dirty way holds what landed, so a
                       block two requests touch is read once; only an abort
                       drops it. Left in kfs: a write barrier between the log
                       and the header, a board driver's to give.

**One way to defer the largest of these.** A model's weights are read,
not written, and `/lib` is bound from the FAT system partition the host
stages, not from kfs. So `modelfs` reading `/lib/models/*.gguf` off the
host-staged partition sidesteps the 4 MB cap while kfs is still small.
What still needs kfs to grow is a file a *program* writes large: a
fine-tuned model, a self-hosted build's output, a long capture. GHOST 0
can start on the read path, and the write path waits on kfs.

**So the order that costs the least.** The roots first and in parallel:
WORKBENCH 3 (`libmui`), FLEET 0 (the network), DEVTOOLS 3 (`/proc`),
DEVTOOLS 0 and 1 (C and the clock), GHOST 0 and 1 (a model as a file, and
the ghost on today's tree). The font from WEB 1 is a root too. Then the hubs'
dependents: WORKBENCH 4, FLEET 1 and 2 (`factotum`), DEVTOOLS 4, WEB 0
and 1 (the wire and the reader). Then what those unblock: `dbgfs` and
its window, the ghost's applications and window, the fleet's roles and
`cpu`, the reader's networks, and the board. The GPU, the NPU and a
model on them are last, because they wait on the most.

`docs/WORKBENCH.md` step 3 is done. The root that three windowed clients
across three plans waited behind is built.

The remaining roots wait on nothing, and each can start now:

    the network        FLEET 0
    /proc, whole       DEVTOOLS 3, DONE
    the font > 128     WEB 1
    C and the clock    DEVTOOLS 0 and 1 DONE. Step 1: the fast clock
                       (`/dev/time`'s five Plan 9 fields, the hardware
                       counter and its rate), `/dev/audio` (a virtio-sound
                       driver, one PCM stream, a second of samples proven),
                       the shared buffer (`SYS_SHMALLOC`/`SYS_SHMATTACH`, a
                       `.Device` run refcounted in `kernel/user/shm.odin`),
                       and the window `store` file over it -- a client
                       `shmattach`es a window's store and paints it, no verb,
                       and a write to `store` flushes it. The resize/share
                       edge is answered by pre-sizing every store to the
                       whole screen, so a resize moves only `w`/`h` and the
                       run never moves under the client. All on three arches.
    libapp             DEVTOOLS 2 started. `sys/libapp`'s spine in Odin --
                       open/frame/present/close over the window store and
                       the clock, the pointer on an io thread, `pump` the
                       frame loop's yield. And its C face: `vapp_*` exports
                       (`capi.odin`), `sys/include/vectra/libapp.h`, and
                       `tests/capp`, a C client linking the Odin library (the
                       mixed image `cmix` proves). And a game, `apps/rebound`
                       (a ball and a paddle, motion in `frame`'s real
                       seconds). `tests/app`, `tests/capp` and rebound all
                       started and closed by the self-test -- the step's boot
                       line met. Sound too: `open` opens /dev/audio, `sound`/
                       `vapp_sound` feed it, both clients play a tone and the
                       self-test reads the device's sample count move. Left:
                       the pads, the last frame rung.
    a model, the ghost GHOST 0 and 1
    kfs large + rename DONE -- the unowned root, built; GHOST 0's write path
                       and DEVTOOLS 7 and 8 no longer stop at kfs

Of these the network has the widest fan-out. Every later FLEET step,
GHOST 4, and the stack half of HARDWARE 3 read it. So it is the next
highest-leverage root, and building it once in FLEET is the "one network
stack" rewrite refused. The font is the smallest root that also repays
the desktop just built. `sys/libedit` drops every rune past 128, so the
toolkit's `String` field cannot yet show them.

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

**The font past 128 glyphs: done, every renderer wired.** Plan 9's shape, not
a wider table: `/lib/font/default.font` names
rune ranges and the subfont file each is in, and `sys/libfont` reads them at
run time -- the first data this system loads rather than bakes -- into a
`Loader` that keeps a few subfonts by recency and answers a rune's cell,
ASCII from the baked table and the rest from a subfont. `tools/gensubfont.py`
rasterises the subfonts (Latin-1, punctuation, arrows so far) and checks them
in, so a build stages them without a rasteriser. `tests/font` proves the
loader. The **kernel console** now draws through it: `console.use_font` opens
`/lib/font/default.font` once `init_fatfs` has the disk, over a `vfs` reader
`kernel/main` gives it, and `draw_glyph` takes a rune and decodes UTF-8 --
`verify_console_font` draws an accented letter to a scratch surface and reads
the ink back. The early-boot log and the panic screen stay ASCII and wait on
no load. The **draw server's title** draws through it too: `servers/intuition`
fills a `Loader` from `/lib/font` at startup and `title_text` decodes the
name's UTF-8 a rune at a time, so a window named with an accent in it draws
rather than dropping the byte -- the kernel draw self-test names a window
`ééé` and reads the ink back.

The **draw protocol's text model** went multi-range with it. `libdraw.Atlas`
is 9front's `Font`: a set of rune ranges, each packed into one shared strip
set at a cell `offset` (9front's `Cachefont.offset`), so a font of several
ranges spends one run of image ids and not one per range. `put_text` decodes
UTF-8 and blits a cell per rune; `put_runes` does the same for a caller that
already holds runes. `libdraw.bake_atlas` is the one baker -- it plans an
atlas's ranges from ASCII and a `libfont.Loader`, and uploads the strips in
one ink over one background -- so `sys/libmui`, `apps/terminal` and
`cmd/window` all bake the same way. A face sources every cell through
`loader_glyph`: baked ASCII when the font is closed, a subfont when open. The
server's image pool is 128 and a full-font face is ~14 strips, so a bake the
pool refuses degrades to the label (or exits the terminal) rather than drawing
half a font.

The **terminal and `cmd/window` hold runes**, not bytes: a cell is a `rune`,
`put_byte` gathers the UTF-8 the shell writes across the bytes it arrives in,
and `draw_row` blits with `put_runes`, so a program that prints an accented
name shows it. `tests/mui` bakes a face and checks the atlas names Latin-1 and
refuses a CJK rune; the terminal's prompt and echo, drawn through the new
path, stay green on the glass.

And **`sys/libedit` stores a typed rune** rather than dropping it: its UTF-8
goes in at the cursor, the cursor and an erase move by whole runes, and
`cursor` answers a column so a caret lands on a cell. A keyboard key with no
character -- an arrow, a function key -- is still dropped, being a rune in
Plan 9's private space and not text. `servers/intuition` delivers the cooked
line as its bytes, not its runes (the byte-truncation bug that hid while only
ASCII was stored). The window line discipline's self-test types `café`, steps
a left arrow over the accent as one rune, and erases it whole.

**So the font past ASCII is whole through the tree**: the kernel console and
panic screen, the draw server's titles, `sys/libmui` labels, the terminal's
output and its typed line all read `/lib/font` and draw or store runes.
`docs/WEB.md` step 1, the reader of the world's pages, has the text stack it
was waiting on.

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
window is the shape that would make it fork. It paid 4 MB per window at
that moment while `fork_segments` copied a run eagerly; it copies on write
now, `docs/PROCS.md` step 2.

### Processes and threads, done

`docs/PROCS.md`, written before its code, and closed in four steps: a
request answered later, copy on write, `rendezvous` and its kin, and
`libthread`. `docs/THREAD.md` is the last step's document. What it leaves
open is small and named there: a note handler in the library, so a proc
other than the first can end the program; a guard page under a thread's
stack; and the kernel change that would let a proc of threads read its
own pipe.

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

The one-core flake is closed, and it was not one. A sweep of sixty boots at
`--smp=4` found six distinct one-in-ten failures, and `docs/TESTING.md`
records the two rules they taught: a heap bracket's opening reading waits for
every collector in the machine (`sched.all_reaped`, `user.settled`, and
`settle` in the user suite), and a check waits for the outcome it names
rather than a counter the handler bumps on the way in. The other four were a
script that stopped a child before its exec, a label read once instead of
polled, a terminal glyph read that has not recurred in sixty boots, and the
shootdown counter order. A failed drain and a failed label now say what they
saw, so the next one names itself.

The label miss was the ruler, not the pixels: the face poll returned the
moment a run of face appeared under a column, and the compositor paints a
window top down, so the band it froze could be the top of a button whose
label sat fifty rows lower. Five boots in two hundred read `55..90` and found
nothing amber there for four seconds while the whole button stood beneath.
The check measures the face again on every look now, and a miss prints the
column as runs of what each pixel is, which is what found it.

**Two kernel `#GP`s on kept machines, and what they most likely were.** On
two machines kept up for lldb after a failure, `ps` later took the kernel
down: once at `iretq` with every register zero on a dead program's kernel
stack, once inside `percpu_id` with the per-core self word's top bytes
overwritten. The first corpse read as a dead thread reaped twice; the second
showed core 0's idle thread marked dead on its own reap list, which only a
`cpu()` answering for the wrong core can do. Both machines had been walked
with an lldb script that *writes* vCPU 0's `rip`, `rsp` and `rbp` to unwind
parked threads, and a batch lldb exits without restoring them, so the guest
resumed vCPU 0 inside some parked thread's frame. That alone makes a core run
a thread that is not its `current`, which is every symptom seen. The walk
restores the registers now. The same recipe without the walk ran clean for
two hundred rounds of `ps` and forks, and the clobbering walk once did not
reproduce it either, so this is the leading explanation and not a proof.
What stays in the tree is worth having whatever the cause: `Thread.reaped`
and `sync.bug` checks in `kernel/sched` for a thread reaped twice, queued
dead, woken reaped, or exiting while the idle thread is `current`; and the
paranoid check `percpu.odin` had promised, a ring 0 trap arriving on the
program's GS base now swaps back and stops with its vector and address
rather than run every handler on another core's record.

Two one-offs seen once each in two hundred boots and not chased: the chord
test's `an alt-n the server does not know reaches the desktop, verbatim`,
and the terminal's `every one of them, before any newline says the line is
finished`, which now says what each cell held when it next fails. Both were
seen before the stale-wake fix above, and a lock two threads believed they
held is a plausible cause of either.

A third, on riscv64, seen once after the stale-wake fix: a load page fault
at address `0x4a` in `sched::unpark`, under `mutex_unlock` in
`wire_submit`, under `chan_close`. The self-test was done and `memfs` had
just been typed at the shell. A waiter record with no thread on it is the
shape. Not chased.

And one that is not a one-off: on riscv64 alone, three boots in seven end
the suite's heap bracket three objects short, `leaked 3`, with every check
of `tests/dbg.rc` held. amd64 and arm64 close the bracket every time. The
script is the last the suite runs, so anything an engine's proc or a
target's exit releases late lands in that reading. Not chased.

**The fork storm "hang" was a kernel page fault, and it is fixed.** A tight
fork storm from rc, four forks a turn on four cores, stopped the boot once
in twenty with no line to say where. It was not a hang. The kernel panicked
at `take_best` in `kernel/sync/wait.odin`, and the report went to the panic
screen alone. Ring 3 holds the serial port once `eiafs` is up, so the
serial log ended at the command that provoked it.

The cause was a wake issued after `wait_lock` was released. A sleeper whose
condition came true unlinked itself, returned, and parked in a wire's
`Mutex`. The late `ready` then pulled it out of that lock with no handoff.
`docs/SYNC.md` has the account and the rule. Every waker now wakes under
the list lock, and a lock waiter checks it got the handoff. The reproducer
is the storm inside a backquote, four at once, typed at the shell of a `-s`
machine: it stopped the first boot before the fix and ran five boots clean
after it. Sixty plain boots on four cores and three arm64 boots followed,
all clean, where the sweep before it lost several in sixty.

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

A directory map: what lives where, and the document that says *why*. The
per-file detail rotted between sessions, so this stays at the directory
level -- section 3's table is the index into the reasoning, and `ls` plus a
package's own comment is the rest.

```
build.odin            The build system: compiles the kernel and every ring 3
                      program, links, stages the ESP, drives QEMU, and holds
                      the per-architecture table. `run`, `check`, `fleet`, `esp`.
boot/                 Limine config and the vendored UEFI binaries.
kernel/
  main.odin           kmain: Limine requests, the boot survey, and every
                      subsystem's bring-up in order. The boot self-tests are
                      the `verify_*.odin` files beside it and in each package.
  arch/               The architecture interface, bound three ways (amd64,
                      arm64, riscv64) with a `neutral/` core; the .S stubs and
                      the paging, GDT/IDT, APIC and MSR code live under amd64/.
                      docs/BOOT.md, docs/PORTS.md.
  mem/                PMM, VMM, heap, and a space per process. docs/MEMORY.md,
                      docs/SPACE.md.
  sched/  sync/       The scheduler, the switch, the tick; spinlocks, the
                      sleeping lock and the sleep queue. docs/SCHED.md,
                      docs/SYNC.md, docs/SMP.md.
  vfs/  mnt/  pipe/   The namespace, the 9P transport (tag pool, workers,
                      Tflush, the wire over bytes), and pipes whose posted end
                      becomes a server. docs/NAMESPACE.md, docs/TRANSPORT.md,
                      docs/PIPE.md.
  devfs/ srv/ env/    The kernel device trees: `#c` /dev, `#s` /srv, `#e` /env,
  procfs/             `#p` /proc. docs/DEVFS.md, SRV.md, ENV.md, PROC.md.
  user/               Ring 3: the syscall door, a process and its namespace,
                      rfork/exec/notes, and the per-process user. docs/USER.md.
  drivers/            kbd, mouse, uart, fb, console, virtio (blk, net, rng),
                      ether. docs/KBD.md, docs/MOUSE.md.
sys/                  The ~20 ring 3 libraries. libuser (the syscall wrappers
                      and heap), vectra9 (the wire), libthread + lib9p (threads,
                      channels, a parking server), libdraw + libpal + libmui
                      (the screen and the toolkit), libedit (the line
                      discipline), libnet + libndb (dial, the database),
                      libauth + libcrypto (the handshake and its primitives),
                      libtls (the TLS 1.3 client over core:crypto),
                      libregex, libfmt, libodin, libkbd, libkey, libfont,
                      libposix (docs/DEVTOOLS.md 7). docs/WEB.md.
servers/              A dozen ring 3 file servers: ramfs/memfs (heap trees),
                      consrv/kbdfs/eiafs (the console and its devices reborn in
                      ring 3), intuition (the draw server + compositor),
                      netfs/cs/dns (the network as files), fatfs/kfs (the ESP
                      and the writable disk), factotum (keys and the handshake).
apps/                 rc (the shell), terminal, filemgr, muidemo, tracker.
                      docs/RC.md, docs/DRAW.md, docs/WORKBENCH.md.
cmd/                  ~40 tools, one package and one binary each; the fleet's
                      srv/import/exportfs/listen and auth are here too.
                      docs/CMD.md; tests/tools.rc runs each once.
tests/                abitest and threadtest (the ABI and libthread from ring
                      3), plus the crypto and auth test programs; `tests/crypto`
                      proves `sys/libtls` end to end against a scripted server,
                      and `tests/tlssrv` + `tests/web.rc` prove `cmd/tlsclient`
                      against one on the machine's own stack.
scripts/fleet.py      Drives the two-machine bench: boots both, crosses a line,
                      imports a tree, refuses a stranger.
tools/                genfont.py (the baked font) and ste-lint.py (the
                      controlled-language checker `build.odin -- lint` runs).
docs/                 Section 3's table. Every "why" lives here.
```
