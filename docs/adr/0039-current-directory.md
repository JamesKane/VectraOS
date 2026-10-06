# ADR-0039: The current directory

Status: accepted, 2026-10-06 (proposed 2026-10-06). M6 step 6d7a (Swift's R17, `swift-on-vectra`'s `docs/os-requirements.md`). It puts a current directory in the native personality, readable and settable from C and set by rc's `cd`, and makes the spawn message's `cwd=` record, until now musl's back end's own, part of the spawn message's ABI (`abi/vx/abi.h`).

## Context

Since M1 a native program has had no current directory: vx-ns refuses a relative name, and rc has no `cd` (rc(1)). The POSIX personality has one: musl's back end keeps a path (`ports/musl/vx/fd.c`), joins relative names to it, and passes it to a child in a `cwd=` record of the spawn message that no document names. Swift's runtime reads the current directory at start-up and Foundation's `FileManager` reads and changes it (R17); rc needs `cd` to be 9front's rc.

9front keeps a process's current directory, `dot`, as a channel (`sys/src/9/port/chan.c`, `namec`): `chdir` walks to the name and keeps the channel if it is a directory; a relative name is walked from it; `..` follows the channel's path name, cleaned lexically (`fixdotdotname`). rc's `cd` searches `$cdpath`, printing the directory it found through an entry other than `""` or `.`, and with no argument goes to `$home` (`sys/src/cmd/rc/simple.c`, `execcd`).

## Decision

1. **A process's current directory is a path:** absolute and clean (no empty, `.` or `..` component), at most 255 bytes, `/` to start with. vx-rt keeps it, one for the process, under a lock its threads share: `vx_getwd(buf, cap)` gives it; vx-ns's `vx_chdir(ns, path)` changes it.
2. **A relative name is resolved against it**, lexically, wherever vx-ns takes a name: walk, open, create, `bind` (both names), `mount` and `unmount`. `..` is cleaned away against the path, as 9front's `..` follows the channel's name.
3. **Changing it:** `vx_chdir` resolves the name, walks it and stats it. A directory becomes the current directory; anything else is refused (`INVALID`, not a directory, or the walk's error), and the current directory is unchanged.
4. **Inherited:** every spawn message carries `cwd=PATH`, the parent's current directory, which vx-ns's `vx_ns_spawn_records` writes for every spawner and vx-rt reads at start-up. A message without one, or with a path not absolute, gives `/`.
5. **One for both personalities:** musl's back end keeps its working directory in vx-rt too, so `chdir` and `getcwd`, `cd` and `vx_getwd` see the same directory, and either kind of child inherits it.
6. **rc's `cd`** is 9front's: `cd dir` searches `$cdpath` for a relative `dir` (as rc does, `$cdpath` empty meaning the current directory alone), printing the directory when it was found through an entry other than `""` or `.`; `cd` alone goes to `$home`; a failure leaves `$status` `can't cd`. A native `pwd`, 9front's, prints the directory.

## Consequences

- Relative names work natively, from C and rc, and a spawned child starts where its parent was.
- 9front's `dot` is a channel, so it survives its directory being renamed, or a mount over a name in its path; ours is a name, so after a rename a relative name walks the old name and fails, as a POSIX shell's `$PWD` would. `..` is the same as 9front's, lexical.
- The namespace's names are resolved by the process that holds them: a namespace group shares a table, not a current directory, as 9front's `rfork(RFNAMEG)` shares mounts but each process keeps its `dot`.
- libvx (6e1) takes `vx_getwd` and `vx_chdir` over as they are.
