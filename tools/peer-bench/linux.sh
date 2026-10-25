#!/bin/sh
# linux.sh DIR [stock|tuned [COOL]]: one Linux boot's share of a D127
# round, run on the board from DIR, which holds build.sh's peer-bench,
# hello-static and hello-linked; prints budget lines and the run's facts.
#
# As freebsd.sh: the rows pinned by MPIDR to the 2.5 GHz Cortex-A720
# pair, Aff1 8 and 9, which Linux numbers 10 and 11 (the same ACPI order
# as FreeBSD's: their own cluster, cpuinfo_max_freq 2500000); the hottest
# thermal zone read before and after each row; the round started once
# it is at or below COOL degrees (45 by default; at most 10 minutes).
# `tuned` sets every CPU's governor to performance (root: sudo -n);
# `stock` leaves the system as installed. Footprint: idle_rss, memory
# in use as free(1) counts it (total less free, buffers and the page
# cache) after 60 s with nothing running but this; idle_wakeups, every
# count in /proc/interrupts (timers and IPIs included) over the next
# 60 s.
set -eu
dir=$1 mode=${2:-stock} cool=${3:-45}
cpus=10,11

hottest() {
  cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1 | awk '{printf "%.1f\n", $1 / 1000}'
}

interrupts() {
  awk 'NR > 1 { for (i = 2; i <= NF; i++) { if ($i ~ /^[0-9]+$/) n += $i; else break } } END { print n }' /proc/interrupts
}

echo "peer: os linux mode $mode"
echo "peer: uname $(uname -a)"
echo "peer: cmdline $(cat /proc/cmdline)"
echo "peer: fs $(findmnt -no FSTYPE --target "$dir")"
echo "peer: cpus $cpus (MPIDR Aff1 8, 9)"
echo "peer: governor $(cat /sys/devices/system/cpu/cpu10/cpufreq/scaling_governor)"

if [ "$mode" = tuned ]; then
  sudo -n true 2>/dev/null || { echo "linux.sh: tuned needs root (sudo -n)" >&2; exit 1; }
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo -n tee "$g" >/dev/null; done
  echo "peer: governor now $(cat /sys/devices/system/cpu/cpu10/cpufreq/scaling_governor)"
fi

waited=0
while [ "$(hottest | cut -d. -f1)" -gt "$cool" ] && [ $waited -lt 600 ]; do
  sleep 10
  waited=$((waited + 10))
done
echo "peer: start $(hottest) C after ${waited} s cooling (to $cool C)"

for row in syscall_null ipc_rtt_same ipc_rtt_cross wake_cross fault_anon map_unmap spawn_exit_static \
  spawn_exit_linked thread_create clock_mono small_read read_4k tree_walk timer_wake_idle; do
  before=$(hottest)
  "$dir/peer-bench" -c "$cpus" -d "$dir" "$row"
  echo "peer: $row temperature $before to $(hottest) C"
done

# Footprint.
sleep 60
used=$(awk '/^MemTotal:/ {t = $2} /^MemFree:/ {f = $2} /^Buffers:/ {b = $2} /^Cached:/ {c = $2} /^SReclaimable:/ {s = $2}
  END { print (t - f - b - c - s) * 1024 }' /proc/meminfo)
echo "budget name=peer.idle_rss value=$used unit=bytes"
before=$(interrupts)
sleep 60
after=$(interrupts)
echo "budget name=peer.idle_wakeups value=$((after - before)) unit=count"
