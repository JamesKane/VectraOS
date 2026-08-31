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

Segment_Kind :: enum {
	Text, // Read-only or executable: shared by every fork
	Data, // Writable, not a stack: shared under RFMEM, copied otherwise
	Stack, // Writable, and always a private copy
	Device, // Memory this allocator never owned: shared, and never freed
	Anon, // A run this allocator did own: asked for by the page, and freed
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
segment_is_run :: proc "contextless" (kind: Segment_Kind) -> bool {
	return kind == .Device || kind == .Anon
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
	frames: [MAX_PROGRAM_FRAMES]uintptr,

	// Where the run starts, for the run shape alone -- see `segment_is_run`.
	// Zero for every other kind, which carry their frames one at a time above.
	base:   uintptr,

	flags:  arch.Page_Flags,
	kind:   Segment_Kind,
}

// The most segments a process can hold: four image rows and a stack. One
// spare keeps the count a decision rather than an accident.
MAX_PROC_SEGS :: 6

// The pool. Twelve processes of five segments is sixty at the ceiling, and
// the self-tests run mostly one program at a time. A full pool is ENOMEM to
// the loader, not a panic.
MAX_SEGMENTS :: 64

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
	if segment_is_run(s.kind) {
		return s.base + uintptr(page) * uintptr(arch.PAGE_SIZE)
	}
	return s.frames[page]
}

// segment_add_frame records one more frame as this segment's to free. False
// means the segment is at the format bound, and the caller unwinds.
@(private)
segment_add_frame :: proc "contextless" (s: ^Segment, frame: uintptr) -> bool #no_bounds_check {
	if s == nil || s.pages >= MAX_PROGRAM_FRAMES {
		return false
	}
	s.frames[s.pages] = frame
	s.pages += 1
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
	base := s.base
	pages := s.pages
	frames: [MAX_PROGRAM_FRAMES]uintptr = s.frames
	for i in 0 ..< MAX_SEGMENTS {
		if &segments[i].seg == s {
			segments[i].used = false
			break
		}
	}
	live_segments -= 1
	sync.release(&seg_lock, guard)

	switch kind {
	case .Device:
		// Nothing. See above -- this is the branch with a control on it.
	case .Anon:
		mem.free_pages(base, pages)
	case .Text, .Data, .Stack:
		for i in 0 ..< pages {
			mem.free_page(frames[i])
		}
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
	if pages <= 0 || !segment_is_run(kind) {
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
	s.base = base
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
