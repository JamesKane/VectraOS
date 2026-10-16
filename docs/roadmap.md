# Roadmap

Each milestone has exit criteria. A milestone is done when its criteria pass
under `vx ci` and every budget it introduces has a running check
(principle 13).

## Where things stand (2026-10-16)

- **V0** is done (2026-10-15).
- **V1**'s work is done: the cuts (91 syscalls, the audit's target), the
  batched hot calls, the one ring and RingCheck, ports as rings. Its
  budgets are judged by `vx bench`, advisory on this shared machine.
- **V2** is under way:
  - Done: the one ABI (item 1), the floor, Sys, libc, ld and the trace
    (item 2), and the control plane (item 4: IPC, Node with bulk rings,
    the launcher).
  - Done but for arm64's and rv64's RTCs: time (item 5).
  - Tier 1 (item 3) runs on amd64 and arm64, with tier 0's libraries,
    FDIO, rc and the commands built for it; rv64 waits for Swift's
    calling conventions in its LLVM.
  - Byte streams (item 6) are begun: the ring's byte-stream mode, stdio
    on it, FDIO, and rc with its commands. An audit against 9front
    (2026-10-16) found rc and the commands far from complete (item 6
    lists the gaps; `vx rc-oracle` checks rc against 9front's, D70).
    The pty runs on rings, and rc runs on one, sharing the terminal
    with the programs it runs.
  - Not started: drivers (item 7), and the console and the router
    (item 8).
  - Exit: `cat /svc/*/status` run by rc passes (amd64, arm64). Still
    open: spawn → main < 200 µs, and the first recorded bench history.
- **V3 onward** are not started (V4's boards have research passes).

## V0. Ground — done 2026-10-15

Goal: croi boots from this repository, and the measuring works from the
first commit.

- Lift croi's boot, kernel, lib, cmake, ld, userboot, vdso and usertest
  (provenance.md).
- Lift todhchai's bench `Judge` and `History`, the trace format, and the
  budget scrape. Port `td` to `vx` with `build`, `boot`, `test`, `bench`,
  `trace`, `ci` and `loc`.
- Write `CLAUDE.md` with the merged toolchain pitfalls.

**Exit:**
- `vx ci` builds and boots amd64, arm64 and rv64 in QEMU.
- croi's self-tests and usertest pass.
- The size budgets run.
- Boot budgets are reported but not recorded. Recording is deferred to V2
  (D17).

Milestones run in order. Each one puts in place what the next one
depends on. Board bring-up (V4) is attempted only once its dependencies
are in place, which includes the bring-up link (V3, D15).

## V1. Setup-engine kernel

The audit is done (`docs/syscall-audit.md`: 154 calls to 91; D18, D19).
The work, in order:
1. **Done (D20):** `object_bind` (batched, ONCE or PERSISTENT) and
   `port_wait` with a leeway, so that every cut has its replacement in
   place. 154 → 150 calls; `vx todhchai-check` retired.
2. **Done (91 calls):** the cuts, one commit per family. Each updates
   the family's design note, its tests, `zircon-divergences.md` and the
   ceiling, and adds a decision entry. A `usertest.c` test the cut touches moves to a Swift
   suite. Done: FIFOs, sockets and streams (D21, 135 calls); the channel
   `_etc` forms and the futex extras (D22, 129 calls); events, signals
   and the thread waits (D23, 123 calls); sleeps, timers and the counter
   waits (D25, 117 calls); clocks (D26, 111 calls); display timelines (D27,
   107 calls); debug_write and vmo_map (D28, 105 calls); interrupt_wait,
   interrupt_destroy and interrupt_trigger (D29, 102 calls);
   thread_raise_exception (D30, 101 calls); system_get_event (D31, 100
   calls); port_cancel_key, handle_close_many, handle_replace and
   test_report merged (D32–D35, 96 calls); vmo_get_size and process_info
   as info topics (D36, 94 calls); vmo_read and vmo_write (D37, 92
   calls); debuglog_read, the last, with item 5 (D38, 91 calls).
3. The batched forms of the hot calls (audit §3). Done: handle_duplicate
   (D39); port_queue, port_wait, counter_add and interrupt_ack (D40);
   channel_read and channel_write (D41); vmar_map, vmar_unmap and vmar_protect
   (D42).
4. **Done (D43):** the one ring (architecture §3) in Swift and as `ring.h`,
   with RingCheck, a model checker that runs both. Doorbells are counters.
5. **Done (D38, D44; 91 calls):** ports become rings (D19): a port made
   with CROI_PORT_RING delivers its packets into the one ring, drained
   with no syscall (D44); the debuglog is a read-only ring, in the ring's
   OVERWRITE mode, and debuglog_read is cut (D38).
6. **Closed (2026-10-15):** the `channel_call` < 1 µs open item. It is a
   hardware target; under KVM (about 1.3 µs) m2's 1.6 µs limit guards it.
   Reaching 1 µs needs fewer switches a call or a cheaper switch, not
   trimming (docs/kernel/roadmap.md, V1 item 6).

**Exit:**
- The kernel and IPC budgets are green.
- The syscall ceiling is published.
- `ring_kicks` = 0 under load.

## V2. Userland base

Lift todhchai's userland onto V1's kernel: about 30k lines, from n1 pinned
at `527ff94` (its driver core matches main; V3 lifts from the same pin).
It was written against croi's old ABI, so most of it is ported, not
lifted as is (`docs/syscall-audit.md` §4 maps each old mechanism to its
V1 form). The layout mirrors todhchai's: `system/`, `services/`,
`drivers/`, `shell/`. Every file lifted gets its IMPORTS.tsv row. The
work, in order:
1. **One ABI (D45).** todhchai has no croi headers: ten files hardcode
   syscall numbers and inline struct layouts, and several calls kept their
   numbers in V1 but now take arrays (handle_close, the VMAR calls,
   port_queue and port_wait, channel_read and channel_write), so old
   callers would build and fail quietly. Lifted code includes VectraOS's
   ABI headers instead. **Done:** statuses, rights and object types are
   in `object.h`, which the kernel, the suites, m2, userboot and
   usertest.c now use, and SysABI's `Values.swift` takes them from there.
   The kernel's literal enums are checked against it by `swift test`
   (AbiTests), and `vx loc --check` refuses device code that makes a call
   by number, or through `td_syscall6`.
2. **The floor and Sys** (`system/sys`, about 4k lines; libc, ld, trace).
   The floor (`_start`, heap, stdio, threads, the C ABI tier 1's runtime
   calls) and the `Sys` wrappers move to V1's calls. Each thread gets a
   port, kept by the floor: waits bind ONCE there, sleep is its
   `port_wait` deadline, join waits for TERMINATED. Events and eventpairs
   become counters; VMO reads and writes become mappings, through one
   bootfs helper instead of the boilerplate in eight programs; sizes and
   process info are info topics. The hosted test kernel (SysHost) follows
   the same model, so todhchai's hosted tests keep running. **Done:**
   the floor is the one user runtime (D49). It is lifted onto V1's
   calls, with a port per thread, and userboot, m2 and the suites run on
   it; croi's runtime is gone. Sys is lifted: SysABI's values are the
   headers', the native backend makes V1's calls (arrays where they take
   them), waits and thread starts go through the floor, and SysHost has
   V1's model (object_bind, counters as the one event), checked hosted
   by SysTests and natively by `bin/sys-test` (boot-sys). The native
   loader is userboot's, shared (`user/lib/loader`'s Program, Sys's
   Loader module): `Process.start` loads a bootfs program and hands it a
   Startup, its processargs with the names table kept (D65); sys-test
   starts itself as a child to check it. The libc is
   lifted: every user program links it (libc.a, its pthreads over the
   floor), `runtime.h` takes its headers, `swift test` compares it with
   glibc, and the `libc` suite checks it natively on each arch (which
   found the floor misplacing a static PIE's TLS image). ld is ported:
   dlopen loads bootfs's lib/ into an EXPORT_DYNAMIC program over croi's
   ELF and bootfs readers (todhchai's are dropped) and userboot's segment
   mapping, now shared (`user/lib/loader`); LdTests check the linker's
   core hosted on each machine's objects, and `bin/dl-test` (boot-dl) a C
   and a Swift library natively. The trace session is lifted, and with it
   the trace rings move onto the one ring (D50): the kernel's
   per-CPU rings and `Trace`'s per-thread ones are trace headers over
   OVERWRITE rings, written and read through Ring.swift; the format is
   version 2. `bin/trace-test` (boot-trace) records the kernel and
   itself, checks the flow they share, and exports both; `vx trace
   collect` (trace-collect) reassembles them from the console. Item 2
   is done.
3. **Tier 1 (D47).** The `*-vectraos` toolchain (todhchai's, renamed), built from the
   pinned Swift 6.4.0 and LLVM sources with its patch series, and tier 1's
   sysroot (libc, pthreads, libc++, the Swift runtime, FoundationEssentials).
   FDIO and rc need it. **Begun:** the series is lifted and renamed (`tools/toolchain`,
   D47 as amended), built from the pinned sources (LLVM, the Swift
   compiler, swift-driver; their smoke tests pass for all three
   triples), and tier 1 runs on croi on amd64 and arm64: compiler-rt's
   builtins (`build_builtins.sh`, ours on every machine, in place of
   Swift 6.4.0's prebuilt x86_64 archive), the sysroot (the floor, the
   libc, the ABI headers and the floor's modules), libc++, libc++abi
   and libunwind, the Swift runtime and standard library,
   FoundationEssentials (`build_foundation.sh`), and six boot tests
   (`user/tier1`: C, C++, full Swift, a library module, concurrency on
   croi's executors, and FoundationEssentials: Codable's JSON and
   property lists, URLs, dates, Decimal, UUIDs, ProcessInfo). Until fdio,
   the libc's file calls are weak and fail (`native/files.c`, as
   `remove` and `rename` were), so Foundation links without files.
   Left: rv64, whose LLVM has none of Swift's calling conventions (clang
   rejects `swiftcall`, which the runtime's C++ uses, and the backend has
   no guaranteed tail calls for `swifttailcc` nor Swift's registers;
   `tools/toolchain/riscv64.md` has upstream's state and the cost): a
   patch series and a Swift ABI for riscv64, then a rebuild, to decide
   (deferred, 2026-10-16: rv64 stays tier 0 until rc or FDIO needs it
   there); and FoundationEssentials' FileManager checks, which come back
   to `user/tier1/Foundation.swift` with fdio. Tier 0's libraries build for tier 1
   from the same sources (`croi_tier1_library` in `cmake/Tier1.cmake`:
   SysABI, Loader, Ring, Sys, LibSys, the trace, IPCWire, IPC with its
   macro, Node and Launch), and `bin/node-test-t1` is node-test as full
   Swift over them (boot-node-test-t1, amd64 and arm64): what FDIO and
   rc (item 6) are built on.
4. **The control plane** (`system/ipc`, `node`, `launch`). The dispatcher
   binds each channel once, PERSISTENT, and reads and replies in arrays.
   Node messages become batches (D18): a request is an array of
   operations, a later one may use an earlier one's result, and bulk
   `read`/`write` opens a ring. Userboot starts the launcher, which builds
   each process's `/svc`. **Done:** IPC is lifted (`system/ipc`,
   `docs/wire-format.md`, idlc) and passes hosted on V1's Sys: the
   tests pass counters where they passed events, and the C side
   (`td_wire.h`, idlc's headers) is on V1's calls, a call being one
   `channel_call` as in Swift. IPC runs natively
   on each arch: IPCWire and IPC are built into Sys (the macro's plugin
   from SwiftPM), and `bin/ipc-test` (boot-ipc) checks Echo's Swift and C
   clients against Swift servers on threads, Loud's composition, and the
   dispatcher serving three channels and a watched counter from one
   thread. The dispatcher binds each channel once, PERSISTENT, and drains
   it: a wakeup takes up to 64 packets, reads every ready channel in one
   `channel_read` array, and writes every reply and event in one
   `channel_write` array, round after round until each would block
   (Sys's `Channel.read` and `Channel.write` take the arrays, D41).
   Watches are PERSISTENT too, and `unwatch` runs on the dispatcher's
   thread, as `wake` does.
   The wire format gains unions (D54), and Node is lifted (`system/node`)
   as batches (D64): operations on a current node, the first failure
   ending the batch, at most one handle back, and a mount taking the
   rest of a batch; NodeTree, namespaces and /srv on top, checked hosted
   and natively (`bin/node-test`, boot-node). The launcher is lifted
   (`system/launch`), its core: manifests, a job and a process per
   service loaded from bootfs, restarts, and each process's namespace
   handed in its Startup, PA_NS_DIR handles named in processargs's
   names table (D65), with no Startup protocol; checked hosted
   (LaunchTests) and natively (boot-launch: `bin/launcher` runs bootfs's
   manifests until `bin/launch-test`, which reads every
   `/svc/*/status` and follows a restart, ends). Bulk reads and writes go on an SQ/CQ ring pair and a data
   VMO the client makes and attaches to a node (Node 2's `attach`, D67):
   NodeTree serves them, `NodeBulkChannel` is the client, checked hosted
   (BulkTests) and natively (node-test). The exit test passes (item 6's
   rc).
5. **Time (D48).** Clock objects are cut: the time service publishes UTC
   in a read-only seqlock page that the launcher hands every process at
   start. **Done but for two RTCs:** the page is `td_utc.h`'s (a seqlock
   over an offset from monotonic time and an error bound), which the
   floor maps at start (PA_VMO_UTC) so `clock_gettime(CLOCK_REALTIME)` is
   a read with no syscall; the launcher makes it with a backstop
   (2026-01-01) and gives a `clock` service a writable copy;
   `services/time` is ported and sets UTC from amd64's CMOS clock
   (RTCTests hosted; boot-launch checks every arch reads the page and
   amd64 the RTC's time). Left: arm64's PL031 and rv64's RTC, which
   need their ACPI discovery.
6. **Byte streams (D46).** stdio, `pipe()` and the pty move from sockets
   to the one ring in its byte-stream mode: one writer per ring, an end
   mark for end of input, and peer death from a channel's PEER_CLOSED.
   **Begun:** the ring's byte-stream mode, in Ring.swift and ring.h
   alike (any amount each way, the end mark after the last bytes, a
   hostile header breaking the ring), checked by RingCheck on both
   (a stream through two slots, about 200,000 states each; a relaxed
   publish caught), ByteStreamTests on the host (each implementation
   feeding the other across threads) and the `ring` suite on each arch.
   stdio is on it: a parent gives a child a ring per descriptor, each
   in a VMO of its own with a doorbell each way and a channel for its
   end (CROI_PA_STDIO, `td_stdio.h`, D46 as amended); the floor
   attaches them at start
   (`stdio.c`, over ring.h) and writes its lines, reads stdin and puts
   the end mark at exit through them, and Sys's `ChildStdio` is the
   parent's side. A process given none writes stdout to the debuglog as
   before. sys-test checks it (its child echoes 20 KB; a child whose
   parent goes sees its stdin end). FDIO is lifted (`system/fdio`,
   tier 1, with the fs protocol's client side, `services/fs`): POSIX's
   file calls over the namespace's Node trees, checked hosted over a
   NodeTree (FDIOTests) and natively through its C names
   (`bin/fdio-test`, amd64 and arm64); what needs the fs protocol waits
   for Taisce (V3), and the libc has no FILE streams over files yet.
   rc is lifted (`shell/rc`, tier 1) with its file commands
   (`shell/commands`, tier 1 with it): each child gets stdio of its own
   and rc's namespace in its Startup, rc relays between children's rings
   and its streams, and its pipes are channel pairs of its own; RcTests
   and CommandsTests (over a NodeTree) hosted, and boot-launch's
   launch-test runs `rc -c 'cat /svc/*/status'` (amd64 and arm64).
   **Audit against 9front (2026-10-16):** rc read against rc(1) and its
   source, and 100 scripts run through both it and 9front's rc (built
   for Linux): 61 match, 36 differ through the port, 3 through Linux.
   The scripts are a standing check now (D70: `vx rc-oracle`, in `vx ci`;
   `shell/rc/tests/oracle`, its `known.tsv` the gaps still open).
   About half of rc(1) works; the commands cover about 40% of 9front's
   options, and rc's base set of programs is about a quarter there.
   Left, the most-hit first:
   - **Fixed since (2026-10-16):** pipelines on the device (a relay
     now holds the pipe's end with rc; boot-launch runs a pipeline of
     programs), `>[n=m]` after `>f` (left to right, as 9front), and
     `cat` with no files reading stdin; here documents (`<<tag`, quoted
     or not, several on a line; boot-launch gives a program one);
     subscript ranges (`$x(n-m)`, `$x(n-)`, as 9front's subwords);
     `$status` one string (a pipeline's joined as 9front's concstatus),
     and `while` keeping its condition's; assignment chains (`x=1 y=2`
     global, `x=1 y=2 cmd` local to the command, a whole pipeline);
     `if not` after an inner `if`, and `if`/`for`/`while` bodies taking
     `|`, `&&` and `||` (9front's precedence); patterns in `~` and
     `switch` active only where written unquoted, their subjects joined;
     runtime errors stopping a script (contained where 9front forks: a
     backquote, a pipeline's builtin stage, a background job); globbing
     as 9front's globdir (dot files matched, a literal tail kept only if
     it exists, the matches sorted by bytes); `~`, `!` and `@` as word
     characters (keywords only alone at a command's start, as 9front's
     klook), and `@` subshells; `$0` and `$pid`, `for`'s variable local
     to the loop, `\`-newline inside a word, `cd`'s and `whatis`'s
     statuses and `whatis`'s forms (all but a function's body); scripts
     parsed and run a line at a time, so a syntax error stops one at its
     line; a `&` in a switch case (it hung the parser); `(` straight after
     a word and `=` outside an assignment refused, as 9front does; an
     assignment's name a word (`$a=v`); `builtin`; `whatis` printing a
     function as 9front's pcmd does; `&` on a compound command (a thread
     in a copy of rc's variables and functions), and a command after `&`
     on its line; programs found along `$path` (9front's searchpath, in
     rc: a system says only whether a path is a program), `rc FILE`,
     `#!` scripts (the system's, as exec's: on the device a nested rc
     gets a job and bootfs; untested there until a filesystem, V3), rc's
     exit code its status; redirection streams closed once their
     command is done; 9front's flags (`-e` as 9front compiles it: off in
     conditions, on in a function's body; `-x`, `-v`, `-s`, `-i`, `-I`,
     `-l`; the rest taken for `flag`), `flag`, `exec` (run, then exit:
     nothing can take rc's place), `.` along `$path` with `-q`, `$cflag`
     and `$rcname`, and the prompt only when interactive; the environment
     as 9front's unix rc keeps it (lists joined by ^A, functions as
     `#()fn name {...}`; taken at start, functions not with `-p`), one
     encoding for every system; `$$x` (a variable's name a word), `<>`,
     `<{}` and `>{}` (paths /dev/fd/N), `` `split{} ``, and a command's
     words evaluated with its redirections in place; on the device, a
     program given each of rc's descriptors, a ring each (D46, amended:
     its own stderr, fds above 2, `/dev/fd/N` in FDIO and cat);
     `rfork` as 9front's execrfork: `n` a clone of rc's namespace, `N` an
     empty one, `m` sealed (a Startup now carries the seal, PA_NS_DIR
     bit 15), `E` hiding from programs what was given and unchanged
     since (Plan 9's Updenv), `F` taking away every descriptor; `e`,
     `f` and `s` ask nothing (rc's environment and descriptors are
     shared with no one; notes are still missing). 9front's unix rc has
     no rfork, so RcTests and launch-test check it, not the oracle.
     Its limits: a namespace is the process's, so `rfork n` in a `&`
     block is rc's too (as `cd` is); `F` leaves the streams open until
     their owners close them, and rc reading a terminal reads on; a
     sealed namespace with nothing in it reaches a child unsealed.
   - **Wrong semantics:** a compound command run with `&` shares rc's
     directory (one per process), so a `cd` in it moves rc too, and its
     namespace (`rfork n` or `N`).
   - **Missing pieces:** notes (`sigint`, `sigexit`); a real
     `$apid`; `/bin` in the namespace (the device's rc alone sees
     bootfs's programs there).
   - **Commands:** nothing streams; unknown flags are ignored, not
     refused; statuses are `1`, not Plan 9's strings; `ls` adds `/` and
     has its own `-l` and multi-directory layout; `touch` doesn't update
     an existing file; `rm -f`, `cp -x`, `mv`'s fallback and most
     flags are missing; no `test`, `read`, `grep`, `sed`, `wc`, `sort`,
     `tail`, `tr`, `sleep`, `kill`, `ps`, `date`, `ns`, `bind`, `mount`.
   - **The pty, done (2026-10-16):** `services/pty` on rings (D46): a
     terminal opens one at /svc/pty/pty and gets its keys and screen
     as descriptors, the client end is a program's fds 0 to 2 and the
     pty's Control; todhchai's line discipline lifted, its server and
     protocol rewritten. rc started with a pty's Control
     (CROI_PA_PTY_CONTROL) is its controller: one thread reads the
     terminal and lends it to the foreground program; ^D ends that
     program's input (rc's own when none has it), ^C kills it.
     launch-test types to a pty and to rc on one. Left: input typed
     while a program has the terminal is that program's, read or not.
7. **Drivers:** PCI, ACPI (the AML interpreter), devmgr, the driver host,
   the virtio library and virtio-input. Each driver binds its interrupt
   with `object_bind` and acks in arrays. The block class's ring (TDBR)
   moves to the one ring when virtio-blk comes with Taisce (V3); the net
   class's (TDFR) with N1 (V3).
8. **Services and the shell:** the console (it reads the debuglog ring,
   D38; the Radharc handoff waits for V6), the router (plumber), the pty
   (done, with item 6),
   rc and `cat`.

**Exit:**
- `cat /svc/*/status` works, run by rc in a native test. **Done**
  (boot-launch, amd64 and arm64; rv64 when tier 1 is).
- The first boot budget history is recorded (`vx bench --record`, on a
  quiet machine), on the kernel as V1 left it (D17).
- spawn → main < 200 µs.
- Services RSS < 32 MiB.
- An interactive console (virtio-input into a pty in the console) if it
  comes cheaply; otherwise V3's SSH session is the first interactive rc.

## V3. Bring-up link (D15)

A shell, file copies and log streaming from the dev machine, plus booting
a new kernel without the USB stick. All of it works in QEMU first, on all
three arches, so the board meets a tested path.

- **Network:** lift todhchai's N1 work: crypto, `services/net` (Ethernet,
  ARP, IPv4/IPv6, DHCP, TCP over NetRing), the net driver class and
  virtio-net.
- **SSH:** lift `services/sshd` (transport, public-key auth, `exec`,
  `shell` through rc on a pty, SFTP v3) and the keyring that holds the host
  key.
  - Off unless the image is built with `vx boot --ssh [PUBKEY]`.
  - Listens on-link only; public keys only.
  - A test checks that a normal image has no listener.
- **Files:** copies land in Taisce on a RAM-backed block device. Lifting
  Taisce's service here means bring-up uses the one file system, not a
  second RAM-only one (D8). Durability on disk is V5's.
- **Push and run** (todhchai N1e): the launcher finds programs in a
  writable `/dev/bin` over bootfs's `bin`, so `scp prog board:/dev/bin/ &&
  ssh board restart prog` runs a new build without a reboot.
- **Board tools:** `log -f` (the debuglog, streamed), `ps`, `kill`,
  `restart`, `trace`, `poweroff`, `reboot`.
- **Warm boot:** `ssh board warmboot kernel.elf bootfs.img` hands off to a
  new kernel and bootfs held in memory. No firmware, no stick.
  - The kernel reuses the loader's ELF, page-table and handoff code
    (`lib/elf`, `lib/pagetables`, `lib/handoff`): it parks the other CPUs,
    builds a handoff from the one it booted with, and enters the new
    kernel as the loader would.
  - It goes through `SYSTEM_POWERCTL` as a new command, so no new syscall
    and the ceiling holds.
  - `vx remote boot HOST` does the copy and the call in one step.

**Exit, in QEMU on amd64, arm64 and rv64, under `vx ci`:**
- `ssh` gives rc.
- `scp` of a program to `/dev/bin`, then run it.
- `log -f` streams while a test runs.
- `vx remote boot` round-trips to a new kernel and is back on SSH.
- No listener without `--ssh`.
- The bring-up budgets are green.

## V4. Orange Pi 6 Plus (CIX Sky1)

The first board (D69, replacing D5's Q8B). Attempted only once V0 to V3
are done. The board work then starts with V3's link, so every later step
is a rebuild and `vx remote boot`, not a stick and a walk. Its facts are
in `docs/boards/orangepi-6-plus/`.

1. **Console first:** the loader and kernel print through COM2, the
   PL011 that DBG2 names (there is no SPCR), as `boot-dbg2-console` does
   in QEMU. A 3.3 V USB-serial adapter on the 10-pin debug header: pin 1
   TX, pin 3 RX, pin 5 GND. The first boot reads the ID registers, which
   settles D53's crypto question.
2. **The platform:** GICv3 with ITS (and erratum 2941627, if this GIC
   revision has it), SMP across three core tiers (D68's kernel half
   lands before V4, in QEMU), and PCIe through the generic ACPI host.
   Boot with `croi.watchdog=off` until a board rule selects the SBSA
   watchdog's `WOR` refresh, and leave the two SMMUv3 as firmware set
   them until a board rule takes them over with the IORT's RMRs (board
   rules are handoff v4).
3. **Ethernet:** an RTL8126 driver in the net class, written for the
   Realtek RTL8125/8126 family, which V4c, brimstone and the Orange Pi 5
   Plus also use.
4. **The V3 link on the board:** `ssh`, `scp`, `log -f` and `vx remote
   boot` against the Orange Pi 6 Plus.
5. **Then the rest:** NVMe, the board rules (the watchdog's refresh, the
   SMMU takeover), a GOP framebuffer text console, and USB for HID. The
   GPU's first probe follows AbyssBSD's power-up order exactly: a wrong
   order costs an SError and a power cycle.

`firmware/README.md` lists each blob's provenance.

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the serial budget scrape.
- Orange Pi 6 Plus power-on → console, and warm-boot turnaround, are
  within budget.
- The Orange Pi 6 Plus and its required components are experimental in
  `docs/hardware/support.tsv` (D66).

## V4b. Orange Pi RV2 (rv64)

The rv64 board (D51), after V4's board (D69) and on the same V3 link.
Its facts are in `docs/boards/orangepi-rv2/`. It starts once the
firmware path (D51's open question) is decided and rv64 builds and tests
against RVA22 in QEMU (`-cpu rva22s64`).

1. **Console first:** the loader and kernel print through UART0, a
   16550-style UART at `0xd401_7000` with 32-bit registers 4 bytes apart.
2. **The platform:** 8 harts through SBI HSM, the PLIC, the SBI timer,
   and DMA within each bus's window, with no IOMMU.
3. **Ethernet:** a K1 EMAC driver in the net class (RGMII, Motorcomm
   PHYs), whose bus reaches only the first 4 GiB of DRAM.
4. **The V3 link on the board,** as for V4's.
5. **Then the rest:** eMMC and microSD (SDHCI, below 2 GiB), PCIe with a
   DesignWare MSI backend, USB 3 for HID, and the P1 PMIC's reset.

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the serial budget scrape.
- RV2 power-on → console, and warm-boot turnaround, are within budget.
- The RV2 and its required components are experimental in
  `docs/hardware/support.tsv` (D66).

## V4c. The AMD tower (amd64)

amd64's first board (D69): the Ryzen 9 7900X tower, after V4b and on
the same V3 link and Realtek driver. Its facts are in
`docs/boards/pc-7900x/`. It boots from a USB stick only, when the owner
frees the machine; its disks hold other work.

1. **Console first:** the board has no serial port (no SPCR, DBG2 or
   16550), so the console is a GOP framebuffer text console (V4's item
   5), or a PCIe serial card whose address the loader is told.
2. **The platform:** xAPIC as firmware leaves it, the LAPIC one-shot
   timer (no TSC-deadline on AMD), and AMD-Vi with interrupt remapping:
   croi's K12b, tested so far only in QEMU.
3. **Ethernet:** the RTL8125, through V4's Realtek family driver.
4. **The V3 link on the board,** as for V4's.
5. **Then the rest:** NVMe and xHCI for HID. The Radeon 610M (RDNA 2)
   waits for D62's desktop track.

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the console budget
  scrape.
- Power-on → console, and warm-boot turnaround, are within budget.
- The tower and its required components are experimental in
  `docs/hardware/support.tsv` (D66).

## V5. Taisce on disk

- Taisce's volumes on virtio-blk, then NVMe (V3 lifted the service on a
  RAM disk).
- Attributes, indices and live queries over the Node protocol.
- Crash, shadow-model and query fuzzers run in CI.

**Exit:** the file budgets are green, and the crash harness passes every
write prefix.

## V6. Desktop

- Radharc, Tracker and Deskbar, from simplefb or GOP up to virtio-gpu.
- `tile` and `space` workspace modes, switchable live with both arrangements
  kept. Spatial Tracker.
- The Platinum Indigo look (D24), after the
  [desktop storyboard](https://claude.ai/artifact/BcQQLDod1qqmgwVzabeTPX)
  ([sources](design/storyboard/)).
- SDK, with a reference app in ≤ 12 calls.
- Native display on the board: Adreno 690 was planned here (ADR-0019)
  while the Q8B was the first board. The board's own display path is
  reordered in its own entry (D69); until then V6 runs on the GOP
  framebuffer on the Orange Pi 6 Plus.

**Exit:**
- The desktop budgets are green on QEMU and on the Orange Pi 6 Plus.
- The mode-switch budget is green.

## V7. Edge: 9gate and the swarm

- 9P2000.L codec and translator, with export and import, on V3's stack.
- Noise IK transport, on V3's crypto.
- VectraOS↔VectraOS extensions for attributes, queries, leases and ring
  bridging.
- Swarm node roles and `/swarm/pool`.

**Exit:**
- Linux `v9fs` mounts a VectraOS export and passes conformance.
- A PC mounts the Orange Pi 6 Plus's `/dev`.
- The LAN budgets are green.

## V8. Compute

- **The Q8B's bring-up first** (D69: it moved here from V4, since the CDSP
  and the Adreno need it), on V3's link:
  - Console: the loader and kernel print through the GENI UART (SPCR
    interface type 0x13), a polled driver after AbyssBSD's
    `uart_dev_qcom_geni.c`, with a register-level model test, since QEMU
    has no GENI. It needs a 1.8 V USB-serial adapter on the 40-pin
    header: pin 6 GND, pin 8 TX (gpio63), pin 10 RX (gpio64). Never
    connect it to the 3-pin header by USB-C, which is 12–20 V power in.
  - The platform: GIC with ITS, SMP across the A78C and X1C clusters,
    PCIe segment 4 behind UEFI's TC9563 switch, and the SMMUv3 under the
    hypervisor's rules (AbyssBSD's `lessons.md`).
  - Ethernet: a TC956x driver (XGMAC2, XPCS, QCA8081 PHY) in the net
    class, after AbyssBSD's `tcx` driver and `ethernet-tc956x.md`, with
    the DMA address offset of `0x10_0000_0000`.
  - The V3 link on the board, then NVMe, `qcom-gcc` and USB for HID.
  - The Q8B and its required components become experimental in
    `docs/hardware/support.tsv` (D66).
- The `/dev/accel` protocol, `.vxm` artifacts, the `vxc` host compiler
  (ONNX/StableHLO → TOSA) and the CPU TOSA executor.
- The CDSP backend on the Q8B: a first-party FastRPC driver following
  AbyssBSD's NPU notes.
- Adreno Vulkan compute.

**Exit:**
- One `.vxm` runs on the CPU, the CDSP and Adreno, with results checked
  against the CPU reference.
- The camera → NPU → render path does 0 CPU pixel copies.

## V9. Wasm and games

- `wasmd`, interpreter first, then AOT through `vxc`.
- WASI over nodes and rings.
- A reference game: a frame-loop intent, input and audio rings, Vulkan.

**Exit:**
- A Wasm build of a small Bevy or Godot sample runs at its frame budget on
  the Orange Pi 6 Plus.

## Research tracks (unscheduled)

- CHERI-RISC-V on rv64 (QEMU-CHERI first).
- Halide-style algorithm/schedule split in VXCompute.
- hetIR-style checkpoint and migration of accelerator work across swarm
  nodes.
- RK3588, on the Orange Pi 5 Plus (on hand), and the Hailo-8 over M.2.
  Shipped with DT, but a community EDK2 gives it ACPI, so using that
  firmware needs a decision, not a DT path (`docs/boards/orangepi-5-plus/`).
- A stretch goal: the Mac mini (M4, base), from Asahi Linux's facts and
  reverse engineering. No UEFI or ACPI, 16 KiB DART pages, and Asahi is
  at early bring-up on the M4 (`docs/boards/macmini-m4/`).

## Known issues

1. ~~**The rv64 PMU self-test fails intermittently**~~ **Fixed 2026-10-15.**
   The test's definition of idle was wrong; the PMU code was fine. See
   `docs/kernel/design/user.md`, K6e. The original report follows. (Found
   2026-10-15, in V0's first `vx ci`.) `boot-smoke` panicked with `pmu self-test: overflow
   sampling`: overflows 57, samples 55, with frames 55, on idle CPUs 1
   (overflows 1). The next 4 runs passed, so it failed 1 time in about 6
   rv64 boots. `PmuSelfTest` counts any cycle sample on another CPU as
   "on an idle CPU". A background thread (`dlog-dumper`, `reclaim`) that
   runs during the sampling window may be enough to trip it. Not yet
   diagnosed. Fix before V0 exits, either in the kernel or in the test's
   definition of idle, with the reason written in
   `docs/kernel/design/cpu.md`.
2. **Status of todhchai's N1** (2026-10-15). It lives on its unmerged `n1`
   branch:
   - **Done:** crypto, the stack hosted and native, sshd hosted with SFTP,
     the net class, virtio-net.
   - **Left:** sshd on croi (d4), rc on a pty (d5), push and run (N1e).
   - **Open there:** a decision on where a headless boot's host key lives,
     because the native keyring needs Radharc for its prompt.

   V3 lifts from a pinned commit of that branch. It either waits for d4/d5
. **`trace.probe_enabled` rose from 18 to 21 ns under KVM, accepted
   (2026-10-16).** D50 put the trace rings on the one ring, whose
   OVERWRITE protocol costs each record a sequence mark, a release fence
   and the sequence's store besides the record and the cursor. `vx bench
   --compare 801b3f6` measured 21.0 ns against 18.0 ns in every one of 5
   interleaved runs; the limit stays 30 ns, met. A cheaper write (filling
   the slot in place instead of copying a built record, fewer checks of
   the CPU's writer) is worth trying before a probe-heavy budget needs it.

## Open questions

1. Host tests: SwiftPM plus CTest, as todhchai does, or CTest only (D11).
   Decided in V0.
2. ~~The shell~~: todhchai's rc, because V3's SSH sessions run it (D15).
3. A dedicated transport for remote ring bridging, versus 9P reads and
   writes (V7).
4. Whether the CDSP accepts unsigned first-party Hexagon code on the Q8B's
   firmware. Check AbyssBSD's `npu/` notes before V8.
5. `space` mode: is it plain free placement with spatial memory, or also a
   pannable, zoomable canvas larger than the screen? Decided in V6 against a
   reference workflow.
6. A hardware watchdog on V4's board, so that a hang becomes a reboot
   into the stick's known-good kernel instead of a walk. The Orange Pi 6
   Plus has an SBSA watchdog in its GTDT that refreshes only through
   `WOR` (D69): a board rule selects it. Whether the Q8B's firmware
   exposes WDAT or an SBSA watchdog is checked in V8.
7. UEFI network boot (todhchai N1f), for recovering from a kernel that
   won't come up at all. Not chosen for V3 (D15); revisit if V4's hangs
   are frequent.
