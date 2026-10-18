#!/usr/bin/env bash
# boot-persist (D105): the cpu image booted twice on one virtio disk,
# cold, as a node is between power cuts. The first boot writes a file to
# /data, the disk's Taisce volume, waits for the group to commit, and
# powers off; the second reads it back. Then vx fsck checks the volume.
#
#   boot-persist.sh VX QEMU PORT ARCH ESP WORK EDK2

set -euo pipefail
vx=$1 qemu=$2 port=$3 arch=$4 esp=$5 work=$6 edk2=$7
here=$(cd "$(dirname "$0")" && pwd)
key=$here/terminal.key node=$(cat "$here/node.pub")
mkdir -p "$work"
disk=$work/disk.img
rm -f "$disk"  # a new disk: vx disk makes it, its volume empty
mark="persisted-$$-$RANDOM"
call() { timeout 30 "$vx" cpu --key "$key" -k "$node" -c "$1" "127.0.0.1!$port" < /dev/null 2>&1 | tr -d '\r'; }
export -f call
export vx key node port mark

"$qemu" --test "cpu: listening on" --forward "$port:17019" --disk "$disk" --timeout 120 --exits \
  --then 'call "echo $mark >/data/persist" && sleep 2 && { call poweroff || true; }' \
  "$arch" "$esp" "$work/first" "$edk2" > "$work/first.log" 2>&1 \
  || { echo "boot-persist: the first boot failed"; tail -20 "$work/first.log"; exit 1; }
grep -aq 'croi kernel: powering off' "$work/first/console.log" || { echo "boot-persist: the first boot didn't power off"; exit 1; }
echo "boot-persist: the first boot wrote /data/persist and powered off"

"$qemu" --test "cpu: listening on" --forward "$port:17019" --disk "$disk" --timeout 120 \
  --then 'call "cat /data/persist" | grep -qx "$mark"' \
  "$arch" "$esp" "$work/second" "$edk2" > "$work/second.log" 2>&1 \
  || { echo "boot-persist: the second boot didn't find /data/persist"; tail -20 "$work/second.log"; exit 1; }
echo "boot-persist: the second boot read it back"

"$vx" fsck "$disk"
