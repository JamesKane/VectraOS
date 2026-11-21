# D177. Use-cases carry the claim: the comparison with Linux and FreeBSD has three layers (control rows held within a few percent, D127's primitives kept to explain, ported applications judged in a band of a few percent), and every gap is a ledger row, attributed by profiling both sides, closed by a pass and guarded afterwards as a budget (2026-11-21, proposed; amends D127; asks an amendment of D4 for bench volumes; the calls under "Open" are the owner's)

The stated goal is that VectraOS comes within a few percent of Linux
and FreeBSD on the work people actually do. D127 built the comparison:
one board, bare metal, rounds, two columns, and rows fixed before the
first run. Its rows have the shape of lmbench, though, and five things
keep it from testing the goal:

1. **No row is a use-case.** The rows are kernel and file primitives.
   The only application-shaped row that runs is `grep_tree`, and bash's
   rows and `make -j` are pending. A primitive's ratio doesn't predict
   an application's: a 10× slower `small_read` costs a database
   whatever share of its time it spends there, and nothing more.
2. **The band is not "a few percent".** D127's parity runs up to
   r ≤ 1.25.
3. **Nothing checks the bench itself.** No row is bound only by the CPU
   or memory, where VectraOS has no excuse to differ. Clocks, cache
   attributes, page sizes, interrupt load and core placement can each
   skew every other row, and the notes on round 1 found two of them by
   accident (unpinned rows landing on the A520s, and the sampler blind
   to fs).
4. **Nothing measures scaling.** Every row uses one core or two.
5. **Remediation is one sentence.** "Every gap becomes a named
   optimization pass" is right, but the round-1 diagnosis
   (`bench/peers/2026-10-25-vectraos/NOTES.md`) shows what a pass
   actually takes: attributing the gap, trying fixes, and rejecting
   some (D139). None of that has a fixed form, and nothing keeps a
   closed gap from opening again.

Where VectraOS stands (one round, then the passes recorded in the
notes): `clock_mono` and `timer_wake_idle` are at parity or ahead;
`ipc_rtt` wins; `syscall_null`, `fault_anon`, the spawn rows and
`thread_create` are 2–10× behind; `small_read` about 27× and `read_4k`
about 15× (a mapped file's read is 86–88 ns under KVM through D145, not
yet run again on the board); `tree_walk` about 7×. Rounds 2–5 wait on
those gaps, as the owner asked.

## The decision

### 1. Three layers, each judged in its own band

r = VectraOS ÷ the better of the two peers, turned so lower is better,
as in D127.

| Layer | What it answers | Band |
|---|---|---|
| **Control** | Is the bench fair? | 0.97 ≤ r ≤ 1.03, both ways |
| **Primitives** (D127's rows) | Where does a use-case's gap come from? | D127's: win ≤ 0.9, parity ≤ 1.25, gap > 1.25 |
| **Use-cases** | Would someone who switches lose anything? | win r ≤ 0.95; parity 0.95 < r ≤ 1.05; gap r > 1.05 |

- **A control row outside its band is a defect in the bench** (a
  clock, a page size, a cache attribute, placement or interrupt load)
  until shown otherwise. That holds in both directions: VectraOS faster
  on a CPU-bound loop means something is unequal too. While a control
  row on a core tier is out of band, the round judges none of that
  tier's use-case rows.
- **The claim is the use-case layer.** "Within a few percent" means
  every use-case row at parity or better against the better peer, in
  the stock and tuned columns alike.
- **Primitives keep D127's bands and rule.** Their passes are ordered
  by the use-case gaps they explain (§5).
- **A row too noisy for its band isn't judged.** If a row's spread
  across the five rounds, (max − min) ÷ median, exceeds half its band's
  width on any OS (3% for a use-case row, 3% for a control row), the
  row is reported, not judged, until its harness is fixed. A 5% claim
  can't stand on a 10% spread.

### 2. The control rows

Bound by the CPU or memory alone, with the same instructions on all
three OSes:

| Row | Workload | Shows |
|---|---|---|
| `ctl_triad`, `ctl_triad_all` | STREAM's triad on one core, then on every core of the tier | DRAM bandwidth, cache attributes, page size |
| `ctl_chase` | A dependent pointer chase over 4 KiB to 256 MiB, ns per load at each size | TLB reach, page size (huge pages or not), the cache hierarchy |
| `ctl_coremark` | CoreMark, one thread a core | The core's clock and its steady state |
| `ctl_zstd_mem` | zstd's in-memory benchmark (`-b3`) on a fixed corpus | Integer and branch code, malloc on a hot path |

`ctl_triad` and `ctl_chase` are first-party, added to `rows.c`, so the
control layer runs before D4's answer (§4). CoreMark and zstd are
ports.

### 3. The use-case rows, fixed now

Each row prints `budget name=peer.<row>` lines as before. Its
parameters (sizes, options, inputs pinned by hash) are fixed in the
row's script before its first run, and a change to them after results
exist is a dated decision, as D127 says.

**Now** (needs only what the libc has: pthreads, mmap, pread, fsync,
posix_spawn):

| Row | Workload | Stresses |
|---|---|---|
| `uc_sqlite` | SQLite's `speedtest1`, WAL journal, on the bench drive; total time, each test's reported | pread and pwrite, fsync, locking, the page cache |
| `uc_sqlite_mem` | The same with `--memdb` | Its CPU share alone, so `uc_sqlite`'s file share can be separated |
| `uc_llama_pp`, `uc_llama_tg` | llama.cpp's `llama-bench`: prompt processing and token generation, a small model pinned by hash, mapped from the volume; on the A720 pair and on all eight A720s | Memory bandwidth, a large mapping, threads across big cores |
| `uc_lua` | Lua 5.4 running a fixed set of scripts (binary-trees, fannkuch, n-body, spectral-norm, a string-building one) | The allocator, the GC, interpreter dispatch |
| `uc_zstd_tree` | zstd compressing `grep_tree`'s 200 MB tree file by file to the volume, then decompressing it | Files and CPU mixed: open, read, write, close at scale |
| `uc_postmark` | PostMark, a fixed configuration on the bench drive | Small-file create, append, read and delete as a mail server does |
| `sc_<test>` | will-it-scale's threads variants (`page_fault1`, `mmap1`, `open1`, `futex1`, `pipe1`, `sched_yield`) at 1, 2, 4 and 8 threads on the A720s | Kernel and fs scaling; judged at 8, the curve reported |
| `uc_hackbench` | hackbench, threads over pipes | The scheduler under many wakers |
| `uc_schbench` | schbench's wakeup latency p99, the A720s loaded | Placement and preemption latency |
| `uc_vkpeak` | vkpeak's fp32 and fp16 rates on the Mali-G720, against Mesa's panthor on Ubuntu (FreeBSD's column empty) | The GPU's compute path through the Vulkan layer |

**Pending**, named now so they can't be chosen after the results are
in, each joining the table in the change that makes it run:

- **Network, host-driven.** There are no BSD sockets and no `poll` on
  VectraOS, by design: a connection is Plan 9's `dial`, `announce`,
  `listen` and `accept` over `/net` (D79, D178). So a server reaches the
  network through a VectraOS backend of its own over those calls, never
  through a sockets layer. These rows need the calls callable from C in
  tier 1 (Sys has them in Swift).
  - `uc_http`: wrk on the dev host against a small static file server,
    first-party C, the same program on all three. Only its network
    backend differs: sockets and epoll or kqueue on the peers, `dial`'s
    calls on VectraOS.
  - `uc_redis`: redis-server on the board, memtier on the host. Redis's
    event loop (`ae`) already has a backend for each OS (epoll, kqueue,
    evport, select), and VectraOS gets one beside them. That is a
    platform patch under §4, not a change to the work.

  The host's ends are third-party under D4's host rule. Raw TCP is
  already D127's `tcp_*` and `udp_64_pps`, so iperf3 adds nothing.
- **Graphics** (needs WSI, D174 §4 step 6): `uc_vkmark`, a fixed set of
  scenes' frame times in a Radharc window against GNOME on Ubuntu, with
  a VectraOS window backend added to vkmark. The best-mechanism column
  is Loinnir's zero-copy present (D174 §3).
- **D127's pending rows** are unchanged: bash's three, the 9P mounts
  (the mounts now partly run as `remote_*`), audio, a desktop app's
  cold start, `make -j`.

The NPU and the video codec join as best-mechanism columns of
`uc_llama_*` and a decode row when their drivers land (V6f).

### 4. Ported programs live on the bench volume, never in an image

A use-case is only a claim if it is the program people run. A
first-party rewrite of SQLite measures the rewrite. So the use-case
rows are ports, and D4 needs an amendment, which this decision asks
for:

- **Each port is pinned like the toolchain's sources:** its version
  and hash, a patch series and a build script in
  `tools/peer-bench/ports/<name>/`, sources in `.cache/peer-ports/`,
  built by the tier 1 toolchain (D47) and, for the peers, by the same
  bundled clang against their sysroots, with the same flags and
  `-march`. Its licence is recorded beside its pin.
- **Patches serve the build only:** the platform, the build system,
  a missing call written over what the libc has. A patch that changes
  the work measured (fewer iterations, a different algorithm, a
  shorter path around a POSIX call VectraOS lacks) changes the row,
  which takes a dated decision. A port that needs a POSIX call the
  libc simply hasn't written yet waits for the libc (D80). What the
  libc leaves out on purpose (`fork`, sockets, `poll`, signals beyond
  notes) is reached through the port's own platform backend over the
  native interfaces, as Redis's event loop and nginx's event modules
  already have a backend for each OS. The libc never gains a POSIX
  shape for a benchmark's sake.
- **Ports never go in bootfs or any image.** The harness copies them
  onto the bench volume at a round's start, so the image measured is
  still the release image D127 asks for. Nothing first-party links a
  port, and no image depends on one.
- **The same rule as the CTS:** D174 §4 step 7 builds VK-GL-CTS as a
  tier 1 port and runs it as a report. That port is the other user of
  this amendment, so there is one rule for third-party test programs on
  a device, not two.
- **Rejected:** first-party rewrites of the use-cases (they measure our
  rewrite); porting lmbench or UnixBench (fork and signals throughout,
  and D127's rows already have their shape).

If the owner declines the amendment, the control layer and the
primitives still run, and the use-case layer shrinks to what we write
ourselves. `uc_zstd_tree` and `uc_hackbench` have first-party
equivalents; SQLite, llama.cpp and Lua don't.

### 5. Remediation: a ledger, attribution, passes, guards

- **The ledger** is `bench/gaps.tsv`, one line a gap: the row, its
  layer, r and the round it was measured in, the cause as attributed,
  the pass, and a state (`open`, `attributed`, `in-pass`, `closed`,
  `accepted`). The roadmap's "where things stand" names the passes and
  points at the ledger. It doesn't list the gaps again.
- **No pass starts before its gap is attributed.** Attribution splits
  the row's time the same way on both sides, using the same PMU events:
  - wall time against CPU time per process (VectraOS's trace and
    sampler, `vx trace`; `perf stat`, `perf sched` and `perf record`
    on Linux; `pmcstat` and DTrace on FreeBSD);
  - instructions against cycles: more instructions means a longer
    path, while more cycles for the same instructions means placement,
    caches or the clock;
  - user against kernel, and on VectraOS the IPC hops a request takes
    and the time in each server.

  The ledger keeps the attribution as one line, with a pointer to the
  notes. The round-1 notes show the form.
- **A use-case gap is broken down into primitives.** The primitives it
  attributes to get their passes first, ordered by the use-case gaps
  they explain. A primitive gap that no use-case row depends on stays
  open, but goes behind them.
- **A pass names its target r** and is judged on the board at its end,
  in a round of its own rows interleaved with the peers'. While it
  works, it iterates on the KVM proxy (§6).
- **A closed gap becomes a budget.** The row's VectraOS value at its
  close is recorded as `peer.<row>` in the board's history, with a
  rule in `Rules.swift`. From then on the board's bench run judges it
  against history like any budget (`docs/performance.md` §1, rule 3),
  so a later change can't quietly reopen the gap.
- **A gap is accepted only in the open:** the owner's call, dated,
  with its r and its reason (an isolation cost we choose to pay, for
  instance), and kept in the ledger as `accepted`. As in D127, a gap
  is never closed by changing the workload or the band.

### 6. Harness, cost and the proxy

- **D127's harness is unchanged:** rounds, BootNext rotation, the same
  core tier by MPIDR, the same starting temperature, the bench drive,
  stock and tuned. The control rows run first in every boot, then the
  primitives, then the use-cases.
- **Cost, estimated before anything runs:** the control rows about
  2 min a boot, the primitives about 2, the use-cases about 10 (each
  row held to 60 s or less, llama.cpp's two thread counts the largest).
  That is about 15 min a boot. A table is 15 boots, about 4 hours with
  cooling, run unattended and on demand, never in `vx ci` or `vx
  bench`'s default set (D127). A pass's own rows, interleaved, fit in
  5 minutes.
- **The KVM proxy:** the use-case and control rows also run on amd64
  under QEMU/KVM, VectraOS against an Ubuntu guest with the same
  `-cpu host`, vCPUs and memory, one VM at a time and interleaved, as
  the Fuchsia column already does. It shows trends for a pass to
  iterate on, and never makes a claim (D127).

## What changes in D127

- D127's rows become the primitives layer, with its bands and its
  "every gap is a pass" rule. The control and use-case layers are added
  beside them, and the use-case band is the comparison's claim.
- The parity band of a few percent applies to use-case rows. The 1.25
  band stays on the primitives.
- A round's use-case rows on a tier are judged only while that tier's
  control rows hold their band.
- "Every gap becomes a named optimization pass" gains §5's form: the
  ledger, attribution first, a target r, and the budget at the close.
- `tools/peer-bench/` gains `ports/` and the control rows in `rows.c`.
  `bench/gaps.tsv` is new.

## Open (the owner's)

1. **D4:** may ported test programs run from a bench volume (§4), as
   the CTS would? Without that, the use-case layer is first-party only.
2. **The band:** ±5% as "a few percent", or another number. Or keep
   D127's 1.25 and restate the goal to match.
3. **`dial`, `announce`, `listen` and `accept` callable from C** (D178: no BSD sockets): where
   do they live for tier 1 (a small native library beside the libc, as
   Plan 9's libc carries them), and do they come forward? They gate the
   network rows.
4. **The model for `uc_llama_*`:** which small model, and its size
   (about 1B parameters at 4 bits keeps a row under 60 s).
5. **The order against the primitive passes now under way:** this
   proposes the control rows first (first-party, a day's work), then
   `uc_sqlite` and `uc_lua` (the smallest ports). The primitive passes
   go on meanwhile, and rounds 2–5 wait on them as before.

## In the tree, once decided

- `tools/peer-bench/rows.c`: `ctl_triad`, `ctl_chase`.
- `tools/peer-bench/ports/<name>/`: a pin, a patch series and a build
  script each; the harness scripts copy the builds onto the bench
  volume.
- `bench/gaps.tsv`, seeded from round 1's gaps and the notes'
  attributions.
- `docs/performance.md` gains the layers and, as gaps close, their
  `peer.<row>` budgets. peer-bench's man page changes in the same
  change as the tool (D86).
