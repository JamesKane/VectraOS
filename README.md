# VectraOS

VectraOS is a new operating system for people who hack on systems. It combines:

- a small **capability micro-kernel** whose IPC runs over lock-free shared-memory rings;
- **Plan 9's namespace model**, extended (9Px) so that windows, sensors, AI context and remote accelerators are all files;
- **Plan 9's terminal/CPU-server split**, rebuilt for heterogeneous CPU, GPU and NPU swarms;
- a **POSIX personality** so LLVM, Python and Git run without growing the kernel;
- a **hybrid WIMP + tiling desktop** in which every action can be reached by mouse, by key and by script;
- **local-first AI**, treated as a system resource like storage or audio.

## Status

**M1 and M2 are done; M3 is in progress** (2026-10-01). [docs/milestones.md](docs/milestones.md) tracks each step, its commit, and the known gaps.

What runs today, under QEMU on x86_64 and aarch64:

- a capability microkernel with SMP, channels, rings, ports, futexes, and user-space drivers' objects (IRQs, MSIs, physical memory, DMA domains);
- `svcd` starting services from manifests, and restarting them;
- user-space drivers for the UART consoles and the virtio network card, matched to PCI functions by `devmgr`;
- 9Px over shared-memory rings, per-process namespaces, `bootfs`, `/proc`;
- `gsh`, a shell, with `ls`, `cat`, `echo`, `ps`, `ns`, `tail`, `ping` and `cs`;
- `netd`: a first-party TCP/IP stack (ARP, IPv4, ICMP, UDP, DHCP, TCP with NewReno, a DNS stub) serving `/net` and `/net/cs` in Plan 9's layout;
- `mount tcp!host!port /n/host`: a 9P file server over TCP in the namespace, such as `host/vx9pserve` sharing a directory from the host.

## Building

```sh
cc -std=c23 -o build build.c     # once; after that ./build rebuilds itself
./build all                      # the kernel, user space and Limine, for x86_64 and aarch64
./build image                    # GPT disk images → out/<arch>/debug/vectra-<arch>.img (reproducible)
./build qemu --arch aarch64      # boot one in QEMU on the serial console; Ctrl-A X quits (--kvm, --gdb)
./build test                     # boot headless on both architectures and check tests/qemu/*.ndb (--release, --tcg)
./build check                    # host tests, fuzzers, vendor-check, format, static analysis, build-time budget
./build vendor-check             # check third_party/ against VENDOR.ndb
./build loc                      # the line-count ledger
```

The toolchain is pinned (ADR-0001): clang, lld and llvm-objcopy 22.1.8 from Fedora 44, at `/usr/bin`, plus `nasm` for Limine's x86_64 loader.

## Documents

| Doc | Contents |
|---|---|
| [docs/milestones.md](docs/milestones.md) | Progress against the milestones: each step, its commit, the known gaps, and what each test scenario checks |
| [docs/00-overview.md](docs/00-overview.md) | Vision, the thirteen design rules, system map, key decisions, traceability to the API case study |
| [docs/01-kernel-ipc.md](docs/01-kernel-ipc.md) | **Phase 1.** Kernel objects and syscalls, capabilities, ring-buffer IPC, memory management, the zero-copy fabric on unified-memory SoCs and discrete GPUs, user-space drivers, scheduling, the POSIX personality |
| [docs/02-namespace-swarm.md](docs/02-namespace-swarm.md) | **Phase 2.** The 9Px protocol, namespace mechanics, the canonical file tree (windows, sensors, AI, accelerators), swarm roles, mounting, `cpu`, and offloading work to other nodes |
| [docs/03-desktop-agentic.md](docs/03-desktop-agentic.md) | **Phase 3.** Rendering pipeline (Vulkan), window server, hybrid tiling, theming, the application framework tiers, and AI in the desktop |
| [docs/04-bootstrap-toolchain.md](docs/04-bootstrap-toolchain.md) | **Phase 4.** Language policy, repository layout, build and cross-compilation, and the milestones: M1–M3 up to a bootable image with a shell and a network mount, then M4–M12 |
| [docs/05-debugger.md](docs/05-debugger.md) | **Phase 5.** The native debugger `dbg`: kernel debug mechanisms, the `/proc` debug files, symbols, crash directories, RAD Debugger-level features, profiling, remote debugging |
| [docs/adr/](docs/adr/README.md) | Architecture decision records |

## Background

The application-framework design builds on the platform API study in `../NeoDarwin-api-study`. That study covers about 44 corpus projects, 30 admitted friction entries, heritage systems from AmigaOS to the Switch, and prototype measurements. [docs/00-overview.md §6](docs/00-overview.md#6-what-the-api-case-study-changes) records which of its findings this design adopts, and where.
