/*
The kernel heap: a slab allocator, and the bridge from it to Odin's own
allocator interface.

Two paths, chosen by size:

  - Small requests come out of a size class. Each class owns a chain of slabs,
    one page apiece, carved into equal objects, with the free ones threaded
    through their own first eight bytes. Allocation and free are a pointer
    push and pop with no search and no coalescing.
  - Large requests go straight to the PMM as a run of contiguous pages.

Both paths put a header immediately before the pointer they return, so `free`
knows which path a block came from without a lookup structure. That header is
also what makes over-aligned allocations work. The block is oversized, and the
returned pointer is aligned inside it. The header records how far in it sits,
so `free` can recover the block's real start.

What this deliberately is not: slabs are never returned to the PMM. Reclaiming
one means proving every object in it is free, which means per-slab occupancy
counts and a partial/full/empty chain per class. Vectra's kernel heap holds VFS
nodes and 9P buffers whose population grows and plateaus, so the machinery would
cost more than the pages it recovers. When something proves that wrong, the
place to fix it is `slab_grow` and `slab_free`, not the callers.
*/
package mem

import "base:intrinsics"
import "base:runtime"

import "kernel:sync"

// Classes are powers of two from 16 bytes to half a page. Below 16 the header
// dominates. Above 2 KiB, a page-granular allocation wastes less than a size
// class rounded up to the next power of two would.
SIZE_CLASSES :: [?]int{16, 32, 64, 128, 256, 512, 1024, 2048}
CLASS_COUNT :: len(SIZE_CLASSES)

// Every class size is a multiple of 16, so every object start is 16-aligned.
// An allocation that asks for no more than that never needs the over-align
// path.
MIN_ALIGN :: 16

HEADER_MAGIC :: u32(0x5645_4331) // "VEC1"
KIND_LARGE :: u8(0xFF)

/*
The per-block header, sitting in the sixteen bytes below every returned pointer.

`offset` rather than a back-pointer, because it is half the width. A corrupted
small integer is also far easier to recognise than a corrupted pointer.
*/
Header :: struct {
	magic:  u32,
	kind:   u8, // Size class index, or KIND_LARGE
	_pad:   [3]u8,
	pages:  u32, // Large blocks only: how many frames to give back
	offset: u32, // Distance from the block's start to the returned pointer
}

#assert(size_of(Header) == MIN_ALIGN)

Slab_Class :: struct {
	object_size: int,
	free_list:   rawptr,
	free_count:  int,
	total:       int,
	slabs:       int,
}

@(private = "file") classes: [CLASS_COUNT]Slab_Class
@(private = "file") large_frames: int
@(private = "file") large_blocks: int

/*
The heap lock.

Nothing here was ever re-entrant, and now everything is. A timer interrupt can
land between a free-list pop and the store that consumes it, and the thread it
switches to allocates. The window is a handful of instructions and the failure
is two callers holding the same object, which surfaces arbitrarily far from
here.

Held across the whole of `alloc`, `free` and `resize`, rather than around the
individual list operations, because the invariant spans them. A class's
`free_count` and its `free_list` have to agree, and in the middle they do not.
`resize` calls `alloc`, so the lock is taken twice on that path -- which is why
`sync.Spinlock` nests.
*/
@(private = "file") heap_lock: sync.Spinlock
@(private = "file") heap_ready: bool

Heap_Stats :: struct {
	class_sizes:  [CLASS_COUNT]int,
	class_free:   [CLASS_COUNT]int,
	class_total:  [CLASS_COUNT]int,
	slab_frames:  int,
	large_frames: int,
	large_blocks: int,
}

heap_stats :: proc "contextless" () -> Heap_Stats {
	s: Heap_Stats
	for c, i in classes {
		s.class_sizes[i] = c.object_size
		s.class_free[i] = c.free_count
		s.class_total[i] = c.total
		s.slab_frames += c.slabs
	}
	s.large_frames = large_frames
	s.large_blocks = large_blocks
	return s
}

/*
heap_init records the size classes and nothing else.

No slab is carved until something asks for one. A kernel that never allocates
64-byte objects should not pay a page for the possibility. The first allocation
in each class is one PMM call more expensive than the rest.
*/
@(private)
heap_init :: proc "contextless" () {
	for size, i in SIZE_CLASSES {
		classes[i] = Slab_Class{object_size = size}
	}
	heap_ready = true
}

// -- Slabs -------------------------------------------------------------------

/*
slab_grow takes one page from the PMM and threads its objects onto the free
list.

The link lives in the object's own first eight bytes, which is free storage.
Nothing uses the object while it is on the list. Objects go on back to front,
so the list comes out in ascending address order. That keeps a run of
allocations moving forward through the page, rather than backward.
*/
@(private = "file")
slab_grow :: proc "contextless" (c: ^Slab_Class) -> bool {
	frame, ok := alloc_page()
	if !ok {
		return false
	}

	base := uintptr(uintptr(phys_to_virt(frame)))
	count := int(PAGE_SIZE) / c.object_size

	for i := count - 1; i >= 0; i -= 1 {
		object := rawptr(base + uintptr(i * c.object_size))
		(cast(^rawptr)object)^ = c.free_list
		c.free_list = object
	}

	c.free_count += count
	c.total += count
	c.slabs += 1
	return true
}

@(private = "file")
slab_alloc :: proc "contextless" (c: ^Slab_Class) -> (rawptr, bool) {
	if c.free_list == nil && !slab_grow(c) {
		return nil, false
	}
	object := c.free_list
	c.free_list = (cast(^rawptr)object)^
	c.free_count -= 1
	return object, true
}

@(private = "file")
slab_free :: proc "contextless" (c: ^Slab_Class, object: rawptr) {
	(cast(^rawptr)object)^ = c.free_list
	c.free_list = object
	c.free_count += 1
}

// class_for returns the smallest class that holds `size` bytes, or -1 if the
// request belongs on the large path.
@(private = "file")
class_for :: proc "contextless" (size: int) -> int {
	for s, i in SIZE_CLASSES {
		if size <= s {
			return i
		}
	}
	return -1
}

// -- Allocation --------------------------------------------------------------

/*
alloc returns `size` bytes aligned to at least `align`.

The reserved block is `size` plus the header. A caller that wants more than the
16 bytes every object already guarantees also gets slack. That slack moves the
returned pointer up to an aligned address inside the block. Zeroing is the
caller's choice because page tables and slab objects want it and a buffer about
to be overwritten does not.
*/
alloc :: proc "contextless" (size: int, align: int = MIN_ALIGN, zeroed := true) -> (rawptr, bool) {
	guard := sync.acquire(&heap_lock)
	defer sync.release(&heap_lock, guard)

	if !heap_ready || size <= 0 {
		return nil, false
	}

	alignment := max(align, MIN_ALIGN)
	slack := alignment > MIN_ALIGN ? alignment : 0
	needed := size + size_of(Header) + slack

	block: rawptr
	kind: u8
	pages: u32

	if index := class_for(needed); index >= 0 {
		object, ok := slab_alloc(&classes[index])
		if !ok {
			return nil, false
		}
		block = object
		kind = u8(index)
	} else {
		frames := int(page_count(u64(needed)))
		frame, ok := alloc_pages(frames)
		if !ok {
			return nil, false
		}
		block = phys_to_virt(frame)
		kind = KIND_LARGE
		pages = u32(frames)
		large_frames += frames
		large_blocks += 1
	}

	// The header has to fit below the pointer, so the earliest the pointer can
	// sit is one header in. Align upward from there.
	base := uintptr(block)
	ptr := uintptr(align_up(u64(base) + size_of(Header), u64(alignment)))

	header := cast(^Header)rawptr(ptr - size_of(Header))
	header^ = Header {
		magic  = HEADER_MAGIC,
		kind   = kind,
		pages  = pages,
		offset = u32(ptr - base),
	}

	if zeroed {
		intrinsics.mem_zero(rawptr(ptr), size)
	}
	return rawptr(ptr), true
}

/*
free returns a block to whichever path produced it.

The magic is checked rather than assumed. A pointer that did not come from
`alloc` might be an interior pointer, a double free, or a stack address.

Without the magic, `free` would read one as a header and act on its garbage.
That turns a caller's bug into heap corruption diagnosed somewhere else
entirely. Here it is simply ignored, and the leak is the cheaper outcome.
*/
free :: proc "contextless" (ptr: rawptr) -> bool {
	guard := sync.acquire(&heap_lock)
	defer sync.release(&heap_lock, guard)

	if ptr == nil {
		return false
	}

	header := cast(^Header)rawptr(uintptr(ptr) - size_of(Header))
	if header.magic != HEADER_MAGIC {
		return false
	}
	block := uintptr(ptr) - uintptr(header.offset)

	// Clear the magic before releasing: a second free of the same pointer then
	// fails the check above instead of corrupting a free list.
	header.magic = 0

	if header.kind == KIND_LARGE {
		free_pages(virt_to_phys(rawptr(block)), int(header.pages))
		large_frames -= int(header.pages)
		large_blocks -= 1
		return true
	}

	if int(header.kind) >= CLASS_COUNT {
		return false
	}
	slab_free(&classes[header.kind], rawptr(block))
	return true
}

// block_size reports how much room the block behind a header actually has,
// which is what `resize` needs to know whether it can answer in place.
@(private = "file")
block_size :: proc "contextless" (header: ^Header) -> int {
	total := header.kind == KIND_LARGE \
		? int(header.pages) * int(PAGE_SIZE) \
		: classes[header.kind].object_size
	return total - int(header.offset)
}

/*
resize grows or shrinks a block, in place when the rounding already allows it.

An allocation rounded up to a size class usually has room to spare, so a
sequence of small `append`s does not copy on every step. When it does not fit,
this is allocate-copy-free. A slab object cannot grow. A large block can only
grow if the frames above it happen to be free. That check costs about as much
as the copy it would save.
*/
resize :: proc "contextless" (
	ptr: rawptr,
	old_size, size: int,
	align: int = MIN_ALIGN,
	zeroed := true,
) -> (rawptr, bool) {
	guard := sync.acquire(&heap_lock)
	defer sync.release(&heap_lock, guard)

	if ptr == nil {
		return alloc(size, align, zeroed)
	}
	if size <= 0 {
		free(ptr)
		return nil, true
	}

	header := cast(^Header)rawptr(uintptr(ptr) - size_of(Header))
	if header.magic == HEADER_MAGIC {
		if capacity := block_size(header); size <= capacity {
			if zeroed && size > old_size {
				intrinsics.mem_zero(rawptr(uintptr(ptr) + uintptr(old_size)), size - old_size)
			}
			return ptr, true
		}
	}

	fresh, ok := alloc(size, align, zeroed)
	if !ok {
		return nil, false
	}
	intrinsics.mem_copy(fresh, ptr, min(old_size, size))
	free(ptr)
	return fresh, true
}

// -- Odin's allocator interface ----------------------------------------------

/*
allocator returns the heap in the form `context.allocator` wants.

Installing this is what makes `new`, `make`, `append` and every core container
work in the kernel. Until `mem.init` runs, the build's
`-default-to-nil-allocator` is in force instead. An accidental allocation
during early boot therefore returns nil, and fails at its use. It does not
quietly succeed against a heap that does not exist yet.
*/
allocator :: proc "contextless" () -> runtime.Allocator {
	return runtime.Allocator{procedure = allocator_proc, data = nil}
}

allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		ptr, ok := alloc(size, alignment, mode == .Alloc)
		if !ok {
			return nil, .Out_Of_Memory
		}
		return (cast([^]byte)ptr)[:size], nil

	case .Resize, .Resize_Non_Zeroed:
		ptr, ok := resize(old_memory, old_size, size, alignment, mode == .Resize)
		if !ok {
			return nil, .Out_Of_Memory
		}
		return (cast([^]byte)ptr)[:size], nil

	case .Free:
		if !free(old_memory) {
			return nil, .Invalid_Pointer
		}
		return nil, nil

	case .Free_All:
		// There is nothing to walk. Every caller shares the slabs, and no list
		// tracks the large blocks. A free of everything would pull the floor out
		// from under the whole kernel.
		return nil, .Mode_Not_Implemented

	case .Query_Features:
		if set := cast(^runtime.Allocator_Mode_Set)old_memory; set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}
