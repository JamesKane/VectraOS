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
| [0008](0008-compiler-rt.md) | compiler-rt's builtins, vendored from LLVM 22.1.8 | Accepted |
| [0009](0009-namespace-groups.md) | Namespace groups shared by default, mounts found by identity, namespace(6) templates | Accepted |
| [0010](0010-notes-and-exit-strings.md) | Notes and exit strings, with POSIX signals built on notes | Accepted |
| [0011](0011-one-process-model.md) | One process table in `procfs`, served as files; `posixd` folded in | Accepted |
| [0012](0012-task-exec.md) | `task_exec`: `exec` keeps the task, and so the pid | Accepted |
| [0013](0013-text-is-utf8.md) | Text is UTF-8, handled in runes: `lib/vx-utf`, strings cut at rune boundaries, names without control characters, rune-aware line editors | Accepted |
| [0014](0014-catalogues.md) | Publisher catalogues for package dependencies: one signed list per publisher key, no shared name space, no install-time code; not a registry | Accepted |
| [0015](0015-lua.md) | Lua 5.5.1, vendored unchanged, as `/bin/lua`; vendored POSIX programs in `./build` | Proposed |
