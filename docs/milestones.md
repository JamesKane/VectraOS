# Milestones

Where VectraOS stands against its milestones. What each milestone contains, and its exit test, are defined in [04 §5](04-bootstrap-toolchain.md#5-milestones-to-hello-world) (M1–M3) and [04 §6](04-bootstrap-toolchain.md#6-after-m3) (M4–M12); this file tracks progress against them. A step's commit is recorded in the commit after it (a commit cannot name its own hash).

Updated 2026-10-01.

## Summary

| Milestone | Status | Exit test |
|---|---|---|
| **M1** First light | Done (2026-09-30) | `tests/qemu/boot.ndb` passes on x86_64 and aarch64 |
| **M2** A shell in a namespace | Done (2026-10-01) | `tests/qemu/shell.ndb` passes on both |
| **M3** Mount the network | Done (2026-10-01) | `tests/qemu/mount.ndb` passes on both (against 10.0.2.100; see below) |
| M4 POSIX and debugging | In progress: step 1 done | — |
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

In progress. 04 §6 gives M4's content but no steps or exit test, so they are set here (decided 2026-10-01). The userland is sbase, and the POSIX shell dash, both vendored.

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
| 3c. libc: `fork` (the child reconnecting its namespace and console, reopening its files), `execve` (`posixd`'s `EXEC`: the same process in a new task), pipes over channels, descriptors and the working directory passed to children, `posix_spawn`'s file actions | Done | not yet committed |
| 3d. Signals: `sigaction`, `kill` through `posixd`, delivery by `thread_interrupt` to a libc trampoline, faults as `SIGSEGV` and the rest, `SIGCHLD` | To do | |
| 3e. A RAM file system for `/tmp`; `/dev/null`, `/dev/zero`, `/dev/urandom`; the POSIX namespace template (`/lib/ns/posix`) | To do | |
| 4. `ptyd`; sockets over `/net`; `poll` and `select`; the `posix` 9Px extension | To do | |
| 5. Lua, sbase and dash, vendored | To do | |
| 6. The `procfs` debug files, crash directories, `lib/vx-debug`, `dbg -c`, `/sys/clock`, `vx-prof` zones | To do | |

**Exit test (proposed):** a C program built against `vectra-musl` forks, execs, pipes and waits; a dash script and Lua run in the POSIX userland; `dbg -c` stops at a breakpoint and prints a backtrace; a crashing program leaves a crash directory.

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
| No loopback route | The guest cannot connect to itself, so `listen` is tested in the host tests and the 9P framework but not end to end in QEMU | M3 step 6, or when a test needs it |
| TCP: no SACK, no timestamps, out-of-order segments dropped; TIME_WAIT 10 s | Recovery from loss is slower than it could be | After M3 |
| x86_64's shootdown is tested only under TCG | KVM flushes a guest's TLB often enough to hide a missing shootdown, so the ktest check catches one only with `--tcg` (aarch64 always runs under TCG) | — |
| `vmo_clone` and `fork` copy at once | Correct, and charged as 01 §5 says, but a `fork` of a large process copies all of it; sharing pages until written can come behind the same call | When `fork` is slow enough to matter |
| No hardware watchpoints; no thread, image or exit events to a debugger yet | A debugger sees faults, breakpoints and steps only | M4 step 6 (the `procfs` debug files), M12 (watchpoints) |
| No threads in the POSIX personality: `clone` is `ENOSYS`, so `pthread_create` fails; the back end does not lock | Single-threaded C programs only | When a port needs threads (the kernel side exists: threads, futexes, the thread pointer) |
| No entropy for user space: `AT_RANDOM`, and so musl's stack guard and malloc's secret, come from the clock; `getrandom` is `ENOSYS` | Nothing secret can be made in user space | A kernel random source, before `keyd` (M8) |
| No wall clock: `CLOCK_REALTIME` counts from boot | Dates read as 1970 | An RTC driver or NTP over `netd` |
| No `as_protect`: `PROT_NONE` is mapped read-write and `mprotect` is `ENOSYS` | Guard pages do not fault; nothing else breaks (musl's malloc expects this) | When a port needs it (JITs, guard pages) |
| Signals, `fork`, `exec`, pipes and `wait` are `ENOSYS`; `kill` and `raise` on oneself end the process | — | M4 step 3 (`posixd`) |
| `O_APPEND` is not atomic; no `rename`, `link` or locks; `mmap` of a file is a private copy | — | M4 step 4 (the `posix` 9Px extension, `Tmap`) |
| musl and the builtins are built without CET-IBT or BTI, so programs against musl are not marked | Indirect-branch protection is off in them | With the kernel's enforcement of it in user space |
| Kernel messages after the console hand-off reach nowhere (`vx.kconsole` keeps them on the serial port): a scenario's `fail="killed"` cannot see a fault in a task svcd started | Such a crash shows only as a negative exit status | A debug-log object (01 §10) |
| `posixd` trusts the task handle a process connects with, and is not restarted; its table holds 64 processes | — | Trust: with capability tokens (M8) |
| A file's offset is not shared with a child: the child opens it again (and a forked child's open directory starts again from its first entry) | `(a; b) > f` from a forked shell interleaves wrongly | M4 step 4 (open-file descriptions in the server, the `posix` extension) |
| Pipes are channels of 4 KiB messages, not rings; a writer that finds the queue full polls | Throughput is modest | When a benchmark says so (01 §9 has rings) |
| A forked child does not reconnect a dialed (TCP) mount cleanly: it dials again, and the old connection's state is left behind | — | When a POSIX program needs one |
| AVX, SVE and SME fault | Code built for x86-64-v1 and armv8-a runs; code that needs AVX or SVE does not | When a port needs them (XSAVE; SVE's state) |
| FP/SIMD registers are not in `thread_state` or a `vx_exception` | A debugger cannot see them; an in-task handler (a signal handler, from step 3) must save them itself | M4 step 3 (signals), step 6 (`dbg`) |
| `task_mem_rw`'s first write to code copies the whole mapping | A breakpoint in a large binary costs its text's size once | When it matters |
| IOMMU in pass-through only (QEMU) | A device can reach any memory; a dead driver's device could write freed memory before `devmgr` turns off its bus mastering | M5 |
| `netd` restarting its driver session is not tested | | M3 |

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
