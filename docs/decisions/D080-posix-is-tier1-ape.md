# D80. POSIX is tier 1's APE, and nothing else's (2026-10-16, decided)

Tier 1 (D47) needs POSIX: the libc, FDIO, libc++ and the ports built on
them. Nothing kept POSIX's shapes from spreading into native interfaces,
and they did: the pty carried termios's modes as a service (removed in
V3, D77). Plan 9 kept POSIX in APE, its ANSI/POSIX environment: a
library over Plan 9's interfaces, never an interface of the system.

- **POSIX lives only in tier 1's libc**, emulated over Plan 9's
  interfaces. Tier 0, Sys, the services and their protocols never take
  or expose a POSIX shape: no termios, signals, sockets, `errno` codes,
  numeric ids or `ioctl` in an IDL, a Node tree or a manifest.
- **The mappings**, each in the libc:

  | POSIX | Over |
  |---|---|
  | termios, `isatty` | `/dev/consctl` (`rawon`, `rawoff`); a descriptor is a terminal when it is a window's `/dev/cons` |
  | signals | notes (`interrupt` as SIGINT, `hangup` as SIGHUP, `alarm` as SIGALRM); `kill()` writes `/proc/N/note` or `ctl` (D79) |
  | sockets, `getaddrinfo` | `/net` and `/net/cs` through `dial` (D79) |
  | `getenv`, `environ` | `/env` (D81) |
  | uids and gids | one user, its name from factotum; `getuid` answers a constant |
  | `errno` | from the error string, as APE maps them |

  `fork` stays out (tier 1 has `posix_spawn` over `Process.start`).
- **WASI (V9) is a guest ABI under the same rule**: `wasmd` maps it
  onto the same interfaces, and nothing native takes its shapes.
- A tier 1 program that wants more of Unix than this gets it in its own
  libc code, not in a service. A POSIX shape proposed for a native
  interface needs a decision naming why Plan 9's form can't serve.

Settles the pty notes' open question (services/pty/README.md): tier 1's
termios and `isatty` see a window through `/dev/consctl`.
