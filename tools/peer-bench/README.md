# peer-bench: D127's rows

VectraOS against stock and tuned Ubuntu and FreeBSD on the Orange Pi 6
Plus (D127). This directory holds the rows run as the *same program*
column, one portable C source for all three OSes, and each OS's harness.

- `rows.c`: the rows that need neither the bench drive nor the network's
  far end: the primitives (`syscall_null`, `ipc_rtt_same`,
  `ipc_rtt_cross`, `wake_cross`, `fault_anon`, `map_unmap`,
  `spawn_exit_static`, `spawn_exit_linked`, `thread_create`,
  `clock_mono`), the cached file rows (`small_read`, `read_4k`,
  `tree_walk`) and `timer_wake_idle`. Each prints `budget
  name=peer.<row>` lines. `hello.c` is the spawn rows' child.
- `build.sh OS OUT`: builds them for `freebsd` or `linux` with the
  bundled clang and lld, the same flags and `-march` (D53's baseline)
  for every OS, against a sysroot in `.cache/peer-sysroots/OS`.
- `freebsd.sh DIR [stock|tuned [COOL]]`: FreeBSD's share of a round,
  run on the board: the run's facts (uname, WITNESS and INVARIANTS,
  loader.conf, the file system), a wait until the SoC has cooled, every
  row pinned to the same cores, each row's temperatures, then
  `idle_rss` and `idle_wakeups`.
- `linux.sh DIR [stock|tuned [COOL]]`: the same for Linux; `tuned` sets
  the performance governor (sudo). Run with DIR on the root file system
  (Ubuntu's `/tmp` is tmpfs), and the system booted to
  `multi-user.target`.

## The cores

Every row runs on the 2.5 GHz Cortex-A720 pair, MPIDR Aff1 8 and 9: the
fastest pair that isn't the boot core's (VectraOS takes every device
interrupt on the boot core, Aff1 10). FreeBSD numbers them 10 and 11.

## FreeBSD's kernel

D127's stock FreeBSD has no WITNESS or INVARIANTS. The board's kernel
has both, so the runs boot `GENERIC-HMP-IOMMU-NODEBUG` (this
directory's copy: the board kernel's `kern.conftxt` with `include
"std.nodebug"`), built from AbyssBSD's `orangepi-6-plus` at the board
kernel's commit with its docs/BUILDING.md recipe for arm64. On a Linux
host, pass `MACHINE=arm64 MACHINE_ARCH=aarch64 MACHINE_CPUARCH=aarch64`
to buildkernel (the modules otherwise take the host's) and not `STRIP=`
(install's flag). Installed as `/boot/kernel.nodebug` beside the
others, then `kldxref`, and booted once a round with `nextboot -k
kernel.nodebug`.

## Results

`bench/peers/<date>-<os>/`: each run's output and a summary.

## Ubuntu's host key

Ubuntu and FreeBSD answer at the board's one address with different host
keys; keep Ubuntu's in a file of its own (`ssh -o
UserKnownHostsFile=~/.ssh/known_hosts.opi6-ubuntu`) so FreeBSD's stays.

## Sysroots

Copied from the board, host-only (D4); `PROVENANCE` in each says which
system and when. FreeBSD's:

```sh
ssh BOARD 'cd / && tar cf - usr/include lib/libc.so.7 lib/libsys.so.7 \
  lib/libthr.so.3 lib/libm.so.5 lib/libgcc_s.so.1 usr/lib/crt*.o \
  usr/lib/Scrt1.o usr/lib/libc.* usr/lib/libc_nonshared.a usr/lib/libsys.* \
  usr/lib/libthr.* usr/lib/libpthread.* usr/lib/libm.* usr/lib/libgcc* \
  usr/lib/libcompiler_rt.a usr/lib/libssp_nonshared.a' \
  | tar xf - -C .cache/peer-sysroots/freebsd
```

## Each OS's best mechanism

To come with the best column: rings and Sys on VectraOS, io_uring on
Linux, kqueue on FreeBSD; the deadline profile, SCHED_DEADLINE and
rtprio.

## Not yet here

The bench drive's rows, the network rows, the loaded latency rows,
`boot_shell` and VectraOS's column (its libc has no
posix_spawn, nftw or clock_nanosleep yet), and `vx bench --peers`.
