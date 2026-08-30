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
not the compositor -- windows, damage and stacking come later, and the
protocol must merely not block them. And it is not a mapping -- section 7
defers that deliberately, with its shape written down.

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

When compositing arrives, it grows inside the same process. Image zero
stops being the screen and becomes the client's window. Nothing in the
protocol changes, and that is the test that chose this topology.

## 4. The file set

The server serves three files. `data` takes the command stream. `ctl`
takes text lines, the `/dev/consctl` convention, and answers a read with
the geometry `/dev/fbctl` reports. `draw` as a directory holds both.

A client session is a fid on `data`. 9P gives per-fid state for free, and
a clunk is the teardown: every image the session allocated is freed. Two
clients hold two fids and never see each other's ids. This is simpler than
Plan 9's numbered directories, and it can grow into them without a wire
change.

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

Image zero is the screen, never allocated and never freed. Ids are the
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
same promise without a copy. In v1 the screen is drawn directly and
`flush` is nearly a no-op. When image zero becomes a window, `flush` is
the damage mark.

## 7. The mapping, deferred with its shape written down

v1 changes the kernel not at all, which is the scope cut the handoff
asked for. The mapping lands as the compositor's own milestone, and it
costs exactly this:

- A `Segment_Kind` for device memory, carried as base and extent. A frame
  list cannot express it: `MAX_PROGRAM_FRAMES` is 64 and the framebuffer
  is about a thousand pages.
- `segment_release` must not free device frames to the PMM. Today it
  unconditionally does, which would free live MMIO on the last release.
- The framebuffer's physical address, plumbed through. `fb.Surface` holds
  only Limine's HHDM pointer, and the physical base is that less the
  offset.
- A syscall in the segattach shape. A syscall is not a 9P message, so the
  wire rule of `docs/VECTRA9.md` stands untouched.

The trigger is named: the day intuition composites whole frames every
round, not before.

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

## 9. Staging

v1: the server in `servers/intuition/`, three files, six verbs, direct
paint through `/dev/fb`, a thin `sys/libdraw` encoder, the readback
self-test. Deferred, each with its trigger: the mapping (whole-frame
compositing), refresh events (windows), font verbs (never -- they stay a
library), window-backed images (intuition's second half).
