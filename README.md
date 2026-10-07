# VectraOS

> *The future we were promised took a wrong turn somewhere around 1992. We went back for it.*

There was a moment when computing could have gone another way. Plan 9 made every resource a file and every machine part of one namespace. The Amiga ran a whole multitasking desktop out of a few hundred kilobytes and treated hypertext help as a native thing. Micro-kernels promised systems small enough to understand and too modular to bring down. Then the industry chose the other road: bigger kernels, deeper stacks, layers wrapped round layers, and machines their owners can no longer read.

**VectraOS takes the road not taken.** It is a retro-future operating system: the clarity of those lost systems, rebuilt from the ground up for the hardware of now. Many-core SoCs, unified memory, GPUs and NPUs, a swarm of your own machines on the desk and in the rack. Neon on chrome. Small enough to hold in your head, fast enough to run your world.

## Jack in

**Everything is a file. Still. Again. Further.** Windows, sensors, GPUs, AI contexts, the network, the process table: all of them are file trees you can `ls`, `cat` and script. If a human can do it, a shell script or an agent can do it through the same door.

**Your machines are one machine.** Plan 9's terminal/CPU-server split, rebuilt for heterogeneous swarms. Your laptop mounts your workstation's GPU or your server's NPU, and uses them as if they were bolted in.

**A kernel you can read in a weekend.** A capability micro-kernel with four jobs and nothing else. Drivers, filesystems, the network stack, the window server and the AI runtime all live in user space as ordinary processes, talking over lock-free shared-memory rings.

**Your namespace is your perimeter.** No ambient authority. A process sees only what it has been handed. Sandboxes, containers, agent permissions and remote sessions are all the same thing: a namespace built for the purpose.

**Local-first AI, wired into the grid.** Models are a system resource like storage or audio, served under `/ai`. Nothing leaves your machine, or your own swarm, unless you say so.

**A desktop for operators.** A hybrid WIMP and tiling desktop on Vulkan, where every action answers to the mouse, the keyboard and the script alike. A built-in editor in the line of Acme and sam. A manual in hypertext, written in a modernised AmigaGuide.

**No legacy sprawl.** One mechanism per job. No compatibility shims, no portability layers, no abstractions over abstractions. The single exception is a POSIX personality, so LLVM, Python and Git come along for the ride without growing the kernel.

**Written in standard C23.** First-party code, read and owned. No package registries; what we import is vendored and reviewed line by line.

## Status: booting

VectraOS is young and runs under QEMU on x86_64 and aarch64. **M1–M4 are done; M5 (storage) is under way.** [docs/milestones.md](docs/milestones.md) tracks each step, its commit and the known gaps.

What runs today:

- the capability micro-kernel: SMP, channels, rings, ports, futexes, and user-space driver objects (IRQs, MSIs, physical memory, DMA domains);
- `svcd` starting and restarting services from manifests, and user-space drivers matched to devices by `devmgr`;
- 9Px over shared-memory rings, per-process namespaces, `/proc`, and a Plan 9-style shell with rc scripting;
- `netd`, a first-party TCP/IP stack serving `/net` in Plan 9's layout, and 9P mounts across the network;
- a POSIX personality on musl: fork, exec, signals, ptys and job control, Lua, and a native debugger;
- the start of `fsd`, a copy-on-write filesystem after 9front's gefs, with snapshots, power-cut safety and memory-mapped files.

The road ahead: a runtime, pixels on screen, GPU drivers, real hardware, the swarm, local AI, self-hosting, audio, a full debugger and a hypermedia web.

## Build it

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

## The blueprint

| Doc | Contents |
|---|---|
| [docs/milestones.md](docs/milestones.md) | Progress against the milestones: each step, its commit, the known gaps, and what each test scenario checks |
| [docs/00-overview.md](docs/00-overview.md) | Vision, the thirteen design rules, system map, key decisions |
| [docs/01-kernel-ipc.md](docs/01-kernel-ipc.md) | Kernel objects and syscalls, capabilities, ring IPC, memory, user-space drivers, scheduling, the POSIX personality |
| [docs/02-namespace-swarm.md](docs/02-namespace-swarm.md) | 9Px, namespaces, the canonical file tree, swarm roles, `cpu`, offloading work to other nodes |
| [docs/03-desktop-agentic.md](docs/03-desktop-agentic.md) | Vulkan rendering, the window server, hybrid tiling, theming, application frameworks, AI in the desktop |
| [docs/04-bootstrap-toolchain.md](docs/04-bootstrap-toolchain.md) | Language policy, repository layout, build and cross-compilation, the milestones |
| [docs/05-debugger.md](docs/05-debugger.md) | `dbg`, the native debugger: kernel mechanisms, `/proc` debug files, crash directories, profiling, remote debugging |
| [docs/06-install-update.md](docs/06-install-update.md) | Installing, signed reproducible releases, peer-to-peer distribution, trial boots and rollback |
| [docs/07-native-apps.md](docs/07-native-apps.md) | A script-free document viewer for the small web, and native clients for chat, social, mail and feeds |
| [docs/08-editor.md](docs/08-editor.md) | `hx`: Acme's file server and plumbing, sam's structural regular expressions, and a modern editor's capabilities |
| [docs/09-native-api.md](docs/09-native-api.md) | `libvx`, the native API straight on the kernel and file servers, a sketch |
| [docs/10-after-posix.md](docs/10-after-posix.md) | **Vision, non-binding.** What a world after POSIX could look like for developers |
| [docs/11-storage.md](docs/11-storage.md) | The copy-on-write system volume after gefs, `fsd` as pager, partitions, `dosfs` and `isofs` |
| [docs/12-manual.md](docs/12-manual.md) | The manual: Plan 9's sections in guide, a modernised AmigaGuide, read by `man` and `hv` |
| [docs/13-portable-code.md](docs/13-portable-code.md) | **Design notes, non-binding.** A core-Wasm profile as a portable target, lowered to native on install, for third-party programs and perhaps more of the user land |
| [docs/15-working-memory.md](docs/15-working-memory.md) | **Design notes, non-binding.** Scott Jenson's working memory (spatial, associative, episodic) on this design: snarf, a window's document, collections as folders, a metadata journal over `fsd`'s dump |
| [docs/16-swift-sdks.md](docs/16-swift-sdks.md) | **Design notes, non-binding.** The Swift SDKs (`VX`, `VXUI`, `VXEngine`, `VXData`) shaped for the cache: batches, ids, columns of plain data, ARC per subsystem, chunked concurrency |
| [docs/17-applications.md](docs/17-applications.md) | **Vision, non-binding.** The application suite: Sheet, Page, Stage, Jukebox, Photos, Notes, Reminders, Stickies, a modern Deluxe Paint and Draw, a vector editor, as file servers over directory documents, local-first over the swarm |
| [docs/adr/](docs/adr/README.md) | Architecture decision records |
| [docs/study/](docs/study/README.md) | The platform API study's findings: friction register, heritage systems, convergent API shapes, prototypes |

## Governance

VectraOS is run by a BDFL (benevolent dictator for life): James Kane. Every decision passes through the BDFL after weighing its pros and cons. Substantive changes get argued in an issue, a pull request or an ADR before the code lands, and a decision says why it was made. If VectraOS ever reaches a user base the size of desktop Linux's, a steady 2–3% of desktops, we'll consider moving governance to a committee.

The [code of conduct](CODE_OF_CONDUCT.md) is four rules: have fun, respect each other, build cool software, and leave politics at the door.

## License

VectraOS is BSD-3-Clause licensed: see [LICENSE](LICENSE). There is no contributor license agreement and no copyright assignment; contributors keep the copyright on what they write. Vendored code under `third_party/` keeps its own licenses.
