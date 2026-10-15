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
- You also need QEMU with edk2 from `/usr/share/edk2`, and Python 3 until
  the `tools/*.py` scripts are folded into `vx`.

## Imported code

`IMPORTS.tsv` records every file lifted from croi, todhchai or NeoVectra:
its path here, the source repository, the commit and the source path.
Imported files stay byte-identical to their source when imported, so
`git diff --no-index` against the source shows exactly what changed.
- When you lift a file, add its row in the same commit.
- When you rewrite a file completely, delete its row.

## Build

One CMake/Ninja tree per arch, under `build/<arch>/`:

    cmake --workflow --preset amd64     # configure, build, run the QEMU tests
    cmake --build --preset arm64        # build only
    ninja -C build/rv64 run             # boot interactively (Ctrl-A x quits)

The `vx` front door replaces these during V0 (D11).
- Don't run two arches' test suites at once. Under that load, rv64 TCG
  tests such as `boot-aia` exceed their timeouts.

## Status

V0 is in progress. croi is imported and passes its suites on amd64, arm64
and rv64. Still to do: todhchai's bench judge and tracer, and `vx`. See
`docs/roadmap.md`.

## Kernel rules

@docs/kernel/rules.md

## Toolchain pitfalls

(To be lifted from todhchai with its bench and trace code in V0.)
