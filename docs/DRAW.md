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

**The geometry `ctl` reports is the window's, not the screen's.** Every
window is the same size, so one report answers for all of them. A client
learns how big it is and nothing about the glass, which is the second half
of a client not knowing where it is. The first half is that no verb reaches
past its window's edge.

A client session is a fid on `data`. 9P gives per-fid state for free, and
a clunk is the teardown: every image the session allocated is freed, and
the window goes back. Two clients hold two fids, never see each other's
ids, and cannot reach each other's pixels. This is simpler than Plan 9's
numbered directories, and it can grow into them without a wire change.

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

### A region, and the magic pixel it retired

Each window keeps two regions. `dmg` is what its client drew since its last
`flush`. `covered` is everything it drew since it opened, and it is what says
which pixels of a window are the window's.

**`covered` replaced a colour.** The milestone before this one spent a pixel
value on the question. A store began as zero and `composite` skipped zero, so a
window put on the glass only what its client drew. That worked, and it cost a
client the ability to paint `0x00000000`. The information belongs in a region
rather than in a pixel, and moving it there gave black back.

It also retired a memset. A slot's run outlives the session it was lent to,
because nothing gives a run back. So the last client's drawing is still sitting
in it, and clearing two megabytes at every `Tlopen` was how that stayed off the
glass. An empty `covered` says the same thing for nothing. A session that drew
nothing owns none of its window.

**A region is a bag of rectangles, not a partition.** Overlaps are allowed, and
that is the simplification the rest rests on. A region of disjoint rectangles
needs a subtract, a subtract needs a split, and a split is where rectangle
algebra goes wrong. Nothing here needs disjointness, because everything a
region drives is idempotent. Painting a pixel out of a window's store twice
puts the same value there twice.

`MAX_RECTS` is sixteen, and a full region collapses to its bounding box. That
is exactly what this file did one milestone ago, so the degradation is to the
last behaviour rather than to a wrong answer. A region is never smaller than
the truth, which is what makes the collapse safe.

`region_add` tries three cheaper answers before it appends: contained already,
side by side in the same band, or stacked in the same columns. The merge is
what keeps a line of glyphs from costing a rectangle apiece. `apps/terminal`
blits one image per glyph, forty-two across a line, each landing beside the
last with the same top and bottom. Its whole render is one rectangle, because
the field fill in front of the glyphs already contains them.

**A window still does not own its whole rectangle.** What lies under one is the
kernel's own boot chassis, and `covered` is what leaves it there. That is the
piece a desktop would change, and the next section is why there is not one.

### The desktop, and what it is actually waiting for

A desktop makes a window own its rectangle: black where the client has not
drawn, and no `covered` needed to hold the compositor back. It was the second
half of this milestone as `docs/HANDOFF.md` had it, and it is not here.

**The blocker is not graphics. It is that two things paint the glass.** The
kernel console draws the boot log straight into the framebuffer, and
`servers/intuition` draws into the same memory through `segattach`. A
compositor that owned the screen would paint over the log, and the log would
paint over the windows.

The idiom that settles it already exists one device away. `/dev/scancode` and
`/dev/eia0` **divert**: while a process holds one open, the kernel's own
handler sees nothing, and the last close gives it back. `/dev/fb` does not, and
that is the missing line. A compositor holding the screen open would own it,
and the console falls back to the serial port for as long as that lasts.

What stops that being a small change is the revert. The console scrolls by
moving pixels, so it holds no text to repaint from -- `kernel/log.odin` keeps
sixteen early lines and nothing more. A screen given back is a screen nobody
can redraw. So the desktop wants one of two things first: a console with a
scrollback, or a saved copy of the glass to hand back. **That is a devfs and
console milestone wearing a compositor's clothes.** `docs/HANDOFF.md` section 6
names it as its own item rather than as this one's tail.

### The controls for the compositor

Fourteen mutations across the two halves of this milestone, each on a real
boot. Thirteen are caught.

| Mutation | Result |
|---|---|
| `flush` does not composite | 20 checks, first `the fill landed on the glass, corner to corner` |
| a draw is owned but never owed | 20 checks, first the same |
| a draw is owed to the glass but never owned | 23 checks, first the same |
| the stack is walked front to back | 5 checks, first `half a window across, which is where the second window is` |
| the windows do not overlap | 5 checks, first the same |
| a region is a bounding box, the way damage used to be | 3 checks, first `the span between them is untouched` |
| a window that closes repaints nothing | 2 checks, first `a window that closes gives back the pixels it covered` |
| a flush composites only the window that asked | 1 check, `without lifting one pixel of it over the window on top` |
| a window covers its whole rectangle from the moment it opens | 1 check, `a pixel under both windows that neither drew is still the chassis` |
| a slot handed on keeps what the last session covered | 1 check, `a session that has drawn nothing covers nothing` |
| `region_add` never merges two rectangles into one | **inert**, and it is a speed mutation |

**The one-check catches are the ones that were designed for.** Each watches a
rule every other check in the file is blind to. The flush-one-window mutation
passes everything about coordinates and clipping. It fails only the check that
draws from *underneath* a window and asks whether the cover survived it.

**The inert one is inert honestly.** Merging rectangles changes how many a
region holds and never which pixels it means. Nothing a readback can see
distinguishes one rectangle from four covering the same band. It is in the
table because a speed mutation that failed a check would mean a check was
watching the wrong thing.

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

- **A desktop**, and the console divert it waits on. See above.
- **A pixel under two windows is written twice.** Front to back with
  subtraction spends each once, and needs the rectangle split a bag of
  rectangles exists to avoid. Worth it at more windows than two.
- **Nothing gives a run back.** A window's memory belongs to the slot rather
  than to the session, and a slot is never released. `segfree` is the Plan 9
  call that changes it, and `docs/USER.md` names it with the other two.
- **Placement is still fixed.** A window a client can move, resize, or raise is
  a `ctl` line, and `segbrk` is what a resize would need underneath it. A move
  is also the first thing that damages two rectangles far apart, which is the
  case `MAX_RECTS` was sized for and nothing yet reaches.

Two windows at 640 by 800 is 4 MB, which is `SEGALLOC_MAX` twice over.
`MAX_WINDOWS`, that bound, and `MAX_PROC_SEGS` are the three numbers that move
together, because a window costs a segment.
