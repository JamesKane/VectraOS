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
./build image [--iso]            # GPT disk images → out/<arch>/debug/vectra-<arch>.img, and UEFI CD images (reproducible)
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
| [docs/04-bootstrap-toolchain.md](docs/04-bootstrap-toolchain.md) | **Phase 4.** Language policy, repository layout, build and cross-compilation, and the milestones: M1–M3 up to a bootable image with a shell and a network mount, then M4–M13 |
| [docs/05-debugger.md](docs/05-debugger.md) | **Phase 5.** The native debugger `dbg`: kernel debug mechanisms, the `/proc` debug files, symbols, crash directories, RAD Debugger-level features, profiling, remote debugging |
| [docs/06-install-update.md](docs/06-install-update.md) | **Phase 6.** Installing from the ISO, releases as signed reproducible trees in a content-addressed store, peer-to-peer distribution over 9Px, boot slots with a one-shot trial boot, and rollback with filesystem snapshots |
| [docs/07-native-apps.md](docs/07-native-apps.md) | **Phase 7.** Documents and applications apart again: a script-free document viewer for a cut-down HTML and CSS profile and the small web, and native clients for chat, social media, mail and feeds over existing open protocols, each an adapter file server plus a small app, joined by the plumber |
| [docs/08-editor.md](docs/08-editor.md) | **Phase 8.** `hx`, the editor: Acme's file server, executable text and plumbing, sam's structural regular expressions, and Zed's capabilities (GPU drawing, tree-sitter, language servers through `lspfs`, multiple selections, multibuffers, Git, remote projects, shared buffers), with no AI inside: that is the system's |
| [docs/09-native-api.md](docs/09-native-api.md) | **Phase 9.** The native API, a sketch: `libvx` straight on the kernel and the file servers with no POSIX underneath, the one-hop rule and cost classes, conventions (slices, `vx_errstr`, nil objects, arenas passed explicitly, one event record, ABI levels), the surface by area, and the study findings the blueprint had not yet taken |
| [docs/10-after-posix.md](docs/10-after-posix.md) | **Vision, non-binding.** How POSIX could die from a developer's point of view: a survey of post-POSIX systems and small toolchains, a hosted C23 library on `libvx`, a Plan 9-style compiler and linker that one person can read with clang kept as the auditor, Git as a format, the POSIX personality as a guest, and what each step would have to change |
| [docs/adr/](docs/adr/README.md) | Architecture decision records |
| [docs/study/](docs/study/README.md) | What this design takes from the platform API study: the friction register (F-101 … F-219), the heritage findings, the convergent API shapes, the compatibility-layer measurements and the prototype results |

## Background

The application-framework design builds on a platform API study, written for an earlier XNU-based design and kept private. It read 44 corpus projects pinned at fixed commits, admitted 30 friction entries, compared heritage systems from AmigaOS to the Switch, and measured prototypes. [docs/study/](docs/study/README.md) keeps the findings and their evidence, cited by project and commit so they can be checked upstream. [docs/00-overview.md §6](docs/00-overview.md#6-what-the-api-case-study-changes) records which findings this design adopts, and where.
