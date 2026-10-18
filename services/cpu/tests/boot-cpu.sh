#!/usr/bin/env bash
# boot-cpu's terminal (D77): run by qemu.sh --then once the node's cpu
# server says `cpu: listening on ..., key KEY` ($QEMU_LINE), it calls the
# node with vx cpu as the tests' terminal (terminal.key, whose public half
# the test image pins), through the forwarded port. KEY must be node.pub,
# the public half of the node key the image gives factotum (node.keys).
#
#   boot-cpu.sh VX PORT WORK PLUMBER ARCH KERNEL BOOTFS
#
# First a command: rc -c reads the dev machine's file through
# /mnt/term/root, writes one there, lists /mnt/term/dev, and copies the
# file to fs(4)'s volume at /data and reads it back. Then a pushed
# build: PLUMBER (the build's plumber.elf) copied to /dev/bin and
# restarted through the launcher's ctl. Then an
# interactive rc: `cat` waits on the terminal, ^C (SIGINT to vx) interrupts
# it, and the next line still runs; the end of input ends the session.

set -euo pipefail
vx=$1 port=$2 work=$3 plumber=$4 arch=$5 kernel=$6 bootfs=$7
here=$(cd "$(dirname "$0")" && pwd)
key=$here/terminal.key

node=${QEMU_LINE##*key }
node=${node:0:64}
[[ $node =~ ^[0-9a-f]{64}$ ]] || { echo "boot-cpu: no node key in: $QEMU_LINE" >&2; exit 1; }
[[ $node == "$(cat "$here/node.pub")" ]] || { echo "boot-cpu: the node's key isn't its image's: $QEMU_LINE" >&2; exit 1; }

root=$work/terminal
rm -rf "$root"
mkdir -p "$root"
echo 'from the dev machine' > "$root/motd"
cp "$plumber" "$root/plumber"
cp "$kernel" "$root/kernel.elf"
cp "$bootfs" "$root/bootfs.img"

fail() {
  echo "boot-cpu: $1" >&2
  [[ -f ${2:-} ]] && { echo "--- what the terminal showed:" >&2; cat "$2" >&2; }
  exit 1
}

# 1. A command, with the terminal's files.
out=$work/command.out
timeout 30 "$vx" cpu --key "$key" -k "$node" -r "$root" \
  -c 'cat /mnt/term/root/motd; echo made by rc >/mnt/term/root/out; ls /mnt/term/dev; cp /mnt/term/root/motd /data/motd && echo copied: `{cat /data/motd}' "127.0.0.1!$port" \
  < /dev/null > "$out" || fail "vx cpu -c failed" "$out"
tr -d '\r' < "$out" > "$out.lf"
grep -qx 'from the dev machine' "$out.lf" || fail "rc didn't read /mnt/term/root/motd" "$out"
grep -q 'cons' "$out.lf" && grep -q 'cpunote' "$out.lf" || fail "rc didn't list /mnt/term/dev" "$out"
[[ $(cat "$root/out" 2>/dev/null) == 'made by rc' ]] || fail "rc didn't write /mnt/term/root/out" "$out"
grep -qx 'copied: from the dev machine' "$out.lf" || fail "rc didn't copy the file to /data" "$out"
echo "boot-cpu: rc -c ran with the terminal's files, and copied one to /data"

# 2. Push and run: the build dir's plumber copied to /dev/bin and
# restarted through the launcher's ctl, which then says it runs the
# pushed build; the session's /mnt/plumb reconnects to it (D100).
out=$work/push.out
timeout 60 "$vx" cpu --key "$key" -k "$node" -r "$root" \
  -c 'cp /mnt/term/root/plumber /dev/bin/plumber && echo restart plumber >/svc/launcher/ctl; while(! ~ pushed `{cat /svc/launcher/status}) x=1; ls /mnt/plumb' \
  "127.0.0.1!$port" < /dev/null > "$out" || fail "vx cpu (push) failed" "$out"
tr -d '\r' < "$out" > "$out.lf"
grep -qx '/mnt/plumb/rules' "$out.lf" || fail "the pushed plumber didn't answer at /mnt/plumb" "$out"
echo "boot-cpu: a pushed plumber runs in place of bootfs's"

# 3. An interactive rc, interrupted.
in=$work/in
out=$work/session.out
rm -f "$in"
mkfifo "$in"
"$vx" cpu --key "$key" -k "$node" -r "$root" "127.0.0.1!$port" < "$in" > "$out" &
vx_pid=$!
exec 3> "$in"
# Waits until the terminal has shown `$1`, or fails.
seen() {
  for _ in $(seq 100); do
    tr -d '\r' < "$out" | grep -q -- "$1" && return 0
    kill -0 "$vx_pid" 2>/dev/null || fail "vx cpu ended waiting for '$1'" "$out"
    sleep 0.2
  done
  fail "the terminal never showed '$1'" "$out"
}
echo 'echo ready' >&3
seen ready
echo 'cat' >&3
sleep 2  # cat is reading the terminal
kill -INT "$vx_pid"
sleep 1
# Were cat still reading, it would show the line as typed, quotes and all.
echo "echo after the 'inter'rupt" >&3
seen 'after the interrupt'
! grep -q "'inter'" "$out" || fail "^C didn't interrupt cat" "$out"
exec 3>&-  # the end of input: rc ends, and the node hangs up
for _ in $(seq 50); do kill -0 "$vx_pid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$vx_pid" 2>/dev/null; then
  kill "$vx_pid"
  fail "the session didn't end with its input" "$out"
fi
wait "$vx_pid" || fail "vx cpu failed" "$out"
echo "boot-cpu: ^C interrupted cat, and rc went on"

# 4. Warm boot (D101, amd64 and arm64): vx remote boot hands the node
# to the build's own kernel and this image's bootfs, with an option that
# says so, and waits for the new boot's cpu server, which has the same
# key, the image's.
if [[ $arch == amd64 || $arch == arm64 ]]; then
  out=$work/warmboot.out
  timeout 120 "$vx" remote boot --key "$key" -k "$node" --kernel "$kernel" --bootfs "$bootfs" "127.0.0.1!$port" \
    'croi.test=1' 'croi.selftest=off' 'userboot.next=bin/launcher' 'warmboot.second=1' \
    < /dev/null > "$out" 2>&1 || fail "vx remote boot failed" "$out"
  tr -d '\r' < "$out" > "$out.lf"
  grep -q '^vx remote boot: back on cpu' "$out.lf" || fail "vx remote boot didn't find the new boot" "$out"
  grep -q '  budget name=remote.warmboot value=' "$out.lf" || fail "vx remote boot didn't time it" "$out"
  grep -q 'devmgr: warm boot, as /dev/reboot asked' "$work/console.log" || fail "devmgr didn't warm-boot" "$out"
  grep -q 'warmboot.second=1' "$work/console.log" || fail "the new boot hasn't the command line given" "$out"
  again=$(grep -a 'cpu: listening on' "$work/console.log" | sed -n 2p)
  [[ ${again##*key } == "$node"* ]] || fail "the new boot's key isn't the image's" "$out"
  out=$work/after.out
  timeout 30 "$vx" cpu --key "$key" -k "$node" -r "$root" -c 'echo back after a warm boot' "127.0.0.1!$port" \
    < /dev/null > "$out" || fail "vx cpu after the warm boot failed" "$out"
  tr -d '\r' < "$out" > "$out.lf"
  grep -qx 'back after a warm boot' "$out.lf" || fail "rc didn't run after the warm boot" "$out"
  echo "boot-cpu: vx remote boot came back with its cpu server"
  grep '^vx remote boot: \|  budget ' "$work/warmboot.out.lf" || true
fi

# 5. The board tools: restart says its usage, and poweroff turns the
# node off through devmgr's /dev/reboot (\_S5's sleep types on amd64).
# The session ends with the machine, so its status is not judged; the
# kernel's line is.
out=$work/tools.out
timeout 20 "$vx" cpu --key "$key" -k "$node" -r "$root" -c 'restart >[2=1]; poweroff' \
  "127.0.0.1!$port" < /dev/null > "$out" || true
tr -d '\r' < "$out" > "$out.lf"
grep -qx 'usage: restart service ...' "$out.lf" || fail "the restart script didn't say its usage" "$out"
for _ in $(seq 100); do
  grep -q 'croi kernel: powering off' "$work/console.log" && break
  sleep 0.2
done
grep -q 'devmgr: powering off, as /dev/reboot asked' "$work/console.log" || fail "devmgr didn't power off" "$out"
grep -q 'croi kernel: powering off' "$work/console.log" || fail "the node didn't power off" "$out"
echo "boot-cpu: poweroff turned the node off"
