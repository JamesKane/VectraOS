# The trace format, version 2

How processes record what they do, so `vx trace`, `vx bench` and the
debugger can read it ([performance.md](performance.md) §3–§4).
`system/trace` (`Trace`) writes it and `system/trace/reader` reads it. This file
is the contract. Records share croi's kernel trace layout (croi
requirement 18; NeoVectra ADR-0049, studied), so kernel and user records
merge into one timeline.

## Records

Every record is 32 bytes, little-endian:

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 8 | `time` | The raw cycle counter (TSC, `CNTVCT_EL0`, rv64 `time`), not nanoseconds: ticks at `counter_hz` |
| 8 | 2 | `kind` | What the record is (below) |
| 10 | 2 | `cpu` | The CPU, where known; `0xffff` when not |
| 12 | 4 | `tid` | The thread: `(process << 12) \| thread index`, so a reader needs no table |
| 16 | 8 | `a` | Depends on `kind` |
| 24 | 8 | `b` | Depends on `kind` |

Kinds `0x0000`–`0x3fff` are croi's kernel categories (`sched` 1–6, `irq`
16–17, the kernel's MARK `0x70`). Kinds `0x4000`–`0x7fff` are user space's
(croi's `CROI_TK_USER_FIRST` to `CROI_TK_USER_LAST`). `0x8000`–`0xffff`
are reserved.

| Kind | Name | `time` | `a` | `b` |
|---|---|---|---|---|
| `0x4001` | MARK | when | the first 8 bytes of a text label | the next 8 |
| `0x4002` | ZONE | start | end, in ticks | name id |
| `0x4003` | FLOW | when | flow id | name id |
| `0x4004` | COUNTER | when | name id | the value (two's complement) |

- **ZONE.** A zone is written once, when it ends, so a crash loses only the
  zones still open. Zones on one thread nest by time.
- **FLOW.** Joins records across threads and processes. For an IPC call the
  flow id is computed by both ends from what they share, so nothing extra
  travels with the message: croi's own function, below, so user records
  join the kernel's.
- **MARK.** Labels are UTF-8, NUL-padded, at most 16 bytes. `td bench`
  brackets each measured run with marks.

### IPC flow ids (croi K7b, commit e960f87)

croi defines the flow id for channel messages (`croi_flow_id` in croi's
`include/ipc.h`, an inline function the kernel and user space share). The
idlc-generated client and server code (M3) computes the same value, so
its FLOW records join the kernel's:

- `channel_id` = min(koid, related_koid), from `object_get_info(handle,
  CROI_INFO_HANDLE_BASIC = 2)`: both ends see the same pair.
- `txid` = the message's first 4 bytes (0 if it's shorter). `channel_call`
  writes a kernel txid with the high bit set and the reply echoes it, so a
  call and its reply share one flow.
- The splitmix64 finalizer, with 64-bit wrapping arithmetic:

      z = channel_id * 0x9E3779B97F4A7C15 + txid
      z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
      z = (z ^ (z >> 27)) * 0x94D049BB133111EB
      flow = z ^ (z >> 31)

The kernel's records, in its category CROI_TRACE_IPC (1 << 3, a kernel
category, not this format's user `ipc` bit):

| Kind | Name | `a` | `b` |
|---|---|---|---|
| 80 | CROI_TK_CHANNEL_WRITE | flow | bytes \| handles << 32 |
| 81 | CROI_TK_CHANNEL_READ | flow | bytes \| handles << 32 |
| 82 | CROI_TK_DONATE | flow | the caller's trace id (thread: the server) |

A call gives the call's write, the server's read, one DONATE and the
reply's write, all with one flow. Donation (the server takes the caller's
profile until it replies) begins once the caller blocks on the call.

Shared-memory rings aren't croi's to define. Ours use the same function
with the ring VMO's koid as `channel_id` and the slot's sequence number as
`txid`, as croi suggested.

## The region

A traced process writes one region: on Linux a file it maps shared, so the
trace survives the process (a crash included) and a reader just opens it.
All offsets are from the region's start.

**Header, at 0 (4096 bytes):**

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic: `"tdtr"` (0x72746474) |
| 4 | 4 | version: 2 |
| 8 | 8 | `counter_hz`: the cycle counter's frequency, calibrated at start |
| 16 | 8 | `start`: the counter when recording began |
| 24 | 4 | process id |
| 28 | 4 | ring count |
| 32 | 8 | ring size in bytes, header included |
| 40 | 8 | the string table's offset |
| 48 | 8 | the string table's size |
| 56 | 8 | bytes of the string table used (atomic) |
| 64 | 8 | the first ring's offset |
| 72 | 4 | rings claimed so far (atomic) |
| 76 | 4 | flags: bit 0, circular (oldest records overwritten); else oneshot (newest dropped) |
| 80 | 8 | the categories enabled |
| 88 | 4008 | reserved, zero |

**The string table** holds the names records refer to. Each entry is a
4-byte length, then the UTF-8 bytes, padded to 4. A name's id is its
entry's offset within the table. Entries are appended and never change.

**Rings** follow, one per thread that has written. A thread claims the next
ring the first time it writes. Each is a *trace ring* (version 2, D50): a
128-byte trace header, then a one ring (architecture §3, `lib/ring`) in
the rest of the ring's bytes. The kernel's rings are the same, one a CPU
(croi's `croi_trace_ring_t`, `kernel/include/trace.h`), so one reader
handles kernel and user rings.

The trace header:

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | `frequency`: the counter's Hz, as in the region header |
| 8 | 8 | `session`: the region's `start`, so rings from one recording go together |
| 16 | 8 | records dropped (oneshot, when full) |
| 24 | 8 | the time of the first drop |
| 32 | 8 | the time of the last drop |
| 40 | 4 | mode: 0 oneshot, 1 circular |
| 44 | 4 | cpu: `0xffffffff` for a thread's ring |
| 48 | 4 | magic: `"ring"` (0x676e6972) |
| 52 | 4 | the thread's `tid` (0 for a CPU's ring) |
| 56 | 72 | reserved, zero |

The one ring is an OVERWRITE ring (D44) of 40-byte slots, its format
descriptor `"TRC2"` (0x32435254): each slot is the ring's u64 sequence,
then a record. Its slot count is a power of two, as many as fit. Only the
owning thread (or CPU) writes, so writing takes no lock: it marks the
slot's sequence all ones, writes the record, sets the sequence to the
slot's cursor, and publishes its cursor (`Ring.write(from:)`). A
circular ring overwrites the oldest; a oneshot one stops once its cursor
reaches the slot count and counts what it drops in the trace header.

A reader keeps its cursor to itself (`Ring.read(to:dropped:)`): it starts
at the producer's cursor less the slot count (0 if fewer were written),
keeps a slot only if its sequence was its cursor before and after the
copy, and counts the rest as dropped. A circular ring's oldest slot may
be mid-overwrite; the sequence says so, so no slack is needed.

## Categories

The enabled set is a 64-bit mask. A disabled trace point costs one relaxed
load of the mask and one predictable branch. User categories: bit 0
`app` (zones a program names itself), bit 1 `frame`, bit 2 `audio`, bit 3
`input`, bit 4 `ipc`, bit 5 `io`, bit 6 `mark`. The rest are reserved.

## Recording on Linux

A program that uses `Trace` with `TODHCHAI_TRACE=DIR` set writes
`DIR/<pid>.trace` (`TODHCHAI_TRACE_CATEGORIES`, `TODHCHAI_TRACE_CIRCULAR`
choose what and how): the hosted writer, `system/trace/writer/host`, which
`swift test`'s TraceTests use. `vx trace print`, `vx trace summary` (per
name: counts and percentiles) and `vx trace diff` (two traces compared)
read the files.

## Recording on croi (M3f; V2)

Natively a process doesn't make its region: whoever traces it does
(`TraceSession`, `system/trace/session`), and hands it to the process as a
VMO in processargs (`PA_TRACE_REGION`, `HandleType.traceRegion`). The
session writes the header, so `counter_hz` is croi's (its rings'
`frequency`), and `start` is croi's trace session. The process maps the
region on its first trace name (or takes it with `Trace.start(region:)`)
and writes rings as on Linux; a thread finds its ring through its thread
block (the floor's, slot 8: croi's per-thread FS base, `TPIDR_EL0` or
`tp`). A region's process id is `0xF0000` plus its number in the session:
croi names threads by an internal task id user space can't read yet, so
user and kernel records join through flow ids, not thread ids.

The session also starts croi's kernel trace (`trace_configure`, with the
tracing or root resource) and maps each CPU's ring. When it ends it writes
every file compacted (the strings used; each ring's records, read as a
reader reads them, written into a fresh ring from sequence 0) and the
kernel's rings as `kernel.trace` (process 0, a ring a CPU, `cpu` set, no
strings). Until croi has a device to the host (virtio), the files leave
through the debuglog in base64:

    td-trace NAME OFFSET BASE64        (120 bytes a line)
    td-trace NAME OFFSET zero COUNT    (a run of zeros)
    td-trace NAME end SIZE

paced below the console's rate (about 110 KB/s under KVM: croi's debuglog
drops records when its console dumper falls 512 behind). `vx trace collect
CONSOLE DIR` reassembles them from a boot's console (a test boot keeps it
as `qemu-*/console.log`) and fails if a piece is missing. `vx trace
summary DIR` then reads that directory as one timeline as well as file by
file: each call's commonest path through the client, croi's
CHANNEL_WRITE, CHANNEL_READ and DONATE, and the server, with the median
time to each step. The boot-trace test (`bin/trace-test`, then
trace-collect) records and collects one.
