#!/usr/bin/env bash
# boot-unlock (D153): the cpu image booted on an encrypted volume, which
# vx disk --encrypt makes. fs asks for its passphrase on the console, and
# the keys are typed through QEMU's monitor: a wrong passphrase first,
# which it asks again for, then the right one. vx cpu, whose server waited
# with /data until then, finds the keybag in fs's status and writes a file
# to /data. Then vx fsck opens the volume with the passphrase.
#
#   boot-unlock.sh VX QEMU PORT ARCH ESP WORK EDK2

set -euo pipefail
vx=$1 qemu=$2 port=$3 arch=$4 esp=$5 work=$6 edk2=$7
here=$(cd "$(dirname "$0")" && pwd)
key=$here/terminal.key node=$(cat "$here/node.pub")
mkdir -p "$work"
disk=$work/disk.img
rm -f "$disk"
echo "open sesame" | "$vx" disk "$disk" 256M 'taisce:*' --encrypt
mark="unlocked-$$-$RANDOM"
keys() { for k in "$@"; do "$vx" qemu-monitor "$QEMU_MONITOR" sendkey "$k" > /dev/null; done; }
call() { timeout 30 "$vx" cpu --key "$key" -k "$node" -c "$1" "127.0.0.1!$port" < /dev/null 2>&1 | tr -d '\r'; }
# Whether the console says $1 within 120 s.
seen() { for _ in $(seq 240); do grep -aq "$1" "$console" && return 0; sleep 0.5; done; return 1; }
export -f keys call seen
console=$work/boot/console.log
export vx key node port mark console

"$qemu" --test "its passphrase is asked for on the console" --forward "$port:17019" --disk "$disk" --timeout 240 \
  --then 'keys w r o n g ret && seen "a passphrase no slot takes" && keys o p e n spc s e s a m e ret &&
          seen "cpu: listening on" && call "cat /svc/fs/status" | grep -q "^keybag passphrase empty empty empty" &&
          call "echo $mark >/data/unlocked && cat /data/unlocked" | grep -qx "$mark"' \
  "$arch" "$esp" "$work/boot" "$edk2" > "$work/boot.log" 2>&1 \
  || { echo "boot-unlock: the boot failed"; tail -30 "$work/boot.log"; exit 1; }
echo "boot-unlock: a wrong passphrase was asked for again, and the right one unlocked /data"
echo "open sesame" | "$vx" fsck "$disk"
