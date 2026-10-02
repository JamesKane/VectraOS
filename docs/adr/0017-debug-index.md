# ADR-0017: The debug index is first-party: `vxdi`, built from DWARF 5

Status: accepted, 2026-10-02 (the user chose our own over vendoring RDI).

## Context

05 §4 has `dbg` turn a program's DWARF into a flat, memory-mappable index the first time it loads it, so symbols load at once after that, as the RAD Debugger does with its RDI format. 05 §13 Q3 asked whether to vendor RDI's format library (MIT-licensed C) or write our own, to be settled by ADR before M4 ends. VectraOS prefers first-party C23 under the house rules (04 §1.1), and imports only what would be costly to write (ADR-0003). `dbg` needs only part of what DWARF says: where functions and lines are, what variables a function has and where they live, and their types.

## Decision

- **Our own index, `vxdi`, in `lib/vx-debug`**: first-party C23, freestanding (the builder works in an arena the caller gives it, and makes no system call), so `dbg`, the kernel's panic backtraces and host tools share it. RDI is not vendored.
- **Built from what clang 22 emits**: DWARF 5 (`.debug_info`, `.debug_abbrev`, `.debug_line`, `.debug_str`, `.debug_line_str`, `.debug_str_offsets`, `.debug_addr`, `.debug_rnglists`, `.debug_loclists`), and the ELF symbol table for code built without DWARF (musl, compiler-rt). Forms are read generically, so a DIE with an unknown attribute is skipped, never misread.
- **One flat buffer**, little-endian, every reference an offset from its start, so it can be written to a file and mapped as it is:
  - a header: magic `VXDI`, version, machine (`EM_X86_64`, `EM_AARCH64`), the build ID it was made from, and each table's offset and count;
  - functions, sorted by address: range, name, declaration file and line, the address past the prologue (where a breakpoint on the function goes), frame base, and their variables;
  - line rows, sorted by address: file and line, statement rows only;
  - variables (parameters, locals with the range of their lexical block, globals): name, type, and location: a DWARF expression, or a location list flattened to address ranges, with `DW_OP_addrx` resolved to `DW_OP_addr` and `.debug_addr`, `.debug_loclists` no longer needed;
  - types: base, pointer, `const`/`volatile`/`restrict`/`_Atomic`, typedef, struct and union with members, array with its count, enum with enumerators, function;
  - ELF symbols, sorted by address;
  - files, and a string table.
- **Cached by build ID**, as 05 §4 says: `/lib/debug/<build-id>.index`. It is a cache: deleting it loses nothing.
- **Not yet**: inlined subroutines as frames of their own, DWARF 4 and split DWARF (`.dwo`), C++.

## Consequences

- `dbg`'s symbols are first-party end to end; the index format changes with `dbg`, by its version number, and an index of an old version is rebuilt.
- RDI's tooling is not shared. Converting to or from it later, if wanted, is a tool, not a dependency.
- The reader is a parser of untrusted input (a crash directory may come from anywhere): every offset is checked against its section, and it is fuzzed.
