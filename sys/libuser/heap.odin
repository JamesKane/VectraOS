/*
A heap for a program, over the memory the kernel gives one.

Every program before `docs/SHELL.md` built with the nil allocator, because a
server has no reason to allocate and every reason not to. A tool is the
other kind of program: `core:strings`, `core:fmt`'s buffers and a `[dynamic]`
of anything all want `context.allocator`, and this is it.

The shape is the simplest that serves: one run of anonymous memory from
`segalloc`, grown by `segbrk` when it runs out, carved into blocks with a
header apiece, and a first-fit free list threaded through the free ones. A
freed block joins its free neighbours. Nothing here is fast, and nothing
here needs to be: a tool allocates a few thousand times and exits.

The run starts at `HEAP_START` bytes and doubles when a request does not
fit, up to the kernel's bound on a run. `segbrk` keeps the base, so every
pointer handed out stays good across a grow.

**One lock, because the heap is shared.** A program on `sys/libthread` is
several processes over one memory, and any of them may allocate: a proc's
reader takes a request record from the heap while a thread in another proc
frees one. `heap_lock` is `Spin`, taken for the length of a walk down the
list and never across a wait. The one call inside it that enters the kernel
is `segbrk`, which copies nothing and parks nobody.
*/
package libuser

import "base:runtime"

// The first run, and the least a program pays to fork: every anonymous
// page is copied into a child, so the heap starts small and doubles.
HEAP_START :: 64 * 1024

@(private = "file")
Block :: struct {
	size: int,    // Bytes after this header, header excluded
	free: bool,
	next: ^Block, // The next block in address order, or nil
}

@(private = "file")
BLOCK_HEADER :: size_of(Block)

@(private = "file")
heap_base: uintptr
@(private = "file")
heap_top: uintptr
@(private = "file")
heap_first: ^Block
@(private = "file")
heap_lock: Spin

/*
allocator is the heap as `context.allocator` wants it. Nothing here is a
runtime import beyond the procedure type, so the same file builds for a
program on any architecture.
*/
allocator :: proc "contextless" () -> runtime.Allocator {
	return runtime.Allocator{procedure = heap_proc, data = nil}
}

@(private = "file")
align_up :: proc "contextless" (v: int, a: int) -> int {
	return (v + a - 1) & ~(a - 1)
}

// grow asks the kernel for more run, or for the first one, and threads the
// new space onto the end of the list as one free block.
@(private = "file")
grow :: proc "contextless" (at_least: int) -> bool {
	want := HEAP_START
	if heap_base != 0 {
		want = int(heap_top - heap_base)
	}
	for want < at_least + BLOCK_HEADER {
		want *= 2
	}
	if heap_base == 0 {
		addr, err := segalloc(want)
		if err != 0 {
			return false
		}
		heap_base = addr
		heap_top = addr + uintptr(want)
		heap_first = (^Block)(addr)
		heap_first^ = Block{size = want - BLOCK_HEADER, free = true}
		return true
	}
	old_top := heap_top
	if segbrk(heap_base, heap_base + uintptr(int(heap_top - heap_base) + want)) != 0 {
		return false
	}
	heap_top = heap_base + uintptr(int(heap_top - heap_base) + want)
	tail := (^Block)(old_top)
	tail^ = Block{size = want - BLOCK_HEADER, free = true}
	last := heap_first
	for last.next != nil {
		last = last.next
	}
	last.next = tail
	coalesce(last)
	return true
}

// coalesce merges a free block with the free block after it, as many times
// as that holds.
@(private = "file")
coalesce :: proc "contextless" (b: ^Block) {
	for b.free && b.next != nil && b.next.free {
		b.size += BLOCK_HEADER + b.next.size
		b.next = b.next.next
	}
}

// heap_alloc takes `size` bytes off the heap, sixteen-aligned, or answers nil.
// The entry a contextless caller uses: `sys/libthread` takes a thread's stack
// and a request's record here, with no context to carry an allocator in.
heap_alloc :: proc "contextless" (size: int) -> rawptr {
	lock(&heap_lock)
	p := alloc(size, 16)
	unlock(&heap_lock)
	return p
}

// heap_free gives a block from `heap_alloc` back. Nil is nothing to give.
heap_free :: proc "contextless" (p: rawptr) {
	lock(&heap_lock)
	free(p)
	unlock(&heap_lock)
}

// alloc is the walk. Caller holds `heap_lock`.
@(private = "file")
alloc :: proc "contextless" (size: int, alignment: int) -> rawptr {
	// The header is sixteen bytes, so a block's payload is aligned to
	// sixteen when the block is; every request is rounded to sixteen and
	// larger alignments are refused, which nothing in a tool asks for.
	if alignment > 16 {
		return nil
	}
	want := align_up(max(size, 1), 16)
	for attempt in 0 ..< 2 {
		for b := heap_first; b != nil; b = b.next {
			if !b.free || b.size < want {
				continue
			}
			// Split when what is left would hold another block; otherwise
			// hand over the slack with it.
			if b.size >= want + BLOCK_HEADER + 16 {
				rest := (^Block)(uintptr(b) + uintptr(BLOCK_HEADER + want))
				rest^ = Block{size = b.size - want - BLOCK_HEADER, free = true, next = b.next}
				b.size = want
				b.next = rest
			}
			b.free = false
			return rawptr(uintptr(b) + uintptr(BLOCK_HEADER))
		}
		if attempt == 0 && !grow(want) {
			return nil
		}
	}
	return nil
}

// free returns a block to the list and merges it with its free neighbours.
// Caller holds `heap_lock`.
@(private = "file")
free :: proc "contextless" (p: rawptr) {
	if p == nil {
		return
	}
	b := (^Block)(uintptr(p) - uintptr(BLOCK_HEADER))
	b.free = true
	// Merge forward from here, then let the block before absorb this one.
	coalesce(b)
	for prev := heap_first; prev != nil; prev = prev.next {
		if prev.next == b {
			coalesce(prev)
			break
		}
	}
}

@(private = "file")
heap_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	_ = data
	_ = loc
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		lock(&heap_lock)
		p := alloc(size, alignment)
		unlock(&heap_lock)
		if p == nil {
			return nil, .Out_Of_Memory
		}
		bytes := ([^]u8)(p)[:size]
		if mode == .Alloc {
			for i in 0 ..< size {
				bytes[i] = 0
			}
		}
		return bytes, nil
	case .Free:
		heap_free(old_memory)
		return nil, nil
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return heap_proc(data, .Alloc, size, alignment, nil, 0, loc)
		}
		b := (^Block)(uintptr(old_memory) - uintptr(BLOCK_HEADER))
		if size <= b.size {
			return ([^]u8)(old_memory)[:size], nil
		}
		lock(&heap_lock)
		p := alloc(size, alignment)
		unlock(&heap_lock)
		if p == nil {
			return nil, .Out_Of_Memory
		}
		fresh := ([^]u8)(p)[:size]
		old := ([^]u8)(old_memory)[:old_size]
		for i in 0 ..< old_size {
			fresh[i] = old[i]
		}
		for i in old_size ..< size {
			fresh[i] = 0
		}
		heap_free(old_memory)
		return fresh, nil
	case .Query_Features:
		if set := (^runtime.Allocator_Mode_Set)(old_memory); set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

// heap_stats reports the run's size and how much of it is free, for a
// self-test that wants to say the heap gave back what it took.
heap_stats :: proc "contextless" () -> (total: int, free_bytes: int, blocks: int) {
	lock(&heap_lock)
	total = int(heap_top - heap_base)
	for b := heap_first; b != nil; b = b.next {
		blocks += 1
		if b.free {
			free_bytes += b.size
		}
	}
	unlock(&heap_lock)
	return
}
