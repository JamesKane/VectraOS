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

Every file lifted from croi, todhchai or NeoVectra starts with
`// From <repo>@<sha>: <path>`. Keep that line when editing. Remove it only
when a file has been rewritten.

When lifting a subsystem, also lift its rules:
- croi's `CLAUDE.md` sections "Rules that cut across subsystems" and
  "Conventions": lock order, no ARC in the higher half, no floating point
  in the kernel, `@c @implementation`, and typed C23 enums.
- todhchai's `CLAUDE.md` "Toolchain pitfalls".

These go into this file in V0, under the headings below.

## Status

V0 has not started. See `docs/roadmap.md`.

## Kernel rules

(To be lifted from croi in V0.)

## Toolchain pitfalls

(To be lifted from croi and todhchai in V0.)
