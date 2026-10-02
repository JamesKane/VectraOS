# Milestones

Where VectraOS stands against its milestones. What each milestone contains, and its exit test, are defined in [04 §5](04-bootstrap-toolchain.md#5-milestones-to-hello-world) (M1–M3) and [04 §6](04-bootstrap-toolchain.md#6-after-m3) (M4–M12); this file tracks progress against them. A step's commit is recorded in the commit after it (a commit cannot name its own hash).

Updated 2026-10-01.

## Summary

| Milestone | Status | Exit test |
|---|---|---|
| **M1** First light | Done (2026-09-30) | `tests/qemu/boot.ndb` passes on x86_64 and aarch64 |
| **M2** A shell in a namespace | Done (2026-10-01) | `tests/qemu/shell.ndb` passes on both |
| **M3** Mount the network | Done (2026-10-01) | `tests/qemu/mount.ndb` passes on both (against 10.0.2.100; see below) |
| M4 POSIX and debugging | In progress: steps 1–4d done | — |
| M5 Storage | Not started | |
| M6 Pixels | Not started | |
| M7 GPU | Not started | |
| M8 Swarm | Not started | |
| M9 AI | Not started | |
| M10 Self-hosting and T1 hardware | Not started | |
| M11 Audio | Not started | |
| M12 Debugger parity | Not started | |

First-party code is about 20.0 kLOC (`./build loc`), against 04 §5's estimate of 25–32 kLOC for M1–M3 together.

## M1 — First light

Done. The kernel boots through Limine on x86_64 and aarch64, reaches user space, and `svcd` runs the exit test's checks. SMP, the stretch goal, was done too.

| Commit | Step |
|---|---|
| `64014f7` | The build tool, the ABI tables, the kernel skeleton, Limine 12.9.1 vendored |
| `d0d5528` | Booting on both architectures; `image`, `qemu`, `test`, `vendor-check` |
| `e53a666` | Steps 1–3: exceptions, memory, time |
| `f40ef8e` | Steps 4–5: threads, ports, user space; the exit test passes |
| `735139e` | `build check`: host tests, the house format, clang-tidy |
| `521bda2` | SMP: every CPU online, with locking and cross-CPU wake-ups |

## M2 — A shell in a namespace

Done. `gsh` runs in a namespace served over 9Px rings, with `/proc`, pipes, and a console driver that can be killed from the shell and is restarted by `svcd`.

| Commit | Step |
|---|---|
| `c3bd4b0` | 1: kernel IPC (channels, `channel_call`, handle transfer) and the process lifecycle |
| `0fe786e` | 2: rings, `vx-ring`, and `vx-check` model-checking the wake-up protocol |
| `601e8aa` | 3: `vx-9p` (codec, client, server framework, hostile-client test) and the ndb writer |
| `371fbe1` | 4: spawn messages, `bootfs`, `vx-ns`, `svcd` spawning services |
| `cd8c025` | 5: the user-space UART drivers serving `/dev/cons` |
| `a451b44` | 6: `procfs`, `gsh` and the commands; the exit test passes |

## M3 — Mount the network

In progress.

| Step | Status | Commit |
|---|---|---|
| 1. ACPI tables, MSI (x86 vectors, aarch64 ITS LPIs), DMA domains, the PCI scan in `devmgr` | Done | `3c76692` |
| — A review of all the code to date, and its fixes; debug builds at `-O0` | Done | `917914b` |
| 2. The virtio-pci transport, `drv-virtio-net`, driver matching in `devmgr`, rendezvous posts in `svcd`; the aarch64 LPI fix | Done | `acf4107` |
| 3a. `vx-net` (Ethernet, ARP, IPv4, ICMP echo, UDP, DHCP), `netd` serving `/net` (`ipifc`, `icmp`, `udp`), `ping` | Done | `5ed5a2b` |
| 3b. TCP in `vx-net` (NewReno, window scaling) and `/net/tcp` with `listen` | Done | `3f536d0` |
| 3c. The DNS stub in `vx-net`, `/net/cs` and `/net/dns`, UDP `headers`, the `cs` command | Done | `94571ec` |
| 4. 9P over TCP (`lib/vx-ns/dial.c`), `mount tcp!host!port` and `9p://host:port` in `gsh`, dialed mounts inherited as `dial=` records | Done | `528b511` |
| 5a. `host/vx9pserve` (`--listen`, `--stdio`), confined with `openat` and `O_NOFOLLOW`; QEMU runs one per connection for tests | Done | `528b511` |
| 5b. Interoperability against `u9fs` (vendored as a host test tool, ADR-0006): attach as `vectra`, not `none`; other servers' error wordings understood | Done | `ec7b1ef` |
| 6. The exit test as a scenario, its write checked on the host (`host=`); `./build image --iso`: ISO 9660 with an El Torito UEFI entry, booted from a CD in the `iso` scenario | Done | `819c8c5` |

The exit test's steps all pass in `tests/qemu/mount.ndb`, with one difference: the server is at 10.0.2.100!5640, not the host's 10.0.2.2!5640, because QEMU will not forward the gateway's own address to a command. The exit test as written works by hand under `./build qemu`, with `vx9pserve --listen 127.0.0.1:5640 DIR` on the host. Booting a real UEFI PC from USB is not gated, and has not been tried.

## M4 — POSIX and debugging

In progress. 04 §6 gives M4's content but no steps or exit test, so they are set here (decided 2026-10-01). The userland is sbase, vendored. Vendoring dash, the POSIX shell, is deferred (2026-10-01): first `gsh` is remade as rc, with its commands, and dash comes only if that proves unable to fill the role.

| Step | Status | Commit |
|---|---|---|
| 1a. `as_unmap` with TLB shootdown; user-memory copies that recover from a fault; kernel stack guard pages; ring mappings unmapped when their sessions end | Done | `d3a4bf7` |
| 1b. The fault path: exception ports, faults handled in the task, `thread_interrupt` with `ERR_INTERRUPTED`, `thread_state`, `vmo_clone`, thread ids; futex words read through the user mapping | Done | `7c4f4df` |
| 1c. The `DEBUG` right: first-chance exception ports, `PASS` and `STEP` (single step on both architectures), `thread_suspend`/`thread_resume`, `task_mem_rw` with private copies of code for breakpoints | Done | `33739bc` |
| 2a. musl 1.2.6 vendored unchanged (ADR-0007), its generated headers committed | Done | `55df068` |
| 2b. Kernel: the thread pointer (x86_64's FS base, aarch64's `TPIDR_EL0`) kept per thread; `thread_state` `GET_TLS`/`SET_TLS`, for the caller itself or a stopped thread | Done | `e089716` |
| 2c. Kernel: FP/SIMD state (x87/SSE by FXSAVE; arm64 v0–v31, FPCR, FPSR) saved per thread; first-party programs no longer `-mgeneral-regs-only`; `thread_start` enters as if called | Done | `f225529` |
| 2d. The vx back end (files, directories, stdio, memory, time, the process), compiler-rt's builtins vendored (ADR-0008), `./build` building `libc.a` and the `vectra-musl` sysroot; `ctest`, a C program against it, runs (`posix`) | Done | `a5ef5bf` |
| 3a. Kernel: `task_create`'s `FORK`, a copy of the caller's memory and handle table (rings' and devices' memory left out, a handle to the caller becoming the child's) | Done | `f5f54eb` |
| 3b. `posixd`: the process table (pids, parents, process groups, sessions) and `wait`; the back end's `getpid`, `setpgid`, `setsid` and the rest from it; `posix_spawn` and `posix_spawnp` in the back end, registering each child before it runs | Done | `5353e4b` |
| 3c. libc: `fork` (the child reconnecting its namespace and console, reopening its files), `execve` (`posixd`'s `EXEC`: the same process in a new task), pipes over channels, descriptors and the working directory passed to children, `posix_spawn`'s file actions | Done | `7e09e6e` |
| 3d. Signals: `sigaction`, `sigprocmask`, `sigsuspend`, `kill` through `posixd`, delivery by `thread_interrupt` to a libc trampoline (deferred to the back end's return, `EINTR` or `SA_RESTART`), faults as `SIGSEGV` and the rest, `SIGCHLD`. Kernel: `thread_interrupt` queues eight; a call that ends without its reply takes back an unread request; an interrupt no longer overwrites a finished wait's result | Done | `8c9b8c2` |
| 3e. `tmpfs` (`/tmp`); `nullfs` (`/dev/null`, `zero`, `random`, `urandom`); the POSIX namespace template (`boot/ns/posix.ndb`, a manifest's `ns=posix`); entropy for user space: the bootloader's, from the kernel to svcd to whoever asks (`entropy=`), through `lib/vx-rand`'s generator; `getrandom` | Done | `b489831` |
| 4a. The `posix` and `xattr` 9Px extensions' 9P2000.L messages (`docs/proto/posix.md`): `Tgetattr`, `Tsetattr`, `Trenameat`, `Tsymlink`, `Treadlink`, `Tfsync`; in vx-9p's codec, server and client, `tmpfs`, and the back end (`rename`, symbolic links followed by the client, `chmod`, `truncate`, `utimensat`, `fsync`) | Done | `80a3704` |
| 4b. Open files kept by the server (`posix`): offsets and `O_APPEND` shared across `fork` and children by token (`Tshare`/`Tjoin`), `Tseek`, `Tdesc`; byte-range locks (`Tlock`, `Tgetlock`, `fcntl`) | Done | `2e4ef96` |
| 4c. `ptyd` (`/dev/ptmx`, `/dev/pts/N`, line discipline, `^C`/`^Z`/`^\` to the foreground group, ending held reads); termios and terminal ioctls in the back end; job control in `posixd` (stop by `thread_suspend`, `SIGCONT`, `WUNTRACED`/`WCONTINUED`). Kernel: an interrupted `channel_call` whose request the server has read waits for its reply; an early wake clears its token; `vx.hangdump=N` | Done | `f29d25a` |
| 4d. `poll`, `ppoll`, `select` and `pselect6` on the one port: pipes by their channels' triggers, files always ready, terminals and the console by a read kept outstanding on a connection of its own (vx-9p's asynchronous ring calls); pipe and terminal reads now end with `EINTR` | Done | `fb75b71` |
| — `O_CREAT\|O_EXCL` goes straight to `Tcreate`, which refuses a name that exists, so `O_TRUNC` no longer empties the file first; `O_EXCL` doesn't follow a link in the last component; `O_CREAT` opens a file another process made between its open and its create | Done | `aa3d40b` |
| 4e. Notes and exit strings (ADR-0010). Kernel: `task_kill` with a message, exit strings in `task_info` and the `EXIT` packet, trap exit strings, notes in `thread_interrupt`, a note with no handler ends the task. vx-rt: `vx_exit(msg)`, `vx_notify`, `vx_noted`. `svcd` and `gsh` keep the string. The back end: signals mapped from notes through one table, POSIX exit codes as strings. Native standard error: a `stderr` channel in the spawn message, taken by vx-rt and given by `gsh`, so errors stop going down pipes as data | Done | `5dda9f9` |
| 4f1. `task_exec` (ADR-0012): the kernel moves a scratch task's address space into the caller, which keeps its id; vx-rt's loader gains an exec mode; the back end's `execve` keeps its task and its pid (no `EXEC` remap, no false exit 0); descriptors still cross by token | Done | `877b66c` |
| 4f2. One process table (ADR-0011): `procfs` holds every process, pid = task id; registration at every spawn (vx-rt, `vx_proc_register`; `svcd` registers its services, each its own note group, and what it started before `procfs`); wait records for parents; `/proc/N/{status,ctl,note,notepg,noteid,ppid,wait}`; `proctest` (`tests/qemu/proc.ndb`) | Done | `c292e61` |
| 4f3. The back end and `ptyd` over `/proc` as APE does it (`note`, `notepg`, `noteid`, `ppid`, `wait`, `ctl`; `kill` as notes, `SIGKILL`/`SIGSTOP`/`SIGCONT` carried out by `procfs`, stops and continues as wait records, `SIGCHLD` by `ctl childnotes`); `posixd` removed; registration names a group or a session; `thread_suspend(0)` stops every thread; vx-9p's ring server: a server's own connection limit, and `again` to serve held requests once more | Done | `510e424` |
| 4g1. Mounts found by identity (ADR-0009, as 9front's `findmount`): resolution from the root, each `Twalk`'s qids checked against the mount points; binds onto any name join the same union; a union bound elsewhere copied; union create honouring `-c`; namespace(6): `newns`'s parser, `ns` output quoted, templates in `/lib/ns` (replacing `boot/ns/*.ndb`), `gsh`'s `mount /srv/NAME` | Done | `17931a2` |
| 4g2. Namespace groups (ADR-0009): `nsd` keeps each group's namespace(6) text and connectors, published read-only to its members, who replay it when its sequence moves and send their changes back; a spawn shares by default (`gsh`, the back end), `svcd`'s services have their own; a `fork` child joins on a channel of its own; `/proc/N/ns`; `proctest` checks a child's bind reaching its parent | Done | `ea1e7a0` |
| 4g3. Text is UTF-8 (ADR-0013): `lib/vx-utf` (Plan 9's rune functions, `vx_utf_valid`, `vx_utf_cut`, `vx_utf_back`), with host tests and a fuzz target, ndb on it; exit strings, notes and `$status` cut at rune boundaries (kernel `task_kill`, `vx_exit_str`, `vx_note_put`, `gsh`); names without control characters and with valid UTF-8 in vx-ns, vx-9p's server and vx-tar, `EILSEQ` in the back end; `ptyd`'s `IUTF8`, on by default, and the serial console erasing and killing whole runes; `gsh` variable names as rc's, and over-long lines refused; ctest checks of C.UTF-8; 00 §1, 03 §5.1 and ADR-0005 updated | Done | `cf0b492` |
| 4h1. Sockets over `/net`, as APE's (01 §9): `ports/musl/vx/socket.c` (`socket`, `bind`, `listen`, `accept`/`accept4`, `connect`, `getsockname`, `getpeername`, `sendto`/`recvfrom`, `sendmsg`/`recvmsg`, `shutdown`, the options programs set), a descriptor holding the conversation's `data`, reopened by path across `fork` and `exec`; UDP through `netd`'s headers; loopback in vx-net (127/8 and the interface's own address, forged 127/8 from the wire dropped); `announce 0` for TCP; `/net` in the POSIX namespace; ctest's socket checks | Done | `a2f26d9` |
| 4h2. Sockets that do not block: each socket's own connection to `netd` keeps one call outstanding (a read of `data`, an open of `listen`, or `connect`'s `ctl` write), so `poll`/`select` see sockets ready, `O_NONBLOCK` and `MSG_DONTWAIT` give `EAGAIN`, `connect` gives `EINPROGRESS` and later `SO_ERROR`, and waits end with `EINTR`; TCP data written without waiting goes behind, on a second connection; `MSG_PEEK`; `SIGPIPE` (sockets and pipes) unless `MSG_NOSIGNAL`; `netd` takes 64 connections | Done | |
| 5. Lua and sbase, vendored. dash is deferred until `gsh`, remade as rc with its commands, is shown unable to fill the role (decided 2026-10-01) | To do | |
| 6. The `procfs` debug files, crash directories, `lib/vx-debug`, `dbg -c`, `/sys/clock`, `vx-prof` zones | To do | |

**Exit test (proposed):** a C program built against `vectra-musl` forks, execs, pipes and waits; a shell script (`gsh` as rc; dash only if rc cannot fill the role) and Lua run in the POSIX userland; `dbg -c` stops at a breakpoint and prints a backtrace; a crashing program leaves a crash directory.

**Picking M4 back up** (paused 2026-10-01, after 4d):

- Next is step 5. Steps 4e–4h are done: the Plan 9 baseline, then sockets. Steps 4e–4g put the Plan 9 baseline back (00 §1, ADRs 0009–0012); each ADR lists what it changes. Done: 4e (notes and exit strings: `vx_main` returns an exit string, `vx_notify` is the note handler, the back end's signals are notes, `lib/vx-posix/posix.h` has the table), and 4f (`task_exec`; one process table in `procfs`, with 9front's `/proc` files, which the back end and `ptyd` use as APE does; `posixd` is gone).
- 4g3, text as UTF-8 (ADR-0013), is done: a name can no longer hold a newline, so namespace(6) text, which `nsd` publishes, replays exactly.
- 4h, sockets over `/net`, is done (4h1 blocking, 4h2 not blocking); `ports/musl/vx/socket.c`'s header says how they wait.
- Then step 5 (Lua and sbase, each vendored with an ADR; dash only if `gsh` remade as rc cannot fill the role) and step 6 (the debugger's pieces).
- The POSIX tests are `tests/posix/ctest.c` (309 checks) in `tests/qemu/posix.ndb`. Run the scenario several times on aarch64 after any change with timing in it: the races found in steps 3d and 4c showed only there.
- To debug a hang or a crash in a POSIX scenario, copy it with `cmdline="vx.skip=gsh vx.kconsole vx.hangdump=25"`: the kernel's messages stay on the serial line, and at 25 s every thread's state and kernel backtrace is printed.


## Known gaps

Deferred deliberately, each with where it is due:

| Gap | Effect now | Due |
|---|---|---|
| 9P replies always use arena offset 0 | Pipelined 9P requests would overwrite each other's replies; the client does not pipeline yet | With pipelining |
| No `Tflush` or timeouts in the 9P client | A read held by a server (`ping` with no reply, a `listen`) waits until it is answered | M3 step 4 or M4 |
| No per-client connection limit | One client can take all 16 of a server's ring connections | Before M8 (swarm) |
| DNS: A records only; no AAAA, no TCP fallback for truncated replies, no search domains | Names resolve to IPv4 only, from what fits in one UDP reply | With IPv6; when a name needs it |
| UDP `headers` mode is not exercised in QEMU | Only the code path through `vx-net` is tested (host tests); netd's header format is not | When a UDP service needs it |
| Each process dials its own TCP connection for a `tcp!` mount (a child cannot be handed one) | Every command in a mounted directory opens a connection, which then waits 10 s in TIME_WAIT; a fast script could use up `netd`'s 32 conversations | Before M8 (a shared 9P connection, through a post) |
| Sockets: IPv4 only, and no `AF_UNIX` | `socket(AF_INET6)` and `socketpair` give `EAFNOSUPPORT`; programs that talk to themselves through a Unix socket fail | `AF_UNIX` with `/srv`, as APE's; IPv6 with netd's |
| A TCP socket's `bind` port is used only by `listen` | `connect` from a bound port goes from a free one (`netd` has no `connect ADDR!PORT LPORT`) | When a program needs it |
| `getaddrinfo` does not use `/net/cs` | musl's resolver reads `/etc/resolv.conf` and `/etc/hosts`, which the POSIX namespace lacks, so names do not resolve; numeric addresses work | Step 5, with sbase (a served `/etc`, or `/net/dns`) |
| UDP datagrams are at most 16 KiB with netd's header | One Twrite or Rread carries a datagram; a bigger `sendto` is `EMSGSIZE`, and a bigger datagram arriving is cut | When 9Px `Tmap` or a larger msize comes |
| A socket's connections to `netd` | Each socket polled or read takes one ring connection (two, writing without waiting) of `netd`'s 64 | Pipelining in the 9P client, or a per-client limit (before M8) |
| TCP: no SACK, no timestamps, out-of-order segments dropped; TIME_WAIT 10 s | Recovery from loss is slower than it could be | After M3 |
| x86_64's shootdown is tested only under TCG | KVM flushes a guest's TLB often enough to hide a missing shootdown, so the ktest check catches one only with `--tcg` (aarch64 always runs under TCG) | — |
| `vmo_clone` and `fork` copy at once | Correct, and charged as 01 §5 says, but a `fork` of a large process copies all of it; sharing pages until written can come behind the same call | When `fork` is slow enough to matter |
| No hardware watchpoints; no thread, image or exit events to a debugger yet | A debugger sees faults, breakpoints and steps only | M4 step 6 (the `procfs` debug files), M12 (watchpoints) |
| No threads in the POSIX personality: `clone` is `ENOSYS`, so `pthread_create` fails; the back end does not lock | Single-threaded C programs only | When a port needs threads (the kernel side exists: threads, futexes, the thread pointer) |
| Entropy is the bootloader's only, seeded once: nothing is mixed in later (interrupt timing, the CPU's RNG instructions), and a service gets it only if its manifest says `entropy` | Enough for urandom's purposes; not a long-lived key store | Before `keyd` (M8) |
| No wall clock: `CLOCK_REALTIME` counts from boot | Dates read as 1970 | An RTC driver or NTP over `netd` |
| No `as_protect`: `PROT_NONE` is mapped read-write and `mprotect` is `ENOSYS` | Guard pages do not fault; nothing else breaks (musl's malloc expects this) | When a port needs it (JITs, guard pages) |
| `O_APPEND` is not atomic; no `rename`, `link` or locks; `mmap` of a file is a private copy | — | M4 step 4 (the `posix` 9Px extension, `Tmap`) |
| musl and the builtins are built without CET-IBT or BTI, so programs against musl are not marked | Indirect-branch protection is off in them | With the kernel's enforcement of it in user space |
| Kernel messages after the console hand-off reach nowhere (`vx.kconsole` keeps them on the serial port): a scenario's `fail="killed"` cannot see a fault in a task svcd started | Such a crash shows only as `svcd` reporting the task's exit string (`sys: trap: fault read addr=… pc=…`) | A debug-log object (01 §10) |
| `nsd` is not restarted, and keeps a group's text in 16 KiB; a member replays the whole text after any change; `gsh` has no `rfork n` (a copied group), and `newns` is not a command; namespace templates take only `mount /srv/NAME` and `bind` | A process whose group is too big to publish keeps its change to itself (`publish` fails) | After M4 |
| `procfs` is restarted by `svcd`, but its table is lost: `svcd` registers its services again, and every other process is gone from `/proc`; it holds 128 processes and 512 wait records. `ctl`'s `startstop`, `waitstop`, `hang` and `nohang`, and the `args` file, are not there yet; wait records have no CPU times | — | After M4 |
| `procfs` trusts the task handle and the parent a registration names; anyone with `/proc` may write any process's `note` and `ctl` | — | With capability tokens (M8) |
| A file's offset is shared with a child only on a server with `posix` (tmpfs); elsewhere (bootfs, u9fs) the child opens it again. A child that joins more than 10 s after its parent's last close finds nothing, and opens it again | — | When `fsd` comes (M5) |
| POSIX locks go only when the process's last descriptor of an open file closes, not any one of several `dup`s; no `flock`, no open-file-description locks | — | When a port needs them |
| Pipes are channels of 4 KiB messages, not rings; a writer that finds the queue full polls | Throughput is modest | When a benchmark says so (01 §9 has rings) |
| A forked child does not reconnect a dialed (TCP) mount cleanly: it dials again, and the old connection's state is left behind | — | When a POSIX program needs one |
| Signals: no alternate signal stack, no registers in a handler's `ucontext`, no `sigqueue` or real-time queueing; a 9P call (a file read, the console) is not interrupted, its handler runs when it is done (a note will flush it, ADR-0010, once the client has `Tflush`); `ptyd` ends its own held reads, but the console (the UART driver) does not | `Ctrl-C` at a blocked console read waits for Enter | When the console is a `ptyd` terminal |
| Job control is partial: no `SIGTTIN`/`SIGTTOU` for a background group's reads and writes, no controlling terminal kept per session; `ptyd` holds 16 terminals and is not restarted; the console has no termios | dash runs without job control on the console | When a shell on a `ptyd` terminal needs them |
| `tmpfs` holds 1024 nodes and 128 MiB, and is not restarted; no `rename`, links or permissions it enforces; namespace templates are applied by `svcd` (`ns=`) only, and only their `mount /srv/NAME` and `bind` lines, not by a program reading `/lib/ns` | — | `rename` with the `posix` extension (M4 step 4); the rest when needed |
| No `epoll` or `kqueue`; `poll` arms what it waits on each time (bindings are kept, not doubled); a polled terminal holds a connection of its own | — | When a port needs `epoll` (01 §9 has it on the same port) |
| AVX, SVE and SME fault | Code built for x86-64-v1 and armv8-a runs; code that needs AVX or SVE does not | When a port needs them (XSAVE; SVE's state) |
| FP/SIMD registers are not in `thread_state` or a `vx_exception` | A debugger cannot see them; the musl back end's signal entry saves them itself | M4 step 6 (`dbg`) |
| `task_mem_rw`'s first write to code copies the whole mapping | A breakpoint in a large binary costs its text's size once | When it matters |
| IOMMU in pass-through only (QEMU) | A device can reach any memory; a dead driver's device could write freed memory before `devmgr` turns off its bus mastering | M5 |
| `netd` restarting its driver session is not tested | | M3 |
| `gsh` is not rc: no `<`, `>>`, `&&`, `||`, `&`, blocks, `if`, `for`, `switch`, functions, lists or `cd`; at most 32 scalar variables | Scripts beyond a pipeline cannot run yet | Before dash is considered (step 5): `gsh` remade as rc, first-party C23 (04 §1) |
| `/srv` is not a file tree: posts come only from `post=` records in manifests, and `ls /srv` fails | A program cannot post a service at run time | After M4 |
| No `/dev/cons` or `consctl` in a namespace: the console is a handle given at spawn | A program cannot reopen the console by name; `cpu`'s `bind /mnt/term/dev/cons` has nothing to bind | After M4 |
| No `/env` (`envfs`), `/fd` or current directory for native programs | The environment exists only as spawn records; native paths must be absolute | After M4 |
| `Twstat` refused by every server and never sent by the client, which sends only `Tsetattr`/`Trenameat` | Rename, `chmod` and truncate fail both ways between VectraOS and 9front or `u9fs` | After M4 (map `Twstat` onto setattr/renameat in vx-9p; send it when `posix` is off) |
| `ORCLOSE`, `DMEXCL` and `DMAPPEND` dropped without an error: the server strips `ORCLOSE`, `tmpfs` masks `perm & 0777` | Remove-on-close, exclusive-use and append-only files silently don't work | After M4 (implement in `tmpfs`, refuse elsewhere) |
| The 9P client fails when a server answers `Tversion` with `unknown` (a 9P2000.L-only server); it does not ask again for `9P2000` | `diod`, virtfs and similar servers can't be mounted, though 02 §3.1 says they can | After M4 |

## Scenarios

`./build test` boots each of `tests/qemu/*.ndb` on both architectures; `--release` and `--tcg` run the same set.

| Scenario | What it checks |
|---|---|
| `boot` | M1's exit test: the kernel reaches `svcd`, which starts the console driver and `bootfs` |
| `panic` | A kernel fault reaches the panic handler, with a symbolized backtrace |
| `write-text`, `write-text-alias` | Kernel code is read-only (W^X), and through the direct map too |
| `lower-half` | The kernel's own page tables leave the lower half empty: a load near 0 faults |
| `phys` | The page allocator hands out and takes back a block of every order, and its count balances |
| `timer` | A 10 ms deadline wakes the idle kernel, never early |
| `smp` | Every CPU comes online, and all four use the page allocator at once without losing a block |
| `ktest` | The kernel's objects and syscalls from user space (`tests/kernel/ktest.c` as the root task): channels, ports, counters, futexes, threads, child tasks, devices |
| `ns` | A namespace built from a spawn message over ring connections to `bootfs`: mounts, binds, unions |
| `cons` | The user-space console: cooked lines, erase and kill-line, `^D`, output that overflows the driver's queue |
| `shell` | M2's exit test |
| `pci` | `devmgr` finds the PCI functions through ACPI |
| `net` | `drv-virtio-net`: a session, ARP to QEMU's gateway and back, the driver killed and restarted |
| `netd` | DHCP, `/net/ipifc/0/status` as M3's exit test reads it, `ping 10.0.2.2`, `cs` through `/net/cs` and `/net/dns` (a service name, `localhost` through QEMU's DNS proxy, NXDOMAIN) |
| `tcp` | TCP against QEMU's own stack: 256 KiB echoed through a host `cat`, hangup, a refused connection |
| `mount` | M3's exit test against `vx9pserve` at 10.0.2.100!5640: `mount`, `ls` and `cat` (children dialing their own), a write found on the host, `9p://`, `ns` |
| `iso` | The ISO, as a CD with no disk, boots to the shell |
| `stack-overflow` | A kernel stack that overflows hits its guard page, and the panic says so |
| `u9fs` | Interoperability: the same against `u9fs`, a stock 9P2000 server, chrooted in a user namespace |

Host tests (`tests/host/`, under ASan and UBSan) and fuzzers (`tests/fuzz/`) run in `./build check`.
