# ADR-0016: sbase, vendored unchanged, as the POSIX userland's commands

Status: accepted, 2026-10-06 (proposed 2026-10-02). The import's code review is still to be recorded (`VENDOR.ndb`, `reviewed.by=pending`).

## Context

M4 step 5 gives the POSIX userland its commands (04 §6), decided as sbase on 2026-10-01 (`docs/milestones/M4.md`): suckless's POSIX tools, about 100 small C programs with two small libraries and no dependencies but a C library. First-party commands of some of the same names (`ls`, `cat`, `echo`, `tail`) already serve native programs and `gsh`. ADR-0003 asks for pinned, reviewed source with one ADR per import.

## Decision

- **sbase at commit `c546c3a`** (2026-05-25, the head of `master`) is vendored unchanged under `third_party/sbase`. sbase makes no releases (its one tag, 0.1, is from 2016), so the import is pinned as u9fs is: `git.tree=` records the commit's tree id, which `git write-tree` over the files reproduces. Fetched from `git.suckless.org/sbase` over HTTPS; when reviewing, compare against a second clone. Licence: MIT, with libutf and a few files under their own permissive notices, as `LICENSE` lists.
- **Generated files**, made once at vendoring as ADR-0003 says, are committed under `ports/sbase/generated/`: `bc.c`, from `bc.y` by `bison -y` (GNU Bison 3.8.2; its skeleton's exception lets the parser be used under sbase's licence), and `getconf.h`, from `scripts/getconf.sh`. `ports/sbase/config.h` defines `PREFIX`, which the Makefile passes on the command line, as `/boot`.
- **The build** is `./build`'s, from `ports/sbase/port.ndb`: the Makefile's `CPPFLAGS` with `-std=c99 -O2` and frame pointers kept (ADR-0007), its `LIBUTFOBJ` and `LIBUTILOBJ` archived, and each of its `BIN` from its own sources. The programs are linked into one binary, as the Makefile's `sbase-box` target does: each program's `main` is renamed `NAME_main` by `-Dmain=NAME_main` on its command line (`mkbox` makes edited copies instead; the tree stays unedited), and `./build` generates the box's `main`, which runs the program its name names. `make` is linked alone, as `mkbox` leaves it out; its globals clash with `bc`'s and libutil's. A hundred static programs would each carry musl and the back end, about 70 MB; the box and `make` are 2.5 MB.
- **bootfs gains hard links** (vx-tar): a link entry reads as the regular file it names, which must come earlier in the archive and be no link itself, so the reader never follows a chain. `/boot/bin/posix` holds `sbase-box`, `make`, and each command's name (and `[`) as a link to the box. bc's library is at `/boot/share/misc/bc.library` (`install=`).
- **Where the commands are**: `/boot/bin/posix`, which the POSIX namespace template binds before `/boot/bin` on `/bin`, as Plan 9's APE binds `/bin/ape` over `/bin`. POSIX programs find sbase's `ls`; native programs and `gsh` keep the first-party commands. Nothing is renamed.
- **Tests**: `tests/qemu/sbase.ndb` runs `sbasetest`, a C program that runs about 40 commands as a shell would (found on `PATH`, with pipes for input and output) and checks their output and status: text tools, files in `/tmp`, `bc`, `sha256sum`. There is no `/bin/sh` to run sbase's own `tests/` scripts.

## Known issues at `c546c3a`

- `rev` and `tail -m` are broken: upstream commit `3de61ef` (2025-03-21) replaced `(c & 0xC0) == 0x80`, a continuation byte, with `UTF8_POINT(c)`, which is true for the other bytes. `rev` prints lines unreversed, and `tail -m` counts the wrong bytes. Not carried as a patch: the tree stays as upstream has it. Report it upstream; take the fix with the next import.
- Commands that need what VectraOS does not have fail when they ask for it: `chroot`, `mknod`, `nice` and `renice`, `chown` and `chgrp` to anyone (one user), `hostname` to set, `logger` (no syslog), `cron`. They are built, since they are part of the set, and report the error they get.

## Consequences

- Upgrading is replacing the tree with a newer commit's, regenerating `bc.c` and `getconf.h`, and checking the Makefile's lists against `port.ndb`.
- sbase's code is not under the house rules (04 §1.1); its warnings stay as upstream has them, and `./build check` does not lint it.
- The box needs every program free of clashing globals, as upstream's own `sbase-box` does; a new program that clashes is linked alone (`alone=yes`).
