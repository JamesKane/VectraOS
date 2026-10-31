#!/usr/bin/env bash
# boot-swarm-unlock (D153): an encrypted volume unlocked by a swarm
# member, nothing typed. Two cpu images: the member, booted on a plain
# volume, its cpu server's port and its unlock port (17021) forwarded to
# the host; and the node, on a disk vx disk --encrypt makes, its calls to
# 10.0.2.100!17021 relayed to the member's. The node's first boot is
# unlocked by its passphrase, typed through the monitor; vx cpu reads the
# member's key from its swarm status, adds a swarm slot naming it on the
# node's fs ctl, writes a file to /data and powers off. Its second boot
# is unlocked by the member alone, and the file reads back; then the
# member's status says it answered.
#
#   boot-swarm-unlock.sh VX QEMU PORT ARCH ESP WORK EDK2
#
# PORT is the node's cpu port, PORT+1 the member's, PORT+2 its unlocks'.
# (qemu.sh has its own $work, $qemu and $disk, so this script's are $dir,
# $qemush and $image.)

set -euo pipefail
vx=$1 qemush=$2 port=$3 arch=$4 esp=$5 dir=$6 edk2=$7
here=$(cd "$(dirname "$0")" && pwd)
key=$here/terminal.key node=$(cat "$here/node.pub")
mkdir -p "$dir"
image=$dir/disk.img
rm -f "$image" "$dir/member.img"
echo "open sesame" | "$vx" disk "$image" 256M 'taisce:*' --encrypt
mark="swarm-$$-$RANDOM"
member=$((port + 1)) answers=$((port + 2))
keys() { for k in "$@"; do "$vx" qemu-monitor "$QEMU_MONITOR" sendkey "$k" > /dev/null; done; }
# vx cpu on the guest whose cpu port is $1.
call() { timeout 30 "$vx" cpu --key "$key" -k "$node" -c "$2" "127.0.0.1!$1" < /dev/null 2>&1 | tr -d '\r'; }
# Whether console $1 says $2 within 120 s.
seen() { for _ in $(seq 240); do grep -aq "$2" "$1" && return 0; sleep 0.5; done; return 1; }

# The node's two boots, run while the member is up.
boots() {
  set -euo pipefail
  seen "$dir/member/console.log" "cpu: listening on" || { echo "boot-swarm-unlock: the member's cpu server didn't start"; return 1; }
  local mkey
  mkey=$(call "$member" "cat /svc/swarm/status" | sed -n 's/^unlock \([0-9a-f]\{64\}\) answered .*/\1/p')
  [[ -n $mkey ]] || { echo "boot-swarm-unlock: no unlock key in the member's status"; return 1; }
  export mkey
  "$qemush" --test "its passphrase is asked for on the console" --forward "$port:17019" --relay "17021:$answers" \
    --disk "$image" --timeout 120 --exits \
    --then 'keys o p e n spc s e s a m e ret && seen "$dir/first/console.log" "cpu: listening on" &&
            call "$port" "echo slot add swarm tcp!10.0.2.100!17021 $mkey >/svc/fs/ctl" &&
            sleep 1 && call "$port" "cat /svc/fs/status" | grep -q "^keybag passphrase swarm=tcp!10.0.2.100!17021 empty empty" &&
            call "$port" "echo $mark >/data/kept" && sleep 2 && { call "$port" poweroff || true; }' \
    "$arch" "$esp" "$dir/first" "$edk2" > "$dir/first.log" 2>&1 \
    || { echo "boot-swarm-unlock: the node's first boot failed"; tail -30 "$dir/first.log"; return 1; }
  echo "boot-swarm-unlock: the passphrase unlocked the node, which added a slot for the member"
  "$qemush" --test "unlocked by the swarm member at tcp!10.0.2.100!17021" --forward "$port:17019" \
    --relay "17021:$answers" --disk "$image" --timeout 120 \
    --then 'seen "$dir/second/console.log" "cpu: listening on" && call "$port" "cat /data/kept" | grep -qx "$mark"' \
    "$arch" "$esp" "$dir/second" "$edk2" > "$dir/second.log" 2>&1 \
    || { echo "boot-swarm-unlock: the member didn't unlock the node's second boot"; tail -30 "$dir/second.log"; return 1; }
  echo "boot-swarm-unlock: the member unlocked the node's second boot, nothing typed"
  call "$member" "cat /svc/swarm/status" | grep -q '^unlock [0-9a-f]* answered [1-9]' \
    || { echo "boot-swarm-unlock: the member's status doesn't count its answer"; return 1; }
}
export -f keys call seen boots
export vx qemush key node port member answers mark dir image arch esp edk2

"$qemush" --test "swarm: listening on tcp!*!17020" --forward "$member:17019" --forward "$answers:17021" \
  --disk "$dir/member.img" --timeout 290 --then boots \
  "$arch" "$esp" "$dir/member" "$edk2" > "$dir/member.log" 2>&1 \
  || { echo "boot-swarm-unlock: failed"; grep -a '^boot-swarm-unlock' "$dir/member.log" || tail -30 "$dir/member.log"; exit 1; }
grep -a '^boot-swarm-unlock' "$dir/member.log"
echo "open sesame" | "$vx" fsck "$image"
