# D127 on VectraOS: research notes (2026-10-25)

Where the VectraOS column of the D127 comparison stands, what was found
diagnosing its gaps against FreeBSD and Ubuntu, and what to do next. The
FreeBSD and Ubuntu columns are done (`../2026-10-25-freebsd`,
`../2026-10-25-ubuntu`). VectraOS has one unofficial round; rounds 2-5
wait until the gaps are understood (the owner: "I don't think it's
valuable to continue without diagnosing the 2 orders of magnitude
differences").

## Round 1 (board-cpu image, pinned to CPUs 10 and 11)

| Row | VectraOS r1 | After the PMM fix | Better peer |
|---|---|---|---|
| syscall_null | 283 ns | 330-1,370 ns (unpinned, finding 3) | 123 ns |
| ipc_rtt_same / cross | 1.54 / 1.54 µs | same | 2.22 / 4.29 µs |
| wake_cross p50 | 4.16 µs | 3.75 µs | |
| fault_anon | 3.2 µs | 2.0 µs | 0.80 µs |
| map_unmap 4k | 5.2 µs | 4.8 µs | |
| spawn_exit_static | 3.4 ms | 0.60 ms | 284 µs |
| spawn_exit_linked | 30 ms | 4.5 ms | 462 µs |
| thread_create | 781 µs | 32 µs | 4.57 µs |
| clock_mono | 42 ns | 41 or 73 ns (unpinned) | 40 ns |
| small_read | 279 µs | 153-436 µs, 215-257 with the WIP | 1.94 µs |
| read_4k | 33 µs | 8.4 µs | 0.59 µs |
| tree_walk | 108 µs/entry | 113 µs/entry | 0.99 µs |
| timer p50/p99/p99.9 | 0.88/1.37/2.21 µs | 0.9/1.4/1.8 µs | 11.7 µs (p50) |

`ipc_rtt_cross` equal to `ipc_rtt_same` is suspicious: check that its
partner thread really runs on the other CPU.

## Committed this session (main)

- 2d7e3fa: the PMM gave single pages (`allocateContiguous(1)`, the heap's
  page-sized allocations: every VMO's first page-list node, so every
  thread stack) by scanning up from each arena's base, ~0.5 ms with
  interrupts masked on 32 GiB. Now the free list's head.
- 079ed30: `vx trace print` gives record times in whole nanoseconds.
- 38960fb: posix_spawn/posix_spawnp/waitpid (spawn(2)), C linked with
  FDIO (`croi_tier1_c`), peer-bench built for VectraOS and shipped in the
  board images as an app.
- 7691f96: D131 decided.
- d5698be: D131 step 1, pager VMOs charged to their account and an
  account at its limit trimming its own clean pager pages first
  (`Reclaim.trim`, `commitMakingRoom`), MemorySuite `pagerCharge`.

## Findings

### 1. small_read is fs's CPU, not the disk (corrects an earlier claim)

The earlier diagnosis "Taisce doesn't cache file data" was wrong. Taisce
has a 16 MiB block cache, and with every fs device read and write logged,
a whole small_read run (one 64-byte file, 10,000 open/read/close) made
none. fs is the bottleneck: its CPU per iteration equals the row's time
(fs is busy throughout; peer-bench barely runs). D131 helps the data
rows (read_4k, grep_tree) but not small_read or tree_walk.

Per iteration, fs makes about 15 syscalls: channel_read 5.7 (each ready
channel is read until SHOULD_WAIT, so one extra read a message),
channel_write 3, port_wait 2.7, channel_create, object_bind,
object_get_info and handle_close 1 each. FDIO sends 3 calls per
iteration: walk+open, stat, read (the WIP folds the stat into the open).

Profile of fs before the WIP: dispatcher and channel I/O ~30%; status
text rebuilt on every open and close 6%; generic key comparisons 5%;
ARC ~10%; a 64 KiB zeroed buffer for every encoded message 3-4%; stat
read the inode twice and scanned all of a node's names.

### 2. Kernel time per fs syscall is ~4 µs (peer-bench's: 0.5-1.5 µs)

About 30% of fs's CPU is kernel time, nearly all in masked sections
under channel read and write (samples land on `arch_interrupts_restore`,
so the sampler can't see inside). Ruled out:
- scheduler lock contention (temporary marks: fs's wait p50 0.1 µs,
  12 ms in total over a run);
- page faults (fs takes none during the loop);
- the handle table (fs has 56 handles; `add` scans 58 slots);
- `UserAspace.coverage` (a binary search);
- `croi.debug_syscalls=on` (it only enables the debug calls).

Settled 2026-10-26: mostly the A520s. A trace of three small_read runs
(`syscall sched`, `vx trace print` now shows each record's CPU) put
~61% of fs's records on CPUs 2 and 5 (A520s), ~37% on CPU 1. fs's mean
kernel time a call, A720 against A520: channel_read 1.15 / 6.9 µs,
channel_write 1.95 / 12.8, channel_create 1.1 / 9.2, handle_close 2.3 /
7.9, object_bind 0.67 / 5.1, object_get_info 0.41 / 2.1. On an A720 the
~15 calls of an iteration are ~17 µs of its ~230 µs: fs's own user code
is the gap, and the core it lands on multiplies both. Why: the
scheduler's fair placement (`Scheduler.place`: last CPU if idle, else
the first idle one, else the least loaded) and `steal` ignore capacity
(only deadline admission reads `CoreCapacity`); Zircon's placement
weighs each CPU's performance scale. A policy change, for the owner.

### 3. Not the A720s' speed: unpinned rows (settled 2026-10-26)

The "A720s at about 56% speed" were rows run on A520s. `peer-bench -c`
from a cpu session can't pin (affinity needs the system resource, which
only the launcher's app gets) and went on after a line on stderr, so
every "per-CPU" pass ran wherever the scheduler put it. With `cpu_mhz`
(a chain of dependent adds, added for this), unpinned runs fall in two
groups: 1800 MHz with clock_mono 73 ns and syscall_null 1,660-1,800 ns
(the A520s: `_CPC` nominal 0x708 = 1800 MHz for CPUs 2-5), and
2172-2466 MHz with 40-44 ns and 282-321 ns (the A720 domains' highest
levels: 2200, 2300, 2500). Under FreeBSD, at each domain's highest, CPUs
6-11 hold 2283/2186/2482 MHz for minutes; only the 2.6 GHz pair (0, 1)
sags, to 2.0-2.4 GHz. The `_CPC` desired register is plain
SystemMemory (no enable, doorbell or min/max), the same one FreeBSD
writes. peer-bench now exits if it can't pin (755d33b). Round 1 ran as
the launcher's app, pinned, so it stands; this table's "After the PMM
fix" column was taken unpinned and is not comparable.

Left open, a real finding: the scheduler doesn't prefer the big cores for
a busy thread, so a saturated fs can sit on an A520 (finding 2's "fs
often lands on a slow CPU").

### 4. Not every create: the first metadata change after boot (2026-10-26)

fs CPU (`/proc/<fs>/status` field 4) around each step, board-cpu image,
twice in one boot: the first `mkdir` cost 38 ms and its commit 158 ms;
afterwards a mkdir ~1 ms, 20 creates 22-26 ms (~1.2 ms each), each
commit ~5 ms, `rm -r` of the 20 ~6-18 ms. Reading the allocator's counts
instead of copying it (`let a = store.volume.allocator`, Engine.swift
420 and 502) made no difference A/B, and was not kept. So the bitmap
copies in the earlier profiles are a one-off after boot (who shares the
arrays then is not found); a host volume of the same size makes 200
creates and 10 commits in 12.6 ms (release). fs's RSS was 161 MB this
boot, against 336 MB before.

## Committed 2026-10-26 (main 755d33b)

- 7aa1b01: the request path (the list the previous notes kept as
  uncommitted work): Taisce byte key compare, `firstName`, one-extent
  reads; fs status as numbers, inodes read once; Node open with stat;
  FDIO open in one round trip; IPC's unzeroed encode buffer. Whole
  suite passed on all three arches; no page changed (node(5)'s batch
  already allowed it, status text is the same).
- 3e2cb49: AllocatorCommitTests no longer runs its smallest volume out
  of space (failed one run in eight).
- 7cfdc3f: IMPORTS.tsv's row for D137's removed Control.swift.
- 2fc3d86, 755d33b: peer-bench's `cpu_mhz` row, and no row runs unpinned.

`tools/peer-bench/vectraos.sh`, the round script, is still uncommitted
(in the session scratchpad, buggy as before): it reads
`/svc/power/status`, which cpu sessions can't see; its `grep -q` under
pipefail never ends the wait loop; its start command didn't start the
app.

## Methods

- Board boots: `vx remote boot arm64 --image board-cpu 192.168.0.19
  userboot.next=bin/launcher croi.halt_on_panic=false` (approved for
  this diagnosis).
- Profile with the image's own symbols (the default kernel path was
  stale once and misnamed everything): `vx remote trace arm64 --out DIR
  192.168.0.19 4 hz 4000`, then `vx trace profile DIR arm64 --kernel
  build/arm64/esp-board-cpu/croi/kernel.elf --bootfs
  build/arm64/esp-board-cpu/croi/bootfs.img [--folded]`.
- Syscall timing: trace categories `syscall sched`, `vx trace print`,
  pair kinds 0x30/0x31 per thread (thread id >> 12 is the task; procs
  maps tasks to names).
- fs CPU per iteration: field 4 of `/proc/<fs pid>/status` is ms (on
  Plan 9 that field is user time; the value matched `ps`'s 0:05) and
  advances at the row's wall rate, so fs is saturated. Its difference
  over a small_read run, divided by 10,100, is the per-iteration
  measure, steadier than the wall time.
- CPU speed: `peer-bench cpu_mhz` pinned (as the app, or anything with
  the system resource); from a cpu session it refuses `-c`.
- Per-CPU busy and switches: `/proc/sysstat` before and after (its
  `idle` didn't add up and needs a look).

## Next, in order

1. Capacity-aware placement for fair threads (findings 2 and 3): the
   owner's decision first.
2. fs's user CPU a small_read iteration (~200 µs on an A720): profile
   again with fs on an A720; the dispatcher's extra read a message.
3. The one-off ~200 ms first metadata change after boot (finding 4):
   profile it.
4. Then D131 steps 2-5, and rounds 2-5 of D127.
