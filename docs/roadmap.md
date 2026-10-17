# Roadmap

Each milestone has exit criteria. A milestone is done when its criteria pass
under `vx ci` and every budget it introduces has a running check
(principle 13).

## Where things stand (2026-10-17)

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
    calling conventions in its LLVM. Until it does, rv64's QEMU suite is off in
    `vx test` and `vx ci` (the owner's call, 2026-10-17): it still builds,
    `vx test rv64` runs it, and its QEMU rows are experimental, last
    passing in full at d45240e.
  - Byte streams (item 6) are begun: the ring's byte-stream mode, stdio
    on it, FDIO, and rc with its commands. An audit against 9front
    (2026-10-16) found rc and the commands far from complete (item 6
    lists the gaps; `vx rc-oracle` checks rc against 9front's, D70).
    The pty runs on rings, and rc runs on one, sharing the terminal
    with the programs it runs; it is temporary, and goes in V3 (D77).
  - Begun: drivers (item 7, D74: todhchai's, ported, in five steps;
    7a, the AML interpreter, 7b, PCI over ECAM, and 7c, devmgr and the
    driver host with edu's interrupt and DMA through each IOMMU, and 7d,
    virtio, virtio-input and kbdfs's /dev/kbd and /dev/cons (D83, D84),
    done; their budgets come at V2's exit).
  - Done: the console and the plumber (item 8, D85).
  - Done: the environment as `/env` (item 6, D81).
  - Done: the manual (item 9, D86): guide's parser and renderer and
    the one directive reader, `vx man` and its check, `man`, `lookman`
    and `sig` on the device over bootfs's `/lib/man`, section 5 from
    idlc, the services' trees checked against their pages, and the
    backlog written (110 pages; `man/missing` holds only the pty,
    which goes in V3).
  - Exit: `cat /svc/*/status` run by rc passes (amd64, arm64), spawn →
    main is 79 µs (< 200 µs), and the first bench history is recorded
    (2026-10-16, cd3eb6d), and the services hold 3.7 MiB (< 32 MiB,
    `services.rss`), and the manual is written (D86).
- **V3** is under way, on the `v3` branch: notes and /proc done
  (2026-10-17). **V4 onward** are not started (V6's boards have research
  passes).

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
depends on. Board bring-up (V6) is attempted only once its dependencies
are in place: the bring-up link (V3, D15), Taisce on disk (V4) and the
desktop (V5), each finished in QEMU first (D76).

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
   amd64 the RTC's time). Left: arm64's PL031 and rv64's RTC. QEMU's
   virt ACPI tables list neither (todhchai's corpus, 2026-10-16), and on
   ACPI machines Linux reads them through UEFI's runtime GetTime, which
   croi never calls after ExitBootServices: their discovery is still to
   choose (a board rule, or a table of our own).
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
     shared with no one; croi has no note groups). 9front's unix rc has
     no rfork, so RcTests and launch-test check it, not the oracle.
     Its limits (a fork's `rfork n` is its own since, below): `F`
     leaves the streams open until their owners close them, and rc
     reading a terminal reads on; a
     sealed namespace with nothing in it reaches a child unsealed;
     notes as 9front's dotrap takes them, between commands: a note's
     function runs (its status stands, with the globals and $*), else an
     interrupt or quit abandons an interactive rc's line (at a prompt,
     the line being typed) and any other ends rc; `sigexit` where 9front
     runs it (at `exit`, at the end of input, under `-e`, where a true
     sigexit lets rc go on), once, not in a fork, not after `exec` or a
     note, and not inherited (rcmain's `fn sigexit`); `exit` in a
     subshell, backquote or pipeline stage ends only that (it ended rc).
     rcport takes Linux's signals as notes, so the oracle checks them;
     on the device the pty is their source (^C sigint, ^\\ sigquit, the
     terminal's going sighup, a `hangup` event in its Control, version
     2), rc killing the programs that have the terminal before it takes
     the note. Their limits: croi has no notes between processes, so
     nothing else can send rc one (no `kill`, no alarm), and a
     foreground program that doesn't have the terminal isn't killed by
     ^C; a hangup races the end of rc's stdin, so sighup may not
     run; /bin in the namespace (D71): Node's `memory` (version 3) gives
     a file as a VMO, to run if its server allows, the bootfs service
     (`services/bootfs`, every arch) serves the boot image as a tree, a
     manifest mounts its bin/ at /bin (`mount /bin bootfs/bin`), and rc
     starts what its namespace holds, needing a job and no bootfs (an rc
     it starts too); `ls /bin` lists it for any program, and `rfork N`
     takes it away. launch-test lists /bin and starts rc from it; `$apid`
     a background job's own number (a program's process koid, a forked
     compound's thread koid; on Linux a pid), `wait PID` waiting for that
     job and taking its status (one rc didn't start, or waited for
     already: nothing), a bare `wait` leaving the status as it was, and a
     compound's job its status (it was always true); where 9front forks (a
     backquote, a subshell, a pipeline's earlier stages, `&`, `<{}`), a
     copy of rc on a fork of its system: its variables, functions, flags
     and directory its own (they leaked into rc, and a `cd` in a background
     compound moved rc), its namespace shared until it does `rfork n`, as
     a Plan 9 fork's, while a pipeline's last stage runs in rc (what it
     sets stays; its `exit` or error is rc's, which a stage contained);
     on the device each rc keeps its own directory and namespace and gives
     FDIO absolute paths (FDIO.open takes a namespace), and `/` with
     nothing mounted there is a directory (`cd /` failed); `-e` as 9front
     compiles it, per line read and per function as defined, so `flag e
     +` reaches the next line, not the rest of its own.
   - **rc(1) as the audit read it:** nothing named is left; what's left
     is the pty's and the missing commands, below.
   - **Commands, as 9front's (2026-10-16):** ls, cat, mkdir, rm, mv, cp
     and touch each take 9front's flags (any other a usage message), say
     its messages in Plan 9's words (`file does not exist: 'f'`), and
     stream their output; ls lists as 9front's (no `/` without -F, a
     named directory's entries under its name, -l's columns, -dnpqQrstu);
     cat stops at the first file it can't open; rm -f, cp -x, mv's rename
     within a directory and its copy elsewhere; touch sets an existing
     file's time (-c, -t). Exit strings (D72): a page in a child's
     Startup that td_exits writes, so `$status` is Plan 9's wait message
     (`ls 1234: errors`), and rc ends with its status. Node's `wstat`
     (D73, version 4) renames, times and cuts. CommandsTests checks each
     against 9front's source; launch-test, the exit strings on the
     device. Left out, as Node has none: modes, owners and access times
     (ls -l shows `d-rwxr-xr-x`, `--rw-r--r--`, owner `none`).
   - **Commands still missing:** `test`, `read`, `grep`, `sed`, `wc`,
     `sort`, `tail`, `tr`, `sleep`, `kill`, `ps`, `date`, `ns`, `bind`,
     `mount`. `ps`, `kill` and `ns` are Plan 9's, over `/proc` (V3, D79);
     `date` reads `/dev/time` (D79).
   - **The environment as `/env` (D81), done (2026-10-16):** the launcher
     serves a tree per environment group, each service's made from its
     manifest's `env` lines and mounted at its `/env`, and `use env`
     grants `/svc/env/new` for more. rc stores variables as Plan 9's rc
     does (NUL-separated lists, `/env/'fn#NAME'`), its programs sharing
     its group, `rfork e` copying it and `E` starting an empty one.
     Sys's Startup carries no environment, and the Unix port's ^A
     encoding stays on Linux (the oracle's). Tier 1's getenv reads
     `/env`. Left: tier 1's `environ`, which isn't built from `/env`.
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
7. **Drivers (D74):** todhchai's, lifted and ported to V1's ABI
   (`object_bind`, acks in arrays) and the one ring, with real IOMMUs,
   ACPI platform devices beside PCI ones, and the runtime's MMIO
   accessors. In order:
   - **7a, the AML interpreter, done (2026-10-16):** todhchai's
     bus/acpi (`drivers/bus/acpi`, TDACPI, about 4,900 lines with tests)
     lifted, with its corpus tool (`vx acpi fetch-qemu|import|list`,
     `.cache/acpi`): ACPITests' 54 hosted, over QEMU 11.1.2's tables for
     q35, pc, microvm and arm64 and rv64 virt, with its fuzzer; its
     corpus floors set from QEMU's tables alone (todhchai's counted this
     machine's too, which `sudo vx acpi import` adds). Natively,
     `bin/acpi-test` (boot-acpi, every arch) loads the boot's own tables
     from the boot data, runs load-time code, initializes the devices and
     decodes a PCI host bridge's `_CRS` and `_PRT`, and on amd64 `\_S5`
     and the CMOS clock's ports. Moved to 7c: userboot's `\_S5` byte scan
     (Power.swift) goes when devmgr owns the namespace (userboot stays
     the kernel's small first process), and the interpreter's budgets
     (todhchai's acpi-bench) come with devmgr, where it runs for real.
   - **7b, PCI over ECAM, done (2026-10-16):** todhchai's bus/pci
     (`drivers/bus/pci`, PCI) lifted: configuration space, enumeration
     across bridges, BARs sized with decoding off and restored, capability
     lists, all bounded against firmware loops; its ECAM through the
     runtime's accessors, now `croi/mmio.h` (module CroiMMIO, 8-64 bits,
     which `runtime.h` includes and the host's tests import) instead of
     `_Volatile`. PCITests' 6 hosted, over a model and q35's MCFG.
     Natively, `bin/pci-test` (boot-pci, every arch) maps the MCFG's
     window from the boot's tables (its base is bus 0's, so the buses
     start `startBus` MiB in, which todhchai's devmgr didn't add) and
     finds the host bridge, edu (its 1 MiB BAR, MSI), virtio-blk and
     virtio-rng (vendor capabilities, MSI-X, 64-bit BARs), rv64's IOMMU,
     and the same again on a second pass. For 7c: mapping all 256 buses'
     window takes 145 ms under arm64 TCG, so devmgr maps the buses it
     walks; QEMU's virtio devices are transitional (1af4:1001, 1005), so
     a modern-only transport (7d) takes them by their modern capabilities
     or QEMU gives `disable-legacy=on`.
   - **7c, devmgr and the driver host, done but for its budgets
     (2026-10-17):** todhchai's devmgr (`drivers/devmgr`: bin/devmgr and
     DevMgr) and driver host (`drivers/host`, DriverHost) lifted and
     ported, with `bin/edu` (`drivers/test/edu`). devmgr reads the boot
     data's tables, loads ACPI's namespace with its regions over the
     machine, enumerates PCI over ECAM (each bus's 1 MiB mapped as it is
     walked: `ECAMWindows`), routes INTx through `_PRT`, lists ACPI's
     present devices with their `_CRS` (amd64's CMOS clock, PNP0B00, among
     them, unbound: the time service has its ports) and matches bootfs's
     `etc/drivers` (every `driver.manifest`, collected by CMake) in
     todhchai's order, its parser on bytes for tier 0. It names each IOMMU
     the tables describe to the kernel (TDACPI's DMAR, IVRS, IORT and
     RIMT; DevMgr's IOMMUs.swift builds iommu_create's descriptors; Sys
     gains `DMA.iommu`), and a device's BTI comes from the first unit that
     covers it, narrowed to its `dma-bits`; the stub only where none does,
     which its status says. Each host starts through devmgr's own
     Launcher (which gains `extraStartupHandles`) with its BARs or `_CRS`
     ranges, configuration space, interrupt, MSI allocation and BTI as
     `CROI_PA_DEVICE` handles; it waits on its interrupt through a bound
     port (`InterruptPort`) and reaches registers through `Registers` over
     `croi_mmio_*`. devmgr serves its tree at once (status, iommus,
     enumeration, acpi, drivers/SERVICE) and ends its status with `bound
     N`. edu proves its registers, configuration space and confinement to
     its BAR, 100 INTx interrupts, and 4 KiB of DMA there and back through
     PinnedMemory at an I/O address of its IOMMU: VT-d, SMMUv3 and the
     RISC-V IOMMU (launch-test's devmgr checks, every arch; DevMgrTests'
     11 hosted, over q35's DMAR and IVRS, arm64's IORT and tables built
     for an INCLUDE_PCI_ALL unit, reserved memory and a PCIe RISC-V
     IOMMU). Found on the way, a kernel bug: pmt_unpin dropped the PMT's
     BTI before closing its handle, whose close takes the BTI's lock, so
     a driver that closed its BTI first panicked the kernel (fixed, with
     the `dma` suite; docs/kernel/design/drivers.md). Not done, and why:
     - The budgets moved here from 7a (todhchai's acpi-bench: loading the
       DSDT, `_STA` across every device). devmgr reports both in its
       `acpi` node; `vx bench` boots m2, not the launcher, so a `budget`
       line from devmgr would have no running check. The owner's call
       (2026-10-17): budgets come at the milestone's exit, once the
       components are in place, not step by step, so these come with
       V2's exit, when the bench boots the launcher.
     - userboot's `\_S5` byte scan stays: userboot powers off after every
       service, devmgr too, has ended, so it can't ask devmgr. It goes
       with the service that holds the power resource and serves
       `/dev/reboot` (V3, D79), which evaluates `\_S5`.
     - D74's BTI window: devmgr narrows the address width alone; a
       window comes with a device that needs one.
     - VT-d scopes behind bridges (the kernel refuses them) and SMMUv1/v2
       (their stream match pairs are a board's) give no BTI yet; the HPET's
       `_INI` fails on q35 (the kernel keeps its page), as todhchai's did
       without regions.
   - **7d, the virtio library and virtio-input, done (2026-10-17):**
     todhchai's virtio library (`drivers/virtio/lib`, Virtio: the modern
     transport, split queues, the devices' configurations) and
     virtio-input lifted; VirtioTests' 6 hosted, byte-identical (with
     virtio-blk's request format, `drivers/block/virtio-blk/lib`, which
     their model drives). Split queues fence with `croi_dma_barrier`
     (croi/mmio.h: arm64's `dmb osh`, rv64's `fence iorw, iorw`) between a
     slot and the index that publishes it, before notifying, and after
     reading the device's index. The transport accepts ACCESS_PLATFORM and
     virtio-input refuses a device without it: QEMU's virtio bypasses the
     IOMMU unless `iommu_platform=on`, taking a driver's I/O addresses as
     physical (found here: the queue read and wrote whatever lay at them).
     The input class, after D82, D83 and D84: keyboards push HID usages
     to kbdfs's `kbin` (`drivers/input/lib`: evdev's codes to usages for
     virtio-input; devmgr mounts kbin into each input host's namespace),
     and kbdfs (`services/kbdfs`, ours after 9front's kbdfs(8), D4) serves
     `/dev/kbd` (`k`, `K`, `c`), `/dev/cons` and `/dev/consctl` (cooked
     lines with ^H, ^W, ^U and ^D, `rawon`), `/dev/kbmap` (by usage, 9front's
     layers but the escaped ones, a US map built in), `kbin` and `kbdin`
     (KbdfsTests' 6 hosted); its reads wait until there are keys, Node's
     streams with calls held by the server (D84, StreamTests). devmgr's
     tree has `dev` for the classes' directories, which manifests mount
     after kbdfs at `/dev`. QEMU has `virtio-keyboard-pci` at slot 0x11 on
     every arch, and qemu.sh types for the guest: a console line `qemu:
     sendkey KEYS` sends them through the monitor (now open in every test
     run, its socket's path kept short; its output read from a descriptor
     of its own, as bash dropped the coproc's after a monitor command on
     rv64). launch-test types `h i ret` and reads "hi\n" from `/dev/cons`,
     then `a` and reads `ka`, `ca`, `K` from `/dev/kbd`: through MSI-X on
     amd64 and arm64, INTx on rv64's PLIC. The first version's typed
     `InputDeviceIPC`, its evdev slots and `open`, went. Not yet: mice
     (the mouse service, V5), kbdfs's compose sequences, the `c` repeat
     and Kdel's interrupt note (notes, V3).
   - **7e, the console's input, done in kbdfs (2026-10-17):** virtio-input's
     keys reach `/dev/cons` with no pty (D83); the console that shows it
     is item 8's.
   **Exit:** on every arch devmgr binds edu and virtio-input, a key
   injected through QEMU's monitor reaches a reader of the input class,
   and edu's DMA goes through the IOMMU. Met (2026-10-17): launch-test checks all
   three on every arch. Not here: virtio-mmio, legacy
   virtio and 0xCF8 access (nothing here needs them); the block class
   (TDBR) moves to the one ring with virtio-blk and Taisce (V3), the net
   class (TDFR) with N1 (V3).
8. **Services and the shell, done (2026-10-17):** the console, the
   plumber, the pty (done, with item 6; temporary: it goes in V3, D77, once
   cpu's session serves `/dev/cons` too: services/pty/README.md), and rc
   and `cat` (item 6). kbdfs serves `/dev/cons` for the keyboard (D83).
   - **The console** (`services/console`, todhchai's, ported): the GOP
     framebuffer from the boot data, the system log read from the
     debuglog's ring (D38) as an OVERWRITE reader waiting on its counter,
     a `write` leaf and `screen` read back; manifests gain `debuglog`, which
     grants the ring and its doorbell. Its font is Spleen, third-party
     data under its own licence with its PROVENANCE (D4 covers code that
     runs), checked against fontgen's table (ConsoleTests). Radharc's
     handoff comes with Radharc (V5). launch-test mounts it at
     `/mnt/console` (not /svc, whose `cat /svc/*/status` its growing
     status would race) and finds a line it logged on the screen.
   - **The plumber** (`services/plumber`, D85): plumber(4)'s `send`,
     `rules` and port files at `/mnt/plumb`, plumb(6)'s messages,
     todhchai's rules engine and regexp (ported to bytes for tier 0, with
     `plumb client` beside `plumb start`); each channel open on a port its
     own copy, through Node's per-channel streams, and a port's read
     waiting (D84). launch-test sends a URL to web's reader, is refused a
     message no rule takes, and appends a rule whose `plumb client` starts
     `cat`, which reads the held message onto the console.
9. **The manual (D86),** in five steps, done (2026-10-17):
   - 9a, **done (2026-10-17).** `system/guide`: the guide parser and its
     text renderer (Swift, tier 0 and host), host tests and a fuzz test;
     `system/directives`, the one directive reader, onto which the
     launcher's and devmgr's manifests moved; `vx loc`'s 1,500-line
     ceiling for it. The body's `@node` and `@guide` lines are
     directives too (D86's amendment).
   - 9b, **done (2026-10-17).** `vx man TITLE` and `vx man --check` (in
     `vx ci`, after the builds), the index (`vx man --index`, TSV), and
     `man/missing` holding everything V0 to V2 left undocumented: 638
     rows (programs, `vx`'s commands and the host tools, the 91
     syscalls, Sys's public declarations, libc's functions, the
     protocols, services, drivers and formats). First pages:
     `guide(6)`, `manifest(6)`, `driver(6)`, `vx-man(1)` and the eight
     `intro` pages. `man(1)` comes with `man` itself, in 9c.
   - 9c, **done (2026-10-17).** `man`, `lookman` and `sig` on the
     device, in the shell's commands (tier 1); bootfs carries
     `lib/man/` and its index, launch-test's manifest mounts it at
     `/lib/man`, and rc runs `man` and `lookman` there in boot-launch.
     The commands' usage messages are generated from their pages
     (`shell/commands/lib/Usage.swift`, `vx man --usage`, kept in step
     by `vx man --check`). Pages: `man(1)`, and `ls`, `cat`, `mkdir`,
     `rm`, `mv`, `cp` and `touch`. `vx mkbootfs` now stores identical
     files once, so the commands' ten names share one binary: the boot
     image fell from 185 to 95 MB on amd64 (arm64's had grown past what
     its memory suite allows at rest).
   - 9d, **done (2026-10-17).** idlc writes section 5's pages
     (`--man-out man/5`), in place of its Markdown, with the protocols'
     `///` comments as their prose: `node(5)`, `srv-board(5)` and pty's
     three. boot-launch checks the services' trees against their pages:
     a FILES path under `/svc/SERVICE/` claims a file, every claimed file
     exists, and a claimed service's files are all documented (D86's
     note). `launcher(8)` is the first such page.
   - 9e, **done (2026-10-17).** The backlog written, in six reviewed
     waves (rc, Sys, the services with devmgr and virtio-input, the
     dev-machine tools and three formats, the C library, the 91
     syscalls): 623 rows out of `man/missing`, 110 pages in all.
     `man/missing` holds only the pty's two rows, which go with the
     pty in V3 (D77).

**Exit:**
- `cat /svc/*/status` works, run by rc in a native test. **Done**
  (boot-launch, amd64 and arm64; rv64 when tier 1 is).
- The first boot budget history is recorded (`vx bench --record`, on a
  quiet machine), on the kernel as V1 left it (D17). **Done**
  (2026-10-16, cd3eb6d, load 1.1). Accepted in the open: the self-tests'
  boot, 4.3 s against V0's 2.4 s, since the self-tests have grown since
  (+18% interleaved against ae7d84e alone, a 4.1-5.5 s spread). It
  recorded `ring.per_1000_slots` at 27.8 µs against its 10 µs limit and
  `ring.kicks` at 11 against 0: a regression since D43 (5.7 µs, 0),
  bisected to af28d2e, from which every user program linked the libc's
  byte-at-a-time memcpy, which each ring slot goes through. Fixed, the
  limits unchanged: memcpy, memmove and memset go a word at a time (7.1
  µs, 0 kicks, round trip 201 to 146 ns).
- spawn → main < 200 µs. **Done** (79 µs recorded; 68-133 µs
  interleaved).
- Services RSS < 32 MiB. **Done** (`services.rss`, 2026-10-16, 2e1ea8d:
  3.7 MiB on amd64, 3.5 MiB on arm64). Each service with what it started
  (its job's tree), private bytes plus its share of shared pages, from
  the launcher's `memory`, judged by vx bench's services boot. Accepted
  in the open with it: the self-tests' boot again (4.3 s against a
  median still holding V0's 2.4 s), and `port.wake_p99`, 14.7 µs against
  9.1 µs (+61%; within its rule in the run before, and a p99 with a wide
  spread), open: to check interleaved and fix if it is real.
- `man man` prints its page from bootfs, `vx man --check` passes under
  `vx ci`, and `man/missing` lists only what V0 to V2 left (D86).
  **Done** (2026-10-17): it lists only the pty, which V3 removes.
- An interactive console (virtio-input into the console's `/dev/cons`)
  if it comes cheaply; otherwise V3's cpu session is the first
  interactive rc.

## V3. Bring-up link (D15, D77)

A shell, file copies and log streaming from the dev machine, plus booting
a new kernel without the USB stick, all through one Plan 9 cpu session
(D77). All of it works in QEMU first, on all three arches, so the board
meets a tested path.

- **Network:** lift todhchai's N1 work: crypto, `services/net`'s stack
  (Ethernet, ARP, IPv4/IPv6, DHCP, TCP), the net driver class and
  virtio-net. Not its sshd or SFTP (D77), and not NetRing or `NetIPC`
  (D79): the stack serves Plan 9's `/net` (`/net/tcp/clone`, per
  connection `ctl`, `data`, `listen`, `local`, `remote`, `status`;
  `/net/udp`, `/net/ipifc`, `/net/iproute`), `data`'s bulk on the one
  ring through Node's `attach` (D67), and `/net/cs` and `/net/dns` for
  names; Sys gains `dial("tcp!host!port")`, `announce`, `listen` and
  `accept`. The net class serves `/net/etherN` (D82), which the stack
  opens.
- **9gate's core, from V7:** the 9P2000 codec (D78: Plan 9's dialect,
  string owners, our extensions negotiated as `9P2000.vx`), export and
  import, over Noise IK (`Noise_IK_25519_ChaChaPoly_SHA256`, on N1's
  crypto). Linux `v9fs` conformance, the extensions themselves and the
  swarm stay V7's.
- **factotum** (todhchai's keyring, D75) holds the node's Noise IK
  static key (`proto=noise-ik`), made on first use; neither 9gate nor
  cpu holds it.
- **cpu:** the node's cpu server, and `vx cpu NODE [-c CMD]` on the dev
  machine (Swift, in vx; tested against the server in `swift test`).
  The client exports the dev machine's tree, which rc on the node sees
  at `/mnt/term`, with its `/dev/cons` over the node's: the dev terminal
  stays in cooked mode and edits lines, and there is no pty on either
  side.
  - Off unless the image is built with `vx boot --cpu PUBKEY`.
  - Listens on-link only; only the pinned dev machine's key.
  - A test checks that a normal image has no listener.
- **Notes between processes** in croi, so the terminal's interrupt
  reaches rc (and its foreground program) as a note, as cpu forwards it.
  Programs post them through `/proc` (D79): a proc service serves
  `/proc/N/{status,ctl,note,notepg,ns,fd,args,wait}` from the kernel's
  info topics and process handles, the kernel's side a right on a
  process handle (the ceiling holds). `ps`, `kill` and `ns` are Plan
  9's over it, and `notepg` gives rc's `rfork` its note groups.
  - **Done (2026-10-17):** notes in the kernel (D87: a queue of five on
    each process, posted and taken as a property under a NOTE right, an
    untaken note killing), Sys's `Note`, the proc service (`jobs`
    grants it the launcher's job; status, args, ctl's kill, note and
    notepg, a note group a job), `ps` and `kill`, rc taking its notes
    as 9front's notifyf does, and `rfork s` a new job. Pages: note(2),
    proc(4), ps(1), kill(1). Left: `ns`, `fd`, `wait`, `stop` and
    `start` (a process's namespace and descriptors are its own, and the
    kernel keeps neither its children nor its start time), and `ns` the
    command with them.
- **The pty goes** (D77): with cpu's session and the console both serving
  `/dev/cons`, nothing needs it; `services/pty`, rc's terminal relay and
  `CROI_PA_PTY_CONTROL` are removed (services/pty/README.md).
- **Files:** copies land in Taisce on a RAM-backed block device. Lifting
  Taisce's service here means bring-up uses the one file system, not a
  second RAM-only one (D8). Durability on disk is V4's.
- **Push and run** (todhchai N1e): the launcher finds programs in a
  writable `/dev/bin` over bootfs's `bin`, so `vx cpu board -c 'cp
  /mnt/term/PATH/prog /dev/bin && restart prog'` runs a new build
  without a reboot; `restart` writes `restart prog` to
  `/svc/launcher/ctl` (D79).
- **Board tools, rc scripts over ctl files (D79):** `log -f` (`cat
  /dev/kprint`), `ps`, `kill`, `restart`, `trace`, `poweroff`, `reboot`
  and `warmboot`; `/dev/reboot`, served over `SYSTEM_POWERCTL` by the
  service holding the power resource, takes `reboot`, `poweroff` and
  `warmboot KERNEL BOOTFS`.
- **Warm boot:** `warmboot /mnt/term/PATH/kernel.elf
  /mnt/term/PATH/bootfs.img`, in a cpu session, writes the line to
  `/dev/reboot`, which hands off to a new kernel and bootfs held in
  memory. No firmware, no stick.
  - The kernel reuses the loader's ELF, page-table and handoff code
    (`lib/elf`, `lib/pagetables`, `lib/handoff`): it parks the other CPUs,
    builds a handoff from the one it booted with, and enters the new
    kernel as the loader would.
  - It goes through `SYSTEM_POWERCTL` as a new command, so no new syscall
    and the ceiling holds.
  - `vx remote boot HOST` does the session and the call in one step.

- **The manual (D86):** V3's pieces arrive with their pages (`cpu(1)`,
  `net(3)`, `proc(4)`, 9P2000's messages in section 5, the board tools),
  and the pty's two rows leave `man/missing` with the pty.

**Exit, in QEMU on amd64, arm64 and rv64, under `vx ci`:**
- `vx cpu` gives rc with the dev terminal's `/dev/cons`, and ^C
  interrupts its foreground program.
- A program copied from `/mnt/term` to `/dev/bin`, then run.
- `log -f` streams while a test runs.
- `vx remote boot` round-trips to a new kernel and is back on cpu.
- No listener without `--cpu`.
- No pty in the tree.
- `kill` over `/proc` ends a program, and `ps` and `ns` read it.
- A cpu session dials out through the terminal's `/net`, bound from
  `/mnt/term/net` (D79).
- The bring-up budgets are green.
- `man/missing` is empty: every program, call, protocol, tree and format
  through V3 has a page, and "fully documented" stays an exit criterion
  of every milestone after. `man rc` and the check pass meet D86's
  budgets.

## V4. Taisce on disk

- Taisce's volumes on virtio-blk, through the block class's
  `/dev/sdXX/data` and its partitions (D82; V3 lifted the service on a
  RAM disk).
  NVMe comes with each board (V6, V6c), since the boards now follow
  (D76).
- Attributes, indices and live queries over the Node protocol.
- Crash, shadow-model and query fuzzers run in CI.
- Taisce's pages (`taisce(4)`, its query language in section 6); the
  manual installed on a volume, bound over bootfs's `/lib/man`.

**Exit:** the file budgets are green, and the crash harness passes every
write prefix.

## V5. Desktop

- Radharc, Tracker and Deskbar, from simplefb or GOP up to virtio-gpu.
- `tile` and `space` workspace modes, switchable live with both arrangements
  kept. Spatial Tracker.
- The Platinum Indigo look (D24), after the
  [desktop storyboard](https://claude.ai/artifact/BcQQLDod1qqmgwVzabeTPX)
  ([sources](design/storyboard/)).
- SDK, with a reference app in ≤ 12 calls.
- **rio (D75):** todhchai's Terminal ported as rio's text window inside
  Radharc: each window serves its programs' `/dev/cons`, `/dev/consctl`
  and `wctl`, edits their input itself (hold mode, `rawon`), and plumbs
  a selection from its directory. `TerminalCore` becomes `vt`, a program
  in a window for tier 1 programs that want xterm. The pty is gone by
  then (V3, D77).
- **The manual as hypertext (D86):** a guide viewer in Radharc with
  AmigaGuide's Contents, Index, Retrace and Browse, its links live and
  never running anything; the plumber's rule for `name(N)` (D85) opens a
  page from any window.
- In QEMU only (D76): GOP or ramfb, then virtio-gpu. The desktop on a
  board comes with the board (V6).

**Exit:**
- The desktop budgets are green on QEMU.
- The mode-switch budget is green.
- rc runs in a rio window with no pty and no escape sequences; `vt`
  in one runs a tier 1 program that wants xterm.

## V6. Orange Pi 6 Plus (CIX Sky1)

The first board (D69, replacing D5's Q8B). Attempted only once V0 to V5
are done (D76), so the board meets Taisce and the desktop already
tested in QEMU. The board work then starts with V3's link, so every later step
is a rebuild and `vx remote boot`, not a stick and a walk. Its facts are
in `docs/boards/orangepi-6-plus/`.

1. **Console first:** the loader and kernel print through COM2, the
   PL011 that DBG2 names (there is no SPCR), as `boot-dbg2-console` does
   in QEMU. A 3.3 V USB-serial adapter on the 10-pin debug header: pin 1
   TX, pin 3 RX, pin 5 GND. The first boot reads the ID registers, which
   settles D53's crypto question.
2. **The platform:** GICv3 with ITS (and erratum 2941627, if this GIC
   revision has it), SMP across three core tiers (D68's kernel half
   lands before V6, in QEMU), and PCIe through the generic ACPI host.
   Boot with `croi.watchdog=off` until a board rule selects the SBSA
   watchdog's `WOR` refresh, and leave the two SMMUv3 as firmware set
   them until a board rule takes them over with the IORT's RMRs (board
   rules are handoff v4).
3. **Ethernet:** an RTL8126 driver in the net class, written for the
   Realtek RTL8125/8126 family, which V6c, brimstone and the Orange Pi 5
   Plus also use.
4. **The V3 link on the board:** `vx cpu`, a copy from `/mnt/term`,
   `log -f` and `vx remote boot` against the Orange Pi 6 Plus.
5. **Then the rest:** NVMe, with Taisce's volumes on it (V4's), the
   board rules (the watchdog's refresh, the SMMU takeover), a GOP
   framebuffer text console, and USB for HID. The GPU's first probe
   follows AbyssBSD's power-up order exactly: a wrong order costs an
   SError and a power cycle.
6. **The desktop on the board** (V5's): on the GOP framebuffer until the
   board's own display path, which D69 reorders in its own entry
   (Adreno 690 was planned for V5 while the Q8B was the first board,
   ADR-0019).

`firmware/README.md` lists each blob's provenance.

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the serial budget scrape.
- Orange Pi 6 Plus power-on → console, and warm-boot turnaround, are
  within budget.
- Taisce's crash harness passes on NVMe, and the desktop budgets are
  green on the board.
- The Orange Pi 6 Plus and its required components are experimental in
  `docs/hardware/support.tsv` (D66).

## V6b. Orange Pi RV2 (rv64)

The rv64 board (D51), after V6's board (D69) and on the same V3 link.
Its facts are in `docs/boards/orangepi-rv2/`. It starts once the
firmware path (D51's open question) is decided and rv64 builds and tests
against RVA22 in QEMU (`-cpu rva22s64`).

1. **Console first:** the loader and kernel print through UART0, a
   16550-style UART at `0xd401_7000` with 32-bit registers 4 bytes apart.
2. **The platform:** 8 harts through SBI HSM, the PLIC, the SBI timer,
   and DMA within each bus's window, with no IOMMU.
3. **Ethernet:** a K1 EMAC driver in the net class (RGMII, Motorcomm
   PHYs), whose bus reaches only the first 4 GiB of DRAM.
4. **The V3 link on the board,** as for V6's.
5. **Then the rest:** eMMC and microSD (SDHCI, below 2 GiB), PCIe with a
   DesignWare MSI backend, USB 3 for HID, and the P1 PMIC's reset.

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the serial budget scrape.
- RV2 power-on → console, and warm-boot turnaround, are within budget.
- The RV2 and its required components are experimental in
  `docs/hardware/support.tsv` (D66).

## V6c. The AMD tower (amd64)

amd64's first board (D69): the Ryzen 9 7900X tower, after V6b and on
the same V3 link and Realtek driver. Its facts are in
`docs/boards/pc-7900x/`. It boots from a USB stick only, when the owner
frees the machine; its disks hold other work.

1. **Console first:** the board has no serial port (no SPCR, DBG2 or
   16550), so the console is a GOP framebuffer text console (V6's item
   5), or a PCIe serial card whose address the loader is told.
2. **The platform:** xAPIC as firmware leaves it, the LAPIC one-shot
   timer (no TSC-deadline on AMD), and AMD-Vi with interrupt remapping:
   croi's K12b, tested so far only in QEMU.
3. **Ethernet:** the RTL8125, through V6's Realtek family driver.
4. **The V3 link on the board,** as for V6's.
5. **Then the rest:** NVMe (Taisce's volumes, as V6's) and xHCI for HID. The Radeon 610M (RDNA 2)
   waits for D62's desktop track.

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the console budget
  scrape.
- Power-on → console, and warm-boot turnaround, are within budget.
- The tower and its required components are experimental in
  `docs/hardware/support.tsv` (D66).

## V7. Edge: 9gate and the swarm

- 9gate toward Linux and 9front, on V3's 9P2000 core and Noise IK (D77,
  D78): 9front mounts an export unchanged, and Linux `v9fs` mounts it as
  9P2000, the translator speaking `.L` only where `v9fs`'s conformance
  needs it (which messages, decided here).
- VectraOS↔VectraOS extensions for attributes, queries, leases and ring
  bridging, negotiated as `9P2000.vx` (D78).
- Swarm node roles and `/swarm/pool`.
- **cpu between VectraOS nodes** (D75), on V3's server (D77): `cpu -h
  NODE` from a node's terminal, the remote rc's text that window's, and
  each node's identity its factotum's Noise IK key.

**Exit:**
- Linux `v9fs` mounts a VectraOS export and passes conformance.
- A PC mounts the Orange Pi 6 Plus's `/dev`.
- `cpu -h` from one VectraOS node to another gives rc with the
  terminal's `/dev/cons`, authenticated through both nodes' factotums,
  with no pty on either side.
- The LAN budgets are green.

## V8. Compute

- **The Q8B's bring-up first** (D69: it moved here from the first board's milestone, since the CDSP
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
- WASI over nodes and rings, a guest ABI under D80's rule: mapped onto
  Plan 9's interfaces, its shapes in nothing native.
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
   - **Left:** push and run (N1e). sshd on croi (d4) and rc on a pty (d5)
     are no longer needed: V3's link is cpu (D77).
   - **Open there:** a decision on where a headless boot's key lives (now
     its Noise IK static key, D77), because the native keyring needs
     Radharc for its prompt. D75 settles
     the prompt (a headless factotum asks no one and makes the key on
     first use); where keys persist across boots waits for V4.

   V3 lifts crypto, the stack, the net class and virtio-net from a pinned
   commit of that branch; IMPORTS.tsv records the commit.
3. **`trace.probe_enabled` rose from 18 to 21 ns under KVM, accepted
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
2. ~~The shell~~: todhchai's rc, because V3's cpu sessions run it (D15, D77).
3. A dedicated transport for remote ring bridging, versus 9P reads and
   writes (V7).
4. Whether the CDSP accepts unsigned first-party Hexagon code on the Q8B's
   firmware. Check AbyssBSD's `npu/` notes before V8.
5. `space` mode: is it plain free placement with spatial memory, or also a
   pannable, zoomable canvas larger than the screen? Decided in V5 against a
   reference workflow.
6. A hardware watchdog on V6's board, so that a hang becomes a reboot
   into the stick's known-good kernel instead of a walk. The Orange Pi 6
   Plus has an SBSA watchdog in its GTDT that refreshes only through
   `WOR` (D69): a board rule selects it. Whether the Q8B's firmware
   exposes WDAT or an SBSA watchdog is checked in V8.
7. UEFI network boot (todhchai N1f), for recovering from a kernel that
   won't come up at all. Not chosen for V3 (D15); revisit if V6's hangs
   are frequent.
