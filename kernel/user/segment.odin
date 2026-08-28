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
}

Segment :: struct {
	refs:   int,
	va:     uintptr,
	pages:  int,
	frames: [MAX_PROGRAM_FRAMES]uintptr,
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

	for i in 0 ..< pages {
		mem.free_page(frames[i])
	}
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
