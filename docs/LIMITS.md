# Limits: how big a table is, and what happens when it is full

Vectra raised a fixed table's size more than twenty times. `MAX_PROCESSES`
went from 12 to 32 to 256. `MAX_FDS` went from 16 to 32 to 64. The draw
server's image pool went from 8 to 64 to 128 to 512. The mount wire's request
pool went from 8 to 16, and in September 2026 the desktop filled sixteen. A
third drawer then froze Workbench, because the seventeenth request parked for
ever.

Each raise fixed the symptom it met. None of them asked whether the table
should have a size at all. This document asks that once, for every table, so
that a limit is a decision and not a constant waiting for its next raise.

It has four parts. Section 1 is what other systems do. Section 2 is the policy
Vectra takes from them. Section 3 is every limit in the tree today, ranked by
the harm a full table does. Section 4 is the order in which to fix them.

---

## 1. What other systems do

**Plan 9 grows what a client holds, and fails a request it cannot meet.**
9front's mount driver has no request pool. A request record comes off a free
list, and the kernel allocates a new one when the list is empty. Its tag comes
from one bitmap over the whole 16-bit tag space. A held read costs one list
node and one tag, and no slot.

Channels, mounts, pipes, `/srv` entries, fd tables and draw clients all grow
the same way. An fd table grows by 20 and stops at 5000, a guard that the
source calls a sanity bound. When a user's request cannot be met, `exhausted()`
returns an error at once. Only kernel work that must finish waits, in
`resrcwait`, which retries and shows its reason in `ps`.

`conf.nproc` is sized from memory at boot, at 100 plus 5 per megabyte. The
note queue and the segment table are small arrays inside a process. They stay
constants, and a full one is an error or a dropped note.

**Linux grows its tables, limits a process by an rlimit, and sizes the
machine-wide cap from memory.** The 9P client takes its tags from an IDR over
the tag space, and a failed allocation is `ENOMEM`. FUSE caps only background
requests, at 12 by default, because a synchronous request already holds a
blocked thread.

The NFS client's slot table grows from 2 to 65536 and parks
only new senders on a backlog. An fd table starts at 64 and doubles. The soft
limit is 1024 and the hard limit is 4096. The machine-wide `file-max` is about
10 per cent of memory. `threads-max` fills at most an eighth of memory.

**Fuchsia bounds a message and not a queue.** A channel message holds at most
64 KiB and 64 handles. A channel write never blocks. At 3500 pending messages
the kernel raises a policy exception on the writer, to catch a leak and not to
ration a well-behaved client. A socket is the bounded stream, and a full one
answers `SHOULD_WAIT`, which is backpressure the writer can see.

**seL4 has no kernel heap.** A process makes each kernel object out of memory
it was given, so exhaustion is that process's own and nobody else's.

**XNU and NT size from memory and let replies through.** A Mach port queue
holds 5 messages by default and 1024 at most. A reply to a send-once right
goes past that limit, so a full queue never blocks the answer that would drain
it.

`maxproc` and `maxfiles` scale with memory. An NT handle table grows in
page-sized blocks up to 16 million handles, which Russinovich calls a leak
detector and not a capacity. An I/O request packet has no count limit. Only
pool exhaustion stops one, and it fails the allocation.

**The rules under all of them.** "Zero, one, or infinity": a count the code
fixes is a count the code will outgrow. A bounded queue exists to push back on
a producer that can make unbounded asynchronous work. A client that waits for
its own answer is already bounded by the threads that exist. A cap on waiters
limits nothing, and only makes a wedge.

---

## 2. The policy

**Rule 1. A table that a waiting client holds grows on demand.** A held read,
an open fid, a parked rendezvous, an fd, a conversation, a window: each lives
as long as its client wants. The table grows in chunks, and a chunk never
moves, so a parked client's pointer stays good. The only bound is the
protocol's number space or memory.

**Rule 2. A full table fails the request, and never parks it for ever.** The
caller gets an error it can report: `ENOMEM`, `ENFILE`, `EMFILE`, `EAGAIN`,
`ENOSPC`. A park is correct only where a slot comes back without the parked
client's help. A park must also end on a note, so a person can stop it.

**Rule 3. Backpressure goes only where a producer can make work without
waiting.** Readahead, write-behind, a send queue, a fire-and-forget message:
these may block the producer when a window fills. The window then counts work
in flight and never a held request. A held read waits for an event outside
the server, a key or a packet. It takes no place in any window that gates
other requests.

**Rule 4. A ceiling is a leak detector, not a capacity.** Where a table keeps
a ceiling, it is one or two orders of magnitude above normal use. Reaching it
is a bug report: the kernel logs the first time, and the request fails. A
ceiling a normal desktop can reach is a capacity, and Rule 1 replaces it.

**Rule 5. A machine-wide pool is sized from memory at boot.** Processes,
address spaces, segments and pages that the kernel keeps for every process
scale with the memory Limine reports, as Plan 9's `conf.nproc` does. A
compile-time constant for one of them fits one machine and no other.

**Rule 6. Teardown never waits behind the limit it tears down.** A flush, a
clunk, a reply and an end of file each have a reserve of their own. Failing
that, they take from a pool that a new request cannot fill. Mach lets a reply past a full
queue. The mount wire gives each request its own flush slot.

**Rule 7. A limit is derived, and never copied.** Where one table's size
depends on another's, the constant names the other. A check reads the
program's constant, or reads the table's size from a file. A copy in a comment
or in a self-test drifts, and the drift became a flake once already.

**Rule 8. A lifetime bug is fixed before a size is raised.** A table that
fills because a slot is not freed on the last close will fill at any size.
`MAX_TCP` stopped filling when a conversation's life followed its descriptors,
and not when it went from 8 to 16.

**Rule 9. Every pool says how full it is.** Each pool counts its current
size, its peak, its limit and its refusals, and serves them as a line in a
file. A limit nobody can see gets raised by a guess.

**What stays a constant.** The protocol's own numbers: the 16-bit tag, the
msize, the walk's 16 names. Small arrays inside one process record, where a
full one is an honest error: the note queue, the segment table, the error
stack. A cache, where a full one evicts and costs only speed. A configuration
table, where a full one refuses a line and says so.

---

## 3. Every limit, ranked by what a full one does

The sweep behind this section read about 700 constants in `kernel/`, `sys/`,
`servers/`, `apps/` and `cmd/`, and the code that allocates from each. It was
made in September 2026. A line here names the file, the value, and what a
full table does now.

### 3.1 A full table wedges, spins, or reaches the wrong thing

These break Rule 2, and they come first.

| Limit | Where | What a full one does |
|---|---|---|
| Mount wire requests, 16 | `kernel/mnt/wire.odin` | Parked for ever. **Fixed, September 2026:** the pool grows by chunks of 16 up to the tag space. |
| In-kernel `Conn` requests, 16, and its workers | `kernel/mnt/mnt.odin`, `kernel/devfs`, `kernel/tree` | Parks with no note. One pool serves all of `#c` and one all of `#t`, and every held cons, mouse or interrupt read holds a slot and a worker. |
| Rendezvous table, `REND_MAX` 64 | `kernel/user/user.odin` | A full table answered as a note does, and `libthread`'s `proc_meet` retried at once, so it spun. **Fixed, September 2026:** there is no table. A sleeper's own process record is its entry, found through a hash, as Plan 9's `rendhash` is. |
| `exportfs` readers, 4 | `cmd/exportfs/main.odin` | Four parked reads stall every read behind them. A full queue runs the read on the serve loop, which can wedge the export. It is on the `cpu` path. |
| Stream wires, `MAX_CHAN_WIRES` 8 | `kernel/pipe/chanwire.odin` | A nil wire makes the mount fall back to `netfs`'s own server, so the mount reaches the wrong tree without an error. |
| TCP accept backlog, 4 | `servers/netfs/tcp.odin` | The SYN\|ACK goes out and the connection is not queued. The peer thinks it is connected, and the slot is never reclaimed. |
| UDP and ICMP conversations, 8 | `servers/netfs/udp.odin` | Freed only by `hangup`, not by the last close. A killed `dns` or `ping` leaks its slot until reboot. |
| Model and ghost sessions, 8 and 4 | `servers/modelfs`, `servers/ghost` | Freed only by `hangup`. A client that crashes leaks its session. |
| Ghost sandbox strip, `MAX_STRIP` 96 | `servers/ghost/sandbox.odin` | Mounts past 96 were not stripped, and `RFNOMNT` then locked them in. **That failed open. Fixed, September 2026:** the sandbox is refused, as a table cut short already was. The strip still ignores an `unmount` that fails. |
| Notes, depth 1 | `kernel/user/user.odin` | A second note overwrites one not yet delivered. Plan 9 queues five. |

### 3.2 A full table fails with an error, and a normal desktop can reach it

These keep Rule 2 and break Rule 1 or Rule 4.

| Limit | Where | Note |
|---|---|---|
| Fids per ring 3 server, `MAX_FIDS` 64 | `sys/libuser/fid.odin` | Shared by every client of one server. A toolkit window takes about five of `intuition`'s, so the draw server refuses at about twelve windows, well below its 32 slots. |
| Windows, `MAX_WINDOWS` 32 | `servers/intuition/main.odin` | Tied to `libdraw`'s names and to `MAX_PROC_SEGS`, with a margin of 2 to 6 segments. |
| Segments per process, 40 | `kernel/user/segment.odin` | `intuition` uses about 36 at a full screen of windows. |
| Pipe fids, 32, and pipes, 32 | `kernel/pipe/pipe.odin` | Two fids a pipe, so 16 live pipes, whatever `MAX_PIPES` says. |
| TCP conversations, 16, and web conversations, 16 | `servers/netfs`, `servers/webfs` | Each reclaims first, then refuses. |
| Fds per process, 64 | `kernel/user/user.odin` | A toolkit window holds five. |
| `/proc`, `/srv`, `/fd`, `#e` fids, 64 each | `kernel/procfs`, `kernel/srv`, `kernel/fddev`, `kernel/env` | `ps` over a fleet walks many. |
| Shared buffers, `SHM_MAX` 64 | `kernel/user/shm.odin` | One per window store, machine-wide. |
| Theme followers, 32 | `sys/libmui/theme.odin` | The 33rd window of a program does not hear a theme change. |
| Icon cache, 256 | `sys/libmui/icon.odin` | Never evicts, so icons stop drawing once it is full. |

### 3.3 Sized for one machine, where memory should size them

These break Rule 5: processes 256, address spaces 260, segments 1024, env
groups 260, fd tables, and `DEV_MAX_FIDS` 1024. Each fails with an honest
error today, so each waits for the day a machine outgrows it.

### 3.4 Silent drops that lose data a person needs

These break Rule 9, because nobody sees them. `matrixfs` drops room members
past 16 and keys past its tables, so messages cannot be decrypted, and it logs
nothing. The key ring of a window drops a newline when full, which breaks a
whole-line read. `plumber` does not declare a port past 32. `cs` and `dns`
answer "not found" for a full translation table. `factotum` answers a full
key table with the wrong reply text.

### 3.5 Constants that stay

The protocol's numbers, the per-process arrays with an honest error, the
caches that evict, and the configuration tables that refuse a line. Section 2
says why. `LATER_MAX`, `RETX_SLOTS` and `SCHED_STACK` were lowered on purpose,
for a kernel stack or a network's manners, and they stay low.

### 3.6 Stale words to fix on the way

`sys/libuser/fid.odin` says sixteen fids, and it has 64. `sys/libapp` says its
mouse queue drops the oldest event, and it drops the newest. The self-test's
`DRAW_SLOTS` is a copy of `MAX_WINDOWS`, which Rule 7 forbids.

---

## 4. The order

**First, the wedges and the security bug, section 3.1.** Each is small and
each is a Rule 2 or Rule 8 bug, not a size.

1. The mount wire's pool grows. *Done, September 2026.*
2. The ghost sandbox strips every mount, or refuses to start the turn.
   *The overflow is refused, September 2026.* An `unmount` that fails is
   still ignored.
3. `REND_MAX`: the table goes, and the sleepers are the table. *Done,
   September 2026.* `tests/abi` puts 72 children to sleep at once.
4. The in-kernel `Conn`: a held read gives its worker back, as a held request
   does in `lib9p`, and the pool grows as the wire's does.
5. `exportfs` reads that park stop holding a reader, the same change.
6. Stream wires grow, and a failed build is an error and never another
   server.
7. `netfs` frees a UDP conversation on its last close, and refuses a
   connection it cannot queue with a reset.
8. `modelfs` and `ghost` free a session on its last close.
9. Notes queue, as Plan 9's five do.

**Second, the ceilings a desktop reaches, section 3.2.** A shared growable
table in `sys/libuser`, chunked and never moved, replaces each fixed table of
records. Fids per server go first, because they are the real window ceiling.

**Third, memory sizes the machine-wide pools, section 3.3.** One boot-time
`conf`, from the memory map, as Plan 9 does.

**Fourth, every pool says how full it is.** A `/dev/limits` file, one line a
pool: its name, current, peak, limit and refusals. The self-tests read their
numbers from it, and a person reads it before raising anything.

## See also

- `docs/TRANSPORT.md`, `docs/VECTRA9.md`: the wire and the tag.
- `kernel/mnt/wire.odin`: the pool that grows, the first of these.
- 9front `sys/src/9/port/devmnt.c`: `mntralloc`, `alloctag`, `mntflushalloc`.
