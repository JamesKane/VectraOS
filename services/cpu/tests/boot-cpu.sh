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

# 1b. A file of many blocks in and out: read ahead from /mnt/term (blocks
# asked for before they are read), written to /data, read back to the
# terminal, the same bytes.
head -c 1048576 /dev/urandom > "$root/blocks"
out=$work/blocks.out
timeout 60 "$vx" cpu --key "$key" -k "$node" -r "$root" \
  -c 'cp /mnt/term/root/blocks /data/blocks && cp /data/blocks /mnt/term/root/blocks.back' "127.0.0.1!$port" \
  < /dev/null > "$out" 2>&1 || fail "vx cpu (blocks) failed" "$out"
cmp -s "$root/blocks" "$root/blocks.back" || fail "a megabyte through /data came back changed" "$out"
echo "boot-cpu: a megabyte read ahead from the terminal came back the same"

# 1b'. The link's budget (performance.md: a 64 MiB copy from /mnt/term,
# >= 100 MB/s under KVM): the copy's time less an empty session's, as
# remote.copy. Reported, not judged: this is TCG, and vx bench boots no
# cpu node yet.
head -c 67108864 /dev/urandom > "$root/big"
out=$work/copy.out
t0=$(date +%s%N)
timeout 60 "$vx" cpu --key "$key" -k "$node" -r "$root" -c 'echo' "127.0.0.1!$port" < /dev/null > /dev/null 2>&1 || true
t1=$(date +%s%N)
timeout 200 "$vx" cpu --key "$key" -k "$node" -r "$root" -c 'cp /mnt/term/root/big /dev/warm/bootfs' "127.0.0.1!$port" \
  < /dev/null > "$out" 2>&1 || fail "vx cpu (64 MiB) failed" "$out"
t2=$(date +%s%N)
rm -f "$root/big"
copy=$(( (t2 - t1) - (t1 - t0) ))
echo "boot-cpu: 64 MiB from the terminal in $(( copy / 1000000 )) ms"
echo "  budget name=remote.copy value=$copy unit=ns limit=671088640"

# 1c. A profile (trace(8), vx remote trace): the node sampled for two
# seconds while the terminal copies to it, its samples named from this
# build's kernel and bootfs: net's functions, and the kernel's.
rm -f "$work/trace.done"
(
  for _ in $(seq 60); do
    [[ -f $work/trace.done ]] && break
    timeout 30 "$vx" cpu --key "$key" -k "$node" -r "$root" -c 'cp /mnt/term/root/blocks /data/blocks' \
      "127.0.0.1!$port" < /dev/null > /dev/null 2>&1 || true
  done
) &
load=$!
out=$work/trace.out
timeout 120 "$vx" remote trace --key "$key" -k "$node" --out "$work/trace" --kernel "$kernel" --bootfs "$bootfs" \
  "127.0.0.1!$port" 2 < /dev/null > "$out" 2>&1 || { touch "$work/trace.done"; fail "vx remote trace failed" "$out"; }
touch "$work/trace.done"
wait "$load" || true
tr -d '\r' < "$out" > "$out.lf"
grep -q 'trace: copied to /mnt/term/root' "$out.lf" || fail "trace(8) didn't copy its recording" "$out"
grep -q '^| `net` | [1-9]' "$out.lf" || fail "the profile has no samples of net" "$out"
grep -q '| bin/net | net |' "$out.lf" || fail "the profile names none of net's functions" "$out"
grep -q '| kernel |' "$out.lf" || fail "the profile names none of the kernel's functions" "$out"
echo "boot-cpu: a profile of the node names net's functions and the kernel's"
grep -m 12 '^| ' "$out.lf" || true

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

# 3b. Supervision: net, a bootfs program, restarted through the
# launcher's ctl, comes back (its program's bootfs held for it), and so do
# the cpu server's calls through it; then a burst of calls that hang up at
# once leaves the server answering (net's wakes coalesced: each queued,
# they passed the port's limit, which killed net).
out=$work/supervise.out
timeout 30 "$vx" cpu --key "$key" -k "$node" -r "$root" -c 'echo restart net >/svc/launcher/ctl' \
  "127.0.0.1!$port" < /dev/null > "$out" 2>&1 || true
for _ in $(seq 60); do
  timeout 20 "$vx" cpu --key "$key" -k "$node" -r "$root" -c 'cat /svc/launcher/status' "127.0.0.1!$port" \
    < /dev/null 2>/dev/null | tr -d '\r' > "$out" || true
  grep -qx 'net running restarts 1' "$out" && break
  sleep 0.5
done
grep -qx 'net running restarts 1' "$out" || fail "net didn't come back" "$out"
for _ in $(seq 32); do (exec 3<>"/dev/tcp/127.0.0.1/$port"; exec 3>&-) 2>/dev/null & done
wait
out=$work/burst.out
timeout 30 "$vx" cpu --key "$key" -k "$node" -r "$root" -c 'echo after the burst' "127.0.0.1!$port" \
  < /dev/null > "$out" || fail "vx cpu after a burst of calls failed" "$out"
tr -d '\r' < "$out" > "$out.lf"
grep -qx 'after the burst' "$out.lf" || fail "rc didn't run after a burst of calls" "$out"
! grep -aq 'policy: process' "$work/console.log" || fail "a process was killed past a limit" "$out"
echo "boot-cpu: net restarted, and the cpu server answers after it and after a burst of calls"

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
