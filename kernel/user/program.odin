/*
The programs -- short blobs of machine code baked into the image.

The first thing ever to run in ring 3 had to come from somewhere the kernel
already had. There was no loader and no file to load from. The blobs are
Odin now, in `kernel/user/programs`, compiled once per program for the
kernel's own architecture and embedded whole; they were assembly, and a
port meant writing every one again. `user.load` copies the bytes into a
frame it maps into a program's space. `image.odin` wraps the two that stand
alone in the file format the loader reads.

**The copy is not an accident of having no filesystem.** No `User` bit sits
anywhere on the path to the kernel image, so a program cannot execute it where
it lies. A loader would have to copy it into pages a program may reach, whatever
the source was. That is what this does, minus the part that reads a file.

Every blob is linked at `TEXT_VA`, which is the one address a copy lands
at, and holds its own strings behind its code. The arguments arrive in the
registers the frame was built with, which `arch.thread_user_init` names:

    the first    the program's data page, which the kernel can also read
    the second   whatever the test wanted this program to touch
    the third    a second number, for the programs that need two

Each writes a mark to its data page before it does anything else. That mark
proves the program reached its first instruction. It is a different claim
from the fault that follows, which is about the instruction meant to fault.
*/
package user

/*
The mark each program writes to the first word of its data page.

Eight readable bytes rather than a counter. A kernel reads this out of a frame,
and it has no other way to know a program started. A wrong value in a hex dump
should say which program wrote it.
*/
MARK_SPIN :: u64(0x5350_494E_5350_494E) // SPINSPIN
MARK_POKE :: u64(0x504F_4B45_504F_4B45) // POKEPOKE
MARK_PEEK :: u64(0x5045_454B_5045_454B) // PEEKPEEK
MARK_PRIV :: u64(0x5052_4956_5052_4956) // PRIVPRIV
MARK_JUMP :: u64(0x4A55_4D50_4A55_4D50) // JUMPJUMP
MARK_HELLO :: u64(0x4845_4C4C_4845_4C4C) // HELLHELL
MARK_PROBE :: u64(0x5052_4F42_5052_4F42) // PROBPROB
MARK_SHADOW :: u64(0x5348_4144_5348_4144) // SHADSHAD
MARK_NAMER :: u64(0x4E41_4D45_4E41_4D45) // NAMENAME
MARK_READER :: u64(0x5245_4144_5245_4144) // READREAD
MARK_BINDER :: u64(0x4249_4E44_4249_4E44) // BINDBIND
MARK_MAPPER :: u64(0x4D41_5050_4D41_5050) // MAPPMAPP
MARK_PARENT :: u64(0x5052_4E54_5052_4E54) // PRNTPRNT
MARK_CHILD :: u64(0x4348_4C44_4348_4C44) // CHLDCHLD
MARK_POSTER :: u64(0x504F_5354_504F_5354) // POSTPOST
MARK_NINER :: u64(0x4E49_4E45_4E49_4E45) // NINENINE
MARK_NOTER :: u64(0x4E4F_5452_4E4F_5452) // NOTRNOTR
MARK_GROUPER :: u64(0x4752_5550_4752_5550) // GRUPGRUP
MARK_FORKER :: u64(0x464F_524B_464F_524B) // FORKFORK
MARK_MEMFORK :: u64(0x4D45_4D46_4D45_4D46) // MEMFMEMF
MARK_FDFORKER :: u64(0x4644_464B_4644_464B) // FDFKFDFK
MARK_REFUSER :: u64(0x5245_4655_5245_4655) // REFUREFU
MARK_PAINTER :: u64(0x5041_494E_5041_494E) // PAINPAIN
MARK_CATCHER :: u64(0x4354_4348_4354_4348) // CTCHCTCH
MARK_DFLTNOTE :: u64(0x4446_4C54_4446_4C54) // DFLTDFLT
MARK_EXECER :: u64(0x4558_4543_4558_4543) // EXECEXEC
MARK_NOWAITER :: u64(0x4E4F_5741_4E4F_5741) // NOWANOWA
MARK_BULKIO :: u64(0x4255_4C4B_4255_4C4B) // BULKBULK
MARK_FORGER :: u64(0x464F_5247_464F_5247) // FORGFORG
MARK_ANON :: u64(0x414E_4F4E_414E_4F4E) // ANONANON

/*
Where `spin` keeps its two words, in units of eight bytes from the data page.

`COUNTER` is what the program adds to and the kernel watches. `STOP` is what
the kernel writes and the program reads. Both directions of the same page,
which is the cheapest demonstration that a mapping is shared rather than
copied.
*/
CELL_MARK :: 0
CELL_COUNTER :: 1
CELL_STOP :: 2

/*
Where the two programs that make system calls put their answers, and where
`hello` finds the line it prints.

One cell per call, in the order the program makes them, so a wrong answer names
the call rather than the program. The message starts at `MESSAGE_OFFSET`, past
every cell. A program hands the kernel that address, and the kernel has to
check it like any other.
*/
CELL_WROTE :: 1
CELL_NOP :: 1
CELL_ARGS :: 2
CELL_UNKNOWN :: 3
CELL_BAD_ADDRESS :: 4
CELL_SLEPT :: 5
CELL_HANDOFF :: 2
CELL_R8 :: 6
CELL_R12 :: 7
CELL_XMM :: 8
CELL_SPUN :: 9

/*
The four places a program looks for something the kernel put there.

Sixty-four bytes apart, past every cell, and named rather than numbered because
each program uses them for different things. `namer` finds a path in the first
and a path that is not there in the fourth. `binder` finds two paths and a line
to print.

`MESSAGE_OFFSET` is the first slot under its older name, which is what `hello`
still calls it.
*/
SLOT_A :: 128
SLOT_B :: 192
SLOT_C :: 256
SLOT_D :: 320

MESSAGE_OFFSET :: SLOT_A

/*
Where the three programs that open files keep their answers.

One cell per call, in the order the program makes them. A wrong answer names
the call rather than the program, which is the only reason to spend five cells
where one would do.
*/
NAMER_OPENED :: 1
NAMER_WROTE :: 2
NAMER_CLOSED :: 3
NAMER_AFTER_CLOSE :: 4
NAMER_MISSING :: 5

READER_OPENED :: 1
READER_READ :: 2
READER_REFUSED :: 3
READER_CLOSED :: 4
READER_BUFFER :: 8 // Byte offset 64, which is where the read lands

/*
Where `anon` keeps its answers, and what each one is a claim about.

Eleven cells, in the order the program fills them. `ZERO` and `BACK` are the
two that read memory rather than a return value. The first says the run
arrived clean. The second says the far end is mapped, and not only the near
one. `KEPT` is the fork rule, read after the parent waits for the child that
overwrote its own copy.

`GROWN`, `TAIL` and `SHRUNK` are `segbrk`, asked of the second run. The run
grows by four pages. The program stores the last word of the new tail, reads
it back, and gives two of the four pages back. What that leaves is a run of
two pieces, which is the shape `sweep` exists to check. The store into the
tail is the one line that faults if the grow lied.

`THIRD` and the three after it are `segdetach`. The program asks for one more
page and gives it back whole. Then it asks the two questions the call must
refuse: its own text, which is an image's shape, and an address no segment
covers.

`GO` is the kernel's, and the program waits on it between the second ask and
the grow. The allocator hands out adjacent runs, so a grow that follows an
ask with nothing between lands on the frames right after the run's block. A
`segment_frame` that reads the tail out of the first piece is then right by
luck. The test takes one frame while the program waits, so the grown piece
cannot be adjacent and the luck runs out. The wait is bounded the way `spin`'s
is, so a kernel that never answers ends the program rather than the boot.

`ANON_PATTERN` is what the parent stores and `ANON_CHILD_MARK` is what the
child stores over it. Two values rather than one, so a `KEPT` that is wrong
says which process wrote last.
*/
ANON_ADDR :: 1
ANON_ZERO :: 2
ANON_BACK :: 3
ANON_AGAIN :: 4
ANON_HUGE :: 5
ANON_NONE :: 6
ANON_KEPT :: 7
ANON_STATUS :: 8
ANON_GROWN :: 9
ANON_TAIL :: 10
ANON_SHRUNK :: 11
ANON_GO :: 12
ANON_THIRD :: 13
ANON_DETACHED :: 14
ANON_DETACH_TEXT :: 15
ANON_DETACH_NONE :: 16
ANON_REUSE :: 17

ANON_PATTERN :: u64(0x5749_4E44_5749_4E44) // WINDWIND
ANON_CHILD_MARK :: u64(0x0BAD_0BAD_0BAD_0BAD)

/*
What the child exits with, so the parent's `wait` answers a number no fault
and no errno could produce.

Two statuses, and the second is the whole reason the child asks for memory at
all. A forked child inherits its parent's address space *and* its parent's
mark above it. A child that started its bump at `MAPPING_BASE` would place its
first `segalloc` on top of a run it already holds. The word it inherited would
be gone.

So the child asks, writes into what it got, and looks at the run it inherited
before it trusts either. `ANON_CHILD_REFUSED` is that path failing, whichever
way it failed.
*/
ANON_CHILD_STATUS :: u64(7)
ANON_CHILD_REFUSED :: u64(8)

// What `anon` asks for, and why it is that number: twice `MAX_PROGRAM_FRAMES`
// worth of pages, a megabyte today. A frame list cannot describe it, so a run
// that comes back whole is a claim about the shape and not only about the
// call.
ANON_BYTES :: u64(2 * MAX_PROGRAM_FRAMES * 4096)

// And what it asks for that it must not get. A gigabyte is past
// `SEGALLOC_MAX` by two orders of magnitude, and past this machine's memory.
ANON_TOO_MUCH :: u64(1) << 30

MAPPER_FD :: 1
MAPPER_ADDR :: 2
MAPPER_AGAIN :: 3
MAPPER_BAD_FD :: 4
MAPPER_STREAM :: 5
// `segbrk` asked of the second attach, which is a card and not a run of
// anonymous memory. `docs/USER.md` recorded the kind check as a rule with no
// caller to test it, and this is the program written to ask the wrong
// question.
MAPPER_BRK :: 6
// And `segdetach` of the same attach, which a card may answer. The mapping
// goes and the card's memory goes back to nobody, which `untracked_frees`
// is what would say otherwise.
MAPPER_DETACH :: 7

BINDER_BOUND :: 1
BINDER_OPENED :: 2
BINDER_WROTE :: 3
BINDER_CLOSED :: 4
BINDER_AGAIN :: 5

/*
Where `painter` keeps its answers -- one cell per call, in call order.

The story is the framebuffer reached from ring 3. Open `/dev/fb` by the
path in slot A. Seek to the offset the kernel left in slot B, and record
what seek answered. Write the pixel bytes from slot C twice -- the second
write proves the descriptor's cursor carried, because its pixels land
after the first's. Seek back, read the same bytes into slot D, and close.
The kernel then looks at the screen, which is the half no cell can say.
*/
PAINTER_OPENED :: 1
PAINTER_SEEKED :: 2
PAINTER_WROTE :: 3
PAINTER_AGAIN :: 4
PAINTER_RESEEK :: 5
PAINTER_READ :: 6
PAINTER_CLOSED :: 7
PAINTER_BUFFER :: 40 // Byte offset 320 -- slot D, where the readback lands

/*
Where `catcher` keeps its answers -- one cell per claim.

The story is the note survived.

A `noted` before any delivery is refused. The handler registers, and the
program spins with a magic number parked in r13. The first note arrives at
the tick, mid loop. The handler counts it, copies the text's first eight
bytes out, trashes r13 on purpose, and answers NCONT. The second note
arrives while the program loops on `sleep`, which is the door's boundary.
After both, the program writes r13 to a cell -- the magic, twice restored
-- and exits zero, alive to choose to.
*/
CATCHER_EARLY :: 1
CATCHER_NOTIFIED :: 2
CATCHER_ROUNDS :: 3
CATCHER_HANDLED :: 4
CATCHER_TEXT :: 5
CATCHER_MAGIC :: 6

// The magic `catcher` parks in r13 across both deliveries, written here and
// as a movabsq in the blob. The two have to agree.
CATCHER_MAGIC_VALUE :: u64(0x13C0_FFEE_13C0_FFEE)

/*
The note `catcher`'s first delivery carries, written here and matched as
eight bytes in the check. Seven characters and the NUL make exactly one
cell, so every compared byte is one the kernel defined.
*/
CATCHER_NOTE :: "signal!"

// Where `dfltnote` keeps its answers. Its handler counts the delivery and
// answers NDFLT: the default action, which is the ending. A handler may
// look at a note and still decline it.
DFLTNOTE_NOTIFIED :: 1
DFLTNOTE_ROUNDS :: 2
DFLTNOTE_RAN :: 3

/*
Where `execer` keeps its answers, and the path it replaces itself with.

The story is the seam's other half. Write a mark to cell 0, then exec
`/bin/child`. On success the process is `child` from there on. It reaches
cell 0 with `child`'s own mark, and exits with `child`'s status, all under
`execer`'s pid. exec returns only on failure, and then cell 1 holds the
errno. The path rides in `execer`'s own text, like every string a blob
carries.
*/
EXECER_FAILED :: 1 // Only written when exec returns, which is only on failure
EXECER_PATH :: "/bin/child"

/*
Where `nowaiter` keeps its answers.

The story is a child no parent waits for. Fork with `RFNOWAIT`, and the
child is the kernel's from birth. The parent records the child's pid, tries
to `wait` for it, and hears ECHILD -- a detached child is nobody's to
collect from ring 3. The child writes a witness and exits, for
`reap_orphans` to find.
*/
NOWAITER_PID :: 1
NOWAITER_WAITED :: 2
NOWAITER_CHILD_RAN :: 8 // The child's witness cell, byte offset 64
// The kernel's word to the child, byte offset 72. The child holds still on
// it after its witness. The reaper collects a detached process the moment
// it ends now. A test that wants to look at one has to ask it to wait.
// Bounded the way `spin`'s is.
NOWAITER_CHILD_STOP :: 9

// What `nowaiter`'s child exits with, and the flags the fork takes:
// RFPROC to make a child, RFNOWAIT to detach it. Written twice, here and as
// immediates in the blob.
NOWAITER_CHILD_STATUS :: u64(0x5A)
NOWAITER_FLAGS :: u64(0x10 | 0x40)

/*
Where `bulkio` keeps its answers -- one cell per call, in call order.

The story is one big transfer in one call. Fill a stack buffer with a byte
ramp and open `/dev/fb`. Write the whole thing at an offset, seek back, and
read it all into a second buffer. The write and read counts are what matter.
Each must be the whole length, not a chunk of it, which is the bulk path's
point. The length is over the copy chunk, so the write and the read each make
more than one pass through the loop.
*/
BULKIO_OPENED :: 1
BULKIO_WROTE :: 2
BULKIO_READ :: 3

// How many bytes `bulkio` moves in one call, and where its buffers sit in the
// data page. Four thousand is over one `IO_CHUNK` (2048), so both the write
// and the read make two passes through the loop. It also fits a blob's one
// data page: the path at byte 32, the buffer at byte 96 through 4096. The
// framebuffer offset arrives as the program's third argument.
BULKIO_LEN :: 4000
BULKIO_PATH :: "/dev/fb"
BULKIO_PATH_OFF :: 32
BULKIO_BUF_OFF :: 96

/*
Where the two programs that reproduce keep their answers.

`child` and `parent` are the first blobs that carry their own strings, in
their own text, reached relative to the instruction pointer. Nothing stages a
path into their data pages, because nothing could. The kernel does not start
them, another program does. A file has no side channel. The cells below are
therefore answers only -- one per call, in call order, as always.
*/
CHILD_OPENED :: 1
CHILD_WROTE :: 2
CHILD_CLOSED :: 3

PARENT_SPAWN_A :: 1
PARENT_WAIT_A :: 2
PARENT_AGAIN :: 3
PARENT_BOUND :: 4
PARENT_SPAWN_B :: 5
PARENT_WAIT_B :: 6
PARENT_MISSING :: 7

/*
Where `poster` keeps its answers -- one cell per call, in call order.

The story the cells tell, in one pass. Open a connection, and reserve a name
in `/srv`. Write the descriptor into it, and mount the name. Reach the
console through the mount. Take the name away, and show the mount survives
it.

The descriptor it writes is the digit `3` in its own text. The first cell is
the check that 3 is what the open really returned.
*/
POSTER_OPENED :: 1
POSTER_CREATED :: 2
POSTER_WROTE_FD :: 3
POSTER_REWROTE :: 4
POSTER_CLOSED :: 5
POSTER_MOUNTED :: 6
POSTER_VIA :: 7
POSTER_WROTE :: 8
POSTER_REMOVED :: 9
POSTER_GONE :: 10
POSTER_AGAIN :: 11
POSTER_WROTE_AGAIN :: 12

// The line `poster` sends through the service it published, written twice in
// the blob's own text like every string a spawned program carries.
POSTER_LINE :: "-- this line went through a posted service"

/*
Where `niner` keeps its answers -- one cell per call, then a count that moves.

The story the cells tell. Make a pipe, and hold both ends. Reserve a name in
`/srv`, and write the client end's digit into it. Give both spent
descriptors back. Then serve: read a 9P request off the pipe, answer it, and
count it. The count is the one cell that changes while the kernel watches,
because the kernel is the client this time.
*/
NINER_PIPE :: 1
NINER_CREATED :: 2
NINER_POSTED :: 3
NINER_CLOSED_SRV :: 4
NINER_CLOSED_END :: 5
NINER_SERVED :: 6

// What `sys_pipe` answers `niner`: the serve end on 3 and the client end on
// 4, packed the way `child` packs its status. Descriptors 0 through 2 arrived
// occupied, which this number also proves.
NINER_FDS :: u64(4 << 8 | 3)

// What `niner` exits with when its byte stream ends before a Tremove does.
// Any number a deliberate exit never uses.
NINER_TORN :: u64(0x77)

/*
The line `niner` answers a Tread with, written twice like every string a
spawned program carries. Once here for the check, once as `.ascii` bytes in
the blob. Its length is hard-coded twice more, as immediates in the Rread
the blob builds. All four have to agree, and the check fails loudly when
they drift.
*/
NINER_READ_LINE :: "these bytes came from ring 3"

/*
Where `noter` keeps its answers -- one cell per call, in call order.

The story is the note's arc from ring 3. Spawn a child that loops for ever,
note it, and collect an ending the child never chose. The wait answers
EINTR, which is the kernel saying a note did this. Then note a pid that is
nobody's child, and hear ECHILD, which is the wall between one process's
authority and the table.
*/
NOTER_SPAWNED :: 1
NOTER_NOTED :: 2
NOTER_WAITED :: 3
NOTER_STRANGER :: 4

/*
Where `grouper` keeps its answers, which is the note group's arc from ring 3.

Two children, both sharing the data page under `RFMEM` so their counters
are the parent's to read. `A` is forked into the parent's own group. `B` is
forked with `RFNOTEG` into a group of one. Both count in a cell, for ever
or until a note ends them.

The parent notes its own group and expects one process to hear it. `A`
ends, noted, and `B`'s counter keeps moving across a sleep. Then a note by
pid ends `B`, which is how a group of one is reached at all.

`POSTED` is what `notepg` answered, and the claim is one, not two and not
zero. A fan-out that counted the poster, or that ignored the group, or that
reached nobody, each fails a different cell.
*/
GROUPER_A :: 1
GROUPER_B :: 2
GROUPER_POSTED :: 3
GROUPER_A_WAIT :: 4
GROUPER_B_MOVED :: 5
GROUPER_B_NOTE :: 6
GROUPER_B_WAIT :: 7
GROUPER_COUNT_A :: 8 // Byte offset 64
GROUPER_COUNT_B :: 9 // Byte offset 72

/*
Where the four rfork blobs keep their answers -- one cell per claim.

`forker` is the call-site continuation and the copy. It seeds a cell
*before* the fork, so both processes hold the seed. The child increments
its copy and exits with what it read. The parent's copy has to still hold
the seed when the kernel looks. Isolation is the number that did not
move.

`memfork` is the share, and the two lifetimes. The child writes a witness
into a cell the parent shares under `RFMEM`. Then it spins on a stop cell
the *kernel* writes, through the parent's data alias. The parent is dead
and collected by then, which is the whole parent-exits-first argument in
one handshake. The spin is bounded like `spin`'s, and the bound is written
twice for `SPIN_LIMIT`'s reason.

`fdforker` runs twice, its rfork flags arriving as the test's argument.
The child closes descriptor 1 and exits. The parent then closes 1 itself.
On a shared table the child's close already spent it, and the parent hears
EBADF. Under `RFFDG` the parent's copy still holds it, and the close
answers zero. One blob, two runs, and the flag is the only difference.

`refuser` holds the flag word to its refusals: each unimplemented or
contradictory word answers EINVAL, and the two harmless self forms answer
zero.
*/
FORKER_PID :: 1
FORKER_STATUS :: 3
FORKER_ISO :: 4
FORKER_SEED :: u64(10)

MEMFORK_PID :: 1
MEMFORK_WITNESS :: 2
MEMFORK_STOP :: 3
MEMFORK_WITNESS_VALUE :: u64(0xC0FF_EEC0_FFEE)
MEMFORK_GAVE_UP :: u64(0x99)
MEMFORK_PARENT_STATUS :: u64(42)

/*
Where the sharer keeps its answers. The parent takes a two-page run, forks a
sharer, grows the run by a page and writes a witness in the new page. Then it
shrinks the run to one page. The child reads the witness through its own tables
once told the grow happened, and touches the same page again once told the
shrink did. The second touch is a fault if the shrink reached it and a word in
`SHARER_SURVIVED` if it did not.
*/
MARK_SHARER :: u64(0x5348_4152_5348_4152) // SHARSHAR
SHARER_BASE :: 1 // The run's address
SHARER_GROWN :: 2 // The parent says the grow happened
SHARER_SEEN :: 3 // What the child read through the grown page
SHARER_SHRUNK :: 4 // The parent says the shrink happened
SHARER_PID :: 5 // The child's pid
SHARER_SURVIVED :: 6 // Written by the child only if the shrunk page still answered
SHARER_WITNESS :: u64(0xBEEF)
SHARER_PAGES :: 2

/*
Where `sharedseg` keeps its answers: in the shared page itself, because the
data page does not survive the exec the program ends with. The parent takes a
shared page and a private one, seeds both, and forks without `RFMEM`. The
child writes a witness into each and exits. The parent waits, reads both back
into the shared page, and execs `/bin/child`. The kernel then reads the shared
page through the segment the exec kept.
*/
SHAREDSEG_CHILD_WROTE :: 0 // The child's witness, in the shared page's first word
SHAREDSEG_SAW_SHARED :: 1 // What the parent read there after the child exited
SHAREDSEG_SAW_PRIVATE :: 2 // What the parent read in its private page
SHAREDSEG_SEED :: u64(0x11)
SHAREDSEG_PRIVATE_SEED :: u64(0x22)
SHAREDSEG_WITNESS :: u64(0x1111)
SHAREDSEG_PRIVATE_WITNESS :: u64(0x2222)

FDFORKER_WAITED :: 2
FDFORKER_CLOSED :: 3

REFUSER_ENVG :: 1
REFUSER_NOWAIT :: 2
REFUSER_LONE_MEM :: 3
REFUSER_BOTH_FDG :: 4
REFUSER_NOMNT :: 5
REFUSER_NOTHING :: 6
REFUSER_NOTEG :: 7

// The line the kernel writes through a mounted `/srv/niner`, which `niner`
// forwards to the console. It lives here rather than in the blob: the payload
// of a Twrite is the client's to choose, and the client is the kernel.
NINER_ECHO_LINE :: "-- a process answered this line"

/*
The line `child` writes, and the paths the two blobs open.

**Each of these is written twice**: once here for the checks, and once as
a literal inside the program that uses it. The pairs have to agree. There
is no way to share them: a ring 3 program cannot import the kernel, and the
kernel cannot import a program. That is `SPIN_LIMIT`'s problem again, with
the same answer: a check fails loudly when they drift.
*/
CHILD_LINE :: "-- a process started this one"

/*
What `child` exits with: its descriptor in the high byte, the bytes it wrote
in the low. One number that says the open landed on 3 -- so descriptors 0
through 2 were inherited, occupied -- and the write reported the whole line.
Both children exit with it: the one whose line reached the screen, and the
one whose line went to `/dev/null`. That is the point. The two runs differ
only in what the namespace did with the bytes.
*/
CHILD_STATUS :: u64(3 << 8 | len(CHILD_LINE))

// What `probe` adds up and sends to `SYS_ARGS`. Six powers of two, so a lost
// or duplicated argument register changes the sum rather than hides in it.
ARGS_SUM :: u64(1 + 2 + 4 + 8 + 16 + 32)

// What `hello` asks to exit with. Any number that is not zero and not a
// plausible byte count.
HELLO_STATUS :: u64(0x2A)

/*
Three values `probe` puts in registers a system call promises not to touch.

`r8` is caller-saved under the System V C ABI and preserved under this one,
which makes it the interesting one. The dispatcher is a compiled procedure and
is entitled to destroy it. The frame the stub builds is what stops it.

`r12` is callee-saved either way and would survive a lax stub by accident.
`xmm0` would not survive anything: Odin uses SSE registers for ordinary struct
assignment, so the first line of the dispatcher writes over it. Only the
`fxsave` in the stub brings it back.
*/
KEEP_R8 :: u64(0x1234)
KEEP_R12 :: u64(0x5678)
KEEP_XMM :: u64(0x9ABC)

/*
How long `probe` runs in ring 3 after its last `sysretq`, and why it runs at
all.

**`sysret` does not validate the selectors it loads.** It writes CS and SS from
`STAR` and sets the hidden descriptor caches to fixed values. Nothing checks
that the GDT entries behind those numbers mean anything. So a wrong user base
in `STAR` produces a program that keeps running, correctly, with nonsense in
CS.

The first thing that reads CS is an interrupt, which pushes it. So a program
that returns from a call and exits at once never gives anything the chance to
notice. This loop is long enough for the timer to preempt it several times,
which is what makes the return path observable. A control found the gap by
passing.

Twenty million rounds is about fifty ticks.
*/
PROBE_SPIN :: 20_000_000

/*
How many times `spin` goes round before it gives up on being told to stop.

A safety net rather than the mechanism. The kernel normally writes `STOP` once
the counter moves, and the loop ends within a few instructions. The limit is
what stops the machine when it does not.

That case is not hypothetical. A program entered with interrupts masked cannot
be preempted, so nothing else on the core ever runs. No bound the observer holds
can help, because the observer is not scheduled. A loop that ends on its own is
the only thing that survives it. See `docs/TESTING.md`.

**The number is written twice**, once here and once as `ROUNDS` in
`kernel/user/programs`, and the two have to agree. There is no way to share
it: a ring 3 program cannot import the kernel. That is the problem
`vector_has_error_code` has in `kernel/arch/amd64/idt.odin`, with the same
answer, a check that fails loudly.

`verify_spin` checks that the counter came back *below* this, which is the
claim that the kernel is what stopped the program. A limit smaller than the
program's would fail that check, and a limit the program can actually reach
fails it too.

Four hundred million rounds is about a second of emulated ring 3. That is about
fifty times what the program reaches before the kernel tells it to stop.
*/
SPIN_LIMIT :: 400_000_000

/*
The programs, as the bytes the loader copies.

Each is one Odin program in `kernel/user/programs`, compiled for the kernel's
own architecture and kept as a flat blob by `build.odin`, which refuses a
program that does not fit the page or wants a global. `#load` puts the blob
in the kernel's rodata, so `program_spin` is a slice of the image and copies
nothing. A build after the programs is what makes them current: the kernel's
own compile is what consumes the artifact.

The five that end without asking end on an undefined instruction, which is
what `programs.die` is on every architecture. The rest exit through the
door, and `parent`, `child` and the others that name a file carry the name
in their own text, reached relative to the program counter, because nothing
stages their data pages.
*/
program_spin :: proc "contextless" () -> []u8 {return #load("../../build/programs/spin.bin")}
program_poke :: proc "contextless" () -> []u8 {return #load("../../build/programs/poke.bin")}
program_peek :: proc "contextless" () -> []u8 {return #load("../../build/programs/peek.bin")}
program_priv :: proc "contextless" () -> []u8 {return #load("../../build/programs/priv.bin")}
program_jump :: proc "contextless" () -> []u8 {return #load("../../build/programs/jump.bin")}

// The ones that ask the kernel for something rather than have it refuse them.
program_hello :: proc "contextless" () -> []u8 {return #load("../../build/programs/hello.bin")}
program_probe :: proc "contextless" () -> []u8 {return #load("../../build/programs/probe.bin")}
program_shadow :: proc "contextless" () -> []u8 {return #load("../../build/programs/shadow.bin")}

// The ones that open files by name, in a namespace of their own.
program_namer :: proc "contextless" () -> []u8 {return #load("../../build/programs/namer.bin")}
program_reader :: proc "contextless" () -> []u8 {return #load("../../build/programs/reader.bin")}
program_binder :: proc "contextless" () -> []u8 {return #load("../../build/programs/binder.bin")}
program_painter :: proc "contextless" () -> []u8 {return #load("../../build/programs/painter.bin")}
program_bulkio :: proc "contextless" () -> []u8 {return #load("../../build/programs/bulkio.bin")}

// The ones that hold memory no file serves, or a device's.
program_mapper :: proc "contextless" () -> []u8 {return #load("../../build/programs/mapper.bin")}
program_anon :: proc "contextless" () -> []u8 {return #load("../../build/programs/anon.bin")}
program_sharer :: proc "contextless" () -> []u8 {return #load("../../build/programs/sharer.bin")}
program_sharedseg :: proc "contextless" () -> []u8 {return #load("../../build/programs/sharedseg.bin")}

// The ones that start, are started, become another program, or serve.
program_parent :: proc "contextless" () -> []u8 {return #load("../../build/programs/parent.bin")}
program_child :: proc "contextless" () -> []u8 {return #load("../../build/programs/child.bin")}
program_poster :: proc "contextless" () -> []u8 {return #load("../../build/programs/poster.bin")}
program_execer :: proc "contextless" () -> []u8 {return #load("../../build/programs/execer.bin")}
program_niner :: proc "contextless" () -> []u8 {return #load("../../build/programs/niner.bin")}

// The ones that post a note, catch one, or take the default.
program_noter :: proc "contextless" () -> []u8 {return #load("../../build/programs/noter.bin")}
program_catcher :: proc "contextless" () -> []u8 {return #load("../../build/programs/catcher.bin")}
program_dfltnote :: proc "contextless" () -> []u8 {return #load("../../build/programs/dfltnote.bin")}

// The ones that fork, by Plan 9's flag word.
program_forker :: proc "contextless" () -> []u8 {return #load("../../build/programs/forker.bin")}
program_memfork :: proc "contextless" () -> []u8 {return #load("../../build/programs/memfork.bin")}
program_fdforker :: proc "contextless" () -> []u8 {return #load("../../build/programs/fdforker.bin")}
program_refuser :: proc "contextless" () -> []u8 {return #load("../../build/programs/refuser.bin")}
program_grouper :: proc "contextless" () -> []u8 {return #load("../../build/programs/grouper.bin")}
program_nowaiter :: proc "contextless" () -> []u8 {return #load("../../build/programs/nowaiter.bin")}
