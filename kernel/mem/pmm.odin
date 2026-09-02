/*
The physical memory manager: one bit per page frame, 1 meaning taken.

A bitmap rather than a free list, for two reasons. A free list has to live *in*
the pages it tracks, so a page fault at the wrong moment corrupts the allocator
itself.

And contiguous multi-page allocation is a run search over a bitmap, against a
linear walk over a list. The VMM needs that for tables, and the heap needs it
for large objects.

The cost is a scan. Two things bound it. A rotating hint sits at the last
allocation, and a skip passes fully-occupied bytes eight frames at a time. That
matters, because the common shape of kernel memory is a long taken prefix
followed by a long free tail.

The bitmap covers every frame from 0 to the top of allocatable memory, holes
included: the hole frames are simply born taken and never freed. Indexing by
`phys / PAGE_SIZE` with no base to subtract is worth more than the handful of
kilobytes that costs.
*/
package mem

import "base:intrinsics"

import "kernel:sync"

@(private = "file") bitmap: []u8
@(private = "file") frame_total: int // Frames the bitmap covers, holes included
@(private = "file") frame_usable: int // Frames that were ever free
@(private = "file") frame_free: int
@(private = "file") double_frees: int
@(private = "file") untracked_frees: int
@(private = "file") frame_peak: int // High-water mark of frames in use
@(private = "file") bitmap_frame: int // Where the bitmap put itself
@(private = "file") bitmap_frames: int
@(private = "file") hint: int

Pmm_Stats :: struct {
	total_frames:  int,
	usable_frames: int,
	free_frames:   int,
	double_frees:  int, // Frames released while already free -- always a bug
	untracked_frees: int, // Frees of an address outside the bitmap -- see `free_pages`
	peak_frames:   int,
	bitmap_bytes:  int,
	bitmap_phys:   uintptr,
}

pmm_stats :: proc "contextless" () -> Pmm_Stats {
	return Pmm_Stats {
		total_frames  = frame_total,
		usable_frames = frame_usable,
		free_frames   = frame_free,
		double_frees  = double_frees,
		untracked_frees = untracked_frees,
		peak_frames   = frame_peak,
		bitmap_bytes  = len(bitmap),
		bitmap_phys   = uintptr(u64(bitmap_frame) * PAGE_SIZE),
	}
}

// -- Bit twiddling -----------------------------------------------------------

@(private = "file")
frame_taken :: proc "contextless" (frame: int) -> bool #no_bounds_check {
	return bitmap[frame >> 3] & (1 << uint(frame & 7)) != 0
}

@(private = "file")
take :: proc "contextless" (frame: int) #no_bounds_check {
	mask := u8(1) << uint(frame & 7)
	if bitmap[frame >> 3] & mask == 0 {
		frame_free -= 1
	}
	bitmap[frame >> 3] |= mask
}

@(private = "file")
release :: proc "contextless" (frame: int) #no_bounds_check {
	mask := u8(1) << uint(frame & 7)
	if bitmap[frame >> 3] & mask != 0 {
		frame_free += 1
	} else {
		/*
		A frame freed twice, counted rather than ignored.

		The count was already safe. A second release finds the bit clear and does not
		raise `frame_free`, so the arithmetic stays true whatever a caller does. What it was not, was *visible*. A double free is
		always a bug in the caller, and an allocator that absorbs it silently is
		an allocator that hides one.

		A count rather than a stop, because this is the physical allocator and
		the panic screen it would reach for needs frames of its own. A self-test
		that brackets this sees a number that should be zero, which is what
		found the first one -- see `docs/SPACE.md`.
		*/
		double_frees += 1
	}
	bitmap[frame >> 3] &~= mask
}

// -- Bring-up ----------------------------------------------------------------

/*
pmm_init builds the bitmap out of the memory map and puts it somewhere.

The bitmap needs memory, and memory needs the bitmap. The usual order solves
that bootstrap problem:

Pick a home for the bitmap by hand out of the raw map. Declare everything
taken. Free the allocatable regions wholesale. Then take the bitmap's own
frames back. The last step is why the first pass cannot simply avoid the
bitmap's range, and skip the second.

Frames are page-aligned inward, never outward. A region that runs from the
middle of one page to the middle of another contributes only the whole pages
strictly inside it. Rounding the other way would hand out a frame that overlaps
something the firmware still owns.
*/
@(private)
pmm_init :: proc "contextless" (b: ^Boot_Memory) -> Error {
	top: u64
	for r in regions(b) {
		if !allocatable(r.kind) {
			continue
		}
		if end := r.base + r.length; end > top {
			top = end
		}
	}
	if top == 0 {
		return .No_Usable_Memory
	}

	frame_total = int(align_up(top, PAGE_SIZE) / PAGE_SIZE)
	need := u64(frame_total + 7) / 8

	home, found := find_bitmap_home(b, need)
	if !found {
		return .Bitmap_Wont_Fit
	}

	bitmap_frame = int(home / PAGE_SIZE)
	bitmap_frames = int(page_count(need))
	bitmap = (cast([^]u8)phys_to_virt(uintptr(home)))[:need]

	// Everything starts taken, so a frame the firmware never described -- a
	// hole in the map -- is never handed out by omission.
	for i in 0 ..< int(need) {
		bitmap[i] = 0xFF
	}
	frame_free = 0

	for r in regions(b) {
		if allocatable(r.kind) {
			release_range(r.base, r.length)
		}
	}
	frame_usable = frame_free

	for i in 0 ..< bitmap_frames {
		take(bitmap_frame + i)
	}

	// Frame 0 stays taken forever. Base revision 6 allows the firmware to call it
	// usable. A kernel that hands it to a caller loses the one thing that makes a
	// null dereference report itself as a fault. Without it, that dereference
	// quietly reads a page of somebody's data.
	take(0)

	hint = 0
	return .None
}

/*
find_bitmap_home picks a physical home for the bitmap out of the raw map.

First fit, skipping frame 0 for the reason above. Deliberately not best fit.
The bitmap is allocated exactly once and never moves. First fit places it in
low memory, which leaves the largest region unfragmented. That is the region
every later allocation comes out of.
*/
@(private = "file")
find_bitmap_home :: proc "contextless" (b: ^Boot_Memory, need: u64) -> (u64, bool) {
	for r in regions(b) {
		if !allocatable(r.kind) {
			continue
		}
		base := align_up(r.base, PAGE_SIZE)
		if base == 0 {
			base = PAGE_SIZE
		}
		end := align_down(r.base + r.length, PAGE_SIZE)
		if base >= end || end - base < need {
			continue
		}
		return base, true
	}
	return 0, false
}

@(private = "file")
release_range :: proc "contextless" (base, length: u64) {
	first := align_up(base, PAGE_SIZE) / PAGE_SIZE
	last := align_down(base + length, PAGE_SIZE) / PAGE_SIZE
	for f := first; f < last; f += 1 {
		if int(f) < frame_total {
			release(int(f))
		}
	}
}

/*
pmm_reclaim hands the bootloader's own memory to the allocator.

Not called during boot, and calling it early is fatal in a way that is very
hard to read afterwards. Bootloader-reclaimable memory holds three things the
kernel still stands on at the end of `mem.init`. Those are the stack `kmain`
runs on, every Limine response structure, and the memory map the reclaim itself
iterates. It becomes free only once two things are true. The scheduler must sit
on a kernel stack of its own, and anything the kernel wants from the responses
must already sit somewhere else.

It is worth doing -- it is 39 MiB on this machine -- which is why it is written
down now rather than rediscovered later.
*/
pmm_reclaim :: proc "contextless" (b: ^Boot_Memory) -> (frames: int) {
	before := frame_free
	for r in regions(b) {
		if r.kind == .Reclaimable {
			release_range(r.base, r.length)
		}
	}
	frames = frame_free - before
	frame_usable += frames
	return
}

// -- Allocation --------------------------------------------------------------

/*
The lock over the bitmap, the hint and the counts.

The bitmap was written with no lock, because one core cannot race itself and an
interrupt handler never allocates a frame. A second core can. Two cores that
scanned at once found the same free frame and both took it. The frame then held
two page tables, or a page table and a program's stack. The fault that found it
was a read through the direct map, on the fourth core of a claim test, one boot
in four.

Held for the scan and the take, and for a free. The zeroing a caller does
after is outside it, because the frame is that caller's by then. Nested
under the heap lock when the heap grows, which is the one order those two
are ever taken in.
*/
@(private = "file")
pmm_lock: sync.Spinlock

/*
alloc_pages finds `count` contiguous free frames and takes them.

The search starts at the last allocation and wraps once. A run of allocations
therefore walks forward through memory, rather than re-scans the taken prefix
each time. Failure is a return value rather than a panic. The heap has a
fallback for it, and the VMM turns it into a `mem.Error`. A physical allocator
that halts the machine is not one a page fault handler can call.
*/
alloc_pages :: proc "contextless" (count: int) -> (phys: uintptr, ok: bool) {
	guard := sync.acquire(&pmm_lock)
	defer sync.release(&pmm_lock, guard)

	if count <= 0 || count > frame_free {
		return 0, false
	}

	frame, found := scan(hint, frame_total, count)
	if !found {
		frame, found = scan(0, hint, count)
	}
	if !found {
		return 0, false
	}

	for i in 0 ..< count {
		take(frame + i)
	}
	hint = frame + count
	if hint >= frame_total {
		hint = 0
	}

	if used := frame_usable - frame_free; used > frame_peak {
		frame_peak = used
	}
	return uintptr(u64(frame) * PAGE_SIZE), true
}

alloc_page :: proc "contextless" () -> (phys: uintptr, ok: bool) {
	return alloc_pages(1)
}

/*
alloc_page_zeroed is the page table constructor's allocator.

A fresh table has to read as `no entry present` in all 512 slots. A frame
something used before does not. Zeroing goes through the direct map, which is
why the PMM may only ever hand out frames from HHDM-mapped regions.
*/
alloc_page_zeroed :: proc "contextless" () -> (phys: uintptr, ok: bool) {
	return alloc_pages_zeroed(1)
}

/*
alloc_pages_zeroed is the same promise over a run.

**A run handed to ring 3 has to be zero, and that is not tidiness.** The frames
come back from a program that ended and go out to one that has not started.
Whatever the last one wrote is still in them. `kernel/user/segment.odin` is the
caller, and the check that reads the first word of a fresh anonymous segment is
what would see the leak.

The zeroing goes through the direct map, which is why this allocator may only
ever hand out frames from HHDM-mapped regions. That was already true of one
page and is no more true of a thousand.
*/
alloc_pages_zeroed :: proc "contextless" (count: int) -> (phys: uintptr, ok: bool) {
	phys, ok = alloc_pages(count)
	if !ok {
		return
	}
	intrinsics.mem_zero(phys_to_virt(phys), count * int(PAGE_SIZE))
	return
}

/*
free_pages hands a run of frames back, and counts the ones that were never
this allocator's.

**A frame past the bitmap is not an error this can act on, and it is always a
bug in the caller.** The framebuffer lives above every usable region on this
machine, so a free of device memory lands here, changes nothing, and says
nothing. A double free was that quiet until `docs/SPACE.md` made it count, and
this hides the same class of mistake. A teardown walking frames that were never
its to walk.

Counted rather than refused, because this is the physical allocator and the
panic screen it would reach for needs frames of its own. A self-test that
brackets this sees a number that should be zero. `kernel/user/segment.odin`
is the caller that must never raise it, and `docs/DRAW.md` section 7 named the
hazard a milestone before the code arrived.
*/
free_pages :: proc "contextless" (phys: uintptr, count: int) {
	guard := sync.acquire(&pmm_lock)
	defer sync.release(&pmm_lock, guard)

	frame := int(u64(phys) / PAGE_SIZE)
	for i in 0 ..< count {
		f := frame + i
		if f < frame_total {
			release(f)
		} else {
			untracked_frees += 1
		}
	}
	// Freed frames are the cheapest thing to allocate next. Aim the search at
	// them, rather than leave the hint past the hole they just made.
	if frame < hint {
		hint = frame
	}
}

free_page :: proc "contextless" (phys: uintptr) {
	free_pages(phys, 1)
}

/*
frame_is_free asks the bitmap about one frame by its physical address.

For a self-test that wants to say `this exact frame came back`, rather than
`the total went back to what it was`. The total is much the weaker claim.
Anything that allocated in between hides a leak inside it, and the heap is
always allocating. See `kernel/user/verify.odin`. The measurement there is
three frames a program held, and everything around it is a thread stack.

An address outside the tracked range reads as free, because a frame this
allocator does not own is not one it is holding.
*/
frame_is_free :: proc "contextless" (phys: uintptr) -> bool {
	frame := int(u64(phys) / PAGE_SIZE)
	if frame < 0 || frame >= frame_total {
		return true
	}
	return !frame_taken(frame)
}

/*
scan looks for `count` consecutive free frames in [from, to).

The 0xFF fast path is what makes this cheap in practice. A fully-taken byte
cannot contain any part of a run, so it costs one compare per eight frames
rather than eight. It only fires on a byte boundary with no run in progress.
The loop proper has to break a run that crosses into the byte.
*/
@(private = "file")
scan :: proc "contextless" (from, to, count: int) -> (int, bool) #no_bounds_check {
	run := 0
	start := 0

	for f := from; f < to; f += 1 {
		if run == 0 && f & 7 == 0 && f + 8 <= to && bitmap[f >> 3] == 0xFF {
			f += 7
			continue
		}
		if frame_taken(f) {
			run = 0
			continue
		}
		if run == 0 {
			start = f
		}
		run += 1
		if run == count {
			return start, true
		}
	}
	return 0, false
}
