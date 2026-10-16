# VectraOS: directives for work in this repository

VectraOS is a capability microkernel OS for edge hardware, written in
Embedded Swift 6.4 with C23 where necessary. Read `docs/principles.md`
before designing anything. Read `docs/decisions.md` before changing
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
    .build/debug/vx test arm64                       # one arch: build + QEMU tests
    .build/debug/vx boot rv64                        # boot interactively (Ctrl-A x quits)
    .build/debug/vx bench                            # boot budgets under KVM (advisory)
    .build/debug/vx loc                              # size budgets

- Each step's output goes to `build/vx/<step>.log`. On failure, vx shows
  the log's tail.
- `vx test` runs one arch's suite after another, never two at once: under
  that load, rv64 TCG tests such as `boot-aia` exceed their timeouts.
- `vx bench` judges against `bench/history/<host>.tsv`, which holds
  seconds or counts. It is advisory on a shared machine. Record only on a
  quiet machine with a committed tree.
- Budget names, and the noise allowed for each, are in
  `tools/bench/lib/Rules.swift`. Limits come from the boot's own
  `budget ... limit=` lines.

## Status

V0 is done (2026-10-15). V1 is under way: `object_bind` landed (D20),
and the cuts have begun: FIFOs, sockets and streams (D21), the channel
`_etc` forms and the futex extras (D22), events, signals and the thread
waits (D23), sleeps, timers and the counter waits (D25), clocks (D26),
display timelines (D27), debug_write and vmo_map (D28), the interrupt
waits (D29), thread_raise_exception (D30), system_get_event (D31),
port_cancel_key into port_cancel (D32), handle_close_many into
handle_close (D33), handle_replace into handle_duplicate (D34),
test_report into the test call (D35), vmo_get_size and
process_info into info topics (D36), vmo_read and vmo_write (D37), and
debuglog_read, the debuglog now a read-only ring (D38): 91 syscalls, the
audit's target (`docs/syscall-audit.md`). The hot calls take arrays:
handle_duplicate (D39), the wakes (D40), channel reads and writes (D41)
and the VMAR calls (D42). The one ring is in Swift and `ring.h`, both
model-checked by RingCheck (D43); the kernel produces it for the
debuglog (D38) and for ports made with CROI_PORT_RING (D44).
- **Done:** croi imported, passing on amd64, arm64 and rv64; todhchai's
  Judge, History, trace format and reader lifted; `vx` with build, test,
  boot, bench, trace, loc and ci.
- **Also done:** croi's Python tools rewritten in Swift and removed.
- **Also done in V2:** the trace producer: the kernel and `Trace` write trace
  rings on the one ring (D50), recorded by a session and collected by
  `vx trace collect`.

Milestones run in order, and each puts the next one's dependencies in
place. Board bring-up (V4) waits for V3, the bring-up link: SSH, warm
boot and the GENI console. The rv64 board, the Orange Pi RV2 (Ky X1 =
SpacemiT K1, RVA22 as rv64's baseline), follows the Q8B as V4b (D51,
`docs/boards/orangepi-rv2/`). amd64's baseline is the 2013 Mac Pro's
Ivy Bridge (`-march=ivybridge`: AVX, no AVX2 or FMA; D52); arm64's is
the Q8B's, `armv8.2-a+fp16+dotprod+rcpc`, which the CIX Sky1 also
meets (D53). See `docs/roadmap.md`.

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
- **Generic SIMD conversions don't inline across files.** Load and store
  whole vectors through spans, and convert lanes by hand.
- **A CMake option meant for Swift must be guarded in a target that has
  assembly** (`$<$<COMPILE_LANGUAGE:Swift>:...>`), or clang gets it.
- **To Swift, CR LF is one Character.** `split(separator: "\n")` doesn't
  split a QEMU serial console's lines; use `split(whereSeparator:
  \.isNewline)`. Found in V0, in `vx bench`.
