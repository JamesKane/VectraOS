# ADR-0034: Swift is a first-party language, in its full and embedded forms

Status: accepted, 2026-10-05 (proposed the same day; toolchain moved to Swift 6.4.0 before acceptance). Amends D1 and 04 §1. Bring-up is in progress in `../lang/swift-on-vectra` (S1 and S2 done).

## Context

D1 makes C23 the language of all first-party code. 04 §1 puts every other language in the community tier: "applications, through `vxui.h` and the POSIX layer; never in the base system". C23 under the house rules suits what most of the system is: a kernel, servers and drivers that move bytes between rings, built from arenas, handles and X-macro tables.

Some of what is still to be written has a different shape:

- **Object graphs with shared ownership.** These include an editor's documents and undo history, a desktop's scene and its windows, an agent runtime's sessions and tools (03 §8), a debugger's view of a program (05), a compiler's syntax trees, and caches with several owners. In C each of these needs a hand-written ownership scheme, and arenas fit them badly, because their lifetimes are not nested.
- **Polymorphism and functional patterns.** Protocol-shaped plug-points, enums with payloads checked exhaustively by `switch`, closures, and `map` and `filter` pipelines over collections. In C these become tables of function pointers, tagged unions checked by hand, and loops.
- **Namespacing.** C has one global name space, so every name carries a prefix (`vx_`, `hx_`, `wm_`), and a large program's internal structure is visible only by convention.

Swift addresses all three. It has value types with copy-on-write, classes with automatic reference counting (ARC), protocols and generics, enums with payloads, modules as namespaces, noncopyable types for handles with one owner, and `async`/`await` with actors and data-race checking at compile time. It calls C directly through its importer, so `libvx` stays the one API (D20). It has two forms:

- **Full Swift**: the runtime with metadata, existentials and reflection, Concurrency and FoundationEssentials. The Swift work plans it on `libvx` with no POSIX underneath (findings.md §1). It rests on ADR-0033's ISO C library and C++ subset, a `vx` threading back end, and a global executor on `vx_loop` and native threads.
- **Embedded Swift**: a subset with no reflection and no runtime metadata beyond what it generates, generics specialised at compile time, and binaries tens of KB in size. Swift 6.4 adds existentials (`any Protocol`) and untyped `throws` with `any Error`, which 6.3 refused. Swift ships it for the system's own bare-metal triples. On 6.3.1 it needed only an allocator, `putchar`, a random source and a few `libvx` symbols (findings.md §3, verified then; to recheck on 6.4, whose existentials may need more). With `-no-allocations` it needs no heap at all.

## Decision

### 1. Swift is a first-party language

Swift joins C23 as a language for first-party code. **C23 stays the default.** Swift is chosen for a component when the solution benefits from at least one of:

- **object-oriented or protocol-oriented structure:** polymorphism over a family of types, or a plug-point defined by a protocol;
- **functional patterns:** enums with payloads and exhaustive matching, closures, transformations of collections;
- **namespacing:** a program large enough that modules and nested types say more than prefixes;
- **ARC:** an object graph with shared, non-nested ownership that arenas do not fit.

The component's design note or ADR names which of these applies. Wanting a language other than C is not one of them.

### 2. Two forms, with different reach

| Form | Where it may be used | What it may use |
|---|---|---|
| **Full Swift** | Applications, the desktop's programs (`vxui` apps, `wm`'s non-Lua parts, the settings and grant surfaces), developer tools (`hx`, `dbg`'s front end), agent and AI services (03 §8), and servers that are started after the store and are not on the boot path | The runtime, `_Concurrency`, `Synchronization`, FoundationEssentials, and the `VX`, `VXUI` and `VXEngine` bindings |
| **Embedded Swift** | The above, and also code that must be small or freestanding: servers and drivers, including those on the boot path and in `bootfs`, and libraries those link | The Embedded standard library only. Drivers and real-time code build with `-no-allocations` unless their design note says why they need the heap |

**Not Swift:**

- **The kernel.** No general allocator, no recursion, `kcfi`, `-mgeneral-regs-only`, and every status checked (04 §1.1). Embedded Swift with `-no-allocations` may meet these one day. That needs an amendment with a prototype, not a reading of this ADR.
- **The ABI and the boundary:** `abi/`, `vx-rt` and `libvx` (the C and C++ runtime libraries are the toolchain's, ADR-0033). They are what every language binds to, so they stay C, and their interfaces stay the `.def` tables (10 §7).
- **Real-time audio callbacks** (03 §6, principle 5), unless they are Embedded Swift with `-no-allocations` and Swift's performance annotations (`@_noLocks`, `@_noAllocation`) check them.
- **System interfaces defined in Swift.** Protocols, 9Px trees, ring layouts and `.def` tables stay language-neutral. A Swift server serves files like any other. A Swift library that other languages call exports a C ABI (`@c`, with `@implementation` where a C header in the house style already declares the function) from a C header written in the house style.

### 3. How Swift reaches the system

- **Through `libvx` only.** The `CVX` module is `<vx/*.h>` imported by ClangImporter, with names fixed by API notes generated from `abi/vx/*.def`. `VX` is the hand-written Swift layer over it: namespaced types, noncopyable handles, typed `throws(VX.Error)`, and `async` over `vx_loop` (findings.md §8). Each `VX` call is one `libvx` call, so D20's one-hop rule holds and rule 13 is not touched: the bindings wrap the system's own API, not another system's.
- **No POSIX, Dispatch, Objective-C, ICU, swift-corelibs-foundation or CoreFoundation.** A Swift program is native. It is never a guest of the POSIX personality.
- **Concurrency runs on the system's scheduler.** It has a cooperative pool of native threads with the `throughput` intent, and a main executor on a `vx_loop`. `Task.sleep` takes absolute deadlines with leeway (rule 5). There are no priorities and no affinity (rule 6).

### 4. House rules for Swift

These are enforced by `./build check`, as the C rules are:

- **The language:** Swift 6 language mode with complete strict-concurrency checking, and warnings as errors (`-warnings-as-errors`, which also catches the importer's dropped functions, findings.md §8.2).
- **The format:** `swift-format`, pinned with the toolchain, with a root configuration matching the house format: two-space indents, and braces on the same line.
- **Debugging and backtraces:** DWARF 5 (D15, the toolchain's default for `vectraos`), and frame pointers kept in every function, so `dbg` and the profiler walk Swift frames as they walk C ones.
- **Memory:** ARC where ownership is shared; value types and noncopyable types where it is not; `Span` and `withUnsafe…` only in binding modules and in code whose design note says why. Per-frame and per-request work still meets the system's budgets. A Swift hot path that allocates in a loop is a bug, as it is in C.
- **Errors:** typed `throws` at module boundaries, so callers can switch on codes. Inside a module, untyped `throws` is allowed in both forms (Embedded since 6.4), except in code built with `-no-allocations`, where an `any Error` box is an allocation.
- **Building:** `./build` compiles Swift itself, one module per component with whole-module optimisation, as unity builds do for C, by calling the pinned `swiftc` by absolute path. Linking stays with the pinned `ld.lld` (ADR-0001). The OS build never runs SwiftPM.

### 5. Trusting the toolchain (ADR-0001, D13)

Swift's toolchain cannot come from Fedora's packages. It needs a triple patched in, and it carries its own LLVM, so it is built from source.

- **Pinned sources.** Swift 6.4.0 (`swift-6.4.0-RELEASE`), its LLVM, and swift-foundation, each at an exact upstream tag, with its tarball's hash recorded in `toolchain/swift/VENDOR.ndb`, as `third_party/` records imports. The sources are fetched once, by a script outside `./build`, and checked against those hashes. `./build` itself still never fetches.
- **A reviewed patch series in this repository.** It lives under `toolchain/swift/patches/`, and every patch is reviewed like first-party code. Today the series is in `../lang/swift-on-vectra/toolchain/patches/`, which is not under version control. It moves into this repository before any first-party Swift is merged.
- **Reproducible.** Two builds of the toolchain from the same pins give the same `swiftc`, standard library and runtime archives. `build.c` checks `swiftc --version` against its pin, as it does for clang, and refuses anything else.
- **The runtime ships as system code.** `libswiftCore`, `_Concurrency`, `Synchronization` and FoundationEssentials link into first-party programs: statically until the loader (M6 6f), then as shared libraries in the release. They are reviewed as imports under D13, by this ADR, with the patch series. FoundationEssentials' platform layer, rewritten over `VX`, is first-party code.
- **Two LLVMs, kept apart.** The pinned clang 22.1.8 compiles all C. Swift's own LLVM compiles Swift, the runtime's C++ and the C that ClangImporter reads. The two meet only as ELF objects linked by the pinned `ld.lld`. When clang is built from source (M12), the aim is one LLVM for both.
- **Packages from developers** may use SwiftPM against the `vectraos` SDK. Their dependencies are their business, under ADR-0014. Nothing a package brings enters the base system.

### 6. Gates before first-party Swift is merged

1. The toolchain is pinned, patched from this repository, and reproducible (§5).
2. ADR-0033's C library (llvm-libc with its VectraOS platform layer) and C++ support (libc++ and libc++abi) exist (M6 6e2), along with the threads and TLS that full Swift needs (6d).
3. `dbg` demangles Swift symbols and reads Swift's DWARF 5 types, enough to show locals and backtraces, so a Swift program can be debugged as a C one is (D15). This is the Swift work's gap G12.
4. `./build check` runs §4's rules.

Until all four hold, Swift on VectraOS is bring-up and experiment, in the Swift work's own repository.

## Alternatives

- **Stay with C23 alone.** This keeps one language, but leaves every graph with shared ownership to hand-written reference counting, and every protocol-shaped design to tables of function pointers. That is where C programs grow their worst bugs.
- **Rust.** D1's reasons still hold: its guarantees stop at `unsafe`, it needs `build-std` for our targets, and `std` brings registry dependencies. Also, its ownership model suits trees better than the shared graphs that motivate this ADR.
- **Odin, Zig, C++.** Odin and Zig have no ARC, protocols or modules of the kind §1 asks for. C++ has all three, but with a much larger surface and no ownership or concurrency checks at compile time. 04 §1 admits it only where no C alternative exists.
- **Full Swift only.** This would lose the drivers and boot-path servers, where a runtime with metadata and a heap is the wrong cost.

## Consequences

- D1 reads "C23, and Swift where ADR-0034 allows". 04 §1's table gains a Swift row, and "Odin and others" no longer speaks for Swift.
- The system has a second language to review, format, debug and build. `dbg`, `./build check`, the manual's tooling (12) and the profiler each grow a Swift path.
- The toolchain is the largest import the system has, and the first built from source. Its pin and patch series are reviewed like the kernel.
- M6 6e2's target `<arch>-unknown-vectraos` is the one Swift uses. The Swift work's clang driver patch (llvm 0003) and ADR-0033's configuration and response files give the same compile options and link line, and must stay in agreement.
- Swift work can proceed in parallel with M6, and joins the tree only through §6's gates.
