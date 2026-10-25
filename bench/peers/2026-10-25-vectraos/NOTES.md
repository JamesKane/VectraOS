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
| syscall_null | 283 ns | 330-1,370 ns (CPU speed, below) | 123 ns |
| ipc_rtt_same / cross | 1.54 / 1.54 µs | same | 2.22 / 4.29 µs |
| wake_cross p50 | 4.16 µs | 3.75 µs | |
| fault_anon | 3.2 µs | 2.0 µs | 0.80 µs |
| map_unmap 4k | 5.2 µs | 4.8 µs | |
| spawn_exit_static | 3.4 ms | 0.60 ms | 284 µs |
| spawn_exit_linked | 30 ms | 4.5 ms | 462 µs |
| thread_create | 781 µs | 32 µs | 4.57 µs |
| clock_mono | 42 ns | 41 or 73 ns (CPU speed) | 40 ns |
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

Not yet checked: how much is the CPU speed (finding 3: fs often lands
on a slow CPU), and what inside `Channels.write` (`finishCall`,
`updateSignals`) and `readMessage` (`take`, `deliver`) takes the time.
Next: temporary trace marks around those steps, on a CPU known fast.

### 3. The A720s run at about 56% speed, varying over time

`peer-bench -c N,0 clock_mono` (pure user code) reads 41 ns on some
A720s and 72-73 ns on others; `syscall_null` 330 ns against 1,050-1,935.
Which CPUs are slow changes from minute to minute (one pass had 7 of 8
slow). power(8)'s desired-performance registers still hold each domain's
highest level (read back: 8192, 7246, 6931, 7876 by pair). Neither
rewriting them every period nor toggling them (64 lower, then back)
changed anything. Every row's number depends on this, so it must be
settled before more rounds.

Ideas, untested: firmware's own power or thermal limits (SCMI
PERFORMANCE_LIMITS, limit-change notifications Linux would get); an
interaction with the idle states user space installs; read the AMU's
delivered/reference counters (`_CPC`'s FFixedHW) to see the real
frequency per CPU; compare Ubuntu's `scaling_cur_freq` under the same
load. The board notes' "power's chain 1.28x faster at the highest" is
not reliable while this varies.

### 4. A Taisce create costs ~110 ms of fs CPU, a commit ~80 ms

Profiles show `Allocator.take`, `free` and `groupCommitted` copying
whole bitmap arrays (`_consumeAndCreateNew` with page faults under it:
fresh 30 MB buffers). The allocator keeps six per-block bitmaps (`words`,
`held`, `deferred`, `fresh`, `logged`, `retired`), ~30 MB each on the
990 PRO's 931 GiB, most of fs's 336 MB RSS (the owner deferred the
memory itself earlier). A copy means a second reference to an array is
alive when it is mutated. FileSystem, Engine, Store and Volume are
~Copyable, but Allocator is a copyable struct. Candidates:
`Engine.commitGroup`'s `let a = store.volume.allocator`
(Engine.swift:420) is alive across `groupCommitted()`; and line 502
(check). For take/free in a create, the holder is not found yet. Fix
the reference, or read scalars instead of copying the struct. This
makes every metadata write slow, so it matters beyond D127 (tree_walk's
setup, spawn's files, any create).

## Uncommitted work in `.claude/worktrees/notices` (the request path)

Built for arm64. The host tests TaisceTests (65), FsTests (12),
NodeTests (46) and FDIOTests (6) pass. `vx test --changed` was running
when the session stopped; its result wasn't seen, so rerun it. Measured
on the board: small_read 215-257 µs on most boots, against 311-436 µs
before; fs's CPU per iteration down by about a third.

- `fs/taisce/lib/Bytes.swift`, `Node.swift`, `BTree.swift`,
  `Engine.swift`: keys compared byte by byte (`precedes`) instead of
  `lexicographicallyPrecedes`.
- `fs/taisce/lib/FileReading.swift`: `firstName` (one entry, not all
  names; `path` uses it); `readBlocks` returns one covering extent's
  blocks directly (no zero-filled buffer and copy).
- `services/fs/server/Service.swift`: status as numbers (`Shown`), text
  made when read; `qid(ino, inode)`; walk reads each inode once and
  carries it; `channel(..., isDirectory:)` skips a stat when the walk
  knew.
- `services/fs/server/Sessions.swift`: stat reads the inode once, qid
  from it, first name only; read drops its extra stat (Taisce says
  isDirectory); the batch passes the walked kind to `channel`.
- `system/node/lib/Client.swift`, `Namespace.swift`: `open(path,
  stat:)` returning `Opened` (client and stat from one batch).
- `system/fdio/lib/FDIO.swift`: open uses it, one round trip where two
  were. The 6.4 tier 1 compiler's move-only checker crashed on a
  noncopyable `let` set in a `do` and read after it, so the value stays
  inside the `do`.
- `system/ipc/runtime/Codec.swift`: messages encoded into an unzeroed
  64 KiB buffer (the encoder zeroes what it reserves).

Still to do before committing: pages (node(5) for the open-with-stat if
it counts as behaviour, fs(4) if status changes), `vx test --changed`,
and a check that `Shown` keeps status identical (it should: same
fields, same order).

Also uncommitted: `tools/peer-bench/vectraos.sh`, the round script. It
has bugs: it reads `/svc/power/status`, which cpu sessions can't see;
its `grep -q` under pipefail never ends the wait loop; its start
command didn't start the app.

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
- CPU speed: `peer-bench -c N,0 -d /data/peer clock_mono` for each A720
  (CPUs 0, 1, 6-11; 2-5 are the A520s); the row runs on the first CPU
  given.
- Per-CPU busy and switches: `/proc/sysstat` before and after (its
  `idle` didn't add up and needs a look).

## Next, in order

1. Rerun `vx test --changed`, write any pages, commit the request-path
   work.
2. Settle the CPU speed (finding 3): without it no row is repeatable.
3. Find the allocator's second reference (finding 4).
4. Time the inside of `Channels.write` and `readMessage` on a fast CPU
   (finding 2); consider the dispatcher's extra read a message.
5. Then D131 steps 2-5, and rounds 2-5 of D127.
