# Architecture decision records

One file per decision, `NNNN-title.md`, numbered in order. An ADR records a decision the blueprint (docs 00–05) does not already settle, or an exception to a rule there. It is short: the context, the decision, and what follows from it. A superseded ADR stays, marked with the ADR that replaced it.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-toolchain-trust.md) | Toolchain trust: pinned clang, lld and compiler-rt | Accepted |
| [0002](0002-limine.md) | Limine 12.9.1, vendored unchanged and built by `build` | Accepted |
| [0003](0003-no-registries.md) | No package registries | Accepted |
| 0004 | The ring layout; freezes `vx-abi` v0 | Written at M2, when the ring code exists |
| [0005](0005-c23-house-subset.md) | C23 and the house subset | Accepted |
| [0006](0006-u9fs.md) | u9fs, vendored as a host test tool for 9P interoperability | Accepted |
| [0007](0007-musl.md) | musl 1.2.6, vendored unchanged, with a VectraOS back end | Accepted |
