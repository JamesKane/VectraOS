# Fuchsia against VectraOS amd64 under KVM, D127's same-program rows (2026-10-26)

Fuchsia is the peer for what being a microkernel costs (where a gap
comes from that, Fuchsia is the mark, not Linux or FreeBSD). It can't
boot the Orange Pi 6 Plus, so this pair runs on the dev machine, each
under QEMU/KVM, and is compared only with itself, not with the board's
columns. Three rounds, Fuchsia then VectraOS, one VM at a time, the
other sessions' builds and QEMU held. `rN-fuchsia.txt` and
`rN-vectraos.txt` are each run's budget lines.

- **Host:** AMD Ryzen 7 9700X (8 cores, 16 threads, up to 5.58 GHz),
  Fedora, the `powersave` governor, KVM's default halt polling.
- **VMs:** 4 vCPUs, 8 GiB, `-cpu host`, nothing pinned (Fuchsia gives a
  program no affinity call, so neither side pins; `ipc_rtt_same` and
  `ipc_rtt_cross` are the same row here).
- **Fuchsia:** `core.x64`, `--release`, at e8b19ec722 (croi's reference
  pin), its emulator with `--engine qemu` (its prebuilt QEMU 11.0.2),
  the rows as `ffx test` components so `/data` is Fxfs
  (tools/peer-bench/README.md).
- **VectraOS:** 2dc299e with this harness, `vx boot --cpu`'s image under
  Fedora's QEMU 10.2.2 with UEFI, `/data` Taisce on a 2 GiB virtio disk,
  the rows from a cpu session.
- **Fuchsia's differences in `rows.c`:** its null call is
  `zx_handle_close` of the invalid handle (VectraOS's is `getpid`, an
  `object_get_info`: heavier); it has no static programs (no
  `spawn_exit_static`), no `nftw` (`tree_walk` by hand: `openat`,
  `readdir`, `fstatat` each entry) and no working `clock_nanosleep`
  (`zx_nanosleep`).

## The clock

`cpu_mhz` read 5,316-5,511 MHz in Fuchsia's runs and 4,138-4,608 in
VectraOS's. The core is the same, and VectraOS's clock keeps time (a
30 s sleep took 30.06 s by the host's). Run alone afterwards, VectraOS's
`cpu_mhz` read 5,080-5,459 MHz, as the host's own does (5,306-5,486), so
in the rounds VectraOS's CPU-bound rows ran ~25% slower than Fuchsia's
for a reason outside both: each VectraOS run followed a Fuchsia run
whose `tree_walk` made 100,000 files on all four vCPUs, and heat
lowering the boost is the likeliest, not shown. Rows within ~25% of
each other (syscall_null, fault_anon, map_unmap, clock_mono,
wake_cross, the timer) aren't settled by these rounds; the others
differ by much more.

## Medians of the three rounds (range)

| Row | Fuchsia | VectraOS | |
|---|---:|---:|---|
| `syscall_null` | 43 ns (39-48) | 93 ns (92-94) | different calls (above) |
| `ipc_rtt` (pipes) | 3.22 µs (3.19-3.23) | 1.98 µs (1.97-1.98) | |
| `wake_cross.p50` | 8.40 µs (7.37-8.49) | 10.16 µs (8.01-10.58) | |
| `wake_cross.p99` | 22.06 µs (20.41-22.25) | 14.66 µs (13.64-38.41) | |
| `fault_anon` | 670 ns (646-694) | 518 ns (503-523) | |
| `map_unmap.4k` | 1.46 µs (1.43-1.49) | 1.77 µs (1.71-1.79) | |
| `map_unmap.2m` | 1.44 µs (1.44-1.46) | 1.87 µs (1.83-1.91) | |
| `spawn_exit_static` | none | 1.30 ms (1.23-1.38) | Fuchsia links nothing static |
| `spawn_exit_linked` | 0.545 ms (0.541-0.555) | 2.54 ms (2.48-2.68) | |
| `thread_create` | 127.7 µs (125.2-131.0) | 59.8 µs (59.2-61.6) | |
| `clock_mono` | 26 ns (25-26) | 20 ns (20-20) | |
| `cpu_mhz` | 5,443 (5,316-5,511) | 4,262 (4,138-4,608) | the clock, above |
| `small_read` | 55.1 µs (50.9-60.4) | 8.3 µs (8.3-10.1) | |
| `read_4k` | 403 ns (323-417) | 530 ns (467-638) | Fuchsia's reads are a kernel stream |
| `tree_walk` | 65.8 µs/entry (64.1-65.9) | 0.69 µs/entry (0.69-0.70) | |
| `timer_wake_idle.p50` | 12.9 µs (12.8-13.1) | 5.0 µs (4.6-5.0) | |
| `timer_wake_idle.p99` | 46.6 µs (43.8-48.6) | 19.5 µs (12.1-23.2) | |
| `timer_wake_idle.p999` | 110.5 µs (91.2-131.5) | 108.4 µs (32.8-116.3) | |

## What it says

- **Files:** Fuchsia's open-read-close is ~55 µs, two round trips
  (its open waits for `OnRepresentation`, close is a synchronous
  `Close`), six or seven times VectraOS's one; its walk opens and stats
  every entry, ~95 times VectraOS's listing with status. Its reads,
  though, never reach Fxfs: a `zx_stream_readv` against the file's
  pager-backed VMO, so `read_4k` is a little faster than VectraOS's
  ring. D131's pager VMOs are VectraOS's step there.
- **Processes:** Fuchsia spawns ~4.7 times faster; VectraOS makes a
  thread in half the time. Both are far from the monolithic peers on
  the board (thread_create 4.6 µs, spawn 0.28-0.46 ms there), which
  makes these two rows VectraOS's own to fix, not the structure's.

## read_4k again, at matched clocks (2026-10-27)

The rounds above ran VectraOS ~25% slower than Fuchsia's clock. Four
rounds again, each VM alone with the other sessions held, 60 s between
VMs, VectraOS at 864db60: Fuchsia's `files` component (its `read_4k`
runs before `tree_walk` heats anything), VectraOS's `read_4k` three
times in one boot, then its `cpu_mhz`. The host's busiest core, sampled
every 0.25 s, read ~5.5 GHz under both; VectraOS's `cpu_mhz` read
5,126-5,462 MHz (it was 4,138-4,608). Budget lines in
`read4k-2026-10-27/`.

| Row | Fuchsia | VectraOS |
|---|---:|---:|
| `read_4k` | 402 ns (394-420, 4 runs) | 615 ns (527-848, 12 runs) |
| `small_read` | 59.6 µs (57.9-59.9) | not run |

The gap is real, and at matched clocks wider than it looked: ~1.5x, not
~1.3x. Fuchsia's runs agree within 7%; VectraOS's vary by 60%, within
one boot as much as between boots, which is a finding of its own.
Fuchsia reads through `zx_stream_readv` on the file's pager-backed VMO,
never reaching Fxfs; VectraOS reads through the ring to fs. D131's
pager VMOs are the step that would let VectraOS read the same way.
