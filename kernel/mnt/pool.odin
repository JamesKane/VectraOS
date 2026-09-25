/*
The request pool both transports share: slots in chunks that never move, a
free list, and growth up to the tag space. `docs/LIMITS.md` is the policy.

A fixed pool made a transport's capacity a kernel constant. A program holds
reads open: a window's keyboard and mouse, a console, an interrupt stream.
Each keeps a slot for as long as it waits. So the constant became a ceiling
on windows and devices, and the request after the last slot parked for ever.
It was 8, then 16. Plan 9's `devmnt` has no such pool. Its rpcs come off a
free list that grows, and its tags off a bitmap the size of the tag space.

    tags below FLUSH_TAG   requests, `WIRE_CHUNK` more each growth
    tag + FLUSH_TAG        that request's own flush slot, so a flush
                           never competes for a slot a stuck request holds
    NOTAG                  Tversion's

The first chunk may sit on storage its owner already has: a `Conn`'s arena,
a self-test's static buffer. The pool allocates every chunk after it, and
frees only what it allocated.

**Locking is the owner's.** A `Conn` and a `Wire` each keep one spinlock over
their slots' states and this pool. The procedures marked "the lock is the
caller's" run under it. `pool_grow` is the exception: it allocates, so it runs
with the lock down, and `growing` keeps it to one caller at a time.

**A lookup takes no lock.** A device reader's wait condition asks whether its
tag was flushed. On `#t` that runs in interrupt context, and the thread it
interrupted may hold the lock. So the chunks hang off a two-level table of
pointers, each written once and never moved. A lookup reads two pointers and
a count, and is right without the lock.
*/
package mnt

import "base:intrinsics"

import "kernel:mem"
import "kernel:sync"
import "vsys:vectra9"

// Slots a chunk holds. The first chunk is the pool a transport starts with.
WIRE_CHUNK :: MAX_REQUESTS

// The first tag of the flush half. A request's flush slot answers to the
// request's tag plus this. The two halves split the 16-bit tag space, and
// `NOTAG`, the top of it, is left to Tversion.
FLUSH_TAG :: 0x8000

// Requests one pool can have in flight: the request half of the tag space.
WIRE_MAX_REQUESTS :: FLUSH_TAG - 1

// Bytes a flush slot's frame buffer holds. An Rflush is seven bytes, and a
// server that sends more under a flush tag is answering a question nobody
// asked.
@(private)
FLUSH_FRAME :: 32

/*
One chunk: `WIRE_CHUNK` request slots, each with its flush slot and the
buffers both reply into. Allocated whole and never moved. `store` is nil on a
pool with no payload.
*/
Chunk :: struct {
	requests:    [WIRE_CHUNK]Rpc,
	flushes:     [WIRE_CHUNK]Rpc,
	flush_store: [WIRE_CHUNK][FLUSH_FRAME]u8,
	store:       []u8,
	owned_store: bool, // Allocated here, so `pool_free` gives it back
}

// The table's shape: `POOL_TOP` blocks of `POOL_MID` chunks, which with
// `WIRE_CHUNK` slots a chunk covers the request half of the tag space.
@(private)
POOL_TOP :: 64
@(private)
POOL_MID :: 32
#assert(POOL_TOP * POOL_MID * WIRE_CHUNK >= WIRE_MAX_REQUESTS)

@(private)
Pool_Block :: [POOL_MID]^Chunk

Pool :: struct {
	top:     [POOL_TOP]^Pool_Block,
	nchunks: int, // Published after the chunk it counts
	spare:   ^Rpc, // Free request slots, through `Rpc.next`
	growing: bool,
	per:     int, // Payload bytes a request slot holds, or zero
	slots:   u64, // Request slots grown to
	refused: u64, // Growths that found no memory
}

/*
pool_init makes the first chunk. `per` is each request slot's payload, zero
for none. `first` is storage for the first chunk's payloads, `WIRE_CHUNK *
per` bytes, or nil to allocate it. False when memory would not come.
*/
pool_init :: proc "contextless" (pl: ^Pool, per: int, first: []u8 = nil) -> bool {
	context = mem.kernel_context()
	pl^ = {}
	pl.per = per
	c := chunk_new(pl, 0, first)
	if c == nil {
		return false
	}
	b := new(Pool_Block)
	if b == nil {
		chunk_free(c)
		return false
	}
	pl.top[0] = b
	pool_install(pl, c)
	return true
}

// pool_free gives back every chunk and the index. Nothing may hold a slot.
pool_free :: proc "contextless" (pl: ^Pool) {
	context = mem.kernel_context()
	for i in 0 ..< pl.nchunks {
		chunk_free(pool_chunk(pl, i))
	}
	for b in pl.top {
		free(b)
	}
	pl^ = {}
}

@(private = "file")
chunk_new :: proc(pl: ^Pool, n: int, first: []u8) -> ^Chunk #no_bounds_check {
	c := new(Chunk)
	if c == nil {
		return nil
	}
	if pl.per > 0 {
		if first != nil {
			c.store = first
		} else {
			c.store = make([]u8, WIRE_CHUNK * pl.per)
			if c.store == nil {
				free(c)
				return nil
			}
			c.owned_store = true
		}
	}
	for i in 0 ..< WIRE_CHUNK {
		r := &c.requests[i]
		f := &c.flushes[i]
		r.tag = vectra9.Tag(n * WIRE_CHUNK + i)
		f.tag = r.tag + FLUSH_TAG
		r.state, f.state = .Free, .Free
		if pl.per > 0 {
			r.payload = c.store[i * pl.per:][:pl.per]
		}
		f.payload = c.flush_store[i][:]
		r.own_flush = f
	}
	return c
}

@(private = "file")
chunk_free :: proc(c: ^Chunk) {
	if c == nil {
		return
	}
	if c.owned_store {
		delete(c.store)
	}
	free(c)
}

// pool_chunk is chunk `k`, or nil past the last. Lock-free: see the file
// comment.
pool_chunk :: proc "contextless" (pl: ^Pool, k: int) -> ^Chunk #no_bounds_check {
	if k < 0 || k >= intrinsics.atomic_load(&pl.nchunks) {
		return nil
	}
	b := intrinsics.atomic_load(&pl.top[k / POOL_MID])
	if b == nil {
		return nil
	}
	return intrinsics.atomic_load(&b[k % POOL_MID])
}

// pool_install adds a chunk and its slots to the free list. The lock is the
// caller's, and the chunk's block exists. The chunk is published before the
// count that makes a lookup look at it.
@(private = "file")
pool_install :: proc "contextless" (pl: ^Pool, c: ^Chunk) #no_bounds_check {
	k := pl.nchunks
	intrinsics.atomic_store(&pl.top[k / POOL_MID][k % POOL_MID], c)
	intrinsics.atomic_store(&pl.nchunks, k + 1)
	for i := WIRE_CHUNK - 1; i >= 0; i -= 1 {
		c.requests[i].next = pl.spare
		pl.spare = &c.requests[i]
	}
	pl.slots += WIRE_CHUNK
}

// pool_pop takes a free request slot, or nil. The lock is the caller's.
pool_pop :: proc "contextless" (pl: ^Pool) -> ^Rpc {
	r := pl.spare
	if r != nil {
		pl.spare = r.next
		r.next = nil
	}
	return r
}

// pool_push puts a request slot back on the free list. The lock is the
// caller's.
pool_push :: proc "contextless" (pl: ^Pool, r: ^Rpc) {
	r.next = pl.spare
	pl.spare = r
}

// pool_can_grow says a client may start a growth now. The lock is the
// caller's.
pool_can_grow :: proc "contextless" (pl: ^Pool) -> bool {
	return !pl.growing && pl.nchunks * WIRE_CHUNK < WIRE_MAX_REQUESTS
}

// pool_ready is what a client waiting for a slot waits on: one free, or
// room to grow and nobody growing. Read without the lock, as a condition.
pool_ready :: proc "contextless" (pl: ^Pool) -> bool {
	if intrinsics.volatile_load(&pl.spare) != nil {
		return true
	}
	return !intrinsics.volatile_load(&pl.growing) && intrinsics.atomic_load(&pl.nchunks) * WIRE_CHUNK < WIRE_MAX_REQUESTS
}

/*
pool_grow allocates the next chunk and installs it, the index doubled first
when it is full. The caller set `growing` under the lock and calls this with
the lock down. It clears `growing` and answers whether the chunk came.
*/
pool_grow :: proc "contextless" (pl: ^Pool, lock: ^sync.Spinlock) -> bool #no_bounds_check {
	context = mem.kernel_context()
	n := pl.nchunks // stable while `growing` is ours
	c := chunk_new(pl, n, nil)
	b: ^Pool_Block
	if c != nil && n % POOL_MID == 0 && pl.top[n / POOL_MID] == nil {
		b = new(Pool_Block)
		if b == nil {
			chunk_free(c)
			c = nil
		}
	}
	made := c != nil
	g := sync.acquire(lock)
	if made {
		if b != nil {
			intrinsics.atomic_store(&pl.top[n / POOL_MID], b)
		}
		pool_install(pl, c)
	} else {
		pl.refused += 1
	}
	pl.growing = false
	sync.release(lock, g)
	return made
}

// pool_slot answers the slot a tag names, request or flush, or nil. It takes
// no lock, and needs none: see the file comment.
pool_slot :: proc "contextless" (pl: ^Pool, tag: vectra9.Tag) -> ^Rpc #no_bounds_check {
	t := int(tag)
	flush := t >= FLUSH_TAG
	if flush {
		t -= FLUSH_TAG
	}
	c := pool_chunk(pl, t / WIRE_CHUNK)
	if c == nil {
		return nil
	}
	return flush ? &c.flushes[t % WIRE_CHUNK] : &c.requests[t % WIRE_CHUNK]
}
