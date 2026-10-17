#!/usr/bin/env bash
# boot-cpu's terminal (D77): run by qemu.sh --then once the node's cpu
# server says `cpu: listening on ..., key KEY` ($QEMU_LINE), it calls the
# node with vx cpu as the tests' terminal (terminal.key, whose public half
# the test image pins), through the forwarded port.
#
#   boot-cpu.sh VX PORT WORK
#
# First a command: rc -c reads the dev machine's file through
# /mnt/term/root, writes one there, lists /mnt/term/dev, and copies the
# file to fs(4)'s volume at /data and reads it back. Then an
# interactive rc: `cat` waits on the terminal, ^C (SIGINT to vx) interrupts
# it, and the next line still runs; the end of input ends the session.

set -euo pipefail
vx=$1 port=$2 work=$3
here=$(cd "$(dirname "$0")" && pwd)
key=$here/terminal.key

node=${QEMU_LINE##*key }
node=${node:0:64}
[[ $node =~ ^[0-9a-f]{64}$ ]] || { echo "boot-cpu: no node key in: $QEMU_LINE" >&2; exit 1; }

root=$work/terminal
rm -rf "$root"
mkdir -p "$root"
echo 'from the dev machine' > "$root/motd"

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

# 2. An interactive rc, interrupted.
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
