# ADR-0001: Toolchain trust

Status: accepted, 2026-09-30.

## Context

Every binary in the system comes out of one compiler and one linker (04 §3.3). A compromised or merely different toolchain changes every one of them, and an unpinned one makes builds irreproducible (04 §7).

## Decision

- clang, lld, llvm-objcopy, llvm-ar, clang-format and clang-tidy come from signed Fedora packages. The pin is **22.1.8 (Fedora 22.1.8-4.fc44)**.
- compiler-rt's builtins, which user programs link (`__multf3` and the rest), are built from vendored source of the same release (ADR-0008), not taken from Fedora's `compiler-rt` package, which has them for the host only. (Amended 2026-10-01.)
- `nasm`, needed only for Limine's x86_64 loader (ADR-0002), is pinned to **3.02 (nasm-3.02-1.fc44)**.
- `build.c` calls each tool by absolute path (`/usr/bin/clang`, `/usr/bin/ld.lld`, `/usr/bin/llvm-objcopy`, `/usr/bin/llvm-ar`, `/usr/bin/clang-format`, `/usr/bin/clang-tidy`, `/usr/bin/nasm`), because other toolchains (a Swift toolchain's clang) come first on `PATH`. A different clang-format or clang-tidy version can format or judge the same code differently, so they are pinned too.
- `build` looks for a line of each tool's `--version` output equal to its pin, and refuses to build with anything else.
- CI installs the same packages.

## Consequences

- Upgrading the toolchain is a change to `build.c` plus an amendment to this ADR, reviewed like any other change.
- Bootstrapping clang from source, and later rebuilding it on VectraOS (M12), are hardening steps that replace the trust in Fedora's signatures.
