/*
Segments: the frames of a program, under an owner that can be shared.

Until this file, a process owned its frames directly: three named fields
for a blob, a receipt table for a compiled program. `unload` gave them
back. That arrangement has exactly one flaw, and `kernel/mem/space.odin`
names it: a frame mapped into two spaces has two owners and no count. The
day `rfork` maps one data segment into a parent and a child, somebody has to
know when the last user left.

A segment is that somebody. It is the frames behind one contiguous mapping,
with one reference count, and it answers the question the space deliberately
refuses to. `mem.space_destroy` keeps freeing page tables and never leaves.
A process releases its segments, and the *last* release frees the frames.

The division of labour, in one table:

    the space      owns its page tables, frees them, never touches a leaf
    the segment    owns the frames, frees them at the last release
    the process    holds references to both, and staging aliases to neither

`kind` exists for `rfork`'s copy rule, which is Plan 9's. Text is shared.
Writable data is shared only under `RFMEM`. A stack is always a private
copy at the same address. Writability alone cannot say which writable
segment is the stack, so the loader says it at birth.

**Device is the fourth kind and the one that owns nothing.** It is the
framebuffer, or whatever `vfs.chan_device` answers for next: memory this
allocator never handed out and must never hand back. Every fork shares it, for
the reason no other kind is shared unconditionally. There is one piece of
hardware, and a private copy of it is a contradiction.

**Anon is the fifth, and it is the device's shape with the ownership put
back.** It is memory a process asked for by the page rather than by the file.
A base and an extent describe it, for the reason a device needs them. A run of
a thousand frames does not fit a frame list.

It is the process's own, so the last release frees it. It is ordinary writable
memory, so `rfork` treats it as Data. `docs/DRAW.md` section 10 named the
trigger a milestone before the code. A window with pixels of its own is two
megabytes, and static `bss` was all a program had.

The two of them are the *run* shape, and `segment_is_run` is the one question
that separates the shapes from the kinds. Everything above this line treats
all five identically.

The pool is fixed, like `mem.spaces` and every other table a program could
make the kernel grow. One package spinlock guards the count, rather than a
bare increment, for the reason `Chan.refs` has a lock. An incref racing the
last release across a preemption either leaks the frames or frees them
live. Both failures are quiet.
*/
package user

import "kernel:arch"
import "kernel:mem"
import "kernel:sync"

/*
One contiguous piece of a run, past the first.

Four is the cap, and it is a cap on how many pieces a run may be in at once
rather than on how big it gets. A `segbrk` that adds pages adds a piece and one
that gives them back takes pieces away, so a run that grows and shrinks and
grows again stays inside it. It is a number to raise rather than a design.
*/
MAX_RUN_PIECES :: 4

Run_Piece :: struct {
	base:  uintptr,
	pages: int,
}

Segment_Kind :: enum {
	Text, // Read-only or executable: shared by every fork
	Data, // Writable, not a stack: shared under RFMEM, copied otherwise
	Stack, // Writable, and always a private copy
	Device, // Memory this allocator never owned: shared, and never freed
	Anon, // A run this allocator did own: asked for by the page, and freed
	Shared, // A run shared by every fork whatever the flags say, and kept by exec
}

/*
segment_is_run is which of the two shapes a segment has.

A base and an extent, or a list of frames. Device and Anon answer the first
way, because both are contiguous by construction and both can be larger than
`MAX_PROGRAM_FRAMES` will hold. Everything else answers the second, because
its frames arrived from the allocator one at a time and in no order.

Three places care: the frame question, the release, and the fork. The
predicate exists so each asks in one word, rather than naming the two kinds
again. A sixth kind then joins the right shape in one edit.
*/
@(private)
segment_is_run :: proc "contextless" (s: ^Segment) -> bool {
	return s != nil && s.run
}

// run_kind is whether a kind is born as a run: what `segalloc` and
// `segattach` make. A fork may give the same kind the list shape.
@(private)
run_kind :: proc "contextless" (kind: Segment_Kind) -> bool {
	return kind == .Device || kind == .Anon || kind == .Shared
}

/*
One contiguous mapping's frames, under one reference count.

**A run segment is described differently, and that is `MAX_PROGRAM_FRAMES`
talking.** Sixty-four frame numbers is a program. The framebuffer is about a
thousand pages and a window is five hundred, and a list holds neither. So a
run segment carries `base` and `pages` instead, and `frames` stays empty.

The two shapes could have been two types. They are one because everything
above this line treats them identically. A process holds a list of segments, a
fork walks it, and a teardown releases each. Only `segment_release` looks at
`kind`, and only to decide what there is to free and how.
*/
Segment :: struct {
	refs:   int,
	va:     uintptr,
	pages:  int,
	// The list shape: one frame per page, from the heap, grown as pages
	// arrive. Zero is a page with no frame yet -- a hole a fault fills.
	frames: []uintptr,
	// Which shape this is. A run keeps `pieces`; everything else keeps the
	// list. A copy-on-write child of a run is a list, because its frames
	// are the parent's one at a time and replaced one at a time.
	run:    bool,

	/*
	The run, for the run shape alone -- see `segment_is_run`. Empty for every
	other kind, which carry their frames one at a time above.

	**A run is a list of contiguous pieces, and almost always one.**
	`segalloc` makes it in a single allocation and `segattach` maps a card
	that is one by construction, so `piece_n` is one until something calls
	`segbrk`.

	Growing is what needs the second piece. The physical block behind a run
	cannot be extended in place -- the allocator has no promise to give --
	and *moving* it is worse than a list: another process may share this
	segment under `RFMEM`, mapping the old frames in its own space, and
	nothing here can reach that space to remap it. A new piece bolted on the
	end takes pages nobody had, so a sharer's mapping stays exactly as true
	as it was.

	Plan 9 needs none of this: its segments are a page map a fault fills in,
	so `ibrk` extends the map and nothing moves. This is the same idea with
	the pieces bigger.

	**The first piece is one of them.** An earlier cut kept it in a `base`
	field of its own, which made "how long is the first piece" a subtraction
	from `s.pages` written out at three call sites -- and the third got it
	wrong, deriving from a total one of its own loops had already invalidated.
	A uniform array cannot be got wrong that way.
	*/
	pieces:  [MAX_RUN_PIECES]Run_Piece,
	piece_n: int,

	flags:  arch.Page_Flags,
	kind:   Segment_Kind,
}

/*
The most segments a process can hold.

Four image rows and a stack was the whole list while a program's memory came
only from its file. Two calls widened it. `servers/intuition` is the process
that spends the most: three image rows, a stack, the framebuffer it attaches,
and one run of anonymous memory per window. That is seven at `MAX_WINDOWS` of
two, and the eighth is the spare that keeps this a decision rather than an
accident.

It is a cap to raise, and the thing to watch when raising it is that a window
costs a segment. `MAX_WINDOWS` and this number move together.
*/
MAX_PROC_SEGS :: 8

// The pool. Twelve processes of five segments is sixty at the ceiling, and
// the self-tests run mostly one program at a time. A full pool is ENOMEM to
// the loader, not a panic.
MAX_SEGMENTS :: 1024

@(private = "file")
Segment_Slot :: struct {
	seg:  Segment,
	used: bool,
}

@(private = "file")
segments: [MAX_SEGMENTS]Segment_Slot

@(private = "file")
seg_lock: sync.Spinlock

@(private = "file")
live_segments: int

Segment_Stats :: struct {
	live:   int, // Segments allocated and not yet fully released
	frames: int, // Frames those segments currently own
}

// segment_stats is the sensor the balance checks read. Modeled on
// `mem.space_stats`, and for the same reason: a teardown that leaks wants to
// be visible as a number, not as a slower machine.
segment_stats :: proc "contextless" () -> Segment_Stats {
	guard := sync.acquire(&seg_lock)
	defer sync.release(&seg_lock, guard)

	s := Segment_Stats{}
	for i in 0 ..< MAX_SEGMENTS {
		if segments[i].used {
			s.live += 1
			s.frames += segments[i].seg.pages
		}
	}
	return s
}

/*
What a sweep of one process's mappings found.

`segment_stats` is a count, and a count balances whatever the mapping says.
A run that grew onto frames it does not own maps them, writes them, reads
them back, and releases exactly the frames its record names. Every total
comes out even, and the frames that were somebody else's were never in any
of them. `docs/USER.md` recorded that as a control no check could see. This
is the check.

Three numbers, each a different way for the rule to be broken:

    stray      a leaf at an address no segment of the process covers. A
               shrink that freed and forgot to unmap, or a mapping made
               behind the segments' back.
    borrowed   a leaf inside a segment's extent whose frame the segment does
               not own. A `segment_frame` that answered the wrong frame, or
               a copy at fork that mapped the parent's frames as the child's.
    short      a segment page with no leaf under it. A run mapped part-way,
               or a sharer that never received a grow -- which is not a
               fault, and is why the caller decides what to make of it.

`leaves` is the walk's own count, kept so a caller can see that the sweep
looked at anything at all.
*/
Sweep :: struct {
	leaves:  int,
	stray:   int,
	borrowed: int,
	short:   int,
}

/*
sweep asks whether every frame a process maps belongs to one of its
segments, and answers by counting the ways it does not.

**The question is ownership, and deliberately not position.** A sharper
check asks whether page n holds the frame `segment_frame` answers for page
n. That check agrees with itself whatever `segment_frame` does, because
`map_run` installed exactly what `segment_frame` said.

The mutation this exists to catch is a `segment_frame` that reads every page
of a grown run out of its first piece. Under it, the mapping and the answer
are wrong together, and a position check passes. What that mutation cannot
fake is the record. The frames past the first piece's end are not in any
piece, and asking the pieces directly says so. So this reads `pieces` and
`frames` and never calls `segment_frame`.

**The caller holds the process still.** The walk takes no lock. The tables
and the segment list belong to the thread that runs the process. A lock that
thread does not take would not stop it.

A process that ended holds still by itself. A server parked between requests
holds still for as long as nobody sends one. Those are the two states the
self-tests sweep in.

`short` is the one number a healthy process may report. A run shared under
`RFMEM` and then grown by one holder maps its new tail in that holder's space
alone. The sharer never asked for it, and `segment_grow` says why nothing
here could reach the sharer's tables.
*/
sweep :: proc "contextless" (p: ^Process) -> Sweep #no_bounds_check {
	if p == nil {
		return Sweep{}
	}
	scan := Sweep_Scan{p = p}
	scan.found.leaves = mem.walk_user(p.space, &scan, sweep_leaf)

	// A hole -- a stack page nothing has reached -- has no frame and no leaf,
	// and is short of nothing. A run has a frame under every page.
	covered := 0
	for i in 0 ..< p.seg_count {
		s := p.segs[i]
		if s == nil {
			continue
		}
		if s.run {
			covered += s.pages
			continue
		}
		for j in 0 ..< min(s.pages, len(s.frames)) {
			if s.frames[j] != 0 {
				covered += 1
			}
		}
	}
	// Every leaf inside some segment's extent counts against that extent,
	// whether or not the frame under it was the right one. What is left is
	// the pages no leaf reached.
	scan.found.short = covered - (scan.found.leaves - scan.found.stray)
	return scan.found
}

@(private = "file")
Sweep_Scan :: struct {
	p:     ^Process,
	found: Sweep,
}

// sweep_leaf is one mapping, judged. Anything that is not one page is stray
// on its face, because nothing in this package installs a larger leaf.
@(private = "file")
sweep_leaf :: proc "contextless" (arg: rawptr, virt: uintptr, phys: uintptr, level: int) {
	scan := cast(^Sweep_Scan)arg
	s := segment_covering(scan.p, virt)
	if s == nil || level != 1 {
		scan.found.stray += 1
		return
	}
	if !segment_owns(s, phys) {
		scan.found.borrowed += 1
	}
}

// segment_covering is the segment whose extent holds an address, of any
// kind. `proc_segment_at` asks the same question of the run kinds alone,
// because `segbrk` may only be asked of those. A sweep has to answer for a
// stack page too.
@(private)
segment_covering :: proc "contextless" (p: ^Process, virt: uintptr) -> ^Segment #no_bounds_check {
	for i in 0 ..< p.seg_count {
		s := p.segs[i]
		if s == nil {
			continue
		}
		span := uintptr(s.pages) * uintptr(arch.PAGE_SIZE)
		if virt >= s.va && virt < s.va + span {
			return s
		}
	}
	return nil
}

// segment_owns is whether a frame is one the segment's record would free.
// The pieces for a run and the list for everything else, read directly --
// see `sweep` for why not `segment_frame`.
@(private = "file")
segment_owns :: proc "contextless" (s: ^Segment, phys: uintptr) -> bool #no_bounds_check {
	if s.run {
		for i in 0 ..< s.piece_n {
			piece := s.pieces[i]
			span := uintptr(piece.pages) * uintptr(arch.PAGE_SIZE)
			if phys >= piece.base && phys < piece.base + span {
				return true
			}
		}
		return false
	}
	for i in 0 ..< min(s.pages, len(s.frames)) {
		if s.frames[i] == phys {
			return true
		}
	}
	return false
}

/*
segment_new claims a slot with one reference and no frames yet.

Frames arrive one at a time through `segment_add_frame`, the moment each is
allocated. That ordering is the leak-safety rule `load_v2` already followed
for its receipt table. A loader that fails halfway leaves a partial segment
a release can still walk. This package maps nothing. The caller maps,
because the caller knows which space.
*/
@(private)
segment_new :: proc "contextless" (
	va: uintptr,
	flags: arch.Page_Flags,
	kind: Segment_Kind,
) -> ^Segment #no_bounds_check {
	guard := sync.acquire(&seg_lock)
	defer sync.release(&seg_lock, guard)

	for i in 0 ..< MAX_SEGMENTS {
		if !segments[i].used {
			segments[i].used = true
			segments[i].seg = Segment {
				refs  = 1,
				va    = va,
				flags = flags,
				kind  = kind,
			}
			live_segments += 1
			return &segments[i].seg
		}
	}
	return nil
}

/*
segment_frame is which frame backs a segment's nth page, whichever shape the
segment has.

One question, two answers. An ordinary segment kept a list, because its frames
came from the allocator one at a time and in no particular order. A run segment
is contiguous by construction, so it keeps a base and does the arithmetic.
Callers that map do not care which, and this is why.
*/
@(private)
segment_frame :: proc "contextless" (s: ^Segment, page: int) -> uintptr #no_bounds_check {
	if s == nil || page < 0 || page >= s.pages {
		return 0
	}
	if s.run {
		// One loop over the pieces, which for a run that never grew is one
		// iteration and the same arithmetic it always was.
		at := page
		for i in 0 ..< s.piece_n {
			if at < s.pieces[i].pages {
				return s.pieces[i].base + uintptr(at) * uintptr(arch.PAGE_SIZE)
			}
			at -= s.pieces[i].pages
		}
		return 0
	}
	if page >= len(s.frames) {
		return 0
	}
	return s.frames[page]
}

/*
segment_add_frame records one more frame as this segment's to free, growing
the list when it is full. Zero records a hole. False means the heap would
not give the list room, and the caller unwinds.

The list doubles, so a segment that grows a page at a time -- a stack, a
`segbrk` -- reallocates a logarithmic number of times. The old list is
freed after the copy, from the heap the kernel runs on.
*/
@(private)
segment_add_frame :: proc "contextless" (s: ^Segment, frame: uintptr) -> bool #no_bounds_check {
	if s == nil || s.run {
		return false
	}
	if s.pages >= len(s.frames) {
		want := max(16, 2 * len(s.frames))
		fresh, ok := mem.alloc(want * size_of(uintptr), align_of(uintptr))
		if !ok {
			return false
		}
		list := (cast([^]uintptr)fresh)[:want]
		for i in 0 ..< s.pages {
			list[i] = s.frames[i]
		}
		if s.frames != nil {
			_ = mem.free(raw_data(s.frames))
		}
		s.frames = list
	}
	s.frames[s.pages] = frame
	s.pages += 1
	return true
}

// segment_set_frame replaces the frame behind one page of a list segment:
// the copy a write fault made, in the seat the shared frame had.
@(private)
segment_set_frame :: proc "contextless" (s: ^Segment, page: int, frame: uintptr) #no_bounds_check {
	if s != nil && !s.run && page >= 0 && page < len(s.frames) {
		s.frames[page] = frame
	}
}

/*
segment_make_list turns a run into the list shape over the same frames, so
one of them can be replaced. A run is contiguous by construction and stays
so on the disk of the allocator; only the record changes, and every holder's
mapping is exactly as true as it was. The pieces go back frame by frame at
release, which `free_pages` does the same way.
*/
@(private)
segment_make_list :: proc "contextless" (s: ^Segment) -> bool #no_bounds_check {
	if s == nil || !s.run || s.kind == .Device {
		return false
	}
	want := max(16, s.pages)
	fresh, ok := mem.alloc(want * size_of(uintptr), align_of(uintptr))
	if !ok {
		return false
	}
	list := (cast([^]uintptr)fresh)[:want]
	for i in 0 ..< s.pages {
		list[i] = segment_frame(s, i)
	}
	s.frames = list
	s.run = false
	s.piece_n = 0
	return true
}

// segment_incref is one more holder. The lock, not a bare increment -- see
// the file comment.
@(private)
segment_incref :: proc "contextless" (s: ^Segment) {
	if s == nil {
		return
	}
	guard := sync.acquire(&seg_lock)
	s.refs += 1
	sync.release(&seg_lock, guard)
}

/*
segment_release is one holder gone, and the last one frees the frames.

The frees happen outside the lock. `mem.free_page` takes the PMM's own lock,
and holding two locks where one will do is how lock orders get invented by
accident. The slot is already unclaimed by then. A concurrent `segment_new`
reusing it sees a clean record rather than a half-freed one, because the
frames were copied out first.
*/
@(private)
segment_release :: proc "contextless" (s: ^Segment) #no_bounds_check {
	if s == nil {
		return
	}

	guard := sync.acquire(&seg_lock)
	s.refs -= 1
	if s.refs > 0 {
		sync.release(&seg_lock, guard)
		return
	}

	/*
	Three answers, one per kind of ownership, and the middle one is the trap.

	Device memory goes back to nobody, because it came from nobody. The frames
	behind a `.Device` segment are a card's, and the physical allocator never
	had them. On this machine they sit above every tracked frame, so a free of
	them is silent rather than fatal. That silence is exactly what makes the
	mistake worth guarding against here. `mem.free_pages` counts an untracked
	free now, so a control that removes this line raises a number instead of
	nothing at all.

	An `.Anon` segment shares the device's *shape* and none of that. It is a
	run this allocator handed out, so it goes back as a run, in one call. One
	control gives it back the device's way, which is to say not at all. That
	one fails the balance check by a page count rather than by a counter.

	Everything else frees its frames one at a time, because that is how they
	arrived.
	*/
	kind := s.kind
	run := s.run
	pages := s.pages
	pieces: [MAX_RUN_PIECES]Run_Piece = s.pieces
	piece_n := s.piece_n
	frames := s.frames
	s.frames = nil
	for i in 0 ..< MAX_SEGMENTS {
		if &segments[i].seg == s {
			segments[i].used = false
			break
		}
	}
	live_segments -= 1
	sync.release(&seg_lock, guard)

	if kind == .Device {
		// Nothing. See above -- this is the branch with a control on it.
		return
	}
	if run {
		// The shared class is a run this allocator owns, like an anonymous
		// one. What differs is who shares it and when, never who frees it.
		for i in 0 ..< piece_n {
			mem.free_pages(pieces[i].base, pieces[i].pages)
		}
		return
	}
	// A frame shared under copy-on-write comes back only from its last
	// holder; `free_page` counts. A hole was never anybody's.
	for i in 0 ..< min(pages, len(frames)) {
		if frames[i] != 0 {
			mem.free_page(frames[i])
		}
	}
	if frames != nil {
		_ = mem.free(raw_data(frames))
	}
}

/*
segment_run builds the run shape: one contiguous allocation of zeroed frames,
recorded as a base and an extent.

The zeroing is `mem.alloc_pages_zeroed`'s and is not optional. These frames
came back from a process that ended and go out to one that has not started.

Failure frees nothing, because a failure here allocated nothing. The caller
maps, and a caller that cannot map releases -- which is the same road every
other segment's failure takes.
*/
@(private)
segment_run :: proc "contextless" (
	va: uintptr,
	pages: int,
	flags: arch.Page_Flags,
	kind: Segment_Kind,
) -> ^Segment {
	if pages <= 0 || !run_kind(kind) {
		return nil
	}
	base, got := mem.alloc_pages_zeroed(pages)
	if !got {
		return nil
	}
	s := segment_new(va, flags, kind)
	if s == nil {
		mem.free_pages(base, pages)
		return nil
	}
	// Both before any caller can fail, so a release finds the whole run to
	// give back rather than half of one.
	s.run = true
	s.pieces[0] = Run_Piece{base = base, pages = pages}
	s.piece_n = 1
	s.pages = pages
	return s
}

/*
segment_one_page builds, records and maps the blob shape: one segment, one
zeroed frame, one mapping. The answer is the frame, for the staging aliases,
and zero for any failure.

Failure leaves nothing to chase. A segment that never reached the process's
list was released here. One that did is `unload`'s to release. The caller's
only move on zero is to unload, and both roads meet there.
*/
@(private)
segment_one_page :: proc "contextless" (
	p: ^Process,
	va: uintptr,
	flags: arch.Page_Flags,
	kind: Segment_Kind,
) -> uintptr {
	s := segment_new(va, flags, kind)
	if s == nil {
		return 0
	}
	frame, ok := mem.alloc_page_zeroed()
	if !ok {
		segment_release(s)
		return 0
	}
	_ = segment_add_frame(s, frame)
	if !proc_add_segment(p, s) {
		return 0
	}
	if mem.map_user(p.space, va, frame, flags, 1) != .None {
		return 0
	}
	return frame
}

// proc_add_segment puts a segment on a process's list, or releases it when
// the list is full. The release keeps the failure path one shape: a caller
// that sees false walks away, and the frames are already on their way back.
@(private)
proc_add_segment :: proc "contextless" (p: ^Process, s: ^Segment) -> bool #no_bounds_check {
	if p == nil || s == nil {
		return false
	}
	if p.seg_count >= MAX_PROC_SEGS {
		segment_release(s)
		return false
	}
	p.segs[p.seg_count] = s
	p.seg_count += 1
	return true
}
