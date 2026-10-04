# 13 — Portable code: design notes

_Design notes, 2026-10-04. **Non-binding.** These are exploration notes on compiling the user land, or part of it, to a portable target shaped like core WebAssembly, then lowering it to native code on the machine that runs it. Nothing here changes a rule or decision in 00, and nothing is scheduled. A part becomes binding only through an ADR, and D12 and rule 13 would need their wording looked at first (§9). Prior art and the state of Wasm in §10 were checked against sources on 2026-10-04._

## 1. Why this is worth thinking about

The blueprint names two architectures, x86_64 and aarch64, and builds each from source. Two is a small, known set, and a fat package covers it. The set is not going to stay that size:

- **RV64 is a likely port.** Two boards are on hand to test with.
- **Community ports are possible and welcome:** PPC, SPARC, even 68K. No one can say which will exist in ten years.

For code built from source, more ISAs cost little, because each port brings a compiler back end and everything is rebuilt. Other cases suffer:

1. **Closed-source third-party programs, mostly indie games.** The developer ships binaries once, cannot test on hardware they do not own, and will never rebuild for a port that appears after the game ships.
2. **A swarm with mixed ISAs.** Plan 9 handles this by binding `/$cputype/bin` on each node (02 §6). Every program then exists once per ISA, and a job runs on another node only if a build for that node's ISA exists.
3. **Distribution.** `distd` shares content-addressed blocks between peers (06). Peers with different ISAs share no program blocks at all.

A portable form that is lowered on the machine that runs it addresses all three. It is Blow's "Java bytecode but not married to any particular backend … an abstracted version of machine instructions that just operates on memory". It is also his complaint that the operating system used to be the thing that "would reliably rerun the same program over time", extended from years to ISAs.

## 2. The idea in one paragraph

Programs are compiled from C23 (or Odin, Zig, Rust, anything with a Wasm back end) to a **profile of core Wasm**: no WASI, no component model, no browser. Their only imports are `libvx` (09), generated from the same `abi/vx/*.def` tables as the C headers. On install, or on first run, the system **lowers** the module ahead of time to a native ELF for the local ISA, caches it by hash, and runs it as an **ordinary process**, confined by its namespace like any other. There is no interpreter on the hot path, no JIT, and no second sandbox. `libvx` itself stays native on every ISA: it is the boundary.

## 3. The portable profile

Core Wasm is small, its spec is frozen in versions, and many compilers already emit it. The profile takes a subset that is deterministic and maps onto every plausible ISA.

| Feature | In or out | Why |
|---|---|---|
| i32, i64, f32, f64; 8- and 16-bit loads and stores | In | The whole point. Blow's "smallest integer is 32 bits" is about locals, which match register widths on every target |
| `v128` SIMD | In | Deterministic, and maps to SSE, NEON, RVV, AltiVec. Wider SIMD comes from a native image (§6) |
| Relaxed SIMD | **Out** | In Wasm 3.0, but its results differ by ISA, which breaks determinism (§6). Wasm 3.0 also defines a deterministic profile; this profile should be a subset of it |
| Bulk memory, multi-value, tail calls, sign extension, saturating conversions | In | Small, and compilers use them |
| Atomics and shared memory (threads proposal) | In | Threads are rule 6's job systems. Spawning a thread is a `libvx` import, not WASI. The proposal is at phase 4 but in no published spec version as of Wasm 3.0, so this row depends on it landing unchanged. WASI's own thread spawn (wasi-threads) was withdrawn in 2023, so nothing upstream competes with the `libvx` import. Whether a thread is a new instance or shares the old one's tables and globals is §11, question 8 |
| Stack switching | Out until it is standardised | Fiber-based job systems, the usual shape in game engines, need it, and core Wasm cannot express them. The proposal is at phase 3. Until it lands, a portable job system uses threads and queues, and a fiber-based engine stays native (§6) |
| Multiple memories | Open | Could give each mapped VMO its own memory. §4.2 proposes a simpler way |
| Custom page sizes | Out at first | A 1-byte page lets a memory end partway through a host page, so guard pages no longer catch every access out of bounds and the checks become explicit (§5). It serves small embedded hosts, which this system does not target. Phase 3 |
| memory64 | Open | Needed for programs over 4 GiB. Costs an explicit bounds check, where memory32 gets one free from guard pages on a 64-bit host (§5) |
| Exception handling | Out at first | C does not need it. Revisit for C++ |
| GC, reference types beyond `funcref`, stringref | Out | Not machine instructions on memory |
| WASI, the component model, WIT | Out | A second system interface. `libvx` is the one (D20, one-hop rule) |

## 4. The host side

### 4.1 Imports are `libvx`

Each `libvx` entry point is a Wasm import from module `vx`. Pointers are offsets into linear memory, and handles are i32 ids, as `vx_fd` already proposes (09 §10, question 4). The import list, signatures and record layouts come from `abi/vx/*.def`, the role WIT plays for WASI (10 §7). A C program sees `<vx/*.h>` unchanged. Only its compiler target differs.

The lowerer turns each import into a direct call to native `libvx`, translating offsets to addresses at the boundary. That is a base add, and a bounds check where a call passes a length.

### 4.2 Zero-copy: VMOs mapped inside linear memory

Wasm's usual weakness for this system is that a module sees one linear memory, and nothing outside it. GPU buffers, audio rings and input rings would need copying in, and rule 7 forbids that.

Lowered ahead of time, linear memory is just a reserved native address range. The host can **map a VMO at a page-aligned offset inside it**: an import such as `vx_map(handle, offset, len, rights)` calls `as_map` with `AS_FIXED` (01 §5) at base + offset. The module then reads and writes the buffer as ordinary memory, with no copy. The Wasm spec does not forbid the host changing memory contents. Whether the toolchains' memory allocators can leave holes for this is a question to prototype (§11, question 2).

Wasm's **memory-control proposal** (phase 1) describes the same operation: `memory.map` and `memory.unmap` give a module mmap inside its own linear memory, a "virtual mode" gives per-page mapping and protection, and `memory.discard` zeroes pages and returns them to the host. `vx_map` should take the proposal's meaning, offsets, alignment and rights included, so that if it is standardised the import becomes the instruction and the profile stays a subset of a published spec (§11, question 5). `memory.discard` also answers a common complaint, that linear memory can grow but never shrink. In lowered code it is a decommit through `vmo_op` (01 §5).

Every pointer in the module is already an offset from a base. So 01 §6.6's structured sharing, where links are offsets inside a VMO, needs no adaptation. A portable program and a native one can share a sealed structure as long as both use offset links.

### 4.3 Lowering and the cache

- **When:** at install by `install` (06), or at first run for programs fetched another way. The cost is paid once per (module, ISA, lowerer version).
- **Where:** the result goes into the store keyed by `BLAKE2b(module hash ‖ ISA ‖ lowerer hash)`. The signed artifact is the module, and the lowered image is derived from it. Anyone can repeat the lowering and compare the bytes, because the lowerer is deterministic (04 §7's reproducibility, applied to a second stage).
- **What it emits:** restricted ELF (10 §7), so the loader (M6f), hot reload, `dbg` and `/proc` see an ordinary program.

### 4.4 The lowerer, in stages

| Stage | Lowerer | Notes |
|---|---|---|
| L0 | **Wasm to C, compiled by the system clang.** The approach of wasm2c and w2c2 | Cheapest. Works on any ISA clang targets. Needs clang on the machine, which M12 brings, or lowering on a build host for now |
| L1 | **An interpreter** for bringing up a new port | Slow, but a new ISA runs every portable program on the day its kernel boots. A few thousand lines of C |
| L2 | **A Wasm front end in `vc` (10 §5)** feeding its SSA middle end | A port then means a kernel plus one `vc` back end, and every portable program comes with it. Fits 10's size budget, because Wasm is easier to parse than C |

## 5. Costs, and what lowering ahead of time recovers

| Cost | Size | Answer |
|---|---|---|
| Bounds checks | Free for memory32 on a 64-bit host, using a 4 GiB reservation plus guard pages. Explicit for memory64 and on 32-bit hosts | Prefer memory32 where it fits. Hoist checks out of loops in L2 |
| Adding the base to every address | One add per access, and a register held for the base | On x86_64, keep the base in a segment register and use segment-relative addressing. Segue (ASPLOS 2025) measured this removing 44.7% of Wasm's overhead on a Wasm-compatible subset of SPEC CPU 2006. The paper built it into wasm2c and WAMR, so L0 can do the same, and L2 directly. Other ISAs have spare registers and keep the add |
| `call_indirect` type check | One compare per indirect call | Acceptable |
| No AVX2, AVX-512 or SVE | Large for some hot loops | A native image beside the portable one (§6) |
| No inline assembly | None for the programs this targets | Code that needs it is native, as `vx-rt` and the arch code are |
| Debugging | Real | Wasm modules carry DWARF in custom sections. The lowerer must remap it to the lowered code so `dbg` shows the original source (D15). L0 makes this hard. L2 can do it properly. Until then, developers debug their native build |
| Lowering time and cache space | Seconds per program, a second copy on disk | Once per install, and garbage-collected with the store |
| Byte order | Wasm memory is little-endian | Every system format is little-endian already (11, ADR-0017, 06, the `accel` protocol). A big-endian port swaps on every load whether or not this exists, so this costs it nothing extra |

## 6. Packages: native first, portable as the fallback

A package may carry any of:

- **native images** for the ISAs its developer built and tested;
- **one portable module.**

`install` picks the local native image if there is one, and otherwise lowers the module. First-party code stays small and native, as the blueprint has it. A game can ship x86_64 with AVX2, aarch64 with NEON, and a portable module that runs everywhere else, including on ISAs that do not exist yet.

**Determinism comes free.** With relaxed SIMD out, core Wasm pins IEEE float behaviour apart from NaN bit patterns, and Wasm 3.0's deterministic profile pins those too. The portable form of a program then computes the same results on every ISA. That gives lockstep multiplayer and replays across x86, ARM and RV64 without the usual care over compiler flags and fused multiply-add.

## 7. How far up the stack: the tiers

"Full stack" can mean several things. Each tier is a separate decision, cheapest first.

| Tier | Portable? | Reasoning |
|---|---|---|
| **Kernel** | No, never | Arch code, page tables, traps. Built from source per ISA |
| **`vx-rt`, `libvx`, the loader** | No | The boundary itself. Native per ISA |
| **Boot path and early servers** (`svcd`, `fsd`, drivers before the store) | No | Nothing can be lowered before the store and the lowerer are running. They stay static and native (09 §10, question 1) |
| **Third-party programs** | **Yes: the main case** | §1 problem 1 |
| **First-party apps and tools** (`hx`, `hv`, `gsh`, the `vxui` apps) | Open | Benefits: one release artifact for every ISA, so `distd` peers share blocks across ISAs; a community port gets the whole user land without the project building it; `cpu` can move work to a node of any ISA (02 §6). Costs: the §5 costs, paid by first-party code that does not need them. One middle way is to ship both, with the portable module as a check that the release builds for an ISA nobody tested |
| **User-space drivers** | Speculative | MMIO is memory, through mapped regions (§4.2), and DMA buffers are VMOs. A portable NVMe or virtio driver would serve every ISA. Needs fence and barrier semantics checked against each ISA's device-memory rules. Interesting, and last |
| **Lua and scripts** | Unchanged | Lua is already portable source. Its interpreter is just one more native or portable program |

The tiers show that this is not "WASM instead of native". It moves the line between what is built per ISA and what is built once, from "everything" toward "the kernel and its runtime".

## 8. What Blow would say

- **He'd agree with:** a stable instruction format that "just operates on memory", run natively, with protection supplied by the OS rather than by the format. No server, no serialising: §4.2 and 01 §6.6 mean structures pass by mapping.
- **He'd object to:** 128-bit SIMD as a ceiling (answered only by §6's native images), losing inline assembly, and any lowerer the developer cannot see through when profiling. §5's debugging row is where this succeeds or fails for a game developer.
- **What he'd notice:** the profile drops nearly everything that makes Wasm complicated, which is the part he said he expected to dislike.

## 9. Fit with the rules

| Rule or decision | Tension | Reading |
|---|---|---|
| **D12** rejects Wasm as "a second runtime, with its own sandbox, for a problem namespaces already solve" | Apparent | This is neither a runtime nor a sandbox. Lowered code is a native process, confined by its namespace. D12's rejection of Wasm *for extensions* stands unchanged. The alternative it rejects is now well developed: lowered Wasm as software fault isolation inside the host's process, as Firefox does with RLBox (§10). Unlike protection keys, that would be a real boundary against hostile code. It stays rejected because 01 §6.6 already shares structures between processes without copying, and a second boundary inside the process would mean a second set of rules for every plugin to follow |
| **Rule 13**, no portability layers | Real, and needs wording | The portable form wraps no other OS. Its only API is `libvx`. It is a code format, as 10 §6 treats Git's object format as a data format. An ADR would need to say so explicitly |
| **D1**, C23 | None | The source language is unchanged. This is a compiler target |
| **D13**, no registries | None if first-party | The L0 translator, the L1 interpreter and L2 are small enough to write. The Wasm spec is read, not imported |
| **D15**, DWARF 5 only | Real | §5. L2 must carry DWARF through, or the portable form is release-only |
| **D20**, the one-hop rule | None | Imports are `libvx` itself |
| **Rule 7**, zero copy | Answered by §4.2 | Must be prototyped before anything else |
| **06**, signed releases | Extends | The signed thing is the module. Lowering is a reproducible local step |

## 10. Prior art

Checked 2026-10-04; sources follow each entry.

- **IBM System/38 and AS/400 (the Technology Independent Machine Interface).** Programs were compiled to a machine-independent interface and translated to native code on the machine. When AS/400 moved from its CISC processors to PowerPC (OS/400 V3R6 in 1995, then V4R1 in 1996), programs were retranslated from the interface templates stored with them, with no recompiling from source. The catch: a program whose templates had been removed could not be retranslated, and customers who had lost the source were stuck. The lesson for §4.3 is that **the portable module is the program, and the lowered image is only a cache.** Never ship or keep only the lowered image. Sources: [IBM AS/400](https://en.wikipedia.org/wiki/IBM_AS/400), [IT Jungle on the PowerPC move](https://www.itjungle.com/2007/08/20/tfh082007-story01/).
- **Inferno and Dis.** Inferno is Plan 9's own sequel, from the same Bell Labs group (1995–96): Styx is 9P, and per-process namespaces carry straight over. Programs are written in Limbo and ship as Dis code for a portable virtual machine. Dis is compiled on the fly to x86, ARM, MIPS, PowerPC and SPARC, and Inferno runs either native or hosted on another OS. It is the closest precedent this project has: the Plan 9 group's own answer to portable binaries. It differs from §2 in compiling at load, not at install, and in tying the format to one language and its garbage collector. Vita Nuova maintains it as free software. Sources: [inferno-os](https://github.com/inferno-os/inferno-os), [the Dis compilers in `libinterp`](https://github.com/inferno-os/inferno-os/tree/master/libinterp).
- **Slim binaries (Michael Franz, ETH Zürich, 1994–97).** Oberon modules shipped as a compact, architecture-neutral tree encoding (semantic dictionary encoding) and were turned into native code as they loaded. Franz's argument was that the portable form is so much smaller than native code that reading it from disk saves about as much time as generating the code costs. The work went on as Juice, a browser plug-in. It is the Wirth line's answer to the same problem, and a second success beside AS/400, though inside one language. Sources: [Slim binaries, CACM 1997](https://dl.acm.org/doi/10.1145/265563.265576), [Code-Generation On-the-Fly](https://www.researchgate.net/publication/33834773_Code-Generation_On-the-Fly_A_Key_to_Portable_Software).
- **Tao Group's TAOS, Elate and intent.** Code shipped as VP (Virtual Processor) code and was translated to native at load on many ISAs. In 2000 Amiga Inc. chose it as the base of AmigaDE (later Amiga Anywhere). Sources: [EE Times, 2000](https://www.eetimes.com/amiga-reborn-via-tao-alliance/), [OSNews interview](https://www.osnews.com/story/157/tao-group-on-elateos-amigade-and-more/).
- **Android ART.** ART compiled dex ahead of time at install from Android 5.0. Since 7.0 it installs without compiling, runs with an interpreter and a JIT, and compiles the hot methods ahead of time later, guided by profiles, while the device is idle. For §4.3, a lowering that waits for idle time is an option if install-time cost becomes a problem. Sources: [ART JIT](https://source.android.com/docs/core/runtime/jit-compiler), [configuring ART](https://source.android.com/docs/core/runtime/configure).
- **WALI, the WebAssembly Linux Interface (2023; WebAssembly Workshop at POPL 2024).** Wasm modules import Linux's system calls directly, as a "thin kernel interface", and WASI is rebuilt as an ordinary Wasm module above them. It runs on Linux and Zephyr, with syscall costs close to native and fast startup. It is the published case for §4.1: the imports should be the system's own interface, and anything higher is a library. Its sections on translating memory addresses and on signal handling are the ones to read before designing the `vx` imports. Sources: [paper](https://arxiv.org/html/2312.03858v3), [WAW 2024](https://popl24.sigplan.org/details/waw-2024-papers/2/WALI-A-thin-Linux-kernel-interface-for-WebAssembly).
- **Operating systems that run only Wasm.** k23 (2024 to now) is a microkernel with Cranelift inside it, compiling Wasm components at run time. Kwast and wasm_os run Wasm in ring 0 with one address space and no hardware isolation. They make the opposite choice to §2: the runtime and the sandbox are the system, where here lowered code is an ordinary process. None has got past early demos. Sources: [k23](https://github.com/JonasKruckenberg/k23), [Kwast](https://github.com/kwast-os/kwast), [wasm_os](https://github.com/IntegralPilot/wasm_os), [a 2025 roundup](https://anil.recoil.org/notes/wasm-on-exotic-targets).
- **Uxn and Varvara (Hundred Rabbits).** A stack VM of about 100 lines of C that carries a text editor, a drawing program and games to everything from a Game Boy Advance to a Raspberry Pi Pico. Their permacomputing argument is that software lasts when its VM is small enough to port in a weekend. It is the case for keeping L1 to a few thousand lines. Source: [100R](https://100r.co/site/uxn.html).
- **The component model's copying.** Its canonical ABI copies strings and lists into the callee's memory through an allocator the callee exports. One published plugin benchmark puts it at 2.8 GB/s against 3.1 GB/s for native C calls, and about 6× faster than JSON-RPC: better than a server, but still the copy §3 leaves out. Source: [DEV](https://dev.to/neeraj_singhi_golang/webassembly-component-model-in-go-backends-sandboxed-plugin-execution-host-abi-design-and-the-5227).
- **Isolation inside a process.** Not used here (§9, D12), but it is the field Blow says has no right answer, and it is moving.
  - RLBox lowers a library to Wasm and then to C with wasm2c, and runs it in the host's process as a sandbox (the Wasm-to-C translators, below).
  - Segue and ColorGuard (ASPLOS 2025) cut Wasm's overhead with x86 segment registers (§5), and fit up to 15× more Wasm instances into one address space by colouring their memories with protection keys. Source: [paper](https://cseweb.ucsd.edu/~tullsen/asplos_segue.pdf).
  - HFI (ASPLOS 2023) is a proposed ISA extension: base-and-bounds regions for sandboxes inside a process, which also hold against Spectre. A preliminary RISC-V version exists, which matters to the RV64 port if hardware follows. Sources: [paper](https://cseweb.ucsd.edu/~dstefan/pubs/narayan:2023:hfi.pdf), [RISC-V spec v0](https://shravanrn.com/riscv-hfi.pdf).
  - CheriBSD's c18n runs each shared library in its own compartment, with rights taken from its ELF linkage and crossings inserted by the runtime linker. A 2026 paper reports Chromium with over 500 compartments per process. It is Blow's dynamic-library plugin with isolation added, but needs CHERI hardware (Morello, CHERIoT). If such hardware reaches a target, the M6f loader's linkage data is the input. Sources: [c18n](https://ctsrd-cheri.github.io/cheribsd-getting-started/features/c18n.html), [paper](https://arxiv.org/html/2609.36731).
- **Verified bytecode for hooks.** uBPF and bpftime run eBPF in user space, checked by a verifier before it runs. That suits small hooks such as filters. Here, small hooks are Lua (D12). Source: [bpftime](https://eunomia.dev/others/miscellaneous/bpftime-kubecon-draft/).
- **Failures.**
  - ANDF: OSF's call for technology in 1989 chose the UK DRA's TDF in 1991. It was never widely adopted, though the TenDRA compiler survives ([TDF guide](http://www.tendra.org/tdf-guide/)).
  - PNaCl: Google deprecated it for WebAssembly on 30 May 2017 and dropped it from the open web in 2018 ([Chromium blog](https://blog.chromium.org/2017/05/goodbye-pnacl-hello-webassembly.html)).
  - Apple's bitcode: required for watchOS and tvOS, then deprecated in Xcode 14 (2022). The App Store stopped accepting it ([Xcode 14 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes)).

  Each was a portable form beside a native ABI that already worked. PNaCl and bitcode were used where their owner controlled every ISA. §1's situation is the opposite: an open-ended set of ISAs and ports run by others. The success, AS/400, was a single vendor's system whose own hardware changed under it, which is closer to §1.
- **Wasm-to-C translators,** for L0.
  - wasm2c is part of WABT. Firefox's RLBox moved from Lucet to wasm2c and shipped it in Firefox 95 (2021) ([Mozilla Hacks](https://hacks.mozilla.org/2021/12/webassembly-and-back-again-fine-grained-sandboxing-in-firefox-95/)).
  - w2c2 aims at old and unusual systems. Its README lists Mac OS 9, NeXTSTEP, OPENSTEP, Haiku and DOS; x86, ARM, PowerPC, SPARC and PA-RISC, big-endian ones included; and old compilers such as CodeWarrior ([w2c2](https://github.com/turbolent/w2c2)). It is evidence that a community port to PPC or SPARC would get L0 nearly for free.
- **The state of Wasm.**
  - Wasm 3.0 was completed on 17 September 2025. It standardised memory64, multiple memories, tail calls, exception handling, GC, typed references, relaxed SIMD and a deterministic profile ([announcement](https://webassembly.org/news/2025-09-17-wasm-3.0/)).
  - The threads proposal is at phase 4 but in no published spec version yet ([proposals](https://github.com/WebAssembly/proposals)).
  - wasi-threads was withdrawn in 2023 for shared-everything-threads, which is still at phase 1 ([wasi-threads](https://github.com/WebAssembly/wasi-threads)).
  - Stack switching and custom page sizes are at phase 3, and memory-control at phase 1 ([proposals](https://github.com/WebAssembly/proposals), [memory-control](https://github.com/WebAssembly/memory-control/blob/main/proposals/memory-control/Overview.md)).
  - The value types are i32, i64, f32, f64 and v128, plus reference types; 8-, 16- and 32-bit loads and stores exist for the integer types ([types](https://webassembly.github.io/spec/core/syntax/types.html)).

## 11. Open questions

1. **Is the portable form worth it below third-party?** §7's first-party row is the real fork in the road. A cheap way to decide is to measure it on the first RV64 port: build `hx` both ways and compare.
2. **Can VMOs be mapped into linear memory under real toolchains?** Clang's Wasm target and `wasi-libc`-free C need an allocator that leaves the reserved holes alone. This is the first prototype, because rule 7 depends on it.
3. **memory32, memory64, or both?** memory32 makes bounds checks free and covers most games. memory64 is needed for large assets held in memory. Possibly memory32 by default, with memory64 per package.
4. **The performance bar.** Proposed: a game-shaped benchmark (a job system, SIMD math, a frame loop, VMO-mapped buffers) within 20% of native through L0 on x86_64, aarch64 and RV64. Below that bar the idea stops.
5. **Our own profile, or exactly core Wasm?** Staying a strict subset of a published spec, and of Wasm 3.0's deterministic profile, keeps every existing compiler as a producer. Any extension, such as a `vx`-specific instruction, would make it a private IR, and §10's failures were private IRs.
6. **Where does lowering run on a machine without clang,** before L2 exists? On a build host, or by `distd` on a peer of the same ISA that publishes the lowered image under the §4.3 key, with the result checkable by anyone.
7. **Does a heterogeneous swarm change `cpu`?** With portable programs, `/$cputype/bin` becomes a cache, not a requirement (02 §6).
8. **Is a thread a new instance?** Under the threads proposal each thread is its own instance sharing one memory, so function tables and mutable globals are per thread, and code loaded later has its function references copied into every thread's table. A lowered program could share one table and one set of globals among native threads, which is simpler and faster, but no longer the published semantics. Shared-everything threads (phase 1) may standardise the shared form. Until then: follow the spec, or make sharing part of the profile and accept a private rule (question 5)?
