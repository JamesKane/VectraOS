#!/usr/bin/env bash
# boot-reload's terminal (hotreload(2), D122): run by qemu.sh --then once
# the cpu image's server listens, as boot-cpu's is. Through vx cpu and vx
# reload, as the tests' terminal:
#
#   boot-reload.sh VX PORT WORK BUILD
#
# 1. Version 1 of minimal's frame is put at /data/hot, and minimal-hot
#    started through the launcher's ctl: it runs image 1.
# 2. Version 2 is reloaded over it: image 2 runs, and the frames drawn,
#    kept in the state block, carried on.
# 3. An image whose state has another layout is refused, and 2 runs on.
# 4. The 10,000-line module is rebuilt from a touched source, reloaded,
#    and timed from the touch to its code running: reload.module_10k.

set -euo pipefail
vx=$1 port=$2 work=$3 build=$4
here=$(cd "$(dirname "$0")" && pwd)
cpu=$here/../../../services/cpu/tests
key=$cpu/terminal.key
node=${QEMU_LINE##*key }
node=${node:0:64}
[[ $node =~ ^[0-9a-f]{64}$ ]] || { echo "boot-reload: no node key in: $QEMU_LINE" >&2; exit 1; }
at="127.0.0.1!$port"

root=$work/terminal
rm -rf "$root"
mkdir -p "$root"
cp "$build"/kernel/libminimalframe.so "$build"/kernel/libminimalframe2.so "$build"/kernel/libminimalframe3.so "$root/"

fail() {
  echo "boot-reload: $1" >&2
  [[ -f ${2:-} ]] && { echo "--- what the terminal showed:" >&2; cat "$2" >&2; }
  exit 1
}
session() {  # COMMAND OUT
  timeout 30 "$vx" cpu --key "$key" -k "$node" -r "$root" -c "$1" "$at" < /dev/null > "$2" 2>&1 || fail "vx cpu -c '$1' failed" "$2"
  tr -d '\r' < "$2" > "$2.lf"
}
reload() {  # IMAGE OUT [vx reload's options]
  local image=$1 out=$2
  shift 2
  timeout 60 "$vx" reload --key "$key" -k "$node" "$@" "$at" "$image" /data/hot/libminimalframe.so > "$out" 2>&1
}
hot=/data/hot/libminimalframe.so.status
status() { session "cat $hot" "$work/status.out"; cat "$work/status.out.lf"; }

# 1. Version 1, and minimal-hot started.
session 'mkdir /data/hot' "$work/mkdir.out"
reload "$root/libminimalframe.so" "$work/v1.out" || fail "vx reload of version 1 failed" "$work/v1.out"
session 'echo start minimal-hot >/svc/launcher/ctl' "$work/start.out"
for _ in $(seq 50); do
  status | grep -q '^image 1 ' && break
  sleep 0.2
done
status | grep -q '^image 1 loads 1 ' || fail "minimal-hot doesn't run image 1" "$work/status.out"
echo "boot-reload: minimal-hot runs image 1"

# 2. Version 2 over it, its state kept: the status written as it loads
# shows the frames version 1 drew.
sleep 0.5
reload "$root/libminimalframe2.so" "$work/v2.out" --status $hot || fail "vx reload of version 2 failed" "$work/v2.out"
grep -q 'hot: image 2 loads 2 ' "$work/v2.out" || fail "version 2 isn't running" "$work/v2.out"
drawn=$(status | sed -n 's/.* drawn \([0-9]*\).*/\1/p')
(( drawn > 20 )) || fail "the frames drawn didn't carry on (${drawn:-none} drawn)" "$work/status.out"
echo "boot-reload: image 2 runs, its state kept ($drawn frames drawn)"

# 3. Another layout, refused.
if reload "$root/libminimalframe3.so" "$work/v3.out" --status $hot; then
  fail "an image with another state layout was taken" "$work/v3.out"
fi
grep -q "refused .*layout isn't the block's" "$work/v3.out" || fail "the refusal doesn't say why" "$work/v3.out"
status | grep -q '^image 2 ' || fail "image 2 didn't run on" "$work/status.out"
echo "boot-reload: an image with another state layout is refused, and image 2 runs on"

# 4. The 10,000-line module, from a touched source to its code running.
touch "$build/kernel/hot10k/Filler.swift"
reload "$build/kernel/libhot10k.so" "$work/v4.out" --status $hot --build "$build" hot10k ||
  fail "vx reload of the 10,000-line module failed" "$work/v4.out"
grep -q 'hot: image 4 ' "$work/v4.out" || fail "the 10,000-line module isn't running" "$work/v4.out"
grep 'reload:\|budget' "$work/v4.out"
echo "boot-reload: all passed"
