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

The owner chose race to completion (D68 amended, ef001fc): fair
threads take the least loaded CPU, the biggest among equals. On the
board fs then ran only on the A720s (each ~12.5% of its records, so it
moves on most wakeups: client and server may cross CPUs on every
request, a later look). Unpinned peer-bench, five runs: small_read 83-85
µs (from 215-257 with the request-path work, 279 in round 1); read_4k
8.7-9.5 µs and tree_walk 121-133 µs/entry unchanged: their limits are
elsewhere.

Then (later on 2026-10-26) the tick sampler turned out to have been
blind to fs. A CPU going idle cancelled its sampling timer, and the
next switch re-armed it for a whole period, so fs's ~84 µs bursts (the
period is 250 µs at 4 kHz) were hardly sampled: 51 samples in 4 s of a
saturated fs. 806ff7a fixes it; earlier profiles of fs under-count it.

Profiled again, two fixes:
- Every syscall exit took the global scheduler lock to read the
  thread's own `suspendRetry` (4304db4: ~84 -> 81.5 µs).
- Taisce copied a cached 4 KiB block a byte at a time for a 64-byte
  read (3e7ed35: -> ~80 µs).

Their samples (13% and 14%) overstated them, because fs ran with cold
caches after every wakeup. A sched trace showed why:
- The client woke fs onto fs's idle last CPU.
- The client's own CPU, going idle, stole fs 1.0 µs later: 2,635 of
  2,659 migrations in a second.
- The client, its CPU now taken, went to yet another CPU on each reply.

Linux, FreeBSD and Zircon were compared at the owner's request:
- Linux and ULE place a woken thread as we do, but never steal a CPU's
  only thread (ULE's `steal_thresh` is 2; Linux pulls only from a queue
  with `nr_running > 1`).
- Zircon hands a channel call's request to the caller's CPU
  (`UnblockSynchronous`).

The owner took ULE's rule (c3f743d); Zircon's handoff, below. fs
now stays on one CPU: 11 migrations in 2 s, 1.07 of its 1.25 s on CPU
8, while it still blocks and is woken every ~13 µs (89,175 wakes). A
first trace claiming 29 switches had started after a short loop of rows
ended: a row is now ~0.65 s with its start, so loop 40 before tracing.
small_read 50-57 µs, tree_walk 97-115 µs/entry, read_4k ~9.6 µs
unchanged.

The sampler still missed fs after 806ff7a: a sample per ~1.2 ms of
fs's busy time, not 250 µs. A timer fires at its deadline plus slack (an
eighth of the period, 31 µs at 4 kHz), and fs's ~13 µs bursts ended
inside that window, cancelling the due timer each time. A carried
remainder is now armed with no slack.

Zircon's handoff, tried the same day and rejected (D139, 32af4a3
reverted): channel_call's request and reply marked synchronous, the
woken thread put on the waker's CPU. Same session, five runs each:
without it small_read 48.7-53.3 µs and tree_walk 91-104 µs/entry; with
it 69.5-74.5 and 106-113, fs migrating ~24,700 times a second. The
reply preempted fs at once (a fair thread running alone has no slice
timer, and `preemptIfRequested` takes that as its slice ended: any
wakeup onto its CPU switches it out), a CPU going idle stole it, and
the next request pulled it back. Without that preemption, close's
PEER_CLOSED (an ordinary wake) sent fs off instead. With close's wake
marked too, 28,118 of 28,141 wakes of fs were local and small_read was
54-70 µs: no faster than two warm A720s, whose wakes buy overlap of
fs's work after a reply with the client's next step. The immediate
preemption of a lone fair thread by any wakeup is worth a look of its
own.

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

### 5. tree_walk was a stat per entry and a quadratic merge (2026-10-26)

A 4 s profile in one row's timed walk (127 µs/entry that row): the
client and fs took turns, ~1 CPU between them (peer-bench 53% of
samples, fs 45%), ~31,000 entries.
- `Walk` listed each directory by names only, then stat'd every entry
  by its path: open, stat and close, three calls to fs, which walked
  the whole path again each time (`FsService.walk`, 19% of fs).
- `Namespace.list` merged each listing with `entries.contains` per
  entry, even with one member: ~500,000 name comparisons for a
  1000-entry directory, `elementsEqual` 16% of all samples (~19 µs an
  entry).
- Smaller: fs stats every entry of a names-only readdir (~3 µs an
  entry); Taisce's 512-node cache misses on a 100,000-file tree (NVMe
  reads, BLAKE3 and decode per miss; D131 keeps the node caches as
  they are, so not its page cache).

Fixed the first two: the walk takes each entry's status from its
directory's listing (fts(2) as BSD's, which stats in `fts_build`), and
a listing goes in whole, later union members looked up in the sorted
names. Five runs: tree_walk 11.1-13.3 µs/entry (from 91-127); small_read
53.7-56.6 and read_4k 8.8-9.0 µs unchanged.

Why fs stat'd at all: a Taisce directory entry holds the child's node
and kind (as ext4's, UFS's and minfs's `d_type` do), enough for a
names-only listing, but fs's internal list filled every entry's size and
time, a B-tree lookup each, and node(5)'s readdir blanked them after.
`getdents` (Linux, FreeBSD) and fuchsia.io's `ReadDirents` read no
inode; Plan 9 returns a full stat per entry but fossil keeps it in the
directory. Now readdir passes whether it wants size or time, and a
names-only listing reads only the directory (kept listings record which
they are; one with status serves one without). The fs protocol's own
`list` still promises stat fields (Tracker).

Profiled again at 4aa7087 (six rows looped, 4 s traced, 12.4 µs/entry):
fs 1.82 s of CPU, the client 0.44 s, nvme 0.22 s; ~2.5 CPU-seconds in
4 s, so ~40% of the walk has nothing running: fs waiting on NVMe. Of
fs, 57% is `Store.node`'s misses on the 512-node (8 MiB, direct-mapped,
16 KiB nodes) cache, through the listing's stat of each entry, whose
inodes come in name-hash order: the evicted node's release
(`swift_release`, 1,292 samples), the BLAKE3 check of the 16 KiB read
(1,212), `Node.decode` into arrays (~1,070), the device read (270).
Channel writes of the replies are 18%. Linux keeps this metadata in
memory until pressure; here a walk of this tree rereads it from the
disk every time.

The owner chose a node cache sized as a share of the RAM (FreeBSD's
vnodes, ZFS's cache): a 64th, never below 8 MiB, CLOCK-evicted by a byte
budget (`NodeCache`, Store.swift), the RAM from a new topology-page field
(version 4, `KMemStats.physical`, `_SC_PHYS_PAGES`). Five runs:
tree_walk 6.9-7.5 µs/entry (from 10.8-13.3); small_read 52.7-53.2 and
read_4k 9.1 µs unchanged. A profile: `Store.node` 24 samples (was
4,146), no checksums, no NVMe; fs 1.0 s of the 4 s, half of it
`IPCOutbox.flush`, the listing replies' channel writes, mostly kernel
time with interrupts masked. fs's resident memory was 464 MB after the
runs (161-336 MB in earlier boots): the cache fills as `--check` reads
every node at mount, up to its budget (~512 MiB on this 32 GB board).

Those masked writes were the kernel heap: a listing reply of 256
entries is over 2 KiB, and the heap took anything larger as contiguous
PMM pages, which `allocateContiguous` finds by scanning up from each
arena's base through every page in use, under the PMM lock (2,026 of
fs's 4,069 samples, `Syscalls.build` → `arch_interrupts_restore`). The
owner chose Zircon's way: a message over the heap's largest slab class
keeps its bytes in single pages listed in its block (BufferChain).
Five runs: tree_walk 2.8-3.0 µs/entry (from 6.9-7.5); small_read
52.5-56.5 and read_4k 8.6-9.2 µs unchanged (one read_4k row 11.7).

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
- Profile with the symbols of what `vx remote boot` sent:
  `build/arm64/kernel/kernel.elf` and `build/arm64/bootfs-board-cpu.img`.
  The `esp-board-cpu/` copies are not updated by a warm boot, and once
  misnamed every kernel sample. Run `vx remote trace arm64 --out DIR
  --kernel ... --bootfs ... 192.168.0.19 3 hz 4000 pages 2048` while a
  loop of rows runs (start it first: one row is ~1 s), then `vx trace
  profile DIR arm64 --kernel ... --bootfs ... [--folded]`. Samples that
  land on `arch_interrupts_restore` are skid: the kernel had interrupts
  masked, and the leaf's own caller is missing from the stack.
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

1. small_read, now 50-57 µs. Profile with the fixed sampler (a92ef1b),
   fs on one warm CPU: fs is ~56% of a CPU, half of it kernel (3,395 of
   6,737 samples). The heap fell to ~6% and `dataBlocks` vanished: they
   had been cold caches. In the kernel, masked sections: port_wait's
   block and wake ~13% of fs (it sleeps ~45,000 times a second, ~2 a
   request), `Channels.write` 4%, `Channels.read` 5%, `coverage` 2%
   (`check`'s cached range missed). In user code, `swift_release` 9%,
   readOnce 10% inclusive. Zircon's synchronous handoff, which would
   cut the sleeps, was no faster (D139, rejected).
2. tree_walk, now ~2.9 µs/entry (finding 5): profile it again. read_4k
   (~9 µs): profile it.
3. The one-off ~200 ms first metadata change after boot (finding 4):
   profile it.
4. Then D131 steps 2-5, and rounds 2-5 of D127.
