# D124. Shared libraries: tier 1 programs start dynamically linked against one copy of the Swift runtime and Kit, bound by the spawner's loader from `/lib`, all at load, with static TLS (2026-10-22, proposed, for the owner's review; extends D47, D92; takes NeoVectra's ADR-0047)

Every tier 1 program is a static PIE carrying its own Swift runtime,
Concurrency, Synchronization, Kit, UICore, the text stack, Light, Themes
and VX: about 13 MB each (rio 13.3 MB, Tracker 15.7 MB, foundation-test
19.6 MB). Six desktop apps hold about 70 MB of the same code. The vt boot
already reaches memory-pressure Warning in QEMU's 512 MB, and the boards
(V6) have real memory limits. The owner deferred this on 2026-10-19 ("We
can deal with the large objects for awhile") and asked for the design at
V5's close.

## What the donors did

- **NeoVectra, ADR-0047** (accepted 2026-10-11, implemented in C as
  `cmd/ld-vx.c` and `lib/vx-dl`, about 770 lines):
  - A program with `PT_INTERP` is started by its interpreter,
    `/lib/ld-vx`. That is a static program at a fixed address, which
    loads the executable from a VMO, inside the new process, as Fuchsia's
    does.
  - A library is `/lib/NAME` for its `DT_NEEDED` name, in the process's
    namespace, with no search path.
  - Read-only segments are mapped from the file's VMO, so processes share
    them. Text relocations are refused.
  - Every symbol is bound at load (`-z now`), with no lazy binding and no
    interposition. The lookup order is the executable, then the libraries
    in load order.
  - The initial set's TLS is static and reached by initial-exec; dynamic
    TLS waits for libraries loaded later.
  - A versioned handover tells the program's runtime the objects loaded
    and their TLS blocks. The runtime lays out every thread's TLS and runs
    the initializers, dependencies first.
- **todhchai, M5k part 3** (2026-10-11) chose the other way:
  - shared objects are loaded into static programs (`dlopen`), not PIE
    programs with an interpreter;
  - the program exports its runtime (`--export-dynamic`), so there is one
    heap and one Sys.
  This is our `system/ld` today, ported in V2 and given fresh copies for
  hot reload (D122).
- **NeoVectra, doc 16 §7**: a shared Swift module built with library
  evolution makes non-`@frozen` structs opaque and stops generic
  specialization across the boundary. Its answer is `@frozen` and
  `@inlinable` for hot types.

## Proposed

ADR-0047's rules, in our Swift loader, with two changes:

1. **The spawner loads and binds; there is no interpreter.**
   - `Program.load` (user/lib/loader, shared by userboot and Sys's
     `Process.start`) already maps a PIE into the new process from the
     parent's side and applies its relocations there. It gains a step: it
     walks `DT_NEEDED` breadth first, maps each library once, and binds
     every object against the whole set with system/ld's core
     (`Ld/Dynamic.swift`).
   - So there is one loader, `system/ld`, for programs at start (here) and
     for `dlopen` and hot reload later (inside the process), and no
     interpreter image or second start-up path.
   - This diverges from ADR-0047 and Fuchsia, which bind inside the
     process. Our spawner already does a PIE's relocation (a parent-side
     loader is what we have), and binding there costs the child nothing
     before main.
2. **No library evolution.**
   - bootfs is built whole from one tree, so a program and its libraries
     always come from the same build, and the libraries promise no ABI
     between builds. Modules build without `-enable-library-evolution`,
     so generics specialize and layouts are known across the boundary, as
     in a static link, and doc 16 §7's cost doesn't arise.
   - The check that a program and its libraries are from the same build:
     each program records its libraries' GNU build IDs in a note, and the
     loader refuses a mismatch with a message naming the library. A
     pushed program, or one copied from `/mnt/term`, built from another
     tree is refused, not crashed.

The rest, as ADR-0047 has it:

- **Where libraries come from:** `/lib/NAME` for each `DT_NEEDED` name, in
  the spawner's namespace (the launcher: bootfs's `lib/`), as `/bin/NAME`
  is read today. There is no search path, and no `LD_LIBRARY_PATH`.
- **Mapping:** each object goes in a VMAR of its own at a random base, with
  guard pages around it.
  - Read-only segments come straight from the file's VMO, so every process
    shares them.
  - Writable ones are snapshot children, shared until written.
  - Text relocations and writable-executable segments are refused, as now.
- **Binding:** every relocation is applied before the program runs; there
  is no lazy binding, PLT or interposition.
  - The lookup order is the executable, then the libraries in load order;
    the first definition wins.
  - Each object's RELRO is then made read only.
  - Relocations taken: today's (relative, absolute, GLOB_DAT, JUMP_SLOT),
    plus COPY and the static TLS ones (TPOFF, DTPMOD and DTPOFF for the
    initial set). Any other refuses the program.
- **What stays in the executable:** the floor, the libc and Sys. They start
  the process, own the one heap and lay out TLS before anything else runs,
  so they can't come from a library. The executable exports them, as a
  dlopen host does today, and every library binds to them, so there is one
  heap and one Sys.
- **TLS:** static for the initial set.
  - The executable's block sits where ld.lld put it, and each library's
    follows in load order at its alignment (below the thread pointer on
    amd64, above it on arm64 and rv64), as the floor's Thread.swift
    already lays out the executable's.
  - Libraries reach their TLS by initial-exec: the stdlib and tier 1
    libraries build with `-ftls-model=initial-exec`. A
    general-dynamic or TLS-descriptor access refuses the library at load,
    with a message.
  - Dynamic TLS, for a library `dlopen` loads later, stays refused, as
    today (D122 left it open for hot reload).
- **The handover:** the startup message gains a record of the loaded
  objects: per object its base, program headers, dynamic section, name,
  TLS block (image, sizes, alignment, offset from the thread pointer) and
  init and fini arrays.
  - It is versioned; a runtime that doesn't know the version refuses it.
  - The floor lays out every thread's TLS from it, and runs the
    libraries' initializers before the executable's, dependencies first.
  - system/ld's `dlopen` starts from that list, so a library loaded later
    binds against the initial set too.
  - A static program has no such record and starts as now.
- **The libraries:**
  - The Swift standard library, Concurrency and Synchronization, built
    shared by `tools/toolchain/build_stdlib.sh`
    (`SWIFT_BUILD_DYNAMIC_STDLIB=ON`, PIC, initial-exec TLS).
  - FoundationEssentials and its shims.
  - Each `croi_tier1_library` module as `lib<Module>.so`: Kit, UICore,
    TextLayout, Light, Themes, VX and the rest.
  Programs link against them with `-L` and no `-static-stdlib`; a
  program may still ask for a static link.
- **The images:** bootfs's `lib/` carries them. A desktop image carries one
  copy, and each program is its own code, about a few hundred KB.

## Budgets, each with its check

- `t1.app_size`: a Kit app's own file, under 1 MB (vx loc's size
  budgets; rio's would go from 13.3 MB).
- `desktop.shared_rss`: what the desktop's tier 1 apps hold together, under
  a third of today's (the launcher's `memory`, reported by boot-desktop's
  apps under the bench's services boot).
- `desktop.cold_start` (D123) stays under 50 ms with the binding: the
  loader binds every symbol of the set at each start, and the budget
  shows whether that needs a cache.
- spawn → main for a tier 1 program, reported beside V2's (< 200 µs for a
  static one): this one's limit is set at its first record.

## Order

Before V6, so the boards get it. Each step lands with its tests:

1. Ld's core: several objects, DT_NEEDED, the scope order, COPY and the
   static TLS relocations. Tested hosted on objects ld.lld links
   (LdTests), as today's relocations are.
2. `Program.load` and the handover; the floor's TLS layout and initializer
   order from it; dlopen seeded from it. boot-dl gains a C program
   linked against two C libraries (a chain, TLS in each, constructors in
   order).
3. The build-ID note and the loader's check.
4. The toolchain: the stdlib, Concurrency, Synchronization and
   FoundationEssentials shared. swift-hello, swift-async and
   foundation-test link dynamically and pass.
5. The tier 1 libraries shared, and every Kit app linked against them. The
   desktop boots pass, and the budgets get their first records.

## Not proposed

- Lazy binding, PLT stubs, symbol versioning, interposition,
  `LD_PRELOAD`: none, as in ADR-0047.
- Unloading: libraries stay loaded (a Swift library mustn't be unloaded,
  CLAUDE.md, Venus).
- Tier 0 programs stay static: Embedded Swift compiles what each uses
  into it (0.7-2.3 MB), and they share no runtime to speak of.
- rv64: tier 1 isn't there yet; when it is, it starts dynamic.
