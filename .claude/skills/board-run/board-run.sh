#!/bin/bash
# board-run.sh IMAGE_DIR LOG [BACKUP_NAME]
#
# One VectraOS boot of the Orange Pi 6 Plus from its FreeBSD
# (docs/boards/orangepi-6-plus/README.md, "Booting VectraOS on it"):
#  1. takes the board's lock, /root/vx-board.lock;
#  2. captures COM2 into LOG from before the boot;
#  3. copies IMAGE_DIR's croi/ and loader onto the ESP (nda0p1), keeping
#     the previous croi/ as BACKUP_NAME if given and not already there;
#  4. sets the VectraOS entry (BOOT_ENTRY, default 000A) as BootNext and
#     reboots;
#  5. waits for board-test's last line (6 minutes at most), then for
#     FreeBSD to answer again (4 minutes more), and releases the lock.
# The last line is always `BOARDRUN DONE <status>`: passed, failed,
# timeout, locked, no-board, copy-failed or deploy-failed.
#
# The lock holds "host pid epoch tag". A lock is stale, and is broken,
# when its owner is a dead process on this host or it is older than
# BOARD_STALE_MIN minutes (default 20; a run takes 11 at most). Any other
# held lock refuses the run.
#
# The serial console drops lines: judge a run by board-test's last line
# and the summary lines the tests reprint at their end, not by the
# console's middle.
#
# Settings (environment):
#   BOARD        root@192.168.0.32
#   BOARD_ALIAS  192.168.0.19 (the board's FreeBSD has .19's host key;
#                a different install once answered at .32 with other
#                keys, so never connect to .32 without the alias)
#   BOARD_TTY    /dev/cu.usbserial-ABSCDIMD (COM2, the board's cuau2)
#   BOARD_TAG    who is running, e.g. a branch or session (default: user)
set -u
image=${1:?usage: board-run.sh IMAGE_DIR LOG [BACKUP_NAME]}
log=${2:?usage: board-run.sh IMAGE_DIR LOG [BACKUP_NAME]}
backup=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
board=${BOARD:-root@192.168.0.32}
alias_=${BOARD_ALIAS:-192.168.0.19}
tty=${BOARD_TTY:-/dev/cu.usbserial-ABSCDIMD}
entry=${BOOT_ENTRY:-000A}
stale_min=${BOARD_STALE_MIN:-20}
ssh_=(ssh -o HostKeyAlias="$alias_" -o BatchMode=yes -o ConnectTimeout=8)
scp_=(scp -q -o HostKeyAlias="$alias_" -o BatchMode=yes -o ConnectTimeout=8)
owner="$(hostname -s) $$ $(date +%s) ${BOARD_TAG:-$USER}"
status=unknown
locked=no

finish() {
  [[ -n ${cat_pid:-} ]] && kill "$cat_pid" 2>/dev/null
  [[ $locked == yes ]] && "${ssh_[@]}" "$board" 'rm -f /root/vx-board.lock' 2>/dev/null
  echo "BOARDRUN DONE $status"
}
trap finish EXIT

# The lock. noclobber makes taking it atomic.
take() { "${ssh_[@]}" "$board" "sh -c 'set -C; echo \"$owner\" > /root/vx-board.lock'" 2>/dev/null; }
if ! take; then
  held=$("${ssh_[@]}" "$board" 'cat /root/vx-board.lock 2>/dev/null')
  if [[ -z $held ]] && ! "${ssh_[@]}" "$board" true 2>/dev/null; then
    echo "board-run: the board does not answer at $board"
    status=no-board
    exit 1
  fi
  read -r h pid t _ <<<"$held"
  dead=no
  [[ $h == "$(hostname -s)" && $pid =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null && dead=yes
  old=no
  [[ $t =~ ^[0-9]+$ ]] && (($(date +%s) - t > stale_min * 60)) && old=yes
  # A lock in the old format ("session ID DATE") has no epoch; treat it as old.
  [[ ! $t =~ ^[0-9]+$ ]] && old=yes
  if [[ $dead == yes || $old == yes ]]; then
    echo "board-run: breaking a stale lock: $held"
    "${ssh_[@]}" "$board" 'rm -f /root/vx-board.lock'
    take || { echo "board-run: lost the lock to another run"; status=locked; exit 1; }
  else
    echo "board-run: the board is held: $held"
    status=locked
    exit 1
  fi
fi
locked=yes

# The console, from before the boot, held open at 115200: macOS forgets
# `stty -f`'s settings when the descriptor closes, and `cat` then records
# nothing.
: > "$log"
BOARD_TTY=$tty python3 "$here/listen.py" "$log" 900 &
cat_pid=$!

# The image onto the ESP.
"${scp_[@]}" "$image/croi/kernel.elf" "$image/croi/bootfs.img" "$image/croi/cmdline" \
  "$image/EFI/BOOT/BOOTAA64.EFI" "$board:/tmp/" || { status=copy-failed; exit 1; }
"${ssh_[@]}" "$board" "set -e
  mkdir -p /tmp/esp
  mount -t msdosfs /dev/nda0p1 /tmp/esp
  if [ -n '$backup' ] && [ ! -e /tmp/esp/$backup ]; then cp -R /tmp/esp/croi /tmp/esp/$backup; fi
  cp /tmp/kernel.elf /tmp/bootfs.img /tmp/cmdline /tmp/esp/croi/
  cp /tmp/BOOTAA64.EFI /tmp/esp/EFI/vectra/BOOTAA64.EFI
  sync
  ls -la /tmp/esp/croi /tmp/esp/EFI/vectra
  umount /tmp/esp
  efibootmgr -n -b $entry >/dev/null
  efibootmgr | grep -i bootnext
  echo deployed" || { status=deploy-failed; exit 1; }
"${ssh_[@]}" "$board" 'shutdown -r now' >/dev/null 2>&1

# board-test's last line, or the deadline.
deadline=$((SECONDS + 360))
sleep 20
while ((SECONDS < deadline)); do
  if grep -aq "board-test: passed" "$log"; then status=passed; break; fi
  if grep -aq "board-test: FAILED" "$log"; then status=failed; break; fi
  sleep 5
done
[[ $status == unknown ]] && status=timeout
# FreeBSD back, so the lock can be released.
while ((SECONDS < deadline + 240)); do
  "${ssh_[@]}" "$board" true 2>/dev/null && break
  sleep 10
done
