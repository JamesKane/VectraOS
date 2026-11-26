---
name: board-run
description: Boot a build on the Orange Pi 6 Plus (CIX Sky1) from its FreeBSD and judge board-test's result. Use before merging any branch that touches a program board-test runs (vulkan-test, loinnir-test, gpu-test, compose-test, and every bound driver), even when the QEMU and Venus runs pass, and whenever the owner asks for a board run.
---

# Running on the Orange Pi 6 Plus

The board sits in FreeBSD between runs. A run copies our image onto its
ESP, sets our boot entry as the one-shot BootNext and reboots. The image
runs `bin/board-test`, which ends within 90 s with `board-test: passed`
or `board-test: FAILED, <n> checks`. The board then reboots into
FreeBSD. See `docs/boards/orangepi-6-plus/README.md`, "Booting VectraOS
on it".

Venus is not the board. `gpu-gaps` merged after passing only under Venus
and turned main red on the board (swizzled image views, R and B swapped
in input attachments).

## Running

1. Build the board's image:

       ninja -C build/arm64 esp-board

   A fresh worktree has no build tree. Reuse a configured one, or
   configure it as the main checkout is, and give the worktree a `.cache`
   symlink for tier 1.

2. Run it with `run_in_background`, then wait on the log's last line:

       BOARD_TAG=<branch> .claude/skills/board-run/board-run.sh build/arm64/esp-board LOG [BACKUP_NAME]

   The script's own output ends with `BOARDRUN DONE <status>`:
   - `passed` or `failed` come from board-test's last line;
   - `timeout` means no last line within 6 minutes;
   - `locked`, `no-board`, `copy-failed` and `deploy-failed` mean it
     never booted.

   LOG gets the serial console. BACKUP_NAME keeps the ESP's previous
   `croi/` under that name, once.

3. Judge the run by board-test's last line and by the summary lines the
   tests reprint at their end, for example loinnir-test's
   `core cases: N passed, M skipped`. The serial console drops lines, so
   a missing line in the middle proves nothing.

4. Report the commit the image was built from. If you commit after
   building, the run no longer counts for the merge.

## What the script handles, and why

- **Address.** The board is `root@192.168.0.32`, with
  `-o HostKeyAlias=192.168.0.19`. Its FreeBSD is the same install that
  answered at .19, with the same host key. A different FreeBSD briefly
  answered at .32 with other keys, so never connect to .32 without the
  alias. `BOARD` and `BOARD_ALIAS` override both.
- **Lock.** The lock is `/root/vx-board.lock`, holding host, pid, start
  time and tag. It is taken atomically. A lock is stale, and the script
  breaks it, when its owner is a dead process on this Mac or it is older
  than `BOARD_STALE_MIN` minutes (20; a run takes 11 at most). Any other
  held lock refuses the run with `locked`. A stale lock once cost a
  75-minute stall.
- **Console.** The console is COM2, the board's cuau2, on
  `/dev/cu.usbserial-ABSCDIMD` (`BOARD_TTY`). `listen.py` holds the
  descriptor open at 115200 8N1. On macOS, `stty -f` followed by `cat`
  loses the speed when stty closes the device, and records nothing.
- **Boot entry.** `BOOT_ENTRY` defaults to `000A`, the VectraOS entry. It
  is never in BootOrder, so any reset returns to FreeBSD.

## What it doesn't cover

- **The desktop image** (`esp-board-desktop`) runs no board-test, so this
  script would report `timeout`. Judge a desktop run by its own end line.
- **A hang before the watchdog starts** needs a power cycle, which only
  the owner can do. Say so plainly and stop. Don't poll the board for an
  hour.
- **Don't leave a board step for the owner to type.** If a check needs
  doing on every run, script it into the runner.
