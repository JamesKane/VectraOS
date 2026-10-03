# 00 — Overview, design rules and key decisions

_Blueprint v0, 2026-09-30._

**How firm these documents are.** Everything needed up to M3 (04 §5) is a design ready to build. Everything after M3 is provisional: it fixes the intended shape, and each part is rewritten against real usage code when its milestone starts. An API is written by first writing the code that calls it, then extracting the API from that code, never the other way round.

## 1. What we are building

VectraOS is **Plan 9 evolved for modern computing**, written in standard C23 instead of Plan 9's own C dialect. It is a micro-kernel operating system in which **every resource is a file server** and **every fast path is a shared-memory ring**. It has four layers, described in §3.

**Plan 9 is the baseline.** Its model is kept whole: per-process namespaces built with `bind` and `mount`, everything a file, one process table under `/proc`, notes, exit strings, `/srv`, `/dev/cons` and rc. VectraOS changes that model only to evolve it: a micro-kernel, rings, 9Px, the swarm. A design that drops a Plan 9 property needs an ADR saying why the change is better, not just different. ADRs 0009–0012 restore what the first milestones dropped by accident.

**Text is UTF-8**, handled a rune at a time, as in Plan 9: names, paths, exit strings, notes, `ctl` messages, ndb, namespace(6) and the console. File contents and pipe data are bytes, never checked. ADR-0013 sets the rules: `lib/vx-utf`, strings cut only at rune boundaries, names with no control characters, and line editors that erase whole runes.

- The kernel knows about address spaces, threads, capabilities and notifications, and nothing else.
- Drivers, filesystems, the network stack, the window server, the AI runtime and the POSIX personality are ordinary processes. They serve 9Px file trees, and where speed matters they also serve rings.
- A process sees only the resources in its namespace. Because a namespace can hold mounts from other machines, a laptop can mount a workstation's GPU, a phone's sensors or a server's NPU and use them as if they were local.

The goal is a system that a single hacker can hold in their head. The kernel should fit in a weekend of reading. Any service should be explorable with `ls` and `cat`, and any action a human can take should be scriptable by a shell script or by an agent through the same interface.

## 2. The thirteen design rules

These rules are normative. A design that breaks one needs an ADR explaining why.

1. **The kernel has four jobs:** address spaces, threads and scheduling, capabilities, and notification and transfer. Anything that could run as a process does.
2. **Files are for control and discovery; rings are for bulk.** Every service has a file interface, which is browsable, scriptable and mountable remotely. A service may also offer rings for hot paths. A ring is never the *only* way to reach a service.
3. **The namespace is the authority.** A process can name only what it has been given, and there is no ambient authority. Sandboxes, containers, agent permissions and remote sessions are all the same mechanism: a namespace built for the purpose. Servers enforce the boundary, not the mount table: a confined view is a connection attached at a restricted root, and the server never lets a walk leave that root. `bind` only arranges names (02 §2).
4. **One wait.** Every event source delivers into a port, and one call waits on all of them. Sources include ring completions, IRQs, timers, child exit, window events, the frame clock, audio buffers and file changes.
5. **Time is an absolute deadline with a leeway.** There is no timer-resolution setting and no sleep-in-a-loop.
6. **Threads declare intent, or reserve whole cores; never priorities or affinity masks.** The intents are `interactive-frame`, `interactive`, `throughput`, `background` and `realtime(period, budget)`. The kernel places threads, including onto heterogeneous cores. A program that needs dedicated cores, such as a game engine's job system, reserves them; the kernel grants whole cores or refuses (01 §8).
7. **Buffers have one currency.** A buffer is a memory object plus a format descriptor plus a timeline fence. CPU, GPU, NPU, display, video, network and disk all exchange that same thing.
8. **Nothing on the frame path waits for a client.** The compositor owns one frame clock per output, and each frame event carries the *actual* presentation time of the previous frame.
9. **No main thread, no modal loops and no global locks in any protocol.** Every protocol supports capability queries from its first version, because version 1 semantics are permanent.
10. **Data is the interface.** State is readable as text, in one record format (ndb, D14). Every service directory describes itself with `.help` and `.schema` files, so humans, scripts and agents discover a service the same way.
11. **Batch by default.** Hot interfaces take arrays with counts. Syscalls that take a single item are for cold paths only.
12. **Local first.** Nothing leaves the machine, or the user's own swarm, unless a policy says so. Remote AI providers are mounts like any other, and a routing policy governs what data they may receive.
13. **Start over; don't rebuild the mess.** We are not re-creating the modern stack. There is one mechanism per job, never a second layer that wraps the first: no compatibility shims, no portability layers, no abstractions over abstractions. The OS never ships or offers such a layer, not in the base system and not as an official port. The one exception is the POSIX personality (01 §9): it is the foundation the development tools stand on, and we are starting over on the architecture, not reinventing LLVM, Git or the toolchains built on POSIX. What users install in their own user land is their business, not the platform's. Adding a mechanism means removing or refusing another. If the first-party base system cannot be understood by one person, it is too big. Imports such as Mesa and ACPICA are not exempt from scrutiny: the line-count ledger counts them next to our own code and publishes the total for the whole image (04 §3.2).

## 3. System map

```
 ┌────────────────────────────── applications ──────────────────────────────┐
 │  vxui apps (C23; Odin through vxui.h)  Lua scripts                        │
 │  POSIX ports (LLVM, Python, Git) · agents                                 │
 └──────────────┬───────────────────────────────────┬───────────────────────┘
                │ libc (musl + vx backend), libns, lib9px, vxui              
 ┌──────────────┴──────────── system servers (user space) ───────────────────┐
 │ svcd(init)  devmgr  procfs  nsd  netd  fsd  winsrv+wm  displayd  audiod   │
 │ aid(AI)  swarmd  keyd(auth)  tlsd  exportfs  auditfs                      │
 │ drivers: drv-virtio-*, drv-nvme, drv-xhci, drv-hda, drv-gpu-*, drv-npu-*  │
 └──────────────┬──────────── rings (shared memory) + channels ──────────────┘
 ┌──────────────┴──────────────── kernel (C23, ~15–25 kLOC) ─────────────────┐
 │ address spaces · VMOs · threads · sched contexts · handles/rights         │
 │ ports · counters · channels · rings · IRQ/MMIO/DMA-domain objects         │
 └───────────────────────────────────────────────────────────────────────────┘
      x86_64 (PC, QEMU q35)          aarch64 (QEMU virt, Q8B, RPi5, Apple M)
```

### Process inventory

| Process | Role | Phase doc |
|---|---|---|
| `svcd` | First process (init). Holds the boot capabilities, starts and restarts services (reincarnation policy) | 01 §7, 04 |
| `devmgr` | Enumerates buses (ACPI, device tree, PCI) and spawns each driver with only the capabilities its device needs | 01 §7 |
| `drv-*` | One process per driver. Each serves a device-class tree under `/dev` plus rings | 01 §7 |
| `bootfs` | Read-only tree unpacked from the boot image | 04 |
| `fsd` | Filesystem servers (one per mounted volume) and the page-cache pager | 01 §5, 02 |
| `netd` | TCP/IP, DNS and DHCP. Serves `/net` in the Plan 9 style | 02 §5 |
| `procfs` | The one process table: pids kept across `exec`, note groups, sessions, `wait`, notes, and the debug files, all under `/proc` (ADR-0011) | 01 §9, 05 §3 |
| `nsd` | Holds the mount table of each shared namespace group, and publishes it to the group's members (ADR-0009) | 02 §2 |
| `winsrv` | Window server and compositor. Serves `/wsys` | 03 |
| `wm` | Window-management policy (layouts, bindings) in Lua, in its own process with a minimal namespace | 03 §5 |
| `displayd` | Modesetting, planes, vblank and atomic commits, one per GPU | 03 §3 |
| `audiod` | Mixer with a fixed period, deadline-scheduled streams, the audio contract | 03 §7 |
| `aid` | Model registry, inference runtimes, sessions, context pools. Serves `/ai`. Optional: nothing else depends on it | 03 §8, 02 §5 |
| `swarmd` | Node discovery, trust, pool leases. Serves `/swarm` | 02 §6 |
| `keyd` | Keys and authentication (a factotum). Keys never leave it | 02 §6 |
| `tlsd` | TLS 1.3 client for services outside the swarm (model providers, `git` over https). It asks `keyd` to attach credentials inside the session, so no app or adapter holds them | 02 §3.2, 03 §8.6 |
| `exportfs`, `auditfs` | Export a namespace; interpose on a namespace and log writes | 02 |
| `distd` | Releases, app packages and the content store; fetching from peers, staging, trial boot and rollback. Serves `/dist` | 06 |
| `webfs` | HTTP, Gemini and Gopher as files, in Plan 9's interface. Serves `/mnt/web`; the only program that speaks them | 07 §5 |
| `plumber` | Routes data between apps by the user's rules, as Plan 9's does. Serves `/mnt/plumb` | 07 §7 |

## 4. Key decisions

| # | Decision | Chosen | Rejected, and why |
|---|---|---|---|
| D1 | Language | **C23** for all first-party code, kernel included, compiled by clang. A house subset and tooling replace language-level safety (04 §1) | Rust: its guarantees stop at `unsafe`, and the core of a kernel (page tables, context switches, MMIO, DMA, ring memory ordering) is unsafe by definition. It would also add a second language beside the C we import, a nightly `build-std` for our own targets, `std`'s registry dependencies, and slow builds. Zig: not used anywhere in the system. |
| D2 | Kernel model | **Capability micro-kernel** in the lineage of seL4 MCS and Zircon; IPC data never passes through the kernel | Hybrid (XNU): the scale we are avoiding. Pure seL4: formal proofs are out of reach, but its scheduling-context model is adopted. |
| D3 | IPC | **Two tiers:** kernel *channels* carry small control messages and capabilities; shared-memory *rings* carry everything hot | Synchronous rendezvous only: per-message kernel entry is the cost rings remove. |
| D4 | Namespace location | **Per namespace group, in user space** (`libns`, plus `nsd` for groups with more than one member). As with `rfork`, a spawn shares the parent's group, copies it or starts clean, and mounts are found by the identity of their mount point (ADR-0009). The kernel has no notion of paths. The table only arranges names; confinement comes from connections attached at restricted roots (rule 3) | In-kernel VFS (Plan 9, Linux): the kernel would grow a path walker, a mount table and caches. Authority lives in the capabilities a process holds, so a user-space mount table grants nothing it could forge. |
| D5 | File protocol | **9Px:** 9P2000 plus data-by-reference, map, read leases, notifications, POSIX file operations and modern auth. Where 9P2000.L already defines a message (attributes, rename, links, locks), 9Px uses it unchanged. It degrades to 9P2000 and 9P2000.L | New RPC IDL (FIDL, gRPC): loses `ls`/`cat` discoverability and 40 years of tooling. |
| D6 | Native GPU API | **Vulkan** (Mesa) plus a published *VectraOS Vulkan Profile* is the only GPU API. Shaders are SPIR-V, compiled at build time. No GL | A new GPU API or shading language: the case study (F-104, Q5) shows every one of them is a lasting cost. GL through Zink, and portability layers over Vulkan: each is a second API wrapped around the first, solving a compatibility or portability problem a single-API system does not have (rule 13). Metal: adds no reach. |
| D7 | Compute and AI | **Vulkan compute** baseline plus vendor NPU drivers behind a uniform `/dev/accel` tree. A CUDA-shaped host API later | A per-vendor stack as the platform API (F-105). |
| D8 | libc | **musl** with a VectraOS back end (`__syscall` becomes IPC); file descriptors live in the process, as in Fuchsia's fdio | Writing a new libc (relibc): valuable, but too slow to reach LLVM and Python. |
| D9 | Bootloader | **Limine** on both architectures, UEFI and BIOS. It provides the memory map, framebuffer, modules, SMP startup and RSDP/DTB | GRUB: multiboot2 has no aarch64 story. A custom UEFI stub: later, for boards Limine does not support. |
| D10 | Build | **`build`**, one first-party C23 file. Every component is a unity build (one translation unit) compiled by clang + lld; ports build from a per-port manifest. A clean build of all first-party code takes under 10 s (04 §3.2) | Make, CMake or Meson: extra languages and machinery that a unity-built C tree does not need. |
| D11 | Window protocol | **Native `/wsys` 9Px tree** with ring fast paths, and nothing else. No Wayland bridge and no SDL backend (rule 13) | Wayland as the native protocol: it brings client-side decorations, asynchronous geometry and per-client occlusion guessing (F-206–F-209). X11: no. |
| D12 | Scripting and extension | **Lua** for window-management policy and scripting, wherever logic is needed. Settings that are only data are ndb (D14). Plugins and agent tools are ordinary processes, confined by a namespace template (rule 3) | Wasm: a second runtime, with its own sandbox, for a problem namespaces already solve. We are not building a browser. Python in the base system: too heavy for the boot path; it arrives with the POSIX layer. |
| D13 | Supply chain | **No package registries.** Outside code is vendored as pinned, reviewed source under `third_party/`, one ADR per import. The build reads only the repository and CI builds with no network (04 §3.1) | Package registries (crates.io, npm, PyPI and the like): dependency trees too deep to audit, with typosquatting, maintainer-takeover and build-script execution risks. When two imports compete, the smaller one that can be audited wins |
| D14 | Text format | **ndb records**, from Plan 9's network database: `key=value` tuples, one record per line, with indented lines continuing it. Every structured text file uses it: `info`, `status`, events, `.schema`, manifests, build files and policy (02 §4.1) | TOML, JSON, YAML and JSON Schema: nesting, types and escaping rules that flat key-value files do not need, and a large parser for each. |
| D15 | Debugger and profiler | **`dbg`**, native, at the level of the RAD Debugger, with the profiler built in (05 §9). It debugs through `/proc` files over 9Px, as Plan 9's `acid` did, so remote debugging and scripting come free. DWARF 5 is the only debug format; `dbg` caches a flat index of it (05) | gdb or lldb as the system debugger: they expect `ptrace` and speak the gdb remote protocol, a second protocol beside 9Px. |
| D16 | Secure channels | **Noise** (first-party, over Monocypher) inside the swarm. **One vendored TLS 1.3 client library**, used only by `tlsd`, for services outside the swarm, which need web PKI: X.509, P-256 and RSA signatures, AES-GCM. The library is chosen by ADR before M11 | TLS inside the swarm: certificate machinery the swarm's own keys don't need. QUIC: a second transport. A TLS library linked into every program: the most exposed parser in the system, many times over |
| D17 | Installation and updates | **A release is one signed, reproducible tree** in a content-addressed store, signed by independent rebuilders; any peer serves it over 9Px, and the hashes make peers untrusted. It boots from one of several slots with a one-shot trial boot; filesystem snapshots protect configuration and files. Apps and their dependencies are packages, resolved per app by minimal version selection into a lock, with names scoped by publisher key. Updates apply only when the user asks (06) | A system-wide package graph for the base (apt, rpm): partial states and one version of each library for everything. A SAT solver for packages: minimal version selection resolved per app needs none. A central index of package names (D13). Updating files in place: no atomic switch, no rollback. A/B partitions holding whole copies: a full image per slot where a slot can name a tree |
| D18 | The web and network apps | **Documents are documents; applications are native.** `hv` shows hypermedia (a versioned HTML and CSS profile, gemtext, Gopher, Markdown) and runs no code from the network. Chat, social media, mail and feeds are native clients over existing open protocols (IRC, XMPP, ActivityPub, Atom, IMAP), each an adapter file server plus a small `vxui` app, joined by the plumber (07) | A full web engine (Blink, Gecko, WebKit, Ladybird, Servo): a second operating system inside this one, every web API a second mechanism (rule 13). JavaScript or Wasm from the network: code the user never chose to run. New protocols for chat or social media: the existing ones have servers and users already |
| D19 | The editor | **`hx`: Acme's architecture with Zed's capabilities.** A file server (`/mnt/hx`), executable text, plumbing and sam's command language, with a GPU-drawn `vxui` interface, tree-sitter, language servers behind `lspfs`, multiple selections, multibuffers, Git, remote projects as mounts and shared buffers. It contains no AI: agents, models, keys and inline assist are the system's, and reach `hx` through its files and proposed edits (08) | Acme unchanged: no syntax, no language intelligence, mouse only. Zed as it is: an agent panel, providers and keys inside the editor, Wasm extensions, a DAP client beside `dbg`, a terminal emulator of its own, and a hosted service for collaboration. A plug-in ABI: integrations are programs over the files, as in Acme |
| D20 | Native API | **`libvx`, directly on the kernel and the file servers,** as Plan 9's libc was: every call does its work itself or makes one syscall or one 9Px request (or one batch), and its reference states which. Slices, `vx_errstr`, nil objects with sticky errors, arenas passed explicitly, one loop and one event record shared with `vxui`, with ABI levels checked at compile time. Linked statically today; dynamically once the loader exists, which hot reload needs anyway, with every symbol bound at load (09) | Building on POSIX or musl: `errno`, signals, `FILE *`, `fork` and `select` are a second layer of mechanisms over the system's own (rule 13); POSIX stays a personality built on `libvx`. A hidden global allocator: an allocation the caller cannot see. Symbol versioning and lazy binding: ABI levels give additions without versioned symbols, and binding at load keeps a library call to one indirect call |

## 5. Hardware tiers

| Tier | Targets | Use |
|---|---|---|
| **T0** | QEMU `q35` (x86_64) and QEMU `virt` (aarch64, GICv3), with virtio devices, OVMF or edk2, SMP | Every milestone, and the only tier until M6. Runs in CI. |
| **T1** | Commodity x86_64 PC (UEFI, NVMe, xHCI, Intel/Realtek NIC, HDA); the Radxa Dragon Q8B (Qualcomm SC8280XP, UEFI and ACPI, Adreno 690 through Turnip, ADR-0018) | First real hardware: the PC in M6 (Runtime), the Q8B in M9, its own milestone, once the GPU stack (M8) is there for its Adreno. Both are booted with ACPI, which is the direction for every board: device-tree SoCs (ADR-0023) are parked until a tiered board needs one. The CIX Sky1 (Radxa Orion O6; SystemReady SR, booted with ACPI; Mali-G720 with CSF) is the candidate second arm64 board. Its survey found AML-reached firmware services and three CPU tiers (ADR-0024); its tables are checked at bring-up. The RK3588 was dropped on 2026-10-02: an older SoC whose firmware does little, so it would cost about three times the Q8B's platform work (ADR-0023), and with it went the only open NPU stack on a tiered board |
| **T2** | Raspberry Pi 5 (UEFI firmware), AMD APUs (UMA, RADV), Intel Xe, Apple Silicon (through the Asahi drivers and m1n1), Snapdragon X, NVIDIA Turing and later (NVK over GSP firmware) | Show the unified-memory SoC design on the hardware it was designed for |

## 6. What the API case study changes

The API case study was written for an XNU-based system, but most of its findings are about the platform surface rather than the kernel, so they carry over. [study/](study/README.md) keeps what this design takes from it. The friction IDs below refer to its register, [study/friction.md](study/friction.md); "heritage §N" to [study/heritage.md](study/heritage.md); Q2 and Q5 to [study/shapes.md](study/shapes.md) and [study/compat.md](study/compat.md); and S7 to [study/prototypes.md](study/prototypes.md).

| Study finding | Where it lands here |
|---|---|
| One wait for everything; self-post wake (heritage §4: Exec `Wait`, GEM `evnt_multi`, Horizon) — F-201 | Rule 4; the kernel `Port` object (01 §4.4) |
| Frame clock with actual presentation time; bounded queue depth; throttled rather than withheld when occluded — F-101, F-102, F-209 | Rule 8; frame lifecycle (03 §4) |
| Absolute-deadline timers, no resolution knob — F-203 | Rule 5; `port_wait` deadline and leeway (01 §4.4) |
| Threads declare intent; heterogeneous cores; topology as data — F-204 | Rule 6; scheduling (01 §8); `/sys/cpu` (02 §5) |
| Real-time audio: admission test, unprivileged within a budget — F-215, F-216 | Scheduling contexts with admission (01 §8); `audiod` contract (03 §7) |
| One buffer object with a format and a timeline fence; host memory as GPU memory; a kernel-owned GPU budget — F-107, F-108, F-109 | Rule 7; the zero-copy fabric (01 §6) |
| No modal loops, no main thread, server-side geometry, popups, title-bar regions, IME in the server, HID keycodes, pointer lock — F-201, F-202, F-205–F-213 | `/wsys` protocol (03 §5) |
| Gamepad class drivers in the system, not in every app — F-214 | `/dev/input/gamepads` (02 §5) |
| Batched asynchronous I/O queue as the asset primitive — F-217 | The rings are that queue (01 §4.3); `fsd` rings |
| Address-space reservations, views and JIT — F-218 | `as_reserve` and `as_map` with views; W^X JIT dual mapping (01 §5) |
| Q5 recommended Vulkan first, GL through Zink, a Wayland core+ bridge and SDL3 backends | Vulkan only; the rest is rejected under rule 13 and left to user-land ports. D6, D11 |
| A one-call GPU surface helper; a text-shaping step; real-time callbacks callable from C — S7 §3 | Toolkit surface (03 §6); callbacks are native, because the toolkit is C |
| Minimal program (window, frame, input, sound) in 12 calls or fewer | An exit criterion for the toolkit (03 §6) |
| Version 1 of a protocol is permanent, so capability queries are needed from day one (FreeMiNT/XaAES) | Rule 9; 9Px version negotiation (02 §3) |
| Do not copy: global locks, pointer-passing IPC, redraw storms, manual cache flushes | Capability IPC with no pointers into other tasks; retained surfaces; the kernel owns cache maintenance for non-coherent DMA |

## 7. Non-goals for v1

- Linux ELF binary compatibility. Ports are rebuilt from source. A Linux-ABI personality is possible later, because personalities are ordinary processes.
- Hard real-time certification. Real-time scheduling here is *admission-tested soft real time* for audio and frames.
- A new shading language, a new GPU API, or a new GUI markup language.
- Formal verification of the kernel. The ring and IPC protocols are model-checked instead (04 §7).
- Web applications that need JavaScript or WebAssembly. The system shows documents and runs native apps (07); a full browser is a user-land port, never part of the platform.
- Games that need kernel-level anti-cheat. Anti-cheat checks for Windows specifically, and no alternative OS can satisfy it. The gamers VectraOS serves play native and indie games and use emulators.
- Several local users on one node. v1 is single-user per node, as a Plan 9 terminal is. POSIX uids exist for ports, with one user. People share with each other across the swarm, through tokens (02 §3.4).

## 8. Budgets users feel

The microbenchmarks in 01 §12 keep the parts fast. These budgets measure what a person actually waits for. Each one is enforced in CI from the milestone that makes it measurable, and a regression fails the build, as the build-time budget does (04 §3.2).

| Budget | Target | Enforced from |
|---|---|---|
| Kernel entry to shell prompt | < 100 ms under KVM; < 500 ms on T1, not counting firmware | M2 |
| Spawn a static program until its `main` runs | < 200 µs | M2 |
| Boot image, kernel plus `bootfs`, release build | < 16 MiB | M3 |
| `posix_spawn`, exit and `wait`, round trip | < 500 µs | M4 |
| Open and read a 4 KiB file already in cache | < 5 µs | M5 |
| Open and read a 4 KiB file from NVMe | device latency + < 20 µs | M5 |
| `ls` of a directory with 10,000 entries | < 3 ms | M5 |
| Resident memory of all services at the shell prompt | < 32 MiB | M5 |
| Shutdown to power off | < 500 ms | M5 |
| Kernel entry to the first desktop frame | < 1 s on T1 | M7 |
| App cold start (the minimal program, 03 §6) to its first frame on screen | < 50 ms | M7 |
| Keypress to glyph in the terminal | The terminal draws within 1 ms of the key event, and the glyph reaches the screen within 2 frames | M7 |
| Terminal throughput: `cat` of 1 GiB of text | < 1 s, measured over the whole path: `cat`, `ptyd` and the terminal (01 §9). Neither `ptyd` nor the terminal is the bottleneck (refterm showed this is easy with a glyph cache and a pass-through console, 03 §6) | M7 |
| Idle desktop: timer wake-ups, measured over 60 s with nothing changing | 0 per second | M7 |
| Idle desktop: resident memory, without `aid` | < 256 MiB | M7 |

**Measurement:** `./build bench` runs the software side in QEMU and on T1 hardware, using timestamps from the kernel and `winsrv`. Input-to-photon needs real hardware, so a small rig measures it on T1: a microcontroller that sends HID key presses and watches a photodiode on the screen.

## 9. Glossary

| Term | Meaning |
|---|---|
| **Handle** | A per-task index into a table of (object, rights). It is the only way to reach a kernel object. |
| **VMO** | Virtual memory object: a set of pages, which may be anonymous, physical, contiguous or supplied by a pager. It can be mapped into address spaces and into device DMA domains. |
| **Port** | A kernel queue of completion packets. The one thing a thread waits on. |
| **Counter** | A kernel-visible 64-bit monotonic value (a timeline). Signalling it wakes waiters whose threshold it has reached. Used for ring doorbells and fences. |
| **Ring** | A pair of lock-free single-producer, single-consumer queues (submission and completion) in a shared VMO, plus a message arena, doorbell counters and a handle side channel. |
| **9Px** | The extended 9P protocol used between all file servers. |
| **Namespace** | A process's mount table: a mapping from paths to (server connection, root fid), with union directories. |
| **Swarm** | The set of nodes whose keys the owner has signed. Their namespaces can be mounted into each other. |
| **Intent** | The scheduling class a thread declares. It replaces priorities and affinities. |
