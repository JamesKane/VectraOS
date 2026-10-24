# D127. VectraOS is measured against Linux and FreeBSD on the Orange Pi 6 Plus: the same workloads on the one board, bare metal, in rounds, each row judged in a parity band against the better peer; the table is an exit item of V6 and its gaps are optimization passes; bash's rows wait for tier 1's bash (2026-10-24; the board, the peers, the shell and the timing are the owner's choice, the rest for the owner's review)

The vision claims that a ring-buffer microkernel can match a monolithic
kernel on the paths our users take every day, and can beat it where
isolation matters. Our budgets (`docs/performance.md`) are absolute
numbers. They say whether VectraOS keeps its own promises, not whether
someone who runs Linux or FreeBSD today would lose anything by
switching. `tools/zircon-bench` compares croi with Zircon, but only on
m2's kernel primitives and only under KVM, and nobody chooses an OS by
comparing it with Zircon.

## The decision

- **One board, bare metal: the Orange Pi 6 Plus (CIX Sky1, D69).**
  Stock Ubuntu and FreeBSD (AbyssBSD's branch) already share its NVMe,
  and VectraOS boots from the space that is left. All three run on the
  same hardware, firmware, cooling and cable. KVM numbers show trends
  and never make a claim.
- **Two peers: Linux (stock Ubuntu) and FreeBSD.** Ubuntu's own kernel
  carries the Sky1's support, so "stock Linux" is the distro kernel
  as shipped, not a vendor BSP. Zircon stays in `tools/zircon-bench`
  for triaging kernel budgets.
- **Two columns for every row:**
  - *Same program*: one portable C source, built by our bundled clang
    with the same flags and `-march` for all three. On VectraOS it is a
    tier 1 program on the libc and FDIO (D47, D80). On the peers it is
    built against a sysroot copied from the board, and only on the
    host (D4).
  - *Best mechanism*: each OS's own fastest way to do the same work.
    That means rings and Sys against io_uring on Linux and kqueue on
    FreeBSD, and the deadline profile against `SCHED_DEADLINE` and
    `rtprio`. The report names the mechanism each OS used.

  A row never mixes the two columns.
- **The rows are fixed before the first run** (below). Adding a row
  later is fine. Removing one, or changing how it is judged, after
  results exist is a dated decision.
- **Parity bands**, from r = VectraOS ÷ the better of the two peers,
  with each row turned so that lower is better:
  - **win**: r ≤ 0.9
  - **parity**: 0.9 < r ≤ 1.25
  - **gap**: r > 1.25

  Every gap becomes a named optimization pass in the roadmap. A gap is
  never closed by changing the workload or the band.
- **Stock and tuned peers, each a column:**
  - *Stock*: Ubuntu as installed, and FreeBSD with its kernel built
    without WITNESS or INVARIANTS (16-CURRENT turns both on, and they
    tax exactly the paths we measure). The run records `uname -a`, the
    kernel command line or loader.conf, and the file system.
  - *Tuned*: the same kernels, changed only at run time. That means the
    performance governor (powerd off on FreeBSD), mitigations set to
    match VectraOS's, and isolated cores for the latency rows
    (`isolcpus` and `nohz_full`, and cpuset on FreeBSD).

  VectraOS boots as it would in production: a release image with no
  `croi.test=` (D125).
- **The same cores and the same heat.** The Sky1 has three core tiers.
  Every row pins its threads to cores of the same tier, by MPIDR, on all
  three OSes. A round starts only once the SoC has cooled to the same
  temperature, and records the temperature at the start and end of each
  row, because a throttled run measures the heatsink.
- **Rounds, not runs.** A round boots each OS once, in rotation, and
  that boot runs every row. The order is set from the host through
  UEFI's `BootNext`. Five rounds make a table, and each figure is a
  median with its spread. There is one profile per OS and no per-row
  boots, so the whole table is 15 boots.
- **Storage rows get their own drive.** A second NVMe that has its own
  DRAM serves as the bench drive for all three OSes, so the board's
  Micron 2550 (DRAM-less, with HMB) never turns a driver feature into an
  OS difference. Before each OS runs, the drive is trimmed whole and
  given a fresh file system, filled to the same level: Taisce, ext4,
  and FreeBSD's default as installed. Each file system's fsync must
  reach the device (an NVMe flush). If the board has no second M.2
  slot, the fallback is equal scratch partitions on the boot drive, and
  the report says so.
- **When it runs:** once for V6's exit. After that it runs on demand
  (before a release, or after an optimization pass, to measure the
  pass), never in `vx ci` or `vx bench`'s default set.

## The rows

Each row prints a `budget name=peer.<row> value=... unit=...` line on
every OS. Where a row is one of our own budgets, the report shows that
budget beside it.

**Primitives** (lmbench's shape; context for the rows below, not
the claim)

| Row | Workload |
|---|---|
| `syscall_null` | The cheapest real kernel entry, 10k, mean (best column only: there is no portable null call) |
| `ipc_rtt_same`, `ipc_rtt_cross` | A 1-byte request and reply over a pipe, on one core and across two (same); each OS's lowest-latency request/reply (best: channel_call) |
| `wake_cross` | A waiter on another core woken through a condition variable; median, p99 |
| `fault_anon` | Touch a fresh 64 MiB anonymous mapping; ns per page |
| `map_unmap` | Map and unmap 4 KiB and 2 MiB, 10k each |
| `spawn_exit_static`, `spawn_exit_linked` | `posix_spawn` of a static and of a dynamically linked hello, until `waitpid` returns |
| `thread_create` | Create and join a thread, 1k |
| `clock_mono` | `clock_gettime(CLOCK_MONOTONIC)` through the vDSO, mean |

**Files** (on the bench drive, except where marked cached)

| Row | Workload |
|---|---|
| `small_read` | open, read and close a 64-byte file, 10k (cached): the "cat a sensor" path |
| `read_4k` | `pread` of 4 KiB from a cached file |
| `tree_walk` | `nftw` with `stat` over 100k entries (cached) |
| `grep_tree` | One grep, ours, built for all three, over a 200 MB source tree (cached) |
| `create_fsync` | Create, write 4 KiB, fsync and unlink, 1k; p50 and p99 |
| `seq_rw` | Write a 1 GiB file, then read it back, uncached |
| `rand_4k_qd1`, `rand_4k_qd32` | Random 4 KiB reads, uncached (best: Taisce's ring, io_uring, aio) |

**Network** (the RTL8126 to the dev host, through one switch)

| Row | Workload |
|---|---|
| `tcp_stream_tx`, `tcp_stream_rx` | A 10 s TCP stream in each direction |
| `tcp_rtt` | 1-byte ping-pong over TCP; p50 and p99 |
| `udp_64_pps` | 64-byte UDP datagrams sent per second (best: the net class's ring, `sendmmsg`, netmap) |

**Latency**, where isolation should show

| Row | Workload |
|---|---|
| `timer_wake_idle` | A thread woken every 1 ms for 60 s, absolute sleep; wake error p50, p99 and p99.9 (cyclictest's shape) |
| `timer_wake_loaded` | The same, with every other core of the SoC busy and a storage flood on the bench drive |
| `frame_loop_loaded` | A 16.67 ms period with 4 ms of work, 10 minutes, under the same load; frames that miss their deadline |

**Footprint**

| Row | Workload |
|---|---|
| `boot_shell` | Power-on to a shell prompt on the serial console, timed by the host; firmware's share reported apart |
| `idle_rss` | Memory in use after booting to a shell and settling for 60 s |
| `idle_wakeups` | Wakeups over 60 s at an idle shell |

## Pending rows

These rows are named now so that they cannot be chosen after the
results are in. They join the table when their dependency lands, each in
the same change that makes it run:

- **bash** (`bash_pipeline`: `cat | grep | wc` over a cached file;
  `bash_spawn_1k`: a script that runs `true` a thousand times;
  `bash_configure`: an autoconf script's checks). These wait for bash on
  tier 1, and bash forks for pipelines and subshells. D80 keeps `fork`
  out of the libc, so bash needs either a fork in the libc's own code or
  a decision that amends D80 (open below).
- **9P mounts** (a 4 KiB read and a bulk read of a VectraOS export,
  against NFS and sshfs between the peers): V7's 9gate.
- **Audio at 128 frames under load**: an audio driver on the board.
- **A desktop app's cold start and a key reaching the glass**:
  reported only, because the compositors differ too much for a band.
  This waits for V6's desktop on the board.
- **`make -j` of a small C project**: clang as a tier 1 program on the
  board.

## Open

- **How bash runs without fork** is the POSIX layer's own decision, made
  when bash lands. Its precedents are Plan 9's APE and AmigaOS's bash.
  APE writes POSIX calls in the libc over native primitives. AmigaOS
  had no fork at all, and its bash was patched around a vfork-style
  call. The kernel and Sys get no fork, as D80 says. A command that runs
  another program (vfork, then exec) becomes `posix_spawn`. A child
  that keeps running shell code (a subshell, or a function inside a
  pipeline) needs one of two things: a bash patched to start a new
  shell carrying the state it needs, or a fork in the libc built on
  copy-on-write VMO children. The bash rows measure whichever is
  chosen, and the report names it.
- **The bench drive**: whether the board has a second M.2 M-key slot,
  and which drive to fit.
- **The host's end of the network rows**: a NIC that can keep up with
  5 GbE.

## In the tree (at V6's exit, not before)

- `tools/peer-bench/`: the rows' C sources, a README listing each
  OS's best mechanism, and the sysroots' provenance.
- `vx bench --peers`, beside `--zircon`, with one shared mechanism: it
  sets `BootNext` for each round, runs the rows, scrapes the `budget`
  lines over serial and ssh, and writes `bench/out/peers.md`. Its page
  goes in `man/`, in the same change (D86).
- The V6 exit's table goes in `docs/performance.md`, and its gaps go in
  `docs/roadmap.md` as optimization passes.
