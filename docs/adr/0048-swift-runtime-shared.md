# ADR-0048: The Swift runtime as the system's shared libraries

Status: proposed, 2026-10-08. Scoped the same day; decided then: the runtime is shared from M6 step 6f3 on, with its ABI frozen later at a named point; availability is Apple's, a VectraOS platform with an OS version; Foundation ships with the runtime. Built in M6 step 6f3 (6f3a–6f3e). Extends ADR-0034 ("the runtime ships as system code … then as shared libraries in the release") and ADR-0047 (the loader).

## Context

ADR-0034 makes Swift a first-party language and its runtime system code. Until now every Swift program links that runtime statically: `swifta` carries about 8 MB of it, `swiftfnd` 20 MB with FoundationEssentials, and every program has its own copy of the type metadata caches, the conformance tables and the global executor's state. A fix to the runtime reaches a program only when it is rebuilt.

Apple ships the runtime in the OS (`/usr/lib/swift`) and has kept it ABI-stable since Swift 5.0. An app is built against an SDK for a deployment target and runs on that OS release and every later one. Four pieces make that work: the stdlib is compiled with library evolution (resilient types, so a later runtime may change a type's layout); module interfaces (`.swiftinterface`, module stability since 5.1), so a later compiler can build against an earlier SDK; availability tied to OS versions (`@available(macOS 10.15, *)`, the stdlib's `SwiftStdlib x.y` macros mapped to OS releases, and `@backDeployed`); and an ABI check per release (`swift-api-digester` against a baseline). Linux ships `libswiftCore.so` without promising any of this: each toolchain's programs need that toolchain's runtime.

What our build already has (measured 2026-10-08):

- `SWIFT_STDLIB_STABLE_ABI` is on, so the stdlib is compiled with `-enable-library-evolution`. Module interfaces are off.
- The runtime makes no `dlopen`, `dladdr` or `dlsym` call and has no static TLS of its own. It finds each image's metadata through that image's `swiftrt.o`, which registers it at start, so several Swift images in one process work as they are (ELF image inspection, not the static kind).
- `ld-vx` binds through the GNU hash table, which matters at this size: about 26,000 exported symbols in `libswiftCore` and 33,000 in FoundationEssentials.
- The compiler has no VectraOS availability platform: `@available` cannot name a VectraOS release, and the stdlib's availability macros cover Apple's platforms alone.
- The runtime reaches the system only through libvx's hooks (`__swift_vectraos_*`, `__llvm_libc_*`; Swift patch 0007 and on), so those hooks become part of what a shared runtime binds to.

## Decision

1. **The runtime is shared, in `/lib`.** `libswiftCore`, `libswift_Concurrency`, `libswiftSynchronization`, `libswift_StringProcessing`, `libswift_RegexParser`, `libswiftRegexBuilder`, `libswiftObservation`, the `VectraOSLibc` overlay, and FoundationEssentials (which swift-foundation links `_FoundationCShims` and `_FoundationCollections` into, as static parts) are built as shared objects (`libNAME.so`, soname without a version until the freeze, item 5) and shipped in the base set's `/lib`, which ADR-0047's loader takes them from by name: no rpath, no search path. A Swift program links them by default (the drivers' `staticStdlibByDefault` becomes false on VectraOS); `-static-stdlib` and `-static-executable` keep today's links for programs that ask. Embedded Swift (ADR-0034) is unchanged: it has no runtime to share.
2. **Module stability.** The SDK carries each library's `.swiftinterface` (`SWIFT_ENABLE_MODULE_INTERFACES`), so a program can be built against a release's SDK by a later compiler. The stdlib stays compiled with library evolution.
3. **Availability is VectraOS's, by OS release.** The compiler gains a VectraOS platform: `@available(VectraOS 1, *)` and `#available(VectraOS 1, *)`, a deployment target in the triple (`x86_64-unknown-vectraos1`; no version means the SDK's own release), and `@backDeployed(before: VectraOS n)`. The stdlib's `SwiftStdlib x.y` macros map to the VectraOS release that first shipped that runtime; versions before the first shipping release map to it. Both drivers pass the deployment target through. A program built for release N that uses an API newer than N fails to compile, as on Apple's platforms.
4. **An ABI check per release.** `./build release` runs `swift-api-digester` over each shipped library's interface against the previous release's baseline. An ABI break fails the release once the ABI is frozen; before that it is reported, and an API change is a release note either way (09 §4.8, 06 §9.2). The baselines live in the tree, one per frozen release.
5. **The ABI freezes later, at a named point.** Until then a release's runtime and its programs are built together, as now, and nothing outside the release depends on the runtime's ABI. The freeze is decided with libvx v0's (ADR-0004), before programs from outside the release exist, since the shared runtime binds to libvx's hooks and both must hold together. From the freeze on: an app built for release N runs on every later release; the sonames take a version; and the release's matrix runs the previous release's Swift programs against the new runtime.
6. **The hooks are part of it.** The `__swift_vectraos_*` hooks and the C and C++ hooks the runtime reaches through llvm-libc and libc++ are exported by `libvx.so` and frozen with it (item 5). A new hook is an addition; a changed one is an ABI break, checked as the rest of libvx's exports are.

*Built 2026-10-08 (6f3a):* the libraries are built shared in swift-on-vectra (each names libc++, libc++abi, libunwind and the C library, and carries the compiler's builtins unexported; Swift patches 0018 and 0019, swift-driver 0003) and shipped in `/lib`, about 25 MB per architecture. The stage programs shrink from 8.4–20.4 MB to 150–210 KB. Their code is shared through bootfs's `Tmap` (ADR-0047 point 4); the kernel's per-task tables grew to 341 mappings and 128 reservations to hold a dozen libraries. Start-up, measured with `time` at 10 ms resolution: under x86_64 KVM a dynamic `swifta` takes 0.16–0.44 s against 0.04–0.24 s static (binding the runtime); under aarch64 TCG 0.38–1.33 s against 0.44–1.35 s (no 8 MB image to copy).

## Consequences

- Swift programs shrink to their own code (`swifta` from 8.5 MB to 181 KB with debug information, 6f3a), and the runtime's code is shared between processes. Starting one costs binding the runtime's symbols (`-z now`): about 0.15 s more for `swifta` under x86_64 KVM (6f3a), a known gap to work down.
- Runtime fixes reach every Swift program with the release that carries them, and a changed behaviour is a release note, as for libvx (09 §4.8).
- The compiler carries one more VectraOS patch (the platform kind, the triple's version, the availability macros' mapping), in both drivers and the frontend.
- Until the freeze, the runtime may change freely, but every Swift program in the release is rebuilt with it; after it, the runtime's ABI is a promise the project keeps for as long as Apple keeps theirs, release after release.
- The deferred behaviour suite (6f1c3) and this ABI check are the same mechanism, for libvx and for the Swift libraries: whichever lands first builds it.

## Alternatives considered

- **Linux's model** (shared, no ABI promise; each toolchain's programs need its runtime): simpler, but third-party Swift programs would then have to carry the runtime, which is the static link again, or be rebuilt for every release.
- **Freeze at once:** locks in Swift 6.4's runtime and today's platform patches before the system's own APIs (libvx v0) are frozen.
- **The runtime's own version for availability** (`SwiftStdlib 6.4`, no platform kind): no compiler patch, but no deployment target, no `@backDeployed`, and no way to say a program needs a given VectraOS release.
- **Runtime without Foundation:** keeps FoundationEssentials static in each program until its ABI is settled; but ADR-0034 names it as shipped runtime, and it is the largest single copy (20 MB in `swiftfnd`).
