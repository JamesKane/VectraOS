# FreeBSD on the Orange Pi 6 Plus, D127's same-program rows (2026-10-25)

Five rounds, a boot each, of tools/peer-bench's rows: `freebsd.sh` run
`stock`, then `tuned` in the same boot. `rN-stock.txt` and `rN-tuned.txt`
are each run's whole output.

- **Kernel:** FreeBSD 16.0-CURRENT at AbyssBSD's `orangepi-6-plus`,
  f12c9f4ee, the commit of the board's own kernel, built on the dev
  machine as `GENERIC-HMP-IOMMU-NODEBUG`
  (tools/peer-bench/GENERIC-HMP-IOMMU-NODEBUG: the board's
  `kern.conftxt` and `std.nodebug`), without WITNESS or INVARIANTS as
  D127 asks; installed as `/boot/kernel.nodebug` and booted with
  `nextboot -k`. The board's default kernel is the debug one.
- **Not loaded:** the out-of-tree graphics stack in rc.conf's
  `kld_list` (drm, komeda, panthor, amvx, aipu): built against the
  debug kernel, refused at load (`depends on dmabuf - not available or
  version mismatch`). So `idle_rss` and `idle_wakeups` are lighter
  than an install with them loaded.
- **System:** UFS with soft updates; loader.conf as installed.
- **Cores:** every row on the 2.5 GHz Cortex-A720 pair, MPIDR Aff1 8
  and 9 (FreeBSD's CPUs 10 and 11).
- **Tuned:** powerd stopped and every CPU at its highest level.
- **Heat:** each round started at 44-45 C, but round 4's tuned run
  started at 51 C (the cool-down's wait didn't hold it); its figures are
  within the other rounds' spread.
- **One stall:** round 4's stock run's timer_wake_idle.p999 is 444 ms
  (the others 18-20 us): at least 60 of its 60,000 wakes were that late,
  as one stall of about half a second and its catch-up would make. The
  median's spread below includes it.

Figures are medians of the five rounds; the spread is (max - min) /
median.

| Row | Stock, median (spread) | Tuned, median (spread) |
|---|---|---|
| `syscall_null` | 162 ns (1%) | 123 ns (1%) |
| `ipc_rtt_same` | 2870 ns (1%) | 2220 ns (2%) |
| `ipc_rtt_cross` | 4930 ns (5%) | 4290 ns (6%) |
| `wake_cross.p50` | 3820 ns (4%) | 3350 ns (1%) |
| `wake_cross.p99` | 4339 ns (12%) | 3750 ns (4%) |
| `fault_anon` | 992 ns (1%) | 799 ns (1%) |
| `map_unmap.4k` | 825 ns (1%) | 624 ns (1%) |
| `map_unmap.2m` | 804 ns (1%) | 608 ns (1%) |
| `spawn_exit_static` | 339.96 us (5%) | 283.86 us (5%) |
| `spawn_exit_linked` | 682.07 us (5%) | 539.86 us (7%) |
| `thread_create` | 6042 ns (1%) | 4573 ns (3%) |
| `clock_mono` | 64 ns (0%) | 52 ns (0%) |
| `small_read` | 3020 ns (3%) | 2323 ns (2%) |
| `read_4k` | 758 ns (2%) | 635 ns (7%) |
| `tree_walk` | 1306 ns (1%) | 993 ns (1%) |
| `timer_wake_idle.p50` | 14.19 us (3%) | 11.74 us (2%) |
| `timer_wake_idle.p99` | 17.19 us (4%) | 15.60 us (1%) |
| `timer_wake_idle.p999` | 18.91 us (2350201%) | 16.28 us (9%) |
| `idle_rss` | 612 MiB (0%) | 612 MiB (0%) |
| `idle_wakeups` | 7027 (14%) | 6570 (3%) |
