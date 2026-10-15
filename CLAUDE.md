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

## Toolchain

- Swift 6.4.0 through swiftly, pinned by `.swift-version`. Use the clang,
  lld and llvm-objcopy bundled with it.
- Outside the repository, swiftly picks its default toolchain (6.3.1 on
  this machine). That toolchain crashes compiling Embedded atomics, so call
  6.4.0's `swiftc` by its path in scratch experiments.
- You also need QEMU with edk2 from `/usr/share/edk2`. CMake runs `vx`
  for its build steps (elf2efi, mkbootfs, check-pixels, todhchai-check)
  and builds it with SwiftPM first, so nothing outside the Swift toolchain,
  CMake, Ninja, QEMU and bash is needed. There is no Python.

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

V0 is in progress.
- **Done:** croi imported, passing on amd64, arm64 and rv64; todhchai's
  Judge, History, trace format and reader lifted; `vx` with build, test,
  boot, bench, trace, loc and ci.
- **Also done:** croi's Python tools rewritten in Swift and removed.
- **Still to do:** a trace producer (V2).

The critical path to the board is V0 → V2 → V3 (the bring-up link: SSH,
warm boot, the GENI console) → V4. V1 runs alongside it. See
`docs/roadmap.md`.

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
