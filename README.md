# VectraOS

> *The future we were promised took a wrong turn somewhere around 1992. We went back for it.*

There was a moment when computing could have gone another way. Plan 9 made every resource a file and every machine part of one namespace. BeOS gave files typed attributes and answered live queries over them. The Amiga ran a whole multitasking desktop out of a few hundred kilobytes. Microkernels promised systems small enough to understand and too modular to bring down. Then the industry chose the other road: bigger kernels, deeper stacks, layers wrapped round layers, and machines their owners can no longer read.

The edge is where it shows. A Raspberry Pi, an SC8280XP board and a desktop PC each carry silicon that would have filled a machine room, and each comes with its own vendor SDK, its own kernel and its own idea of what a file is. Frames, packets and tensors get copied across boundaries they never needed to cross. The people who pay for it are the indie game developers, makers and systems hackers who just want the hardware to do what it says on the box.

**VectraOS takes the road not taken.** It is a retro-future operating system: the clarity of those lost systems, rebuilt from the ground up for the hardware of now. Maker SBCs, desktop PCs, the GPUs and NPUs attached to them, and a swarm of your own machines on the desk. A capability microkernel written in Embedded Swift with strict memory safety, so the language catches what a proof would otherwise have to. Neon on chrome. Small enough to hold in your head, fast enough to keep a frame deadline.

> [!WARNING]
> **VectraOS is a hobby OS, built so you can see everything your machine is doing. It is not hardened, and it never will be.** Traces, counters, `/proc`, the debuglog and the namespace are open to whoever owns the machine, by design. That openness is a feature, not a bug: the user owns the machine, and the system hides nothing from them. It also means a clever party with access to your machine or your swarm can find and take whatever is on it. The capabilities, KASLR, W^X, PAC and BTI below keep programs honest with each other; they are not a promise to stand up to a determined attacker. Don't put secrets, credentials or anything sensitive on a VectraOS machine, and don't expose one to a network you don't trust.

## Jack in

**A kernel that sets up and steps aside.** The kernel creates address spaces, threads, capabilities and shared memory, then gets out of the way. Bulk data never passes through it. Drivers are ordinary user processes that receive their DMA memory as capabilities.

**Nodes for control, rings for bulk.** Every service is a node you can browse, script and reach over the network. When a path gets hot, the node hands you a lock-free shared-memory ring. There is one ring format for input, audio, frames, packets, blocks and tensors, and one wire format for everything structured.

**Your machines are one machine.** The namespace is exported over 9P2000.L. `mount tcp!pi5!564 /n/pi5` and a board's GPIO is a directory on your PC; a Q8B's NPU appears under `/dev/accel` beside your own GPU. Linux mounts it with stock `v9fs`.

**Write the model once.** Models are lowered on the host to one artifact and run on the CPU, GPU or NPU of whichever node they land on. A camera ring feeds the accelerator, the accelerator feeds the renderer, and the CPU never touches the frames.

**Files that know things.** Taisce, the file system, carries typed attributes and answers live queries, as BeOS did. Window positions and folder layouts are attributes, not preference files.

**A desktop both ways.** Every workspace is either tiled or spatial, and you can flip it at any time. Both arrangements persist, so switching is a projection, not a loss.

**One wait, one deadline, one intent.** A thread waits on one port for everything: doorbells, IRQs, timers, child exits, window events. Time is an absolute deadline with a leeway. Threads declare what they are for (`frame`, `interactive`, `realtime`), never a priority.

**Every promise is a budget.** Boot time, IPC latency, syscall count and line count are numbers with checks running against them. A budget is never loosened in the change that would fail it.

**Your namespace is your map.** No ambient authority. A process can name only what it was handed. Nothing phones home: the system sends nothing off your machine, or your own swarm, unless you tell it to. That keeps programs in their lanes; it is not a wall against someone determined to get in.

**Only our code on the device.** First-party Swift and C23, with C only where Swift can't reach. Heavy compilers stay on the developer's host and produce our formats; vendor firmware blobs are the only exception, each listed with its provenance.

## Where it comes from

This repository joins three earlier projects, and when two of them solved the same problem, one solution wins and the other goes ([docs/provenance.md](docs/provenance.md)):

| Source | What it gives VectraOS |
|---|---|
| [croi](../croi) | the kernel, the UEFI loader and the arch code (already Embedded Swift + C23) |
| [todhchai](../todhchai) | performance contracts, the Node protocol and typed IPC, the Taisce file system, the Radharc compositor and the SDK |
| [NeoVectra](../NeoVectra) | the "one mechanism per job" rule, the ring and doorbell data plane, the swarm design and the Q8B hardware notes |

## Status: setting up

**V0 is done (2026-10-15): the croi kernel boots and passes its self-tests on amd64, arm64 and rv64 in QEMU.** V1, the setup-engine kernel, has made its cuts: 154 calls down to 91, the audit's target ([docs/syscall-audit.md](docs/syscall-audit.md)), with `object_bind`, batched hot calls and the one ring in place. V2, the userland base, is under way: todhchai's userland lifted onto the cut kernel.

What runs today:

- a capability microkernel after Zircon, on three architectures, with KASLR, W^X, PAC and BTI, SMP, scheduling contexts, VMOs and the pager, channels, ports and futexes, user-space driver objects (IRQs, MSIs, DMA) and IOMMU support (VT-d, AMD-Vi, SMMUv3, the RISC-V IOMMU);
- a UEFI loader that boots it through UEFI and ACPI alone;
- the one ring, in Swift and C and checked by a model checker, carrying port packets, the debuglog, trace records and stdio;
- a userland on it: the floor (the one user runtime), libc and `dlopen`, Sys, typed IPC, the Node protocol with bulk transfers on ring pairs, the launcher, and rc;
- tier 1: C, C++ and full Swift programs, built by the `*-vectraos` toolchain, on amd64 and arm64;
- `vx`, the one front door: build, test, boot, bench, trace, loc, hardware and CI;
- boot and size budgets reported on every run, judged against this machine's history.

The road ahead ([docs/roadmap.md](docs/roadmap.md)): the one ring and the cut-down kernel (V1), the userland base (V2), the bring-up link (V3), Taisce on disk (V4), the desktop (V5), then the first boards: the Orange Pi 6 Plus (V6), the Orange Pi RV2 (V6b) and an AMD desktop (V6c), the swarm (V7), compute, starting with the Radxa Dragon Q8B (V8), and Wasm and games (V9). What runs where, and how sure we are of it, is [docs/hardware/](docs/hardware/); support for hardware not on it needs a contribution from someone who has it, or donated test hardware (contact the BDFL, James Kane, first).

## Build it

```sh
swift build --product vx && .build/debug/vx ci   # everything vx ci checks
.build/debug/vx test arm64                       # one arch: build + QEMU tests
.build/debug/vx boot rv64                        # boot interactively (Ctrl-A x quits)
.build/debug/vx bench                            # boot budgets under KVM (advisory)
.build/debug/vx loc                              # size budgets
.build/debug/vx hardware                         # the hardware support list
```

You need Swift 6.4.0 through swiftly (pinned by `.swift-version`, with its bundled clang, lld and llvm-objcopy), CMake, Ninja, bash, and QEMU with edk2 from `/usr/share/edk2`. Nothing else.

## The blueprint

| Doc | Contents |
|---|---|
| [docs/vision.md](docs/vision.md) | What we are building, and what we take from the Scalable Edge Architecture paper |
| [docs/principles.md](docs/principles.md) | The twenty-nine rules every change follows |
| [docs/architecture.md](docs/architecture.md) | How the layers fit: kernel, the ring, the Node protocol, the swarm, Taisce, the desktop, compute, Wasm |
| [docs/performance.md](docs/performance.md) | The budgets and how they are enforced |
| [docs/provenance.md](docs/provenance.md) | Which code comes from which repository, and why |
| [docs/decisions/](docs/decisions/) | The dated decision log |
| [docs/roadmap.md](docs/roadmap.md) | The milestones and their exit criteria |
| [docs/hardware/](docs/hardware/) | What runs where, at what support level (research to supported), and the evidence for each (D66) |
| [docs/boards/](docs/boards/) | One notebook per board and PC: its facts, sources and what to check on the machine |
| [docs/syscall-audit.md](docs/syscall-audit.md) | V1's audit: which calls stay, which go, and what replaces them |
| [docs/trace-format.md](docs/trace-format.md) | The trace format the budgets are read from |
| [docs/design/storyboard/](docs/design/storyboard/) | The desktop storyboard ([live canvas](https://claude.ai/artifact/BcQQLDod1qqmgwVzabeTPX)): the Platinum Indigo look, D24 |
| [docs/kernel/](docs/kernel/) | The kernel's rules, roadmap, design notes per subsystem, and its divergences from Zircon |

## License

VectraOS is BSD-3-Clause licensed: see [LICENSE](LICENSE).
