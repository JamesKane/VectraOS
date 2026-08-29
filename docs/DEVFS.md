# devfs: the first server whose files are devices

`kernel/devfs/` — `#c` bound at `/dev`, with `cons`, `consctl`, `null`,
`zero`, `fb`, `fbctl`, `scancode` and `eia0` in it.

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

`/dev/consctl` is the other half of the console, and the first `ctl` file in the
tree. It is what makes `/dev/cons` a terminal rather than a byte pipe, and the
convention it sets is the one every later `ctl` file follows.

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

**The flush is checked before the drain, and the order is load-bearing.** A
client that gave up on a read has a tag `kernel/mnt` reclaimed, and a reply
on it is dropped. A reader that drained first would consume the bytes into
that dropped reply. The next read would find them gone -- a byte lost to a
flush that raced its arrival. The transport sets `flushed` before it wakes
the reader, so checking it first leaves the bytes for the read that follows.

`kbdfs` found this. Its reader reads `/dev/scancode` on the interruptible
path, which flushes every `NOTE_POLL` ticks, and one boot in three lost a
keystroke to the old order. Both device-read loops, the console's and the
taps', check the flush first now.

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

### Cooked and raw

A byte that arrives does not go straight into the ring. It goes into a line
under construction, and the whole line reaches the ring when the user presses
Enter. That is *cooked* mode, and it is the default because it is what a person
at a keyboard wants. A typed character can be taken back until the moment the
line is sent.

| Typed | Cooked mode does |
|---|---|
| a printable character | appends it to the line, and echoes it |
| `\b` or DEL | takes the last character off the line, and off the screen |
| `^U` | throws the line away, and the echo starts a fresh one |
| `\r` or `\n` | sends the line, newline included |
| `^D` on a line with characters | sends the line, with no newline |
| `^D` on an empty line | is the end of the file |
| any other control character | nothing, and it never reaches a reader |

*Raw* mode is the other half. Every byte reaches the ring as it arrives, none of
those characters mean anything, and nothing is echoed. That is what a program
which draws its own input needs, and what a program which reads a password
needs.

**Two things about that table are decisions rather than conventions.**

`^D` means two things, and which one depends on whether there is a line to send.
On a line with characters it sends them with no newline, which is how a reader
receives a line nobody ended. On an empty line there is nothing to send and the
only remaining meaning is *there will be no more*. That is also the one place a
read of `/dev/cons` may answer with zero bytes. Nothing else does, which is
what makes zero bytes usable as an end of file.

`^U` echoes a newline rather than erasing the line it threw away. Erasing would
be one acquisition of `out` per character. A kill is also a deliberate
abandonment, and seeing where the old line stopped is better feedback than
watching it disappear.

**A line that fills stops accepting characters.** It does not send itself and it
does not throw itself away. Both would lose work the typist can still see. The
limit is one short of the array, so Enter always has somewhere to go. A line
that could fill completely would be a line Enter could not end.

### The end of file is a count, and it is read last

`Cons.eofs` is a count rather than a flag, because two `^D` presses are two
answers and a flag would merge them. A reader consumes one only when the ring is
empty.

That ordering is the whole of it. An end of file is something a reader *reaches*,
so it must never overtake bytes typed before the `^D`. `devfs_read` drains first
and asks second, and `cons_take_eof` refuses if anything is left.

## `/dev/consctl`, and the convention it sets

`docs/VECTRA9.md` decision 1 covers this. When a service needs an operation 9P
does not have, the answer is a file that takes a line of text. This is the first
service to need one, so this is where the shape of a `ctl` file gets decided.
Four rules:

1. **One write is one command.** Nothing is buffered between writes, and a
   command may not be split across two of them. A `ctl` file that reassembled a
   command from fragments would have to guess where one ended, and 9P gives it
   nothing to guess with.
2. **A command nothing recognises is EINVAL**, and the write takes none of it.
   Silence would let a client believe it changed something. The write is never
   short for the same reason. A count below what was sent would mean *I took
   some of your command*, which no client can act on.
3. **The file reads back as the writes that would restore it.** Not a status
   report in a different vocabulary.
4. **The last close reverts it.** Below.

The vocabulary is four words:

    rawon     bytes as they arrive, no editing, no echo
    rawoff    the line discipline above, with echo
    echoon    echo, without touching the mode
    echooff   ...and the other way

`rawon` turns echo off and `rawoff` turns it back on, because a raw read that
echoed would be a password on a screen. `echoon` and `echooff` exist for a
client that wants a combination those two do not produce. A cooked line nobody
sees is a reasonable thing to want.

### Reading a ctl file back

Plan 9's `consctl` cannot be read. Vectra's can, and it answers with the
commands that would restore it:

    rawoff
    echoon

**That is a departure, and it is the one thing here Plan 9 would not recognise.**
It is worth it for two reasons. A client can save what it reads and write it
back later. That is what makes this one file rather than a `consctl` and a
`consstat`. And a self-test has something exact to compare against, rather than
a flag it has to reach into the driver for.

Generated on every read rather than snapshotted at open. Plan 9 snapshots, and
it is right to for a file whose contents are long or expensive. This one is
fifteen bytes, and a client that reads it twice wants the second answer to be
true. `offset` is honoured so a read past the end returns nothing rather than
repeating.

### The last close reverts the mode

**This is the property the whole file exists for.** A program that turns raw
mode on and then faults leaves a console nobody can type at. No echo, and no
line editing to fix a mistake with. On a machine with no other terminal that is
the end of the session.

Tying the mode to an open fid means the kernel undoes it when the program goes.
The program does not have to survive long enough to undo it itself. Plan 9 does
exactly this, and it is worth copying for exactly this reason.

What it costs is a count of open `/dev/consctl` fids, and knowing at `Tclunk`
whether the fid being released was one of them. That is why `vfs.Fid_Table` grew
an `open` flag per slot. 9P wants that flag anyway. A fid before `Tlopen` may
be walked and may not be read, and a fid after it is the reverse. No server in
this tree enforces that yet, and this milestone did not make it one.

**A mode change discards the line under construction**, whoever caused it. Those
characters were typed under rules that no longer apply. A raw reader handed a
half-edited line would get characters the user already backspaced over.

## The raw framebuffer, and the first device with contents

`fbdev.odin` — `/dev/fb` is the screen's memory as a file, and `/dev/fbctl`
is the geometry beside it. This is `docs/HANDOFF.md`'s "a device a user
process can reach", and it took no new system call to reach it. A process
opens `/dev/fb` by name, seeks its descriptor, and writes pixel bytes.
`seek` already carried the position, `Twrite` already carried it here, and
the new ground is only a device that honours it on the far side.

Two masters want this file, which is why it exists now rather than with
`/dev/draw`. A userland devfs needs the kernel to serve the console's raw
halves, so a process can stand where `#c`'s handler stands. And `/dev/draw`
is mostly a protocol over exactly this memory. One file serves both.

**Every device before this one was a stream.** A stream has no length and
ignores its offset, and `Rgetattr` says size zero so nobody reads one by its
size. The framebuffer is the opposite on every count. It has exactly
`height * pitch` bytes — padding included, because the padding is memory a
client's row arithmetic addresses — and the offset names which of them. So
`fb` is the one row in the table whose `Rgetattr` reports a real size. A
screenshot is a read of the file by its length.

The boundary follows three rules, each the honest answer at its edge:

- a read at or past the end answers zero bytes, which is a real end of file
- a read or a write that straddles the end takes what fits and reports the
  short count, because the bytes up to the edge did move
- a write that starts at or past the end is ENOSPC — there is no space at
  that offset and there never will be, and a zero count would read as `try
  again`

**No lock covers a pixel copy, on purpose.** Two clients that write the
same pixels tear the picture, and the picture is not kernel state. The
screen already works that way: `klog` draws with no lock from the fault
path, and the console's writes share the same surface. A server that
serialised pixel writes would hold a worker to buy nothing.

`/dev/fbctl` reports what a client cannot draw without:

    size 1280 800
    pitch 5120
    depth 32
    r 8 16
    g 8 8
    b 8 0

One line per fact, `depth` in bits, each channel as its width and its shift
into the pixel word. It is a `ctl` file with an empty command vocabulary,
because nothing about this hardware can be set yet. Every write is
therefore EINVAL, which is rule 2 with no rows in its table. The day a mode
can change, `size` becomes a command and rule 3 starts to hold for it.

## The taps: the input streams, served raw

`tap.odin` — `/dev/scancode` is the keyboard before translation, and
`/dev/eia0` is the serial port before the line discipline. Both names are
Plan 9's, and its `kbdfs` is the program these files exist for. A userland
driver reads the raw stream, does its own translation, and serves the
cooked result back as files of its own. With `/dev/fb` these close the
handoff item — every piece of hardware behind `#c` is now a file a process
can open.

**A tap diverts the stream, and that is the design decision in this
milestone.** While something holds `/dev/scancode` open, the kernel's own
translation sees nothing. While something holds `/dev/eia0`, the line
discipline hears nothing from the port. A *copy* of the stream would leave
two line disciplines fighting over one keyboard, and every keystroke would
act twice. Ownership is what `a process stands where the kernel's handler
stands` has to mean.

The last close gives the stream back, which is `consctl`'s revert again.
A program that takes the keyboard and faults must not leave a machine
nobody can type at. Unread bytes drain at that moment — captured under
rules that no longer apply, they belong to nobody.

The keyboard side crosses one seam. `kernel/drivers/kbd` gained a second
function pointer: a raw hook with first refusal on every scancode. The
driver stays as ignorant of devfs as its `Sink` always was. It resets its
modifier state when a diversion ends, because a shift released into the
tap would otherwise leave the console shifted for ever. The serial side
needs no seam at all: `cons_input` is this package's own thread, and
`serial_deliver` is the one call it makes per byte.

Writes are asymmetric on purpose. `/dev/eia0` writes raw bytes out the
wire — under `Cons.out`, so a console line cannot be torn — and draws no
glyph. This file is the port, and `/dev/cons` is the screen.
`/dev/scancode` refuses writes with EPERM: nobody writes a keyboard.

A tap read parks like a console read, minus two cases. No line discipline
stands between a tap and its reader, so any byte answers. And there is no
`^D`, so nothing here ever answers zero bytes. Park, byte, or flush is the
whole state space.

## The worker count is a bound on blocked readers

`WORKERS` is 4, so **at most three reads may park at once**. The fourth worker
is what serves the `Tflush` that unsticks one of them. It is exactly one
because a flush never parks. It marks the request, calls the abort hook, and
returns.

Three files can park a read now — `cons` and the two taps — so three
single-reader clients fill the bound exactly. The flush worker stays free.
That is the userland-devfs shape: one server per stream, one parked read
each. A fourth parked read stalls the connection, and the bound wants
raising the first time something legitimate hits it.

`kernel/mnt` states this rule where the number is chosen, and says it cannot
check it. How many of a server's requests can block is the server's own
business. Exceed it here and nothing corrupts. It *stops*: every worker waits for
a key, and the flush that would release one waits behind them for a worker. A
byte typed at the port frees the whole thing, which makes it a stall rather than
a deadlock, and does not make it acceptable.

Plan 9 avoids the question by giving every request a thread of its own. That is
the fix when threads are cheaper than they are today.

## What a device answers, and what it refuses

| Message | `/dev` | `cons` | `consctl` | `null` | `zero` | `fb` | `fbctl` | `scancode` | `eia0` |
|---|---|---|---|---|---|---|---|---|---|
| `Tlopen` write | EISDIR | ok | ok, and counted | ok | ok | ok | ok | ok, diverts | ok, diverts (ENXIO with no port) |
| `Tread` | EISDIR | parks until a line | the state | 0 bytes | zeroes, for ever | pixels at the offset | the geometry | parks until a scancode | parks until a byte |
| `Twrite` | EISDIR | draws, and sends | one command | count | count | pixels, may be short | EINVAL | EPERM | raw, out the wire |
| `Treaddir` | eight entries | ENOTDIR | ENOTDIR | ENOTDIR | ENOTDIR | ENOTDIR | ENOTDIR | ENOTDIR | ENOTDIR |
| `Tclunk` | — | — | may revert the mode | — | — | — | — | may give the stream back | may give the stream back |
| `Tgetattr` size | 0 | 0 | 0 | 0 | 0 | height × pitch | 0 | 0 | 0 |
| `Tlcreate`, `Tmkdir`, `Tremove` | EPERM | EPERM | EPERM | EPERM | EPERM | EPERM | EPERM | EPERM | EPERM |

Two of those rows are decisions rather than defaults.

**Creation is EPERM, not EOPNOTSUPP.** The two say different things to a client.
EPERM is *there is such an operation and you may not*, which is the truth. The
shape of `/dev` is the driver table, and a client does not get to add a row to
it.
EOPNOTSUPP would send a client off to look for a server that does implement it.

**Every stream reports a size of zero,** and `offset` is ignored on every read
except `/dev/consctl`'s and the framebuffer pair's. That is the definition of a
stream rather than an oversight. A second read of `/dev/cons` at offset zero
does not read the same bytes again, because the bytes are gone. A file whose
contents are the future has no position to be at. A size of zero is what stops
a caller from trying to read one by its length.

`/dev/consctl` and `/dev/fbctl` are exceptions because they are not streams.
Each has contents, the contents are short, and a client with a small buffer has
to be able to finish them. `/dev/fb` is the full exception: contents, a size,
and an offset that names a pixel. The section above owns that design.

`null` and `zero` are here for two reasons beyond being useful. A dispatch table
with one row is not a dispatch table. And the self-test needs a read that does
*not* park, to compare the one that does against.

## What is deliberately absent

**No word erase, and no history.** `^W` and the arrow keys are what a person
misses next after `^U`. Both are a larger edit buffer and a cursor position
inside it, rather than a new idea.

One translation happens in both modes, because nothing above could undo it. A
terminal sends CR for Enter. A reader that got CR would have to know which
terminal typed at it. So CR becomes `\n` here, which is the newline everywhere
else in the tree. No mode makes a reader want to know what kind of terminal it
has.

**No per-namespace console.** There is one `Cons` and `/dev/consctl` changes it
for everybody. That is correct while there is one screen and one keyboard, and
it stops being correct the day `/dev` means something different in two
namespaces.

**No `/dev/random`, `/dev/draw`, `/dev/mouse` or `/dev/kbd`.** Each is a row in
`DEV_NODES` and a case in two switches, which is the path `fb`, `fbctl`,
`scancode` and `eia0` walked. `draw` is now a protocol question rather than a
memory question, because `/dev/fb` already serves the memory. And `kbd` —
Plan 9's *cooked* keyboard file, runes with modifiers spelled out — is a
userland `kbdfs`'s to serve over `/dev/scancode`, not this server's to grow.

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
read from a merely slow one.

**Cooked mode made that check stronger, and the extra step is the interesting
one.** The read has to still be unanswered *after a character arrives*, because
a character is not a line. A console that delivered characters as they
arrived would fail exactly there, and nothing else in the file would notice.

The line-editing checks read bytes that reached the ring before the read
started, so none of them means to park at all. They use `chan_read_for` with a
short deadline rather than a thread. A read that cannot fail to return is not
the blocking thing the rule is about. A bug that made one park comes back as
EINTR and a failed check, rather than as a hang.

**The echo checks are the console's cursor, twice.** There is no way to read a
framebuffer back, so where the cursor stands is the only observable. A typed
character has to move it one column, and a backspace has to move it back. Both
happen at the end of the proof line rather than at column zero. That is where
`console.backspace` has a real glyph beside it, and has to get the emboss
shadow right.

### The controls

Twenty-nine mutations, one at a time, each observed on a real boot. The first
eleven are the device server, and the next nine the line discipline and the
`ctl` file. Four more are the raw framebuffer, four the taps, and the last the
flush-order fix `kbdfs` demanded. Two more tap controls live on the driver's
side of the seam, in `docs/KBD.md`.

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
| cooked mode delivers each character as it arrives | `and the read still does not answer, because a character is not a line` (9 checks) |
| a backspace does not shorten the line | `and takes the character off the line as well` |
| a kill does not clear the line | `a kill throws the whole line away` |
| `^D` on an empty line marks no end of file | `and is the end of the file, the only read that answers nothing` |
| the last close of `/dev/consctl` does not revert | `and puts the console back in cooked mode` |
| an unknown command is accepted | `a command nothing recognises is refused` |
| the report ignores the offset | `a read at an offset starts there` |
| a mode change keeps the line under construction | `and the half-typed line went with the rules that accepted it` |
| `console.backspace` clears no pixels | `and takes the pixels off the screen, rather than only the cursor` |
| a write to `fb` ignores its offset | `and the first pixel is on the screen` (3 checks, 4 more in ring 3) |
| `fb_read` loses its past-the-end guard | a `#PF` on the boot, at the first byte past the frame — see below |
| the geometry report says depth in bytes | `reporting the geometry of the surface the server holds` |
| `fb` reports a size of zero | `with a real length, the first device that has one` |
| `tap_feed` consumes with the gate closed | `a scancode fed while nobody holds the file is the driver's` (5 checks) — and the *live* keyboard fails its injection check, one suite later |
| the last close does not stop the tap | `and the stream is the console's again` (6 checks) — and the live keyboard again, stuck diverted |
| the abort hook forgets the tap rendezvous | `a tap read that outlives its deadline comes back` |
| `serial_deliver` bypasses the tap | `a byte off the port reaches the file raw` (2 checks) |
| a device read drains before it checks the flush | `kbdfs`'s `carrying the characters ...` fails about one boot in three -- a flush racing a keystroke consumes it into a dropped reply. A flake, not a clean fail, and the reason the check moved to flush-first |

**The last two only fail because the checks were rewritten to make them.** Both
came back clean the first time, and neither was a narrow window — they were
checks aimed one layer above the effect.

The mode-change control passed because every line the test typed ended in a
newline, so the buffer it discards was always empty. It types four characters
and leaves them there now.

The backspace control passed because the check was the cursor column, and moving
the cursor is exactly what the mutation kept doing. `fb.get_raw` exists so the
check can count lit pixels in the cell instead.

**The same mistake has now been made three times in this one file**, which makes
it the pattern rather than the anecdote.

The write check began as `the driver's byte counter went up`. That counter goes
up whether or not a glyph was drawn. It became the console's cursor column: 49
bytes written is 49 columns further along.

Then the backspace check was that same cursor column, and a backspace that moved
the cursor without clearing the cell passed it. That one became a count of lit
pixels, which is the actual screen.

Each fix moved the check one layer closer to the effect. Each time, the layer
left behind was bookkeeping the code under test also maintains. It agrees with itself whatever else is broken. This is the same
lesson as the FPU accumulator in `docs/SCHED.md`, and `docs/TESTING.md` now
carries it as a rule rather than as three stories.

**The guard control failed to fail on its first run, and the miss is worth
more than the catch.** The boundary checks probed exactly `limit`, where the
clamp `limit - offset` answers zero with or without the guard. The guard only
matters strictly past the end, where the unsigned subtraction wraps, and
nothing tested there. The checks now probe `limit + 8` as well, on both the
read side and the write side.

On the rerun the mutation did not fail a check. It stopped the machine: a
kernel `#PF` at the first byte past the frame, because the page after the
framebuffer is not mapped. That is recorded as caught, and it also names what
the guard is. Without it, a process with a descriptor and a `seek` can fault
the kernel with a number. The checks still earn their place. A subtler wrong
arrangement — a partial clamp, a guard at the wrong comparison — corrupts an
answer without leaving the frame, and fails a check instead.

**Both ownership controls were caught twice, and the second catch was free.**
Each broke the tap contract, and each also failed the keyboard's own injection
check a suite later. The diverted-or-stuck stream swallowed the live
keystroke the 8042 was asked to raise. That is two independent suites agreeing
about one seam, which is the cheapest corroboration a control ever buys.

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

- **A keyboard driver**, which is what makes `cons_input` an interrupt handler
  and deletes the poll. `cons_feed` is the entry point it already has.
- **`^W` and a cursor in the line**, which is word erase and the arrow keys. A
  larger edit buffer and a position inside it, rather than a new idea.
- **The userland devfs itself.** Every raw half is served now — the screen,
  the scancodes, the wire — so the port stops being blocked and starts being
  work. `consrv` is the server shape, and a `kbdfs` over `/dev/scancode` is
  the natural first tenant.
- **`/dev/draw`**, which is now a protocol question rather than a memory one.
  `/dev/fb` serves the memory, and `apps/terminal` will want the protocol.
- **A bulk path for pixels.** `user.COPY_MAX` is 256 bytes, so a ring 3 repaint
  of the whole frame is about sixteen thousand `write` calls. Fine for a
  cursor, wrong for a compositor. Either a bigger copy bound or a mapping.
- **A worker per blocked request**, or a way for a handler to defer its reply
  without holding a worker. Either one removes the bound this file's worker
  count stands in for.
- **The `open` flag on a fid, enforced.** `vfs.Fid_Table` now carries it, and
  neither server refuses a walk on an open fid or a read on an unopened one.
  Enforcing it is a change with a blast radius, because `chan_clone` walks a
  fid that may already be open. It wants a milestone of its own rather than a
  paragraph in this one.

## See also

- `docs/TRANSPORT.md` — the workers, the payload buffer, and `Tflush` from the
  server's side.
- `docs/NAMESPACE.md` — what `mount_device` and `resolve` do to get here.
- `docs/BOOT.md` — the console driver this sits on, and the log that shares it.
- `docs/VECTRA9.md` — decision 1, which is why `/dev/consctl` is a file rather
  than a message.
- `docs/TESTING.md` — the self-test discipline, and the two controls above that
  cannot be expressed yet.
