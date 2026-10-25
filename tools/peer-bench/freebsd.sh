#!/bin/sh
# freebsd.sh DIR [stock|tuned [COOL]]: one FreeBSD boot's share of a D127 round,
# run on the board from DIR, which holds build.sh's peer-bench,
# hello-static and hello-linked; prints budget lines and the run's facts.
#
# The rows run pinned by MPIDR to the 2.5 GHz Cortex-A720 pair, Aff1 8
# and 9, which FreeBSD numbers 10 and 11 (`dmesg`: `CPU 10: ARM
# Cortex-A720 r0p1 affinity: 8 0`); the hottest thermal zone is read
# before and after each row. `tuned` stops powerd and holds the CPUs at
# their highest level; `stock` leaves the system as installed. The round
# starts once the hottest zone is at or below COOL degrees (45 by
# default; at most 10 minutes' wait), as every OS's does.
# Footprint: idle_rss, the pages wired, active and in laundry after 60 s
# with nothing running but this; idle_wakeups, every interrupt (`vmstat
# -i`, timers included) over the next 60 s.
set -eu
dir=$1 mode=${2:-stock} cool=${3:-45}
cpus=10,11

hottest() {
  sysctl -a 2>/dev/null | sed -n 's/^hw\.acpi\.thermal\.tz[0-9]*\.temperature: \([0-9.]*\)C$/\1/p' | sort -n | tail -1
}

echo "peer: os freebsd mode $mode"
echo "peer: uname $(uname -a)"
echo "peer: kernel options $(sysctl -n kern.conftxt | grep -cE '^options[[:space:]]+(WITNESS|INVARIANTS)$') of WITNESS, INVARIANTS"
echo "peer: loader.conf $(grep -v '^#' /boot/loader.conf 2>/dev/null | tr '\n' ' ')"
echo "peer: fs $(mount -p | awk -v d="$(df "$dir" | tail -1 | awk '{print $6}')" '$2 == d {print $3}')"
echo "peer: cpus $cpus (MPIDR Aff1 8, 9)"
waited=0
while [ "$(hottest | cut -d. -f1)" -gt "$cool" ] && [ $waited -lt 600 ]; do
  sleep 10
  waited=$((waited + 10))
done
echo "peer: start $(hottest) C after ${waited} s cooling (to $cool C)"

if [ "$mode" = tuned ]; then
  service powerd onestop >/dev/null 2>&1 || true
  for c in 0 2 6 8 10; do
    top=$(sysctl -n dev.cpu.$c.freq_levels | cut -d/ -f1)
    sysctl dev.cpu.$c.freq="$top" >/dev/null
  done
fi

for row in syscall_null ipc_rtt_same ipc_rtt_cross wake_cross fault_anon map_unmap spawn_exit_static \
  spawn_exit_linked thread_create clock_mono small_read read_4k tree_walk timer_wake_idle; do
  before=$(hottest)
  "$dir/peer-bench" -c "$cpus" -d "$dir" "$row"
  echo "peer: $row temperature $before to $(hottest) C"
done

# Footprint.
sleep 60
pages=$(( $(sysctl -n vm.stats.vm.v_wire_count) + $(sysctl -n vm.stats.vm.v_active_count) \
  + $(sysctl -n vm.stats.vm.v_laundry_count) ))
echo "budget name=peer.idle_rss value=$(( pages * $(sysctl -n hw.pagesize) )) unit=bytes"
before=$(vmstat -i | awk '/^Total/ {print $2}')
sleep 60
after=$(vmstat -i | awk '/^Total/ {print $2}')
echo "budget name=peer.idle_wakeups value=$(( after - before )) unit=count"
