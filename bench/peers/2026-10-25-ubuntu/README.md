# Ubuntu on the Orange Pi 6 Plus, D127's same-program rows (2026-10-25)

Five rounds, a boot each, of tools/peer-bench's rows: `linux.sh` run
`stock`, then `tuned` in the same boot. `rN-stock.txt` and `rN-tuned.txt`
are each run's whole output.

- **System:** Ubuntu 26.04.1 LTS, its kernel as shipped, 7.0.0-41-cix
  (Ubuntu's flavour with the Sky1's support); the kernel command line as
  installed (each run's `peer: cmdline`); ext4 on the boot NVMe's
  partition; glibc 2.43. Spectre v2: `Mitigation: CSV2, BHB`.
- **Boot:** each round a fresh boot by UEFI BootNext (Ubuntu's entry,
  0004) to `multi-user.target`, no desktop, as FreeBSD's boots to a
  console; the default target was put back to `graphical.target`
  afterwards. A first run with GNOME up (not kept) held 1.9 GB and woke
  393,366 times in 60 s.
- **Files:** in `~/peer` on ext4 (`/tmp` is tmpfs), as FreeBSD's ran on
  its root file system, UFS.
- **Cores:** every row on the 2.5 GHz Cortex-A720 pair, MPIDR Aff1 8
  and 9, which Linux numbers 10 and 11 (their own cluster).
- **Tuned:** every CPU's governor set to performance (stock is
  schedutil).
- **Heat:** every run started at 43-44 C.

What shapes the figures, all stock Ubuntu's defaults:

- **Timer slack:** a thread's default timer slack is 50 us
  (`timerslack_ns` 50000), so timer_wake_idle sits at 53-59 us; FreeBSD
  has none. The best-mechanism column may set it (`PR_SET_TIMERSLACK`);
  this one keeps the default.
- **Idle states:** the cores have LPI-1 and LPI-2 (acpi_idle; 360 and
  500 us exit latency), so wake_cross depends on whether the waiting
  core was in one: its p50 is bimodal from round to round (stock 17-18
  us or 142-145 us; tuned 9 us or 58-62 us), its p99 steady (about 175
  and 75 us).
- **timer_wake_idle.p999** is 2.0-2.8 ms in every round: something
  periodic holds wakes off for about 2 ms.

Figures are medians of the five rounds; the spread is (max - min) /
median.

| Row | Stock, median (spread) | Tuned, median (spread) |
|---|---|---|
| `syscall_null` | 679 ns (1%) | 215 ns (2%) |
| `ipc_rtt_same` | 3840 ns (5%) | 3570 ns (4%) |
| `ipc_rtt_cross` | 22.14 us (4%) | 7960 ns (6%) |
| `wake_cross.p50` | 36.21 us (353%) | 58.44 us (91%) |
| `wake_cross.p99` | 177.60 us (8%) | 75.64 us (8%) |
| `fault_anon` | 2931 ns (12%) | 1297 ns (6%) |
| `map_unmap.4k` | 5847 ns (16%) | 2568 ns (7%) |
| `map_unmap.2m` | 2709 ns (12%) | 2171 ns (4%) |
| `spawn_exit_static` | 708.64 us (14%) | 358.35 us (4%) |
| `spawn_exit_linked` | 905.22 us (11%) | 462.01 us (7%) |
| `thread_create` | 32.32 us (3%) | 20.64 us (6%) |
| `clock_mono` | 64 ns (11%) | 40 ns (0%) |
| `small_read` | 4695 ns (4%) | 1937 ns (3%) |
| `read_4k` | 943 ns (8%) | 589 ns (1%) |
| `tree_walk` | 1320 ns (6%) | 1268 ns (3%) |
| `timer_wake_idle.p50` | 58.66 us (1%) | 52.97 us (0%) |
| `timer_wake_idle.p99` | 60.73 us (2%) | 53.59 us (0%) |
| `timer_wake_idle.p999` | 2115.70 us (29%) | 2625.37 us (30%) |
| `idle_rss` | 561 MiB (5%) | 564 MiB (3%) |
| `idle_wakeups` | 15243 (51%) | 14847 (16%) |
