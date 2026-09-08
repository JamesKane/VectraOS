/*
Shared buffers: memory two processes map by an id, `docs/DEVTOOLS.md` step 1.

A window's store is the case this exists for. The draw server allocates it,
the client that owns the window maps the same frames and paints into them,
and the server composites from them to the glass. `segattach` maps a card
the allocator never owned; this maps a run the allocator did, held alive by
a reference count rather than freed with the first mapping to go.

**A run, not a list.** The frames come from `alloc_pages_zeroed`, contiguous
by construction, the same shape `segalloc` and `segattach` make. So a mapping
is a `.Device` segment over `[phys, phys + pages]` -- which never frees its
run on release -- and this table frees the run once, when the last mapping
detaches. Each mapping's segment carries the `shm_id`, and `segdetach` calls
`shm_release`.
*/
package user

import "kernel:mem"
import "kernel:sync"

// The most shared buffers at once. A window store apiece, so this rides
// `MAX_WINDOWS` with room, the way the image pool does.
SHM_MAX :: 64

// The most one buffer may be, a generous window. `docs/DRAW.md`'s largest is
// under two megabytes, and this is the cap a mistake turns into an errno.
SHM_BYTES_MAX :: u64(8) << 20

@(private = "file")
Shm :: struct {
	used:  bool,
	id:    u64,
	phys:  uintptr, // the run's first frame
	pages: int,
	refs:  int, // live mappings; the run is freed when this reaches zero
}

@(private = "file")
shms: [SHM_MAX]Shm
@(private = "file")
next_shm_id: u64 = 1
@(private = "file")
shm_lock: sync.Spinlock

// shm_create allocates a shared buffer's frames and a table slot, and
// answers its id. It maps nothing: a caller attaches it, itself included.
@(private)
shm_create :: proc "contextless" (pages: int) -> (id: u64, phys: uintptr, ok: bool) {
	if pages <= 0 {
		return 0, 0, false
	}
	base, got := mem.alloc_pages_zeroed(pages)
	if !got {
		return 0, 0, false
	}
	guard := sync.acquire(&shm_lock)
	defer sync.release(&shm_lock, guard)
	for i in 0 ..< SHM_MAX {
		if !shms[i].used {
			shms[i] = Shm{used = true, id = next_shm_id, phys = base, pages = pages, refs = 0}
			next_shm_id += 1
			return shms[i].id, base, true
		}
	}
	// No slot: the frames go back rather than leak.
	mem.free_pages(base, pages)
	return 0, 0, false
}

// shm_lookup answers a buffer's frames and page count, for a caller about to
// map it, and bumps the reference count. False for an id no buffer has.
@(private)
shm_lookup :: proc "contextless" (id: u64) -> (phys: uintptr, pages: int, ok: bool) {
	guard := sync.acquire(&shm_lock)
	defer sync.release(&shm_lock, guard)
	for i in 0 ..< SHM_MAX {
		if shms[i].used && shms[i].id == id {
			shms[i].refs += 1
			return shms[i].phys, shms[i].pages, true
		}
	}
	return 0, 0, false
}

// shm_release drops one mapping's reference, and frees the run and the slot
// when the last mapping is gone. `segdetach` calls it for a shm segment.
@(private)
shm_release :: proc "contextless" (id: u64) {
	guard := sync.acquire(&shm_lock)
	freed_phys: uintptr
	freed_pages: int
	for i in 0 ..< SHM_MAX {
		if shms[i].used && shms[i].id == id {
			shms[i].refs -= 1
			if shms[i].refs <= 0 {
				freed_phys = shms[i].phys
				freed_pages = shms[i].pages
				shms[i] = Shm{}
			}
			break
		}
	}
	sync.release(&shm_lock, guard)
	// The free is outside the lock, and there is nothing to free when the
	// count did not reach zero.
	if freed_pages > 0 {
		mem.free_pages(freed_phys, freed_pages)
	}
}
