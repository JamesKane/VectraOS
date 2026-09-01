# Vectra `/dev/draw` -- the protocol over the screen's memory

Every other document in this directory records decisions after their code.
This one comes first, because the handoff called `/dev/draw` a protocol
question rather than a copy one. A protocol argued in prose is cheap to
change. A protocol argued in a served file is a client base. The decisions
here were settled before implementation, and the code that follows answers
to them.

## 1. What it is for, and what it is not

`/dev/fb` serves the screen's raw bytes at an offset, and `/dev/fbctl` its
geometry. That is enough for a painter and wrong for an application. An
application wants to say *fill this rectangle* and *blit that glyph*, not
to own pixel arithmetic and a four-megabyte repaint. `/dev/draw` is the
file that takes those sentences.

Three things it is not. It is not a new 9P message -- the wire stays
9P2000.L, and every verb below is the body of an ordinary `Twrite`. It is
not a mapping -- section 7 has that, and it is a private arrangement
between the server and the kernel. And it was not a *whole* compositor
until section 10's second half: windows, then stacking and damage.

## 2. The two clients

`apps/terminal` is the first client, and its needs list is short. Upload a
glyph set once, blit it thousands of times, fill a rectangle, scroll one,
place a cursor. Small commands, pixels resident on the server's side. That
client stands now, and the six verbs carried it without an addition.

`servers/intuition`, the compositor, is the second. It touches the whole
frame every round, and no command stream makes that cheap. It wants the
mapping. The reframe that shapes this design: under section 3's topology,
the compositor *is* the server. So the whole-frame path is a private
arrangement between one trusted process and the kernel, and never a
feature the protocol owes its clients.

## 3. Topology

The draw server is the first half of `servers/intuition`, with compositing
absent. It follows the tenant shape `kbdfs` and `eiafs` proved: the kernel
serves the raw resource, ring 3 serves the cooked one. The server opens
`/dev/fb`, posts `/srv/draw`, and repaints through bulk writes. A client's
command costs one extra hop, which is tolerable while pixels live
server-side and only commands cross per frame.

Compositing grew inside the same process, exactly as this said it would.
Image zero stopped being the screen and became the client's window.
**Nothing in the protocol changed** -- not a verb, not a body, not a rule.
A client written against v1 draws into a window without an edit. That was
the test this topology was chosen to pass, and it passed.

## 4. The file set

The server serves three files. `data` takes the command stream. `ctl`
takes text lines, the `/dev/consctl` convention, and answers a read with
a geometry. `draw` as a directory holds both.

**The geometry `ctl` reports is the window's, not the screen's.** A client
learns how big it is and nothing about the glass, which is the second half of a
client not knowing where it is. The first half is that no verb reaches past its
window's edge.

The report is built when it is asked rather than once at start, because a
client can change its own shape now. Reading it back is the only confirmation a
`ctl` line gets, and the only one it needs.

A client session is a fid on `data`. 9P gives per-fid state for free, and
a clunk is the teardown: every image the session allocated is freed, and
the window goes back. Two clients hold two fids, never see each other's
ids, and cannot reach each other's pixels.

**It grew into Plan 9's numbered directories, and the wire did not change.**
That prediction held. The tree is `/new` and a directory per window, and every
step of it is an ordinary walk of an ordinary name.

    /new       read it, and it answers which window has no session
    /N/data    the command stream, and the claim on window N
    /N/ctl     window N's geometry out, and its control lines in

The trigger was section 11's `ctl` lines. A flat tree could say how big a
window was, because every window was the same size. It could not say *which*
window a line was about, and a line that moves one has to.

`new` is advice rather than an allocation. It answers the lowest window with no
session, and the claim is the `Tlopen` of that window's `data`. A client that
loses the race between the two gets a refusal by name. Any allocator this
server could write would give the same answer.

`data` and `ctl` are both exclusive, one fid at a time. That is the whole of a
window's protection, and it is not much. A window whose client never opens its
own `ctl` leaves the controls for whoever asks. Users are what Plan 9 puts in
that gap, and there are none here.

## 5. The six verbs

The command stream is binary, little-endian, length-prefixed per command.
One 4 KiB write carries dozens of commands, which is what dissolves the
`IO_CHUNK` cost for an application. Six verbs are the whole vocabulary:

| Verb | Payload | Meaning |
|---|---|---|
| `alloc` | id, width, height | a server-side image, client-chosen id |
| `load` | id, rect, pixels | pixels into an image, format as `ctl` reports |
| `fill` | id, rect, color | one color across a rectangle |
| `blit` | dst id, dst point, src id, src rect | the workhorse |
| `free` | id | the image goes, the id may be reused |
| `flush` | none | what was drawn becomes visible |

Image zero is the session's window, never allocated and never freed. Ids are the
client's to choose, devdraw's rule, so no answer carries an allocation
back. Rectangles clip to their destination. Text, lines and fonts are a
client library over `blit`, not verbs. The six cover the terminal's whole
needs list, and scope creep is the failure mode this table guards.

A malformed command fails the whole write with `Rlerror`, devdraw's rule
again. A short count would leave the client to guess which commands ran.
The stream is not transactional beyond that: what stood before the bad
command already drew.

## 6. Flush means visibility

`flush` promises the drawing so far is visible, and promises nothing about
how it got there. It does not mean the server observed a write, and the
protocol nowhere assumes the server sees pixels only through `data`. That
one sentence keeps section 7 compatible: a mapped compositor satisfies the
same promise without a copy.

**It is the damage mark now, and that is the whole of section 10's second
half.** It was nearly a no-op for two milestones: a draw went straight to the
glass, so the promise was kept before the verb arrived. A window has pixels of
its own now. A draw lands in them, and this is what walks the damage onto the
screen.

**Not one client changed.** A client that already flushed was already correct,
which is what this section was written to guarantee. One that never flushed was
always wrong by this text and only now finds out. `apps/terminal` flushed from
the day it was written and needed no edit.

## 7. The mapping, and what it cost

Deferred once with its shape written down, then built when its trigger
arrived. The four costs this section listed before the code are the four
things that changed, and the list was right:

- **A `Segment_Kind` for device memory**, carried as base and extent. A frame
  list cannot express it: `MAX_PROGRAM_FRAMES` is 64 and the framebuffer is
  about a thousand pages. `Segment` carries a `base` for that kind alone, and
  `segment_frame` is the one question both shapes answer.
- **`segment_release` must not free device frames to the PMM.** It does not.
  The framebuffer sits above every tracked frame on this machine, so a free of
  it would have been *silent*. `mem.free_pages` counts an untracked free now,
  which is the move `docs/SPACE.md` made for the double free. That counter is
  what the control fails on.
- **The framebuffer's physical address, plumbed through.** One subtraction:
  Limine puts the screen in the direct map, so `mem.virt_to_phys` of the
  surface's pointer is the answer.
- **A syscall in the segattach shape.** `SYS_SEGATTACH`. A syscall is not a 9P
  message, so the wire rule of `docs/VECTRA9.md` stands untouched.

### The descriptor is what names the device

The one decision this section did not settle in advance. `segattach` takes an
open descriptor, not a class string out of a kernel table.

**The namespace is then what says which device, and whether this process may
have it.** A process that cannot open `/dev/fb` cannot attach it. A process
whose namespace binds something else over that name attaches the something
else. That is the permission story, and it came free rather than needing an
answer of its own.

The kernel asks the chan through `vfs.Server.device`, a second thing a server
may offer the *kernel*, beside `release`. `kernel/devfs` sets it and answers
for `/dev/fb` alone. Every other file is a stream, `/dev/fbctl` included.
Geometry is a report in text, and a text report is a stream however close it
sits to the pixels.

### What the server lost

`servers/intuition` has no write path left. It opens `/dev/fb` for the
namespace's sake, attaches it, and every draw after that is a store. Exit code
0x77 is a screen that would not map, and there is no fallback on purpose. **Two
paths to the same pixels would be two things to keep correct, and the self-test
could not say which one drew.**

The measurable effect is in the boot log. The system call count fell by about
a quarter, which is the seek and write per touched row that used to cross the
door.

## 8. The self-test

The painter test proved the idiom: write through a mount, read `/dev/fb`
back, compare the glass. The draw test is the same sentence one level up.
A known command stream goes to `data`, and the readback asserts the
rectangles and blit patterns it must have made.

The controls, per `docs/TESTING.md`. Drop clipping, and the readback
catches the out-of-bounds fill. Swap blit source and destination. Corrupt
one command mid-batch, and the whole write must answer `Rlerror`. Free an
image twice, and the id table must refuse the second. The balance sensor
is the session teardown: images live after a clunk must be zero.

Two limits recorded rather than hidden. Tearing and flush timing are
invisible to a readback. And a text check is pixel-exact only against the
baked font, so v1 checks rectangles and blits, not glyphs.

### The controls for the mapping

Seven mutations, each on a real boot.

| Mutation | Result |
|---|---|
| the teardown gives a device's memory back | 1 check, `with nothing offered back that it never owned` |
| every file in `#c` answers that it is memory | 2 checks, first `and answers that it is a stream` |
| a second attach lands on top of the first | 1 check, `a second attach is a second address` |
| the device mapping is executable | 1 check, `and never execute, because no card is code` |
| the device mapping carries no user bit | **the boot stops**, and the reason is below |
| `rfork` copies a device segment | **not caught**, and the mutation is inert |

**The uncaught one is inert for a stated reason.** Nothing forks a process that
holds a device segment. `intuition` does not fork and `consrv` has no card. It
becomes a real mutation the day the compositor forks a worker, which is
compositing's own milestone.

### The controls for windows

Six more, and all six are caught.

| Mutation | Result |
|---|---|
| a fill is not translated by the window's origin | 4 checks, first `the first landed at the screen's origin` |
| a fill clips to the screen rather than the window | 1 check, `and nothing at all past it` |
| a blit is not translated | 2 checks, first `which lands inside its own window` |
| a clunk does not give the window back | 2 checks, first `a clunk gives the window back` |
| `ctl` reports the screen instead of the window | 4 checks, first `and is narrower than the screen it does not name` |
| every session draws into window zero | 21 checks |

**The one-check catch is the interesting one.** The old edge test asked whether
a fill past the edge painted up to the last column. That passes whether the
bound is the window or the glass, because the window's last column is a real
column either way. The check that fails is the one added with this milestone,
and it watches the *first pixel a client may not have*.

### What a control found that the checks did not

Two things, and both are worth more than the mutation that exposed them.

**A check passed for the wrong reason.** The second-attach check asked only
whether the second address was *larger* than the first. Removing the bump made
the second attach fail instead, and a negative errno reads back as an enormous
unsigned number, which is larger. The check now asks whether the answer is an
address at all.

**A ring 3 server that faults mid-request leaves its client parked.** The
no-user-bit control kills `intuition` inside a `Twrite`, and the boot stops
rather than failing a check. The wire poisons on hangup, so the client should
get `EIO`. What stops it is that a killed process's descriptors wait for a
reap, and `reap_orphans` runs only from `spawn_path`. Nothing spawns again
during that test, so the pipe never hangs up.

That is a gap this milestone made reachable rather than created: before the
mapping, `intuition` could not fault. It is named in `docs/HANDOFF.md` section
6, and the fix is a process's descriptors closing when it stops running rather
than when somebody collects it.

**A third time, with windows, and the same shape.** The control that removed
the origin from `run_blit` passed everything. Every blit in the file came from
window zero, where translating by the origin is translating by nothing. The
second session blits now, from half a screen across, and the same mutation
fails two checks.

That is three for three: each time a control came back clean, the answer was
that the test never reached the code. `docs/TESTING.md` has it as the first
question to ask.

## 9. Staging

v1: the server in `servers/intuition/`, three files, six verbs, direct paint
through `/dev/fb`, a thin `sys/libdraw` encoder, the readback self-test.

v2: the mapping, section 7. The server paints through memory, and the protocol
did not change -- which was the test this topology was chosen to pass.

Deferred, each with its trigger: refresh events (windows), font verbs (never,
they stay a library), and window-backed images. That last one is what remains
of intuition's second half. Image zero stops being the screen and becomes the
client's window. `flush` becomes the damage mark, and the compositor walks
dirty rectangles into the memory it now holds.

## 10. Windows, and what a backing store would cost

Image zero is the session's window. A `Tlopen` on `data` takes one and a clunk
gives it back. Every draw to image zero moves by the window's origin and clips
to its extent. That is the whole of the isolation, and it is two lines in
`run_fill` and two in `run_blit`.

**The clip is in window coordinates, and the order matters.** Clipping against
the screen and then translating would let a client past its own edge and into
the window beside it. The control that swaps the order fails exactly one
check, and it is the check that watches the first pixel a client may not have.

### Placement is the server's, and says so

Two windows, and they overlap. A client cannot choose, cannot ask where it is,
and cannot ask for another. Section 5 names scope creep as the failure mode the
verb table guards. A window a client places is a `ctl` line that nothing yet
needs.

**They did not overlap while a window was a clip, and the placement was what
stopped them.** Two clients on one pixel would have taken turns destroying each
other's work, so the policy had to keep them apart. A window with pixels of its
own removed the reason, and the cascade below is what put the new rule under a
check. Window `i` sits half a window right of window `i-1`, and a higher slot
is higher in the stack.

`MAX_WINDOWS` is two for two reasons now. Two proves a second client cannot
reach the first's pixels. Two also proves that one client's pixels outlive the
other covering them. It is a cap to raise rather than a design. A third session
is refused at `Tlopen`, before it draws anything it would have to take back.

### What a backing store cost, and what it did not

A window with pixels of its own turns `flush` into the damage mark and stacking
into occlusion. It also makes a resize a repaint the client does not have to
make -- Plan 9's `segbrk`, which `docs/USER.md` records as missing. It needed
memory the server could not have:

- A 640 by 800 window is 2 MB.
- `MAX_PROGRAM_FRAMES` is 64, so one segment was at most 256 KB.
- `MAX_PROC_SEGS` is 6, so a whole process was at most 1.5 MB.

**A ring 3 program could not hold one window**, let alone two. Static `bss` was
all a program had, and the image format bounds it. So the trigger was named
here, and the thing it named was not a graphics question. It was a segment of
anonymous memory described by base and extent, the way section 7's device
segment already is. The PMM allocates contiguous runs, so what was missing was
a syscall and a kind rather than an allocator.

**Both arrived, and the prediction was exact.** `SYS_SEGALLOC` and
`Segment_Kind.Anon` are the whole of it, and neither is a graphics object.
`docs/USER.md` owns the call. Two sentences from that milestone are worth
carrying back here:

- The kind is the device's shape with the ownership put back. One predicate,
  `segment_is_run`, separates the two shapes from the five kinds, and the
  release, the frame question and the fork each ask it in one word.
- The call reuses `segattach`'s bump, so a device mapping and a run of memory
  cannot be handed the same addresses. One counter has no argument to make
  about which region grows into the other.

**Both arrived, and the prediction was exact.** `SYS_SEGALLOC` and
`Segment_Kind.Anon` are the whole of the memory half, and neither is a graphics
object. `docs/USER.md` owns the call.

## 11. The graphics half, and what a backing store turned out to retire

Each window holds a run of `win_w * win_h * 4` bytes. `run_fill` and `run_blit`
store into it, and the translation by the window's origin *left* those two
procedures. It lives in `composite` now, which is the only code that knows
where a window sits. A draw is one clip against the window's own bounds and
nothing else.

`flush` is the damage mark section 6 promised. It composites what this client
drew since it last asked, out of every window, back to front. Slot order is
stacking order, so a covered window paints first and the cover paints over it.
That sentence is all of occlusion -- there is no depth test and no per-pixel
owner.

**The event this design deferred was retired rather than built.** Section 9
listed refresh events with windows as their trigger. The trigger arrived and
answered the question the event was going to ask. A covered client is never
told it is covered, because it has nothing to redraw. Its pixels were its own
the whole time they were invisible, and the compositor puts them back from
memory it held.

A window that closes gives back what it was sitting on, and the client
underneath draws nothing to earn that. **That is what a backing store is**, and
it is the one check this milestone exists for.

### A window owns its rectangle, and what that took

**A desktop.** `DESK_GROUND` is `SLATE_DEEP`, and
`kernel/drivers/fb/palette.odin` comments that entry `Desktop ground` a
milestone before there was one. The grid is `VOID`, darker than the ground. A
lighter grid draws attention to itself and a darker one reads as engraved. That
is the trick `console.Style.Engraved` plays on text, and the reason the chassis
looks like metal. A window's own ground is `SLATE`, the palette's recessed well,
which is what a window is in this idiom.

A window is opaque over its whole rectangle now, so `composite` is a rectangle
intersection. The desktop is painted at start and where a window uncovers,
never per flush. Nothing else writes the glass while this server holds the
screen, so ground under a window that has not moved is still there.

**Two mechanisms died to get here, and both existed for one reason.** The first
was a magic pixel value. A store began at zero and `composite` skipped zero, so
a client paid by not being able to paint black. The second was a `covered` region
per window, which said the same thing without spending a colour. Each was a way
for a window to *not* paint its own blank rectangle, because what lay under one
was the kernel's boot chassis. Painting over it was worse than holding back.

There is ground under a window now, so neither is needed.

**The memset came back.** A slot handed to a new session has to be cleared.
Every pixel of a window is on the screen whether the client drew it or not.
That was two megabytes at each `Tlopen`, which `covered` bought its way out of.
A window that is a window rather than a stencil is what it buys.

*It went again in section 12.* A window frame paints its plinth's face over the
whole rectangle before it chisels anything, so the frame is the clear.

### A region, and what is left of it

Damage is still a region: a bag of rectangles whose union is what it means,
overlaps allowed, because everything it drives is idempotent. Painting a pixel
out of a window's store twice puts the same value there twice.

`MAX_RECTS` is sixteen, and a full region collapses to its bounding box, which
is what this file did two milestones ago. A region is never smaller than the
truth, which is what makes the collapse safe.

`region_add` tries three cheaper answers before it appends: contained already,
side by side in the same band, or stacked in the same columns. The merge is
what keeps a line of glyphs from costing a rectangle apiece. `apps/terminal`
blits one image per glyph, forty-two across a line, each landing beside the
last with the same top and bottom. Its whole render is one rectangle, because
the field fill in front of the glyphs already contains them.

The second region went with `covered`. What a window covers is its rectangle.

### The blocker was not a graphics one, and that is the whole lesson

A desktop was named as this milestone's second half, and it took two more to
arrive. Not because painting a background is hard, but because **two things
painted the glass.** The kernel console drew the boot log straight into the
framebuffer while this server drew into the same memory through `segattach`. A
compositor that owned the screen would have painted over the log, and the log
would have painted over the windows.

The idiom that settled it was one device away and already written.
`/dev/scancode` and `/dev/eia0` divert: while a process holds one open, the
kernel's own handler sees nothing, and the last close gives it back. `/dev/fb`
does the same now, and `docs/DEVFS.md` owns the mechanism and its controls.
What made it small is that the console needed no scrollback. It draws into a
shadow of the glass, and coming back is one blit.

So the graphics half of this section is four constants and a paint. Everything
that made it *look* hard belonged to another subsystem, and finding that out
was the work.

### Three lines, and the tree that had to grow first

    move X Y     put a window somewhere else
    size W H     make it another shape, inside the run it was born with
    raise        bring it to the front

**Three `ctl` lines rather than three verbs.** Section 5 guards that
distinction, and did so from the milestone there were six verbs and nothing
else. A verb is about pixels, and a window is not a pixel. What the lines cost
was not a verb but a tree, and section 4 has the numbered directories they
needed.

`raise` is why the stack became a list. Slot order was stacking order for two
milestones. That is the simplest rule with an answer for every pixel, and it
cannot also be a client's to change. A window's index is where its memory is.
Its place in the stack is where it is on the screen.

`move` is **the first thing in this server that damages two rectangles far
apart**. That is the case `MAX_RECTS` was sized for, and nothing reached it
until now. The old place and the new one are two entries in one region rather
than one box around both.

`size` moves a window's edges inside the run it holds and never past it. The
store is one `segalloc` run fixed at the birth size, and nothing in this kernel
grows a run in place. `docs/USER.md` names `segbrk` with the other two Plan 9
segment calls Vectra does not have. The stride does not move with the width, so
a pixel a client drew at `(x, y)` is still at `(x, y)` afterwards. Shrinking
loses the edges, growing brings back the band that was there before the last
shrink, and that band is cleared to ground.

**No event tells a client any of this happened, and none is needed: the client
asked.** A `ctl` read answers the new shape for anything that wants to be sure.
That is the third time a backing store retired an event this design once
expected to build.

## 12. Chrome, and one palette for both privilege levels

`kernel/splash.odin` paints the boot chassis. It says of itself that
`intuition`'s window frames should be recognisably the same object as the
screen the kernel painted before there was a compositor. That could not happen
while the vocabulary was a set of surface painters in ring 0.

**A piece of chrome is a list of coloured rectangles, and that is the whole
design.** `sys/libdraw`'s `panel`, `well` and `lamp` decompose and paint
nothing. The draw server paints into a window's store or onto the glass, and a
client sends `fill` commands down a pipe. A `Piece` carries an `RGB` rather
than a packed pixel word, so a third painter can pack against the mode the
bootloader actually set.

**That third painter is the kernel, and it is `fb.paint`.** Five lines walking
a `[]Piece` through `fill_rect`, which is the whole of what ring 0 had to grow.
`fb.bevel_edges` is `libdraw.edges` painted. `splash`'s console well is `libdraw.well`, the same call
`apps/terminal` sinks its field with through a pipe. `splash.draw_lamp` is
`libdraw.lamp`. The kernel's copy is gone rather than agreed with, and an unlit
jewel is `mix(colour, VOID, 200)` in one place.

**The face and the edges had to come apart to do it.** `panel` wrote a face and
then chiselled it, and two callers want the chiselling without the face. The
chassis draws its plinth with `brushed` and its copper bar with `gradient_v`,
and the desktop draws ground with a grid engraved in it. None of those three is
a rectangle. So `edges` is the walk and `panel` is a face in front of it, which
is also the honest version of what `desk_chrome` was doing when it asked for a
face and skipped the first piece.

What the rectangle model does not carry is the chassis's two richest surfaces.
`gradient_v` is a colour per row and `brushed` is a pattern per pixel, and
neither is a rectangle. **The chassis keeps both by painting them over the
decomposition rather than instead of it.** A lit jewel is a flat `Piece` that
`draw_lamp` then ramps and puts a specular pixel on. Ring 3 has neither and its
lamps are flat, and the state the rule is actually about -- an unlit lamp dark
in its own colour -- is a rectangle in both rings. A client that wants a
gradient sends one fill per row. **A gradient verb would be the seventh verb
section 5 guards against**, and a row of fills is what a client library is for.

### One table, both rings

The palette lived in `kernel/drivers/fb/palette.odin`. It promised there that
`intuition` would expose the same table. The boot splash, the panic screen and
the desktop are meant to be visibly the same machine. By the time there was a desktop,
three places had their own copy. The kernel's, the draw server's three
constants, and the terminal's two.

It is `sys/libpal` now, in the tree both privilege levels already import. `fb`
aliases every name, and `mix` and `shade` with them. Those two are the table's
own arithmetic rather than the surface's. `pack` stayed behind, because packing
is the one part that depends on the mode. Ring 3 reads the colours
through `xrgb`, or through the shift written against the table when it needs a
constant. `libpal` records that second shape rather than leaving each
call site to rediscover it.

All three copies are gone. The terminal's two, the kernel's, and the draw
server's three, which took a second pass: the first moved the table and left
the literals behind.

### What is wearing it

**The boot chassis.** The console well, the plinth's bevel, the copper bar's,
and every lamp in the indicator strip. It is the caller the vocabulary was
built for and the last one to arrive, and what it proves is the thing
`Piece.color` being an `RGB` was for: the same list of rectangles packs against
a 16-bit mode in ring 0 and against `/srv/draw`'s one depth in ring 3.

**The desktop is a recessed well.** The screen has the same two-pixel bevel
the chassis sinks its console into. The ground reads as sunk into a machine
rather than as a colour somebody chose.

**A lamp per window, down the right edge**, which is the one column of desktop
two half-screen windows never cover. Lit when that window has a session. A
compositor knows that and has nothing else worth a lamp yet. It is also the
first thing on this screen that reports state rather than draws pixels.

An unlit lamp is a dark version of its own colour rather than a neutral grey.
That sentence is `kernel/splash.odin`'s and so is the reason. A bank of lamps
with none of them on still reads as several of the same kind of thing. It is
the one part of the idiom that is a judgement rather than an arithmetic, and so
the part with a check on it.

**`apps/terminal`'s field is sunk into a well**, sent as ordinary fills. That
is the whole point of a vocabulary made of rectangles. The app draws the same
object the kernel draws, through a protocol that never learned what a bevel is.

**And a window is a raised plinth with a sunken screen in it**, which is the
chassis in one sentence. `window_frame` decomposes that into a bevel's edges
and two panels: the border, the copper bar across its top, and the well the
client area is sunk into. The draw server stores them into the window's own
run, so the compositor never learns there is a frame -- a window is still one
opaque rectangle backed by one segment.

**The decomposition is `sys/libdraw`'s; the numbers are the server's.**
`FRAME_EDGE`, `FRAME_TITLE` and `FRAME_WELL` sat in `libdraw` for one
milestone, which is a story about the test rather than about the vocabulary --
see "How the test knows where a window is" below. A window's border depth is
one server's layout, and no ring 3 client ever read it.

**The client area is the well's interior, and that is the whole cost.** A
client's (0, 0) moved in by the border, the bar and the recess. `ctl` reports
the client area rather than the window, `size` names the same rectangle, and
`run_fill` and `run_blit` clip to it and then move into it. A client is never
told there is a frame and no coordinate it sends means anything outside the
area it was given.

The translation this brought back is the one a backing store retired a
milestone ago, one level in. It used to move a client's rectangle onto the
glass, and got a check of its own because the wrong order let a client into the
window beside it. It moves a rectangle into the client area now, and the wrong
order lets a client onto its own border. Clip first, then move, for the same
reason and with a smaller consequence.

**And the frame is what clears a slot.** Its three parts tile the window
between them -- the plinth's edges take the border ring, the bar takes the rows
under it, and the well takes the rest -- so painting a frame writes every pixel
of the rectangle. That retired the two megabyte `memset` at every `Tlopen` and
the band clear at every `size`, both of which existed because there was nothing
else writing those pixels. A control confirms it: removing the frame from
`window_open` fails the stale-slot check as well as the frame ones.

The part that matters for disclosure is the *well's* face, and it is the part
that cannot come loose. The border and the bar sit strictly outside the client
area at every size a window can take, so nothing a previous session drew is
ever under them. A future bar that is a gradient rather than a rectangle would
stop tiling and would still not leak a pixel.

**The plinth has no face at all.** At `FRAME_EDGE` deep its three nested rings
are the whole border, so a face under them was half a megabyte of stores per
window that nothing ever saw. That is what `edges` exists apart from `panel`
for, and an assertion that the two depths agree is what keeps the tiling from
opening a gap.

### The name, and the font the server did not have

A fourth `ctl` line: `name TEXT`, and the bar says it.

**It is the one thing on this screen the server draws about a client's
window.** A client uploads its own glyphs as images and blits them, which is
section 5's answer to a font verb and stays the answer. A title is not the
client's text. So the server links `sys/libfont` -- the same 8x16 table the
kernel console draws with -- and stores the letters into memory no client can
reach. **No verb, and no font in the protocol.**

The line's operand is not a number, which makes it the only one `ctl_end` has
nothing to say about: every byte after the verb is the name, trimmed of space
and its newline. An empty name is a legal name and clears the bar.

`apps/terminal` sends `name terminal` before it uploads a glyph, and is the
first program in the tree to use the line.

### Focus, and what a title bar is for

**The window in front has the focus, and its bar is the lit copper.** Every
other bar is `COPPER_DARK` with `COPPER` above it and `VOID` below: the same
trim one step down the same table. It is the lamp's rule about an unlit
indicator applied to a surface, and for the lamp's reason -- a row of windows
with one of them in front still has to read as several of the same kind of
thing.

**Focus is not state.** It is `stack_top()`, which the stacking order already
answers, so there is nothing here for a second mechanism to fall out of step
with. `raise` moves the front and therefore moves the focus, with no second
call and no field to set. That is the whole of why this was one milestone's
smallest piece: the thing that would have been hard is a *policy* about which
window should be listened to, and there is only one policy a system with no
pointing device can have.

**What it cost is a repaint of two bars per stack move**, which is `refocus`.
At most two windows change whatever the move was -- the one that was in front
and the one that is now -- so a screen full of windows costs what a screen with
two costs. Three callers move the stack and all three call it: a window opens
over the front, a window closes and hands the front back, and a window is
raised.

**The close is the interesting one**, because it is the only path where focus
arrives at a window that did nothing to ask for it and is not told. The client
under a closing window was already drawing into its own store; it gets the
front, and its bar relights, and it is not consulted. That is the same property
the backing store has, one level up.

**The name did not change colour.** `TITLE_FG` is `SLATE_DEEP` on a lit bar
and on a dark one. An engraved wordmark is engraved whichever window the
machine is listening to, and what changes under it is the metal. So focus costs
the bar one colour and costs the name none -- and the sensor the name checks
read stayed put across the milestone, which is what a look that is layered
rather than substituted buys.

The first thing on this screen that reports **which client the machine is
listening to**, which is what a title bar is for and what the lamps could not
say. A lamp says a window has a session. The bar says which one is in front.

### What is not wearing it yet

**A window has no buttons on its frame** -- nothing to close, shade or resize
it with. All three exist as `ctl` lines already, so what is missing is a
pointer, and there is no pointing device in this system yet.

**Focus routes the keyboard now**, which is section 13.

### How the test knows where a window is

**It scans for it.** `verify_draw` asks a client to fill every pixel of the
area it was told it has, and reads the bounding box of that fill off the glass.
That box is the client area: where it starts is the frame's inset, and how big
it is is what the server actually gave.

**It used to compute the same thing from the server's own constants**, which is
why they were in `sys/libdraw` -- the kernel's self-test cannot import
`servers/`. `docs/TESTING.md` names agreeing with the code under test as the way
a check passes for the wrong reason, and this was exactly that: an inset both
sides read from one table made every mutation of a frame's *geometry*
unobservable. Only a server that stopped drawing a frame at all could fail.

Three things follow, and the third is the one that took a second pass:

    the report      a client fills what it was promised and gets exactly
                    that, which is the report answering for itself rather
                    than being restated
    the frame       the fill starts inside a border and further below a
                    title bar, and reaches neither
    the anchor      and it sits the same depth in from both of its
                    window's edges, because a border is a border

**The anchor is the one a discovery cannot do without.** A scan follows a
client's pixels wherever they went, so on its own it cannot say they went to
the wrong place: a server that translated one pixel too far is simply found one
pixel further along, and every check after it agrees. The window's own edges do
not move, and `win_right` finds them by walking out until the desktop begins.
That is also the first check to read **a window is opaque over its whole
rectangle** directly rather than through a client's pixels.

None of the three says how *deep* a frame is, and two mutations confirm it: a
deeper border and a taller bar are inert, because the report moves with them
and the test finds what it needs. That is a look rather than a fault, and a
test that failed on it would be over-specifying the design.

**And the desktop underneath is measured too.** The first cut restated
`desk_paint`'s own arithmetic -- the step, the phase, the two colours -- which
put the desktop's look back into the test at the moment the frame's was taken
out. A restyled desktop would then have failed the *frame's* anchor checks. The
draw server paints the whole desktop before it posts `/srv/draw`, so the glass
at that instant is a desktop with nothing on it: one run of one row gives the
ground, the grid and the step between grid lines. A flat desktop is now caught
by the one check that measures it rather than by six that stand on it.

The same idea runs twice more. `verify_terminal` finds its window as the first
run of not-desktop across a low row, and accepts it only when the client area
it then measures is as far up from the screen's bottom as it is in from the
side -- the same symmetry `verify_draw` anchors on. A half-composited window
fails that and the poll goes round again, which is self-validating where an
earlier cut assumed `paint_window` walks rows top to bottom. And a title bar is
read as the band between a window's top edge and its client area, rather than
looked up by its copper and then asked whether it is copper.

### The controls for chrome

Six mutations, each on a real boot. All six are caught.

| Mutation | Result |
|---|---|
| a window's store gets no frame when it opens | 12 checks, first `the window stands in a raised border, lit at its left edge like every panel in the chassis` |
| the client area is not sunk into a well | 10 checks, first `the window's own ground is the well it is sunk into, not the plinth around it` |
| a resize does not move the frame with the edge | 1 check, `and its frame moved to the new edge, over what the old one left in the run` |
| `ctl` reports the window rather than the client area | 29 checks, first `gets exactly the area it was promised, which is the report answering for itself` |
| a draw is not moved into the client area | 11 checks, first `inside a border, and further below a title bar, neither of which it is told about` |
| a draw is moved one pixel further in than the report accounts for | 6 checks, first `the same depth in from both of its window's edges` |
| `frame_client` and `frame_window` disagree by four columns | 2 checks, first the same |
| the desktop loses its grid | 9 checks, first `has painted a desktop, ground and grid, over the whole screen` |
| a deeper border | **inert**, and correctly so |
| a taller title bar | **inert**, and correctly so |
| the name is drawn in the bar's own colour | 2 checks, first `and the bar says so, in the font the draw server has and never gave a verb to` |
| a rename draws over the bar rather than repainting it | 1 check, `and takes the old one off with it` |
| every bar is the lit copper, focus or no focus | 3 checks, first `so the bar of the window it covered goes dark` |
| the focused bar is the dark copper and every other one lit | 5 checks, first `with a copper bar across the top of it, which is the chassis's own trim` |
| a window that opens does not take the focus | 2 checks, first `so the bar of the window it covered goes dark` |
| a window that closes does not hand the focus back | 1 check, `and the window under it comes to the front, which nothing had to ask for` |
| a raise does not take the focus with it | 1 check, `and takes the focus with it, because the front is the whole of what focus is` |
| a lamp does not light when its window opens | 1 check, `its lamp is lit, in the phosphor both sides of the door read from one table` |
| a lamp does not go out when its session does | 1 check, `its lamp goes out with its session` |
| an unlit lamp is a neutral grey | 1 check, `dark in its own colour, which is what an unlit lamp is` |
| a panel has a face and no edges | 1 check, `its field is sunk into a well` |
| a recessed bevel is lit from the top left | 1 check, the same |
| the terminal's field is a plain fill again | 1 check, the same |

**The lamp mutations are single checks, and that is the shape flat chrome has.**
There is no arithmetic in a lamp for a readback to catch sideways. Each rule
puts one colour at one place, so each mutation moves exactly one pixel the test
names. The interesting one is the neutral grey, the only rule in the set that
is a judgement rather than a consequence.

**A frame is not that shape, and three of its mutations found it.** Two were
inert on the first cut, because every other check in the file reads a pixel a
client drew or a pixel a client did not, and a window with no border is
neither. The frame needed sensors that name a *surface*: the border's highlight
at column zero, the bar's copper face, the well's slate ground. Each of those
is a colour out of `sys/libpal` that neither a client's fill nor the desktop
below could produce.

**And one mutation went through three answers before it got a right one.** A
server that reported the *window* rather than the client area sent every
readback off the bottom of the screen, because every row `verify_draw` read was
derived from that report. `fb.get_raw` has always bounded one pixel, but a save
and restore of a rectangle is a raw slice of `Surface.pixels`, and Odin does not
check those at all, so the boot faulted.

The first answer was a gate: the check returned as well as failed. Wrong
altitude -- the next sensor added above it is unprotected again. The second was
`fb.span`, a run of pixels bounded the way `get_raw` bounds one, which is right
and stands. The third is that the check itself was the wrong check: `fh ==
s.height` only ever compared the server's arithmetic with itself. What catches
it now is a client filling what it was promised and the glass saying it got
something smaller.

**Two mutations were unobservable until that landed**, and both are in the
table above: a draw moved one pixel too far in, and a report that disagrees with
the store by four columns. Neither changes whether a frame is drawn, which is
all the old checks could see.

**A mutation went away entirely, which is what one of the fixes was for.** A
blit that was not moved into the client area used to be its own row here. A
fill and a blit now make the same `client_clip` call, which clips and then
translates in that order because there is no way to ask for the other one. The
two can no longer disagree, so there is nothing left to mutate apart.

### The controls for the compositor

Twenty-six mutations across the milestones this section covers, each on a real
boot. Twenty-three are caught, two are inert, and one breaks the machine.

| Mutation | Result |
|---|---|
| `flush` does not composite | 20 checks, first `the fill landed on the glass, corner to corner` |
| a draw is owed to the glass but never marked | 23 checks, first the same |
| the stack is walked front to back | 5 checks, first `half a window across, which is where the second window is` |
| the windows do not overlap | 5 checks, first the same |
| a region is a bounding box, the way damage used to be | 3 checks, first `the span between them is untouched` |
| a window does not appear until its client draws | 3 checks, first `the second window covers ground no client has drawn on` |
| a window that closes repaints nothing | 2 checks, first `a window that closes gives back the pixels it covered` |
| a flush composites only the window that asked | 1 check, `without lifting one pixel of it over the window on top` |
| the desktop is never painted | 1 check, `where no window is left, the desktop is back` |
| a window that closes does not put the ground back | 1 check, the same |
| a slot handed on keeps the last session's pixels | 1 check, `covered where they meet a window whose session drew nothing` |
| the desktop has no grid on it | 1 check, `a grid engraved in it, a step apart from its ground` |
| `raise` does not change the stacking order | 1 check, `puts its own pixels over the window that was above it` |
| `composite` walks the slots rather than the stack | 1 check, the same |
| a move leaves the ground it was covering | 1 check, `leaves the ground behind where it was standing` |
| a window's `ctl` is not exclusive | 1 check, `a second holder of one window's controls is refused` |
| a session may claim a window another session holds | 13 checks, first `a window another session holds is refused to a third` |
| `region_add` never merges two rectangles into one | **inert**, and it is a speed mutation |
| a move damages one rectangle around both places | **inert**, for the reason below |
| a `size` may ask for more than the run holds | **the boot stops**, and that is the honest result |

**The one-check catches are the ones that were designed for.** Each watches a
rule every other check in the file is blind to. The flush-one-window mutation
passes everything about coordinates and clipping. It fails only the check that
draws from *underneath* a window and asks whether the cover survived it.

**Both inert ones are inert honestly, and they are the same fact twice.** A
region is a *bag*, and `composite` paints windows and nothing else. So a
coarser region paints the same windows over more ground, which costs time and
never a pixel. Merging rectangles cannot be caught, and neither can boxing a
move's two places into one. Both are in the table because a speed mutation that
failed a check would mean a check was watching the wrong thing.

**And one mutation is not a check's to catch.** Removing `size`'s bound against
the allocation lets a client write past its own `segalloc` run. The boot stops
rather than failing a check, and that is the right answer. The bound is memory
safety, and the thing that reports it is the fault handler.

### What two controls found that the checks did not

**Two places cleared the same state, so neither one held it.** `covered` was
emptied at `window_close` and again at `window_open`. Removing the one at open
changed nothing, because the one at close had already run. A mutation that
changes nothing is either inert or a duplicate, and this was the second. The
close-side clears are gone. `used` is the gate every reader passes, so a closed
slot's regions are out of reach until the session that reopens it empties them.

**And a check could not fail, for a reason that is worth more than the check.**
The first cut asked a reopened session to draw two far-apart pixels and looked
between them. It cannot fail whatever `covered` holds. A flush paints damage,
damage is what *this* session drew, and the store under it is therefore always
fresh. A stale `covered` is invisible from the window that has it.

What a stale `covered` actually does is let a window that drew nothing paint
over the window beneath it. So the client underneath is what has to ask
the question, and the check reads a pixel the window below repaints across the
overlap. That is five for five on `docs/TESTING.md`'s first question, and the
first time the answer was that the test was asking the wrong process.

### What is left

- **A pixel under two windows is written twice.** Front to back with
  subtraction spends each once, and needs the rectangle split a bag of
  rectangles exists to avoid. An opaque window is what finally makes it
  correct, so this is the first milestone where it *could* be done. Worth it at
  more windows than two.
- **Nothing on a frame can be pressed.** No close, no resize handle, no drag.
  Every one of those is a `ctl` line already, so what is missing is a pointing
  device, which this system does not have.
- **Nothing gives a run back.** A window's memory belongs to the slot rather
  than to the session, and a slot is never released. `segfree` is the Plan 9
  call that changes it, and `docs/USER.md` names it with the other two.
- **A window cannot grow past the run it was born with.** `segbrk` is the Plan
  9 call that would lift it, and `docs/USER.md` names it with the other two.
- **A window's `ctl` is exclusive and nothing else guards it.** A client that
  never opens its own controls leaves them for whoever walks to them. Users are
  the answer, and there are none.

Two windows at 640 by 800 is 4 MB, which is `SEGALLOC_MAX` twice over.
`MAX_WINDOWS`, that bound, and `MAX_PROC_SEGS` are the three numbers that move
together, because a window costs a segment. A frame costs none of it: the
border, the bar and the well are pixels inside the run a window already had,
and what they take is out of the client's area rather than out of memory.

## 13. The keyboard, and the window in front

A focused title bar reported which client the machine was listening to while
nothing was being sent there. This is the other half: **a window has a `cons`,
and a line typed at the keyboard goes to the window in front.**

### What 9front does, and what this server is therefore not

The design question was where the keystrokes come from, and `rio` answers it
plainly. `rio`'s `kbdproc` opens `/dev/cons`, writes `rawon` to `/dev/consctl`,
and prefers `/dev/kbd` when that exists. **It never opens `/dev/scancode.`**

`kbdfs` serves both of the files it does open, one process further out. That
program holds the raw stream and runs the state machine.

So a window system is not a keyboard driver, and this server does not become
one. What it diverts is still only `/dev/fb`. The scancode divert already
exists one tenant along, in `servers/kbdfs`, and the translation is written
once there rather than a third time here.

That corrects what the handoff predicted. It read the focus milestone as
wanting `/dev/scancode` diverted the way `/dev/fb` is. It does not: the glass
has one owner and the keyboard has a cooked file, and those are different
relationships with the hardware.

### The file, and the bind that makes it `/dev/cons`

`rio` serves a flat file set per window -- `cons`, `consctl`, `kbd`, `mouse`,
`label`, `wctl`, `winid` -- and `filsysmount` puts it in the client's
namespace with two calls:

```c
mount(fs->cfd, -1, "/mnt/wsys", MREPL, buf);   /* buf is the window's id */
bind("/mnt/wsys", "/dev", MBEFORE);
```

**The namespace picks the window, and the program reads plain `/dev/cons`.**
That is the whole idea, and it is why `rio` needs no cooperation from the
programs it runs. A window's id travels as the attach `aname`, because `rio`'s
file server has no directory per window to walk to.

This server does. Section 4's numbered directories are `devdraw`'s shape --
`Qtopdir`, `Qnew`, and `Q3rd` per client -- and they were already here. So a
walk names the window, and the bind is of that directory:

    bind /mnt/N /dev before

One bind shorter than `rio`'s and the same end state. `ORDER_BEFORE` rather
than replace, so `/dev/consctl`, `/dev/fb` and every other device still resolve
behind it, and only the names a window serves are taken over.

A window's directory therefore holds three files now:

    /N/data    the command stream, and the claim on window N
    /N/ctl     window N's geometry out, and its control lines in
    /N/cons    what was typed at window N, when window N was in front

`cons` is exclusive the way the other two are. Two readers of one window's
keyboard would each get part of every line, and which part is a race.

**A slot does not carry a queue across sessions**, which is the store's rule
one file along. A window's key ring outlives the session it was lent to exactly
as its pixels do, and a line typed at a client that never read it is still
sitting there. `window_open` drops the tail on the head, beside the frame that
paints over the last client's pixels, and the two are the same sentence about
two kinds of memory. The exclusive files go back at the same moment, so a
window's own client is never refused its own `cons` because somebody walked to
it while the slot was free.

The residual is the one `ctl` already had: a fid opened while another session
held the window keeps working after the slot changes hands. Nothing server-side
can revoke a fid, and users are what Plan 9 puts in that gap.

**Its size is what is waiting in it**, which `kbdfs` answers the same way. That
is what lets a queue be asked whether anything is there without reading from
it, and section 8 records what happens to a test that asks the other way.

### The cost: a second process, and a loop that can park

`libuser.serve` cannot park, and this server's own note said so -- one loop,
inline, nothing waits. A read of `cons` has to wait for a keystroke, so the
loop is `serve_mux` now, with a reader child forked over `RFMEM`, which is
`servers/consrv`'s shape and `servers/kbdfs`'s.

    the child    parks reading /dev/cons, and pushes each line into the
                 ring of whatever window is in front when it arrives
    the parent   serves 9P. A read of /N/cons drains that window's ring,
                 parking in a worker until a line is typed

**One loop still draws.** `blocks` claims exactly one message -- a read of a
window's `cons` -- so every message that moves a pixel is still answered
inline, in order, by the loop that owns `scratch` and the glass. A worker
touches its window's ring and the fid table, and neither a window's store nor
the framebuffer is reachable from it.

**And the loop refuses to park, which took a count to arrange.** `serve_mux`
answers inline when no slot is free, and that is right for every message here
except the one that waits. An inline `cons` read parks the loop that paints --
and `Tremove` is inline too, so a server stuck that way cannot even be stopped.
It is reachable: a worker whose client died polls a ring nobody will fill, so
abandoned reads accumulate until the pool is spent.

`cons_parked` is what makes the inline case identifiable from inside the
handler. At most `SLOTS` workers exist, so a `cons` read arriving with `SLOTS`
already parked is the inline one, and it answers `EAGAIN` instead of waiting.
`EAGAIN` rather than a short read, because a read of nothing means end of file
to every client in this tree.

**Focus is read when the line arrives**, not when the read was posted. That is
the honest rule for cooked lines: a line belongs to whoever had the focus at
the instant it completed, because that is the only instant the whole line
existed. `focus_win` reads the stack the way a second process must -- each half
once, and every answer bounds-checked -- because the parent moves the stack
between any two of the child's instructions. A torn read costs a line to the
window that was in front a moment earlier, which is inside the rule rather than
outside it.

### The defect this shape had, and section 14

The first cut left the editing state in `kernel/devfs`, shared by every
window, so a line half-typed when the focus moved went whole to the window
that had it when the newline landed. Section 14 is that fixed, the way `rio`
fixes it.

### What a client had to change

`apps/terminal` grew two calls -- the bind, and an open of `/dev/cons` after it
-- and its read loop changed which descriptor it names.

**The open is the part that is not free**, and it is worth knowing why. A bind
does not move a file somebody already holds open. Descriptor zero is the
console this program was *born* holding, from `open_standard`, so the bind
cannot reach it and the program has to open the name again to get the window's.
`rio`'s children are spawned into the new namespace and never hold the old one,
which is why `rio` needs no equivalent.

### The controls

| Mutation | Result |
|---|---|
| the reader drops every line | boot **hangs**, and see below |
| every line goes to window zero rather than the one in front | 2 checks, first `and in no other window, because a line belongs to the one in front` |
| a line goes to every window rather than the one in front | 3 checks, first the same |
| `cons` is not exclusive | 1 check, `and one reader of it, the way its data and its ctl are` |
| a slot keeps the last client's keystrokes | 3 checks, first `with nothing in it, because a slot does not carry the last client's keystrokes either` |

**One of those was inert on the first cut, and the fix was the test's.** A
server that sent every line to window zero passed every check, because window
zero is the window `verify_ctl` raises and the two answers agreed. A routing
rule checked in one direction is a rule agreeing with itself. `verify_cons`
raises the other window and makes the same claim again, so the second call
catches what the first cannot.

**The first one is the standing gap, not a missing check.** `verify_cons`
fails its own checks and does not hang. The read of a window's queue is gated
on the size, so a delivery that never happened fails rather than parks.

What hangs is `verify_terminal` afterwards. `apps/terminal` parks on a read
that will never answer, and the test then types `exit` at a program that cannot
hear it. `docs/HANDOFF.md` section 6 names the reason: a killed process holds
its descriptors until something reaps it, so nothing hangs up the pipe. It is
the same gap a control in section 8 found, from a different direction.

**A flushed read still answers, and that is not fixed here.** `Tflush` is
answered inline while the worker holding the flushed `Tread` stays parked, and
its `Rread` goes out later carrying the flushed tag. 9P wants no reply after
`Rflush`. The kernel's wire drops a reply naming no request in flight and
counts it, so the damage today is a wasted reply rather than a desync -- but a
client that reuses the tag first would take the stale `Rread` as the answer to
whatever it asked next. The cancel has to reach the worker, which is
`sys/libuser`'s to add and is the same standing gap the paragraph below is
about. `servers/kbdfs` and `servers/consrv` answer `Tflush` the same way.

**And one control was the test's own first cut.** Asking an empty queue with a
deadline read looked right and is not. The deadline flushes the request on the
wire and `serve_mux`'s worker never hears it, so every abandoned read left a
worker polling a ring for ever, and the server wedged once every slot was
spent. Three deadline reads is all it took. The size field is the way to ask,
and that is why `cons` answers one.

## 14. A line discipline per window

Section 13 left one editing state and it was the kernel's. **A line half-typed
when the focus moved went whole to the window that had the focus when the
newline landed**, and the window it was being typed into never saw the part it
was owed. This is that fixed, and the fix is `rio`'s.

### rawon, and what the kernel keeps

`rio` writes `rawon` to `/dev/consctl` and takes single characters. So does
this server now, and for the same reason: **a window system that cooks per
window has to be given the characters.**

`kernel/devfs` keeps its own discipline and still cooks `/dev/cons` for
everything that has not diverted the console. Nothing moved out of the kernel.
What moved is *which* discipline a window's client is behind, and the kernel's
`consctl_close` puts the console back when the draw server's descriptor goes --
so the mode is held for the server's life, the way `apps/terminal` holds its
own.

Raw mode turns the kernel's echo off with it, which is what `apps/terminal` was
writing `echooff` to do by hand. That write is now belt and braces: it happens
before the program mounts anything, so it still reaches `kernel/devfs`, and it
is no longer the thing that turns the echo off.

### The keys, which are `rio`'s

`rio`'s `wbswidth` decides how far back an erase goes, and it has three
answers. `erase_back` is that procedure:

    ^H, DEL     one character
    ^U          the whole line
    ^W          one word: the letters and digits before the cursor, and any
                spaces between them and it

**`^W` is the one the kernel never had**, and a window has it now. That is not
a divergence to go and close: 9front's kernel does no line editing at all, and
its two userland disciplines disagree on purpose -- `aux/kbdfs` erases back to
whitespace and `rio` erases back over letters and digits. A discipline belongs
to the layer that serves a `cons`, and this is one.

A newline finishes a line, and nothing else does. `^D` is `kernel/devfs`'s
end-of-transmission and this does not answer it: a partial line delivered with
no newline would break the one-line-per-read rule below, and an empty one has
to mean end of file, which is a claim about a window's life rather than about
its keyboard.

### One read, one line

`rio`'s cons drain copies from the window's output point and **breaks at the
newline**, so a program gets one line however many are queued behind it.
`ring_drain_line` is that rule, and it retired a defect a review found in
section 13's code: the server emptied its queue into one buffer, and
`apps/terminal` took the first line and dropped the rest.

The client-side workaround went with it. `apps/terminal` finds one newline
again, because the server's contract is back.

### The focus is read per character

Section 13 read it once per line, which was the bug. It is read once per
*character* now -- not once per chunk either, because a chunk carries whatever
arrived since the last read and the front can move between two of its bytes.

That is the whole of the fix. A character joins the line under construction in
the window that has the focus at that instant, and only a completed line
reaches a window's queue.

### A window's own consctl

`rio` serves a `consctl` per window and so does this. `/N/consctl` takes the
two words `/dev/consctl` takes, for the same two meanings:

    rawon     no line discipline: every character, the moment it arrives
    rawoff    the discipline above, and whole lines out

A read reports the mode as the word that would set it, which is
`docs/DEVFS.md`'s convention. The mode reverts to cooked when the fid that set
it closes, which is `/dev/consctl`'s rule kept: a client that died in raw mode
would otherwise hand the next one a window with no line discipline.

**Echo is not here**, because nothing in this server echoes. The kernel's
console draws typed bytes on glass it no longer owns, and a window's client
draws its own text out of glyphs it uploaded. There is nothing for an
`echoon` to turn on, which is why a window's `consctl` takes two words where
the kernel's takes four.

Switching mode drops the line under construction. Half a line edited under one
discipline is not a line under the other.

### The fence the test needed, and why it is not a delay

`verify_split` asserts what happens *between* two typed characters: `ab` at one
window, the front moves, `cd` at another. A self-test types into
`devfs.keyboard_sink` and the process reading it is somewhere else, so typing
and moving on races the draw server's child.

**A race here does not produce a wrong answer. It produces the old one** --
`abcd` arriving at one window, which is exactly what this milestone exists to
reject. So the first cut failed three checks for a reason that had nothing to
do with the code under test.

`devfs.cons_takes` is the fence: one of the counters `Cons` already keeps for
the boot report, exposed rather than added. `type_settled` types and waits
until the console says a reader consumed that many bytes. It is the only thing
in the system that says so, and `docs/TESTING.md` has nothing good to say about
the alternative.

### The controls

| Mutation | Result |
|---|---|
| one editing state for every window, which is what section 13 had | 3 checks, first `the window that took the front gets what was typed after it, and not before` |
| a read empties the queue rather than stopping at one line | 2 checks, first `and a read answers the first of them and stops at its newline` |
| `^W` is an ordinary character | 2 checks, first `and ^W takes one word, which the kernel's console never had` |
| a window's `consctl` does not revert when its fid goes | 1 check, `and the mode went back to cooked with the fid that set it` |
| the focus is read once per chunk rather than per character | **inert**, and see below |

**The first one is the milestone.** It is section 13's defect written out as a
mutation: one line buffer shared by every window, so `ab` typed at one and
`cd` at another come back as `abcd` to whichever finished the line.

**The inert one is inert because the test cannot reach it.** Reading the focus
once per chunk and once per character agree on everything a check can observe,
because `type_settled` waits for the child to consume a chunk before the front
moves -- and without that wait the check races and reports the old answer for
the wrong reason. To tell the two apart, a chunk boundary would have to
straddle a focus change, and nothing in a self-test can arrange that: the
chunk boundary is the child's read timing and the focus change is a 9P write
from another process.

Per character is kept because it is the finer of two answers that agree
wherever they can be compared, and because a raise arriving from another
process mid-chunk is real even when it is not reachable from here. That is the
same reasoning section 12 uses for a deeper border: inert, and correctly so.

**And one control used to hang instead of failing.** Emptying the queue leaves
the second read of a two-line check with nothing, and an ordinary read of an
empty queue parks for ever. That read is gated on the size now, so the control
reports as a failure. It is the same lesson section 13 learned one file along.

## 15. The echo, and which half holds the line

Section 14 gave every window a line discipline, and left a person typing into
one with nothing to look at until the line completed. **Nothing echoed.** The
kernel's console draws on glass it no longer owns, and `apps/terminal` drew
only finished lines.

### What Plan 9 does, and what this is not

The handoff predicted a read that answers a partial line, or an event a client
draws from. **Both are wrong**, and `rio` says so twice.

`rio`'s cons read gate scans from the window's output point for a `'\n'` and
sends nothing until it finds one. There is no partial-line read in Plan 9, and
there is nothing shaped like one.

The reason is that `rio` never needs it: **a `rio` window echoes because the
window is the text.** `wkeyctl` inserts the character into the window's own
buffer and the frame draws it. The program in the window reads finished lines
and draws nothing.

So the question is not how a server tells a client about a half-typed line. It
is **which half holds the line**, and Plan 9's answer is: whichever one draws.
Every program there that draws its own text takes the keyboard raw and edits
for itself -- `vt`, `con`, `ssh`, `sam` all write `rawon` and none of them ask
anybody what is in the line so far.

### So the terminal holds it

`apps/terminal` writes `rawon` to its own window's `consctl` and cooks the
line itself. It is the program that owns the pixels, so it is the one that can
show a character as it arrives.

**`/dev/consctl` is a different file than it was ten lines earlier in the same
program.** The `echooff` it writes at start reaches `kernel/devfs`, because it
happens before the bind. The `rawon` reaches its own window, because it happens
after. That is the namespace doing exactly what section 13 bound it for, and it
is worth reading twice.

**The server's discipline is not wasted by this.** Cooked is what a window's
`cons` is by default, and a client that only wants lines -- which is most of
them, and would be an `rc` here -- gets them without asking. The terminal is
the special case, exactly as `vi` is in a `rio` window. Section 14's split fix
holds either way, because the focus is read per character before the mode is
consulted at all.

### One discipline, two reasons to hold a line

`sys/libedit` is `rio`'s `wbswidth` as a package, and both callers wear it.
`servers/intuition` cooks a window's line because that is what a `cons` is.
`apps/terminal` cooks its own because it draws. Those are different reasons and
one set of rules, which is the same shape `sys/libpal` and `sys/libdraw` have.

    ^H, DEL     one character
    ^U          the whole line
    ^W          one word

`put` answers `Edited`, `Done` or `Full`. `Edited` covers an inserted character
and an erased one alike, because both mean the same thing to a program that
echoes: draw the line again. The newline is not stored, because the caller that
delivers a line wants one on the end and the caller that draws it does not.

**`kernel/devfs` keeps its own copy**, and that is the right answer rather than
a job left undone. 9front's kernel does no line editing -- `devcons.c` reads a
queue -- and the two disciplines it does have, in `aux/kbdfs` and in `rio`, do
not agree about what a word is. A discipline belongs to the layer that serves a
`cons`. The kernel serves one before any of this exists, and ring 3 serves two
that share these rules because they are one layer apart rather than two.

### What the echo looks like

`render` already filled the field before drawing, so an echo is that call on
every edit. A finished line leaves the field showing it: there is no scrollback
here, and clearing on Enter would take the answer away at the moment it
arrived. The next character clears it anyway.

### The check that could tell

**Every glyph check in `verify_terminal` read the field after a newline**,
where a terminal that only ever drew finished lines looks exactly like one that
echoes. The new checks read it *before* one, which is the whole difference, and
a control confirms it: a terminal that draws nothing on `.Edited` fails them
and passes everything else.

### The controls

| Mutation | Result |
|---|---|
| the terminal draws nothing until a line is finished | 8 checks, first `and yet appear on the glass, because the window that draws them holds the line` |
| the terminal asks for cooked rather than raw | 8 checks, first the same |
| `erase_back` forgets the word rule | 2 checks, first `and ^W takes one word, which the kernel's console never had` |

**The last one is what says the discipline is shared.** It mutates
`sys/libedit` and the checks it fails are `verify_cons`'s -- the *server's*
side, in a procedure that never goes near `apps/terminal`. One package, two
callers, and a control that reaches both from either end.

## 16. A cursor in the line, and what the arrow keys actually need

`docs/HANDOFF.md` named word erase and the arrow keys as the two things a
person wants next, and did so before there was a window. Section 14 gave a window
`^W`. This is the other one, and reading 9front changed what it is.

### The arrow keys are runes, and there are none here

In Plan 9 an arrow key is **a rune in the private Unicode space**.
`sys/include/keyboard.h` sets `KF = 0xF000` and `Kleft = KF|0x11`, so a left
arrow is U+F011 and arrives as three bytes of UTF-8 through the same stream a
letter does. `rio` reads it with `chartorune` and switches on the rune.

**Nothing in this tree speaks runes.** There is no UTF-8 anywhere in the
kernel or in `sys/`, and `kernel/drivers/kbd` consumes the `0xE0` prefix and
drops the key on purpose -- its own comment says ignoring the prefix "would
make the arrow keys type letters", because an extended code shares its second
byte with an ordinary one.

So the arrow keys are not a line-editing question at all. They are a rune
question, and that is a milestone of its own: a keyboard that emits runes, a
`/dev/cons` that carries them, and a decoder in every reader.

### What `rio` does with ordinary bytes

`rio` moves by a whole line with two control characters, and those are plain
single bytes there as here:

    ^A    Ksoh, 0x01, to the beginning of the line
    ^E    Kenq, 0x05, to the end of it

`sys/libedit` has both, with rio's values. A `Line` grew a `pos`, a character
goes in **at** the cursor rather than at the end, and an erase takes what is
**before** it -- which is `winsert` and `wdelete` over one line's worth of
buffer instead of a window's whole text.

An erase at the front of a line therefore takes nothing, because nothing is
behind the cursor. `rio` answers the same way: `wbswidth` is only ever called
after `if(w->q0==0 || w->q0==w->qh) return`.

**Both callers got it from one edit.** `servers/intuition` cooks a window's
line with a cursor now and needed no change at all. `apps/terminal` needed one,
because it draws.

### The caret, and what it cost the checks

**A caret is two pixels under a cell**, in the amber the glyphs are drawn in.
An underline rather than a block, because a block over a character hides the
character and this field has one line to show. A caret past the last glyph is
the ordinary case: it is where the next one goes.

That broke two checks, and the break was real rather than incidental. Both
compared a cell against a blank glyph, pixel for pixel, at a column the caret
now sits in. A caret *is* pixels in that cell.

So the test grew two readers. `caret_at` reads the bottom row of a cell and
asks whether it is all foreground. `cell_body_blank` reads the rows above the
caret's band and asks whether they hold a letter. The two checks that broke
became four that say more: no letter here, and the caret is here.

**`CARET_BAND` is deliberately looser than the caret is thick.** The test says
where the caret is and not how tall, so a thicker caret stays inert -- the same
choice section 12 makes for a deeper window border, and for the same reason.

### The controls

| Mutation | Result |
|---|---|
| a character appends rather than going in at the cursor | 1 check, `^A puts the cursor at the front, and a character goes in where it is` |
| `^E` does not move the cursor back | 7 checks, first `and ^E puts it back at the end, which is where it was born` |
| the terminal draws no caret | 8 checks, first `and the caret comes back with it, to where the next one goes` |
| an erase takes from the end rather than from before the cursor | 7 checks, first `and an erase at the front of a line takes nothing, because nothing is behind it` |

**The last one is the invariant, seen from outside.** `erase_back` never
answers more than the slice it gets, and the caller gives it `buf[:pos]`, so
what it answers can never exceed the cursor and the splice index can never go
negative.

**What that mutation does is not defined**, and it is worth saying so. Handing
`erase_back` the whole line makes `^A` then a backspace ask to move bytes from
in front of index zero, which under `#no_bounds_check` is undefined rather than
wrong. It stopped one boot outright and failed seven checks on another, from
the same mutation on either side of a cleanup that did not touch the arithmetic.
A control whose answer is undefined behaviour reports whatever the layout gives
it that day, and the checks above are what actually hold the invariant.
Hand it `buf[:n]` instead and `^A` followed by a backspace asks to remove one
byte from in front of position zero. The boot does not fail a check, it stops.

That is the third mutation in this document to report that way, and the shape
is always the same: a control that removes a property everything else stands on
does not report, it stops. A clamp in `put` would make it fail politely and
would also make the invariant untrue, so there is none.

## 17. Runes, so a key that is not a character can arrive

Section 16 gave a line a cursor and could not give it the arrow keys, because
an arrow produces no byte. `kernel/drivers/kbd` consumed the `0xE0` prefix and
dropped the key, and its own comment said why: an extended scancode shares its
second byte with an ordinary one, so translating it would make an arrow type a
letter.

`docs/KBD.md` listed "anything above 7-bit" and "the arrow keys, once there is
a cursor in the line under construction for them to move" as two of its
absences. The cursor arrived in section 16. This is both of them.

### The encoding is what lets a keyboard say more than a byte

**Plan 9's answer is that such a key is a rune.**
`sys/include/keyboard.h` sets `KF = 0xF000` -- the beginning of the private
Unicode space -- and gives every non-character key a value in it. `Kleft` is
`KF|0x11`, which is U+F011.

Every one of those is above `0x7F`, which is the whole trick: a stream carrying
UTF-8 carries them, and **no byte of ASCII can ever be mistaken for one**. The
encoding is not decoration on top of the keyboard. It is the thing that lets a
keyboard say something a byte cannot.

**The arithmetic is not this project's.** `core:unicode/utf8` is UTF-8, it is
`proc "contextless"` throughout, it allocates nothing, and it compiles under
the kernel's freestanding flags. A hand-written `chartorune` was a second copy
of a solved problem, and the first cut of this milestone had one.

`sys/libkey` is what a standard library cannot have: which numbers Plan 9 gives
to which keys. Seven constants out of `keyboard.h`, because they are a wire
format and both sides of `/dev/cons` have to agree about them.

### What the console had to be told after all

**The sink's contract changed under `kernel/devfs`, and the first cut did not
notice.** The console's line discipline refuses a control character -- `b <
0x20` -- and stored everything else. An arrow's bytes are `EF 80 91`, all above
`0x20`, so it stored three of them and echoed three glyphs nobody typed.

Nothing in that file had changed, which is exactly why it was easy to miss: the
*invariant* it relied on was retired instead. A byte from the sink used to be a
printable character or a control code, and now it can be a third of a key.

It refuses anything above 7-bit now, for the reason it refuses a bell: a
discipline over a 7-bit font should not store what it cannot spell. A
discipline that wants those keys decodes them, and `sys/libedit` is that one.
This is the console before any of it exists.

### Nothing else between the two ends learned anything

`kernel/drivers/kbd` encodes and `sys/libedit` decodes. In between, `step`
answers a rune where it used to answer a byte, and `deliver` pushes the bytes
that carry it.

**The sink stayed byte-wide.** ASCII is one byte and still arrives as one, on
the same branch it always took. A key with no character arrives as the three
its rune needs. The line discipline, the ring, `/dev/cons`, the window's `cons` and
`libuser.Ring` all carry them without knowing.

### Where the decoding has to live

`put` takes one byte at a time, so a rune above `0x7F` arrives across two or
three calls. The `Line` holds what it has in `pend` and answers `.Pending`
until the sequence is whole -- and every caller already had a branch for a byte
that changed nothing.

`utf8.full_rune_in_bytes` is what answers "is it whole yet", and it is the
right question to have asked someone else: it calls an *invalid* lead byte
full, so a stream that started mid-rune resolves to `RUNE_ERROR` here rather
than waiting for bytes that can never make it well-formed.

That is why the decoding is in `sys/libedit` and not in either caller: both
would otherwise need the same partial-sequence buffer, and one of them is a
server cooking two windows at once.

### Only ASCII is stored, and that is a cost rather than a rule

**A rune the line does not act on is dropped.** `sys/libfont` is an 8x16 table
of 7-bit characters, so there is no glyph for anything else -- a line that
stored one would hold bytes no caller can draw, and a caller that invented a
glyph would be inventing the layout with it.

So this milestone carries the runes a keyboard makes and not the ones a
language needs. What it would take to store them is a font with more than 128
entries and a `put_text` that advances by rune rather than by byte, and neither
is a keyboard question.

### The controls

| Mutation | Result |
|---|---|
| the driver drops extended keys again | 2 checks, first `and the key behind it is a left arrow, as the rune Plan 9 names` |
| a left arrow moves the cursor right | 2 checks, first `a left arrow moves the cursor one character, and it arrives as a rune` |
| a rune with no meaning is stored rather than dropped | 1 check, `a rune the line has no use for leaves nothing behind, because it has no glyph either` |
| the console stores what it cannot spell | 1 check, `an arrow key's rune is refused rather than stored as the bytes that carry it` |
| the driver stops taking the ASCII branch | **inert**, and correctly so |

**The inert one is a pure optimisation.** `utf8.encode_rune` answers the same
single byte for ASCII that the branch in front of it does, so removing the
branch changes what the keyboard costs and not what it says. A check that
failed on it would be measuring the shape of the code rather than its
behaviour.

**One control retired with the code it tested.** The first cut rejected
overlong encodings by hand and nothing could observe the rule: every rune this
line acts on is `KF|n`, at least `0xF00D`, which needs three bytes in its
*shortest* form -- so no overlong spelling of one exists, and an overlong
sequence always decodes to a rune the line drops anyway. The rule now belongs
to `core:unicode/utf8`, which is the right place for a property that is about
the encoding rather than about this system.
