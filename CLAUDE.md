# VectraOS: directives for work in this repository

VectraOS is a capability microkernel OS for edge hardware, written in
Embedded Swift 6.4 with C23 where necessary. Read `docs/principles.md`
before designing anything. Read `docs/decisions/` before changing
anything that a decision covers.

## The rules that most often matter

- **One mechanism per job** (principle 1). Before adding a mechanism, name
  the one it replaces or explain why none exists. When croi, todhchai and
  NeoVectra solved the same problem, `docs/provenance.md` says which one
  wins. Do not import the loser.
- **Nodes for control, rings for bulk.** There is one ring format
  (architecture §3) and one wire format (D6). Do not define another.
- **Every promise is a budget with a running check.** A new budget lands
  together with its check and a milestone. Never loosen a budget in the
  change that would otherwise fail it (`docs/performance.md`).
- **Nothing third-party on the device** (D4). Host tools may use third-party
  compilers only to produce our artifact formats.
- **C23 only where Swift can't reach.** Each C file says why in its header
  comment.
- **A change to behaviour changes its page** (D86), in the same commit:
  `man/<section>/<page>`, in guide(6). Something new comes with its page,
  never a row in `man/missing`, and `vx man --check` (run by `vx ci`)
  fails otherwise. Keep the text clean: a page says what the system does,
  its limits, and its known bugs (BUGS). It never says which milestone,
  step, decision or source repository added or changed it; that history
  is in git and `docs/`.
- **New tests are Embedded Swift** (D20): a suite file in `user/test/swift/`
  with named checks, run by `ProgramSelfTest.runSuites`. Don't add to
  `user/test/usertest.c`. When a change touches one of its tests, move
  that test to a suite (D21).

## Toolchain

- Swift 6.4.0 through swiftly, pinned by `.swift-version`. Use the clang,
  lld and llvm-objcopy bundled with it.
- Outside the repository, swiftly picks its default toolchain (6.3.1 on
  this machine). That toolchain crashes compiling Embedded atomics, so call
  6.4.0's `swiftc` by its path in scratch experiments.
- You also need QEMU with edk2 from `/usr/share/edk2`. CMake runs `vx`
  for its build steps (elf2efi, mkbootfs, check-pixels)
  and builds it with SwiftPM first, so nothing outside the Swift toolchain,
  CMake, Ninja, QEMU and bash is needed. There is no Python.
- SwiftPM's one dependency is swift-syntax (the IPC macro and idlc,
  host-only under D4), pinned `exact:` in `Package.swift`; `Package.resolved`
  isn't tracked. Without network, point SwiftPM at a local clone with
  `swift package config set-mirror --original
  https://github.com/swiftlang/swift-syntax.git --mirror PATH` (kept in the
  untracked `.swiftpm/`).
- Tier 1 (C, C++ and full Swift programs, D47) needs the `*-vectraos`
  toolchain, built from source by `tools/toolchain` into `.cache/toolchain`
  (its README: hours of build and several GB of links, so warn the other
  sessions and cap `LINK_JOBS`). Without it, the tree builds and tests as
  before; with it, `cmake/Tier1.cmake` adds tier 1's sysroot and programs.

## Imported code

`IMPORTS.tsv` records every file lifted from croi, todhchai or NeoVectra:
its path here, the source repository, the commit and the source path.
Imported files stay byte-identical to their source when imported, so
`git diff --no-index` against the source shows exactly what changed.
- When you lift a file, add its row in the same commit.
- When you rewrite a file completely, delete its row.

## Build: `vx`

`vx` is the front door (D11). SwiftPM builds `vx` and the host tests;
CMake/Ninja builds the images, with one tree per arch under `build/<arch>/`.

    swift build --product vx && .build/debug/vx ci   # everything vx ci checks
    .build/debug/vx test --changed                   # only what the change risks (D88)
    .build/debug/vx test arm64                       # one arch: build + QEMU tests
    .build/debug/vx boot rv64                        # boot interactively (Ctrl-A x quits)
    .build/debug/vx bench                            # the budgets the change risks, under KVM (advisory)
    .build/debug/vx loc                              # size budgets
    .build/debug/vx man TITLE                        # the manual (D86); --check
    .build/debug/vx rc-oracle                        # our rc against 9front's (D70)
    .build/debug/vx hardware                         # the hardware support list (D66)

- Each step's output goes to `build/vx/<step>.log`. On failure, vx shows
  the log's tail.
- **Test what a change risks; the full suite closes a milestone** (D88).
  During a milestone, run `vx test --changed` (`--plan` to see it first),
  not the full suite after each step. `docs/risk.tsv` maps paths to the
  tests they risk: a new test or test target gets its row in the same
  change (`vx test --check`, in `vx ci`), and a map that missed
  something is fixed in the map. `vx ci` on every arch is the exit.
- `vx test` runs an arch's QEMU tests in parallel (`ctest -j`, a boot
  for every four host CPUs), one arch after another. No arch's run may
  take over 5 minutes; a check that flakes is removed, not retried.
- rv64's suite is off in `vx test` and `vx ci` (2026-10-17); rv64 still
  builds, and `vx test rv64` runs it. Tier 1 runs there since 2026-10-25
  (llvm 0005 to 0007), but checks added while the suite was off, like
  launch-test's mouse, fail there. Its QEMU rows in docs/hardware are
  experimental meanwhile.
- `vx bench` judges against `bench/history/<host>.tsv`, which holds
  seconds or counts. It is advisory on a shared machine. Record only on a
  quiet machine with a committed tree.
- Budget names, and the noise allowed for each, are in
  `tools/bench/lib/Rules.swift`. Limits come from the boot's own
  `budget ... limit=` lines.

## Status

V0 is done (2026-10-15). V1's work is done: 91 syscalls, the audit's
target (`docs/syscall-audit.md`, D20-D38), the hot calls batched
(D39-D42), the one ring in Swift and `ring.h` with RingCheck (D43), ports
and the debuglog as rings (D38, D44). V2 is under way. Done: the one ABI,
the floor, Sys, the libc, ld, the trace, the control plane (IPC, Node
with bulk rings, the launcher), time (but for two RTCs) and the
environment as /env (D81). Begun: tier 1 (amd64, arm64 and rv64), and byte
streams (the ring's byte-stream mode, stdio, FDIO, rc and its
commands, which an audit against 9front found
far from complete), and drivers (D74:
ACPI, PCI, devmgr with edu's DMA through each IOMMU, virtio, virtio-input and
kbdfs's /dev/kbd and /dev/cons, D83:
item 7's exit met). Done: the console and the plumber (item 8, D85), and the manual (item 9, D86). V2's exit test `cat /svc/*/status` passes, run by
rc. V3, the bring-up link, is done on amd64 and arm64 (2026-10-18): cpu
and `vx cpu` with the terminal's files and /net, warm boot and `vx
remote boot`, the link on rings (D103), `trace` (D102); rv64's waits
for tier 1 there. V4, Taisce on disk, is done (2026-10-18): the block
class and virtio-blk (D106), /data a Taisce volume on a virtio disk
across reboots, its queries, live queries and mapped files, and the
file budgets judged (D105). V5, the desktop, is done on amd64 and arm64
(2026-10-22, D107-D123): Radharc, the SDK and Kit, rio and vt, the shell,
the themes, the GPU through Venus, the guide and hot reload, its exit
budgets judged under KVM (boot-rio-kvm), `reload.module_10k` missed and
accepted. Tier 1 programs are linked against shared libraries in
bootfs's `lib/` (D124, 2026-10-23), bound by the process that starts
them (linkmap(6)); FDIO stays in each program, with the libc.
`docs/roadmap.md` opens with where things stand; keep
it current.

Milestones run in order, and each puts the next one's dependencies in
place. Board bring-up (V6) waits for V3, the bring-up link (cpu and
warm boot), and for Taisce on disk (V4) and the desktop (V5), both
finished in QEMU (D76). The first board is the Orange Pi 6 Plus (CIX Sky1, D69,
`docs/boards/orangepi-6-plus/`); the Q8B moved to V8, whose CDSP and
Adreno need it. The rv64 board, the Orange Pi RV2 (Ky X1 = SpacemiT K1,
RVA22 as rv64's baseline), follows as V6b (D51,
`docs/boards/orangepi-rv2/`), and the AMD tower as amd64's first board,
V6c (`docs/boards/pc-7900x/`). amd64's baseline is the 2013 Mac Pro's
Ivy Bridge (`-march=ivybridge`: AVX, no AVX2 or FMA; D52); arm64's is
the Q8B's, `armv8.2-a+fp16+dotprod+rcpc`, which the CIX Sky1 also
meets (D53). See `docs/roadmap.md`. What runs where, and at what level
(research to supported), is `docs/hardware/` (D66).

## Kernel rules

@docs/kernel/rules.md

## Toolchain pitfalls

These are lifted from todhchai's `CLAUDE.md`, keeping the ones that apply
to code in this tree. The rest come back with the code they concern.

- **Swift 6.4 miscompiles a `throws(E)` closure passed to a `rethrows`
  function** (such as `Array.withUnsafeMutableBytes`) when the caller then
  casts the caught error (`error as? E`). The error comes out corrupt.
  Pass an untyped closure there.
- **Swift Testing's `#expect` and `#require` can't take an expression on a
  `~Copyable` value.** Compute it into a local first.
- **`Set` and `Dictionary` in tier 0 code need libm.** Embedded Swift's
  hashed collections call `ceil`, and tier 0 links without libm. Use
  arrays.
- **No key paths in tier 0 code.** Embedded Swift rejects them, including
  `\.name` passed as a function. Write a closure. Only the Embedded build
  catches this.
- **Tier 0 code has no `weak` or `unowned`**, and has no Synchronization
  `Mutex` on the kernel's targets.
- **Embedded Swift's String has no `contains(String)`.** Compare bytes or
  lines.
- **rv64 user code is `lp64` (soft-float), not the kernel's `lp64d`.** The
  toolchain's prebuilt rv64 Embedded libraries are soft-float, and ld.lld
  won't mix the two ABIs.
- **A value's lifetime ends at its last use, not at the end of its
  scope.** Something that must outlive a wait, such as a channel, needs a
  use after the wait (`_ = consume x`).
- **On arm64, a short String read through a nested function that
  captures a `var` struct came out corrupt.** Its discriminator lost bits
  61 and 62, so the small string was read as a large one and faulted;
  instrumenting the code hid it. Found in the plumber's `Rules.apply`
  (D122), and again in the loader's library check (D124: a soname read
  through a closure into `Array($0.utf8)`). Pass such a value to a static
  function, and read it into a local; for names, compare bytes in loops.
- **Generic SIMD conversions don't inline across files.** Load and store
  whole vectors through spans, and convert lanes by hand.
- **A CMake option meant for Swift must be guarded in a target that has
  assembly** (`$<$<COMPILE_LANGUAGE:Swift>:...>`), or clang gets it.
- **To Swift, CR LF is one Character.** `split(separator: "\n")` doesn't
  split a QEMU serial console's lines; use `split(whereSeparator:
  \.isNewline)`. Found in V0, in `vx bench`.
