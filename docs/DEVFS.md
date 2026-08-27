# devfs: the first server whose files are devices

`kernel/devfs/` — `#c` bound at `/dev`, with `cons`, `null` and `zero` in it.

Everything before this in Vectra could name a file. Nothing before it could name
a piece of hardware. `devfs` closes that gap, and the line it prints during the
boot self-test is the whole point of it:

    open_path(ns, "/dev/cons", O_RDWR)   a walk that crosses two servers
    chan_write(c, 0, "hello\n")          Twalk, Tlopen, Twrite, a worker, a glyph
    chan_read(c, 0, buf)                 Tread, a worker, a park, a keystroke

Three of Vectra's subsystems were built for a server that does not exist yet.
This is that server, and it is what makes them reachable from a path rather than
from a self-test.

| What it uses | Built in | Reached from a path here |
|---|---|---|
| Worker threads on a 9P connection | `kernel/mnt` | Four workers behind `#c` |
| A payload buffer per request slot | `kernel/mnt` | Every `Rread` from `/dev/cons` |
| A read with a deadline, and `Tflush` | `kernel/vfs` | `chan_read_for` on `/dev/cons` |
| A thread that waits for a condition | `kernel/sync` | A read of an empty console |

## Why `static.odin` could not be it

`vfs.static.odin` serves the same shape of tree, and `docs/HANDOFF.md` said for
two milestones that it was the wrong shape "only because it is read-only". That
turned out to understate it by one word. It is read-only, and its files *have
contents* — a `data: string` in `.rodata`. A device has no contents. It has
behaviour, and the behaviour is what the node table has to hold.

So the node carries a `Dev_Kind` instead of a string, and two switches in the
handler dispatch on it. Adding `random` or `kbd` is a row in the table and a
case in each switch. Nothing about the walk, the listing, the fid table or the
error vocabulary has to learn a new file kind.

**What the two servers do share is the fid table.** `static.odin` opened by
saying that a second server should not mean a second fid table. This is the
milestone that made it a promise rather than a plan. `vfs.Fid_Table` moved out
into `kernel/vfs/fidtab.odin`, `static.odin` uses it, and so does this. It binds
an `i32` to a fid and has no opinion about what the number means.

## Three things this is the first of

### The first handler that may not hold its lock

`static_handler` takes the server's spinlock on the way in and drops it on the
way out. Every line between those two is a table lookup, so the whole handler is
one critical section and that costs nothing.

This handler cannot do that. It writes to a framebuffer and it parks on a
rendezvous, and a spinlock forbids both. The first, because a scroll copies
most of a 1280x800 framebuffer with interrupts masked. The second, because
`sync.can_sleep` says so and stops the machine on a broken rule.

So `Dev_Tree.lock` guards the fid table and only the fid table, taken for the
length of a lookup by `bind_fid`, `node_of` and `drop_fid`. The node table needs
no lock at all: it is `.rodata` and it never changes.

### The first server whose reads genuinely park

Everything that waited before this waited because a self-test told it to. A read
of `/dev/cons` with nothing typed has nothing to answer with and no way to
invent one. It parks on `Cons.ready` until a byte arrives.

The loop around the park is `sync.sleep`'s contract honoured rather than
defensive coding. A wake is a hint. Two readers woken by one byte cannot both
have it, so the loser finds an empty ring and parks again.

### The first abort hook that means something

`devfs_abort` is what `kernel/mnt` calls when a `Tflush` names a live request.
It wakes every parked reader, and each re-tests whether the flush was its own.

**The transport's flushed bit is the authority, not a flag of this server's.**
`vfs.server_flushed` reads `Rpc.flushed` on the request slot, and `kernel/mnt`
clears that bit when the slot is claimed. A server keeping its own copy would
have to clear it at exactly that moment, which is a moment no server can see. Take
a flush that arrives after a slot goes to a worker and before the handler
starts. The handler would clear it, and the client would wait for an `Rflush`
that nothing sends.

Waking everybody rather than the one flushed reader is deliberate. This hook is
handed a tag. What identifies a parked reader is the rendezvous it is on. The
alternative is eight rendezvous to avoid waking three threads that go straight
back to sleep.

## The console device

`cons.odin` is the driver, and it has two halves with almost nothing in common.

**Output** goes to the framebuffer console and to the serial port, which is what
every other sink in Vectra already does.

**Input** arrives on a thread. The 16550 driver is polled, because it is the
one thing that has to work before there are interrupts. So a thread stands
where an interrupt handler will stand. It polls, pushes into a ring, and wakes whoever
waits. Nothing above the ring can tell the difference. The day IRQ 4 is wired
up, `cons_input` goes away and the handler pushes into the same ring.

`cons_feed` is that entry point, made public. It is what a keyboard driver will
call. It is also what the self-test calls to end a parked read. A check that a
read parks and then finishes has to be the thing that finishes it, and it
cannot type at a serial port.

### Two locks, and they are different kinds on purpose

    Cons.out    a sleeping lock, held across a write to the screen
    Cons.lock   a spinlock, held across two integers and a byte

`out` parks because a write draws glyphs, and a write at the bottom of the
screen scrolls first. A scroll copies most of a 1280x800 framebuffer. A
spinlock masks interrupts for as long as it is held. One here would mask them
across four megabytes of memory copy. `docs/HANDOFF.md` records that the LAPIC
coalesces every tick it cannot deliver. They would not come back.

`lock` is a spinlock for the opposite reason. What it guards is small, and the
producer is a thread that will one day be an interrupt handler. An interrupt
handler cannot park, so the lock it takes may never be one that parks.

**`klog` deliberately takes neither.** It writes to the same console and is
left alone. It runs from the fault path. A sleeping lock is forbidden there, and
a lock held by a dead thread is worse than a torn line. The ordering of a log
line against a `/dev/cons` write is therefore undefined. What is defined is that
neither can deadlock the other.

### The ring buffers what nobody asked for

A key pressed while nothing reads `/dev/cons` is kept, up to `CONS_INPUT_BYTES`
of it. A driver that only moved bytes when somebody waited would lose everything
typed between two reads, which is every character a user types ahead.

`head` and `tail` are monotonic and never wrap by hand — the index is the counter
masked. That is what makes `head - tail` the count. There is then no ambiguity
between a full ring and an empty one, which is the bug every other arrangement
has.

A full ring drops the byte and counts it in `dropped`. That is what an interrupt
handler with nowhere to put a byte does, and this has to behave the way its
replacement will.

## The worker count is a bound on blocked readers

`WORKERS` is 4, so **at most three reads may park at once**. The fourth worker
is what serves the `Tflush` that unsticks one of them. It is exactly one
because a flush never parks. It marks the request, calls the abort hook, and
returns.

`kernel/mnt` states this rule where the number is chosen, and says it cannot
check it. How many of a server's requests can block is the server's own
business. Exceed it here and nothing corrupts. It *stops*: every worker waits for
a key, and the flush that would release one waits behind them for a worker. A
byte typed at the port frees the whole thing, which makes it a stall rather than
a deadlock, and does not make it acceptable.

Plan 9 avoids the question by giving every request a thread of its own. That is
the fix when threads are cheaper than they are today.

## What a device answers, and what it refuses

| Message | `/dev` | `cons` | `null` | `zero` |
|---|---|---|---|---|
| `Tlopen` write | EISDIR | ok | ok | ok |
| `Tread` | EISDIR | parks until a byte | 0 bytes | zeroes, for ever |
| `Twrite` | EISDIR | draws, and sends | count | count |
| `Treaddir` | three entries | ENOTDIR | ENOTDIR | ENOTDIR |
| `Tgetattr` size | 0 | 0 | 0 | 0 |
| `Tlcreate`, `Tmkdir`, `Tremove` | EPERM | EPERM | EPERM | EPERM |

Two of those rows are decisions rather than defaults.

**Creation is EPERM, not EOPNOTSUPP.** The two say different things to a client.
EPERM is *there is such an operation and you may not*, which is the truth. The
shape of `/dev` is the driver table, and a client does not get to add a row to
it.
EOPNOTSUPP would send a client off to look for a server that does implement it.

**Every device reports a size of zero,** and `offset` is ignored on every read.
That is the definition of a stream rather than an oversight. A second read of
`/dev/cons` at offset zero does not read the same bytes again, because the bytes
are gone. A file whose contents are the future has no position to be at. A size
of zero is what stops a caller from trying to read one by its length.

`null` and `zero` are here for two reasons beyond being useful. A dispatch table
with one row is not a dispatch table. And the self-test needs a read that does
*not* park, to compare the one that does against.

## What is deliberately absent

**No line discipline.** A read returns bytes as they arrive rather than waiting
for Enter. Backspace does nothing, because there is no line buffer to erase
from. Plan 9 puts both behind `/dev/consctl`, and so will this. A `ctl` file
that takes `rawon` and `rawoff` is the shape, because Vectra9 adds no message
to 9P for something a file can carry. See `docs/VECTRA9.md`, decision 1.

One translation happens anyway, because nothing above could undo it. A terminal
sends CR for Enter. A reader that got CR would have to know which terminal
typed at it. So CR becomes `\n` here, which is the newline everywhere else in
the tree.

**No echo policy beyond a flag.** `Cons.echo` is on, because the only writer at a
keyboard today is a person who wants to see what they typed. It belongs behind
the same `ctl` file.

**No `/dev/random`, `/dev/draw`, `/dev/mouse` or `/dev/kbd`.** Each is a row in
`DEV_NODES` and a case in two switches. `kbd` is the interesting one, because it
is what turns `cons_input` from a poll into an interrupt.

## The self-test, and what it costs to make honest

`kernel/devfs/verify.odin`, run at the end of the boot against the machine's own
`/dev`. There is no fixture: it opens the real mount, on the boot namespace,
through the real transport with four workers on it.

**Neither blocking check runs on the thread that reports.** A read that parks and
is never woken never returns, so the boot thread inside one would print nothing
from that point on. `docs/TESTING.md` calls that failure worse than a failed
check and names two earlier occurrences of it. Both reads run on a spawned
thread, watched with a bound. A thread that does not come back is a check that
fails and a boot that carries on.

The parked-read check waits for something *not* to happen, which is the one wait
in the file that is not bounded by `watch`. A read of an empty console has to
still be unanswered after `SETTLE_TICKS`. That is what distinguishes a parked
read from a merely slow one. It is the check that a read answering nothing
immediately would fail.

### The controls

Eleven mutations, one at a time, each observed on a real boot:

| Mutation | First failure |
|---|---|
| a cons read that never parks | `a read of an empty console does not answer` (6 checks) |
| no abort hook | `a read that outlives its deadline comes back at all` |
| the parked reader never checks whether it was flushed | `a read that outlives its deadline comes back at all` |
| a write to cons draws no glyph | `and every byte of it drew a glyph` |
| a directory opens for writing | `and refuses to open for writing` |
| `/dev/zero` does not zero the buffer | `and reads zeroes over whatever was in the buffer` |
| the fid table never releases a fid | `vfs 31 transport checks` — and `#c` itself would not come up, ENFILE |
| the readdir cookie is off by one | `/dev lists` |
| the ring's read cursor never advances | `and exactly the one byte there was` (7 checks) |
| a write to cons takes no lock | **not caught** |
| creating a file in `/dev` is not refused | **not caught** |

**The write check earns its place, and nearly did not.** It began as a check that
the driver's own byte counter went up. That counter goes up whether or not a
glyph was ever drawn, so the mutation above passed it. The check is now the
console's own cursor: 49 bytes written is 49 columns further along. The newline
goes separately, so the count is exact.

This is the same lesson as the FPU accumulator in `docs/SCHED.md`. A check that
observes a bookkeeping field rather than the effect is a check the effect can be
removed from underneath.

**Both uncaught mutations are uncaught for the same reason, and it is not the
usual one.** Neither is a narrow window. `Cons.out` guards against two threads
interleaving inside one line, and this test writes from one thread. The EPERM on
creation is unreachable because `kernel/vfs` has no `chan_create` for a client to
call it with. Both become reachable the moment there is something to reach them
with: two writers for the first, a POSIX `open(O_CREAT)` for the second.

That is worth stating plainly rather than filing as a gap. A control that
cannot be expressed is different from a control that fails to fire.
`docs/TESTING.md` says to check which one you have before recording it.

## What this leaves for next time

- **`/dev/consctl`**, and the line discipline behind it. Cooked mode, echo, and
  the `rawon`/`rawoff` pair. It is the first `ctl` file in the tree, so it is
  also where the convention for parsing one gets set.
- **A keyboard driver**, which is what makes `cons_input` an interrupt handler
  and deletes the poll.
- **`/dev/draw`**, over `kernel/drivers/fb`, which is the other half of a
  console and the thing `apps/terminal` will actually want.
- **A worker per blocked request**, or a way for a handler to defer its reply
  without holding a worker. Either one removes the bound this file's worker
  count stands in for.

## See also

- `docs/TRANSPORT.md` — the workers, the payload buffer, and `Tflush` from the
  server's side.
- `docs/NAMESPACE.md` — what `mount_device` and `resolve` do to get here.
- `docs/BOOT.md` — the console driver this sits on, and the log that shares it.
- `docs/TESTING.md` — the self-test discipline, and the two controls above that
  cannot be expressed yet.
