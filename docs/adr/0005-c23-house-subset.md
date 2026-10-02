# ADR-0005: C23 and the house subset

Status: accepted, 2026-09-30.

## Context

D1 chooses C23 for all first-party code, kernel included, with safety coming from a small kernel and from tooling rather than from the language (04 §1.2).

## Decision

- The house subset in 04 §1.1 governs the OS tree: the kernel, `abi`, libraries, servers, drivers, commands and `build`. Applications build with whatever flags and style their authors choose.
- The flags are fixed in `build.c` (`HOUSE_FLAGS`), so they cannot drift between components.
- Any exception to the subset needs its own ADR.
- Source files are UTF-8, and so is clang's execution character set, so a plain `"é"` is UTF-8 bytes already. House code never uses `u8"…"`: in C23 its type is `char8_t[]`, which does not pass as `char *` (ADR-0013).

## Consequences

`-Werror` applies to the OS tree from the first commit. A warning introduced by a toolchain upgrade (ADR-0001) is fixed in the same change as the upgrade.
