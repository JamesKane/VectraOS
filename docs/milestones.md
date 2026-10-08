# Milestones

Where VectraOS stands against its milestones, in brief. What each milestone contains, and its exit test, are defined in [04 §5](04-bootstrap-toolchain.md#5-milestones-to-hello-world) (M1–M3) and [04 §6](04-bootstrap-toolchain.md#6-after-m3) (M4–M15). Each step's record (what it did, its commit and the decisions on the way) is in [`milestones/`](milestones/); what is deferred on purpose is in [known gaps](milestones/known-gaps.md), and what `./build test` checks in [scenarios](milestones/scenarios.md).

Updated 2026-10-08.

## Summary

| Milestone | Status | Exit test | Steps |
|---|---|---|---|
| **M1** First light | Done (2026-09-30) | `tests/qemu/boot.ndb` | [M1–M3](milestones/M1-M3.md) |
| **M2** A shell in a namespace | Done (2026-10-01) | `tests/qemu/shell.ndb` | [M1–M3](milestones/M1-M3.md#m2--a-shell-in-a-namespace) |
| **M3** Mount the network | Done (2026-10-01) | `tests/qemu/mount.ndb` | [M1–M3](milestones/M1-M3.md#m3--mount-the-network) |
| **M4** POSIX and debugging | Done (2026-10-02) | `dbg.ndb` and `rcscript.ndb` | [M4](milestones/M4.md) |
| **M5** Storage | Done (2026-10-04) | `install`, `powercut`, `fsdadm`, `fsddump`, `fsdnvmerestart` | [M5](milestones/M5.md) |
| **M6** Runtime | Done (2026-10-08) | `libvx` level 1 frozen (`abi/levels/1`), its behaviour suite (`vxapi`, `libvx`) green on both | [M6](milestones/M6.md) |
| **M7** Pixels | Scoped 2026-10-08 ([docs/21](21-pixels.md)): tracing first, then display, input, `winsrv`, `vxui`, the terminal | The minimal and CPU-pixel programs on screen, a terminal running rc, M7's budgets under KVM | [M7](milestones/M7.md) |
| M8 GPU | Not started | | |
| M9 Real hardware | Not started: the PC (9a, moved from M6's 6g on 2026-10-08), then the Q8B | | [M9](milestones/M9.md) |
| M10 Swarm | Not started | | |
| M11 AI | Not started | | |
| M12 Self-hosting | Not started | | |
| M13 Audio | Not started | | |
| M14 Debugger parity | Not started | | |
| M15 Hypermedia and native clients | Not started | | |

Every exit test passes on x86_64 and aarch64. The milestones were renumbered on 2026-10-02 into the order they will happen; commits and documents from before then use the old numbers.

## History

Work began on 2026-09-30 from a written blueprint (docs 00–05). The first week built the system from the bottom up: a capability microkernel booting on both architectures with SMP (M1); 9P over shared-memory rings, namespaces, user-space drivers and a shell (M2); the network (M3); a POSIX personality on musl with sbase, a 9front-compatible `rc` and a native debugger (M4); and storage, with a copy-on-write file system after 9front's gefs, NVMe, IOMMUs, ACPI, FAT and ISO 9660, and an installer with rollback slots (M5). M6 then gave the system what applications stand on: a manual with its own tooling, SIMD state, threads, pipelined 9P and concurrent servers, a native C and C++ library (llvm-libc and libc++), Swift as a first-class language, a dynamic loader with the C, C++ and Swift runtimes shared, and now `libvx` v0, the native API.

## M1–M3

The kernel boots through Limine, reaches user space and runs `svcd` (M1, with SMP). A shell, `gsh` (later remade as `rc`), runs in a namespace served over 9Px rings, with `/proc`, pipes and a console driver that is restarted when killed (M2). PCI, MSI and virtio come up under `devmgr`; `netd` serves `/net` with TCP/IP and DNS, and a remote 9P server is mounted over TCP, interoperating with `u9fs` (M3).

## M4 — POSIX and debugging

POSIX programs run on musl over a back end that speaks 9Px, with `fork`, signals, ptys, job control and `poll`; sbase is the userland and Lua is vendored. `rc` is the shell. `dbg` debugs a process through `/proc`. Decisions: ADRs 0009–0011 (the Plan 9 baseline), and no dash.

## M5 — Storage

`fsd` serves a copy-on-write file system of the project's own (ADR-0025, [docs/11](11-storage.md)) with snapshots, a checker and power-cut safety, mapped files through pager VMOs, and users and permissions. NVMe and virtio-blk drivers sit behind VT-d and SMMUv3, ACPI comes through ACPICA, and `dosfs` and `isofs` read and write FAT and ISO 9660. `install` builds a bootable disk with rollback slots, fed by `distd`.

## M6 — Runtime

| Step | What | Status |
|---|---|---|
| 6a | The manual's tooling (`vx-guide`, `man`), and `rc` made 9front's | Done |
| 6b | The manual's backlog, written in waves | Done |
| 6c | SIMD: every XSAVE component on x86, NEON on arm64, kernel SIMD, protection keys | Done |
| 6d | Threads, pthreads, robust futexes, pipelined 9P, concurrent `fsd`, `sched_ctx`, the rest of rc | Done |
| 6e1 | Address-space calls, seals and leases, `/env`, identity, 9Px `notify`, `vx_heap` | Done |
| 6e2 | The native target: llvm-libc and libc++ (ADR-0033) | Done |
| 6e3 | Swift on VectraOS: concurrency and Foundation (ADR-0034) | Done but `dbg` for Swift, tabled |
| 6e4 | `libvx` v0 (ADR-0004): headers and exports, arenas, strings and formatting, processes and threads, the event loop, files, the rule-2 review, the behaviour suite, and level 1 frozen | Done |
| 6f1 | The dynamic loader; `libvx`, `libc` and libc++ shared | Done |
| 6f2 | C++ exceptions (libunwind); llama.cpp deferred | Done but llama.cpp |
| 6f3 | The Swift runtime and Foundation shared, with an ABI check (ADR-0048) | Done |

## M7 — Pixels

Scoped 2026-10-08 in [docs/21](21-pixels.md): tracing first (7a, [docs/20](20-tracing.md)); then seeing pixels (the harness's screenshots, write-combining, `vx-buffer`, `displayd` on simplefb and virtio-gpu 2D, 7b); input (7c); `winsrv` with a CPU compositor, `/wsys` and the frame protocol (7d); fonts and `vxui` v0 with the exit programs (7e); the terminal (7f); `lib/vx-text`, `dbg`'s GUI, hot reload, the plumber and tzdata (7g); budgets and the exit (7h). Decided with the user: the exit is pixels only (sound and gamepad with M13 and M9), M6's formatting library becomes `lib/vx-fmt`, the terminal is an M7 step.

## M9 — Real hardware

Not scoped past its first step. The real PC (9a, M6's 6g until 2026-10-08) comes first, then the Radxa Dragon Q8B's platform. Both are T1, both boot with ACPI, and the PC's step builds what the Q8B also needs: a debug log for a machine with no serial port, `drv-xhci` and ACPI's events.

## Line counts

First-party code is about 73.1 kLOC (`./build loc`, 2026-10-05; 355 kLOC vendored); 04 §5 estimated 25–32 kLOC for M1–M3 together.
