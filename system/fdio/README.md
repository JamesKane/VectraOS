# fdio

POSIX descriptors over Node and the fs protocol.

## Files: fdio

Tier 1 reaches files through POSIX's descriptors (M6g, decided
2026-10-12): `system/fdio` (`FDIO`, after Fuchsia's fdio) keeps the
process's descriptors (a channel to a node of its namespace, an offset,
the open flags) and current directory, and does `open`, `read`, `write`,
`pread`, `pwrite`, `lseek`, `fstat`, `ftruncate`, `fsync`, `stat`,
`mkdir`, `unlink`, `rmdir`, `rename`, `access`, `chdir`, `getcwd`,
`realpath`, `opendir`/`readdir` and BSD's `fts` (`Walk.swift`, compared
with glibc's) over Node and the fs protocol, with
errno as Linux sets it (our libc's `<fcntl.h>`, `<sys/stat.h>`,
`<dirent.h>`, `<unistd.h>`). Natively it's a tier 1 library
(`system/fdio/native`: the C names; `open` is C, being variadic) whose
namespace is the process's Startup's (D65) unless `FDIO.install` gave
one; `VectraOSLibc` wraps `open` and the `S_IF*` constants as Glibc
does. Descriptors 0 to 2, and any above them the process was started
with, are the floor's rings (D46): read and written by number, never
reused for a file, and opened again as `/dev/fd/N` (N itself: no dup
yet). No permissions, owners, links or times beyond the modification
time. On fs(4)'s volume (/data) an open file outlives its name, as on
Linux; on other services' trees it stops working.

FDIO reaches services' trees over Node (opens, reads, writes, listings,
directories), and what needs the fs protocol (truncating, renaming,
syncing) works where the server speaks it, fs(4)'s volume, and fails
elsewhere.
`FDIOTests` checks it hosted over a NodeTree; todhchai's comparison with
Linux over a volume isn't lifted yet. Natively `bin/fdio-test` checks
the C names (boot-fdio-test, amd64 and arm64). Tier 1 modules are built
by `croi_tier1_library` (`cmake/Tier1.cmake`, `CSOURCES` for C). The
libc has no FILE streams over files yet (`fopen`).
