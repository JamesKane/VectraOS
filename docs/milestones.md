# Milestones

Where VectraOS stands against its milestones. What each milestone contains, and its exit test, are defined in [04 §5](04-bootstrap-toolchain.md#5-milestones-to-hello-world) (M1–M3) and [04 §6](04-bootstrap-toolchain.md#6-after-m3) (M4–M12); this file tracks progress against them. A step's commit is recorded in the commit after it (a commit cannot name its own hash).

Updated 2026-10-01.

## Summary

| Milestone | Status | Exit test |
|---|---|---|
| **M1** First light | Done (2026-09-30) | `tests/qemu/boot.ndb` passes on x86_64 and aarch64 |
| **M2** A shell in a namespace | Done (2026-10-01) | `tests/qemu/shell.ndb` passes on both |
| **M3** Mount the network | In progress: all but step 5b (interoperability) done | `tests/qemu/mount.ndb` passes on both (against 10.0.2.100; see below) |
| M4 POSIX and debugging | Not started | |
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
| 5b. Interoperability against a stock 9P2000 server (`u9fs` or 9front's `exportfs`) | To do: none is installed | |
| 6. The exit test as a scenario, its write checked on the host (`host=`); `./build image --iso`: ISO 9660 with an El Torito UEFI entry, booted from a CD in the `iso` scenario | Done | `819c8c5` |

The exit test's steps all pass in `tests/qemu/mount.ndb`, with one difference: the server is at 10.0.2.100!5640, not the host's 10.0.2.2!5640, because QEMU will not forward the gateway's own address to a command. The exit test as written works by hand under `./build qemu`, with `vx9pserve --listen 127.0.0.1:5640 DIR` on the host. Booting a real UEFI PC from USB is not gated, and has not been tried.

## Known gaps

Deferred deliberately, each with where it is due:

| Gap | Effect now | Due |
|---|---|---|
| No `as_unmap` | Each ring session (9P connections, the driver's net session) leaves its mapping, about 0.5 MiB, until the task exits | Before M4 |
| 9P replies always use arena offset 0 | Pipelined 9P requests would overwrite each other's replies; the client does not pipeline yet | With pipelining |
| No `Tflush` or timeouts in the 9P client | A read held by a server (`ping` with no reply, a `listen`) waits until it is answered | M3 step 4 or M4 |
| No per-client connection limit | One client can take all 16 of a server's ring connections | Before M8 (swarm) |
| DNS: A records only; no AAAA, no TCP fallback for truncated replies, no search domains | Names resolve to IPv4 only, from what fits in one UDP reply | With IPv6; when a name needs it |
| UDP `headers` mode is not exercised in QEMU | Only the code path through `vx-net` is tested (host tests); netd's header format is not | When a UDP service needs it |
| Each process dials its own TCP connection for a `tcp!` mount (a child cannot be handed one) | Every command in a mounted directory opens a connection, which then waits 10 s in TIME_WAIT; a fast script could use up `netd`'s 32 conversations | Before M8 (a shared 9P connection, through a post) |
| No stock 9P2000 server to test against | `vx-9p` and `vx9pserve` are tested only against each other | M3 step 5b |
| No loopback route | The guest cannot connect to itself, so `listen` is tested in the host tests and the 9P framework but not end to end in QEMU | M3 step 6, or when a test needs it |
| TCP: no SACK, no timestamps, out-of-order segments dropped; TIME_WAIT 10 s | Recovery from loss is slower than it could be | After M3 |
| Kernel stacks have no guard pages | A kernel stack overflow corrupts memory instead of faulting; the deepest path measured uses about 9 of 16 KiB at `-O0` | M4 |
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

Host tests (`tests/host/`, under ASan and UBSan) and fuzzers (`tests/fuzz/`) run in `./build check`.
