# ADR-0008: compiler-rt's builtins, vendored from LLVM 22.1.8

Status: accepted, 2026-10-01. The import was reviewed by James Kane, 2026-10-01 (`VENDOR.ndb`).

## Context

Code that clang compiles calls a few routines it expects a runtime library to have: software 128-bit floating point (aarch64's `long double` is IEEE quad, so musl's `printf` and `strtold` need `__addtf3`, `__multf3` and the like), complex multiplication (`__muldc3`), 128-bit integer division, and more. On Linux they come from libgcc or compiler-rt's builtins. Fedora's `compiler-rt` package has the builtins for the host (x86_64 Linux) only, and the pinned toolchain (ADR-0001) has no other copy. Writing them is a large, exacting job that LLVM has already done and tests.

## Decision

- **compiler-rt's builtins** from the LLVM 22.1.8 release, the same release as the pinned clang, are vendored under `third_party/compiler-rt`: just `lib/builtins` and `LICENSE.TXT`, unchanged, as `subset=` in `VENDOR.ndb` records. The release tarball (the whole monorepo since LLVM 18) is signed by an LLVM release manager's key (fingerprint `FFB3 3689 80F3 E6BB 5737 145A 316C 56D0 64CA CBA5`, Douglas Yung, from `releases.llvm.org/release-keys.asc`; confirm it against a second source when reviewing). Licence: Apache-2.0 with LLVM exceptions.
- **`./build` builds `libclang_rt.builtins.a`** for each architecture into the `vectra-musl` sysroot, from the lists in upstream's `CMakeLists.txt` for a hosted ELF target that is neither Apple nor Fuchsia: `GENERIC_SOURCES`, `GENERIC_TF_SOURCES`, `atomic.c` and `clear_cache.c`, with each architecture's files (an architecture's file replaces the generic one of the same name, as `filter_builtin_sources` does). Left out:
  - `emutls.c`, `enable_execute_stack.c`, `eprintf.c`: emulated TLS and helpers for old toolchains; VectraOS has native TLS.
  - `gcc_personality_v0.c`: needs `unwind.h`; nothing unwinds by tables yet.
  - aarch64's outline atomics (`lse.S` helpers): clang does not emit calls to them for our triple.
  - aarch64's SME ABI routines and `emupac.cpp`: SME traps (01 §11), and the second is C++.
- Flags as upstream's: `-std=c11 -fno-builtin -fvisibility=hidden`, at `-O2`, with frame pointers kept, as for musl (ADR-0007).

## Consequences

- Programs link the builtins after `libc.a`. The kernel and first-party freestanding programs do not use them.
- Upgrading is replacing the subset with the next release's when the toolchain pin moves, and comparing the CMake lists again.
