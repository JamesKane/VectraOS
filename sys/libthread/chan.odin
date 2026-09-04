/*
Channels, and `alt`: how threads talk, within a proc and across them.

A channel carries elements of one size. An unbuffered one is a meeting: a
send parks until a receive arrives, and the element goes straight from one
to the other. A buffered one is a queue of `nbuf` elements: a send parks
only when it is full, a receive only when it is empty. Every operation is
a case of `alt`, which waits on several channels at once and executes the
first that can go. When several can go it picks one at random, so no
channel starves another. That is Plan 9's `channel.c`, in the 9front
shape.

## How a wait works

One lock, `chanlock`, over every channel and every queue of waiters.
`alt` takes it and looks at each channel. It either executes an operation
and returns, or hangs the calling thread's `Alt` records on every channel
they name and parks. When another thread executes an operation against
one of those records, it copies the element. It then removes *all* of
that thread's records from their queues, under the same lock, and readies
the thread. The woken thread learns which record went from `alt_ret`.

A record is on the caller's stack. That is safe because the caller is
parked until every record is off every queue.

`chanlock` is a spinlock held for the length of a copy and never across a
wait. A thread in another proc may be inside it, and the only way to wait
for that is to yield the core.
*/
package libthread

import "base:intrinsics"

import "vsys:libuser"

Chan :: struct {
	elemsize:  int,
	nbuf:      int, // Capacity in elements, zero for a meeting
	n:         int, // Elements held
	off:       int, // The oldest one's index
	buf:       [^]u8,
	senders:   ^Alt, // Waiting to send, oldest first
	receivers: ^Alt,
}

Chan_Op :: enum u8 {
	Send,
	Recv,
	Noblock, // Answer -1 rather than wait, when nothing can go
}

// One arm of an `alt`. `c`, `v` and `op` are the caller's, and the rest is
// the library's while the arm waits. `v` may be nil on a receive to
// discard the element.
Alt :: struct {
	c:      ^Chan,
	v:      rawptr,
	op:     Chan_Op,
	thread: ^Thread,
	next:   ^Alt,
	index:  int,
}

chanlock: libuser.Spin

// chancreate makes a channel of `elemsize`-byte elements holding `nbuf`
// of them, or nil when there is no memory.
chancreate :: proc "contextless" (elemsize: int, nbuf: int) -> ^Chan {
	c := (^Chan)(libuser.heap_alloc(size_of(Chan)))
	if c == nil {
		return nil
	}
	c^ = {}
	c.elemsize = elemsize
	c.nbuf = max(nbuf, 0)
	if c.nbuf > 0 {
		c.buf = ([^]u8)(libuser.heap_alloc(elemsize * c.nbuf))
		if c.buf == nil {
			libuser.heap_free(c)
			return nil
		}
	}
	return c
}

// chanfree gives a channel back. Nothing may be waiting on it.
chanfree :: proc "contextless" (c: ^Chan) {
	if c == nil {
		return
	}
	if c.buf != nil {
		libuser.heap_free(c.buf)
	}
	libuser.heap_free(c)
}

// chan_count is how many elements a buffered channel holds right now.
chan_count :: proc "contextless" (c: ^Chan) -> int {
	return intrinsics.volatile_load(&c.n)
}

/*
alt waits until one of its arms can go, executes it, and answers its
index. An arm with `.Noblock` makes the answer -1 instead of a wait. The
arms are examined in a random order when several can go.
*/
alt :: proc "contextless" (alts: []Alt) -> int #no_bounds_check {
	t := self()
	libuser.lock(&chanlock)
	ready := 0
	noblock := false
	for i in 0 ..< len(alts) {
		a := &alts[i]
		a.index = i
		a.thread = t
		a.next = nil
		switch a.op {
		case .Send, .Recv:
			if canexec(a) {
				ready += 1
			}
		case .Noblock:
			noblock = true
		}
	}
	if ready > 0 {
		k := int(rand() % u64(ready))
		for i in 0 ..< len(alts) {
			a := &alts[i]
			if (a.op == .Send || a.op == .Recv) && canexec(a) {
				if k == 0 {
					altexec(a)
					libuser.unlock(&chanlock)
					return i
				}
				k -= 1
			}
		}
	}
	if noblock {
		libuser.unlock(&chanlock)
		return -1
	}

	// Nothing can go. Hang every arm on its channel and park. Whoever
	// executes one of them removes them all and readies this thread.
	t.alts = alts
	t.alt_ret = -1
	for i in 0 ..< len(alts) {
		a := &alts[i]
		switch a.op {
		case .Send:
			enqueue(&a.c.senders, a)
		case .Recv:
			enqueue(&a.c.receivers, a)
		case .Noblock:
		}
	}
	libuser.unlock(&chanlock)
	block()
	return t.alt_ret
}

// canexec says whether an arm can go now. Caller holds `chanlock`. A
// meeting needs a partner from another thread. A buffer needs room, or an
// element.
@(private = "file")
canexec :: proc "contextless" (a: ^Alt) -> bool {
	c := a.c
	if c.nbuf > 0 {
		return a.op == .Send ? c.n < c.nbuf : c.n > 0
	}
	if a.op == .Send {
		return partner(c.receivers, a.thread) != nil
	}
	return partner(c.senders, a.thread) != nil
}

// partner is the oldest waiter on a queue from a thread other than the
// caller's. An `alt` that both sends and receives on one channel does not
// meet itself.
@(private = "file")
partner :: proc "contextless" (q: ^Alt, t: ^Thread) -> ^Alt {
	for a := q; a != nil; a = a.next {
		if a.thread != t {
			return a
		}
	}
	return nil
}

/*
altexec executes an arm `canexec` accepted. Caller holds `chanlock`.

A receive from a buffer takes the oldest element. If a sender was parked
on the full buffer, it then moves that sender's element in and wakes it.
A send to a buffer hands the element to a parked receiver if one waits,
which can only be when the buffer is empty. Otherwise it appends the
element. A meeting copies between the two arms and wakes the other.
*/
@(private = "file")
altexec :: proc "contextless" (a: ^Alt) {
	c := a.c
	if c.nbuf > 0 {
		if a.op == .Recv {
			elem_copy(a.v, slot_at(c, c.off), c.elemsize)
			c.off = (c.off + 1) % c.nbuf
			c.n -= 1
			if s := partner(c.senders, a.thread); s != nil {
				elem_copy(slot_at(c, (c.off + c.n) % c.nbuf), s.v, c.elemsize)
				c.n += 1
				alt_wakeup(s)
			}
			return
		}
		if r := partner(c.receivers, a.thread); r != nil {
			elem_copy(r.v, a.v, c.elemsize)
			alt_wakeup(r)
			return
		}
		elem_copy(slot_at(c, (c.off + c.n) % c.nbuf), a.v, c.elemsize)
		c.n += 1
		return
	}
	if a.op == .Recv {
		s := partner(c.senders, a.thread)
		elem_copy(a.v, s.v, c.elemsize)
		alt_wakeup(s)
		return
	}
	r := partner(c.receivers, a.thread)
	elem_copy(r.v, a.v, c.elemsize)
	alt_wakeup(r)
}

// alt_wakeup takes every arm of a parked thread off its queue, records
// which one went, and readies the thread. Caller holds `chanlock`.
@(private = "file")
alt_wakeup :: proc "contextless" (won: ^Alt) #no_bounds_check {
	t := won.thread
	for i in 0 ..< len(t.alts) {
		a := &t.alts[i]
		switch a.op {
		case .Send:
			dequeue(&a.c.senders, a)
		case .Recv:
			dequeue(&a.c.receivers, a)
		case .Noblock:
		}
	}
	t.alts = nil
	t.alt_ret = won.index
	threadready(t)
}

@(private = "file")
slot_at :: proc "contextless" (c: ^Chan, i: int) -> rawptr {
	return rawptr(uintptr(c.buf) + uintptr(i * c.elemsize))
}

@(private = "file")
elem_copy :: proc "contextless" (dst: rawptr, src: rawptr, n: int) {
	if dst == nil || src == nil || n == 0 {
		return
	}
	intrinsics.mem_copy_non_overlapping(dst, src, n)
}

@(private = "file")
enqueue :: proc "contextless" (q: ^^Alt, a: ^Alt) {
	a.next = nil
	if q^ == nil {
		q^ = a
		return
	}
	last := q^
	for last.next != nil {
		last = last.next
	}
	last.next = a
}

@(private = "file")
dequeue :: proc "contextless" (q: ^^Alt, a: ^Alt) {
	if q^ == a {
		q^ = a.next
		return
	}
	for p := q^; p != nil; p = p.next {
		if p.next == a {
			p.next = a.next
			return
		}
	}
}

// -- The one-channel cases -----------------------------------------------------

send :: proc "contextless" (c: ^Chan, v: rawptr) {
	arms := [1]Alt{{c = c, v = v, op = .Send}}
	_ = alt(arms[:])
}

recv :: proc "contextless" (c: ^Chan, v: rawptr) {
	arms := [1]Alt{{c = c, v = v, op = .Recv}}
	_ = alt(arms[:])
}

// nbsend and nbrecv answer false rather than wait.
nbsend :: proc "contextless" (c: ^Chan, v: rawptr) -> bool {
	arms := [2]Alt{{c = c, v = v, op = .Send}, {op = .Noblock}}
	return alt(arms[:]) == 0
}

nbrecv :: proc "contextless" (c: ^Chan, v: rawptr) -> bool {
	arms := [2]Alt{{c = c, v = v, op = .Recv}, {op = .Noblock}}
	return alt(arms[:]) == 0
}

// A pointer or a word as the element, for a channel made with an element
// size of eight. Plan 9's names.
sendp :: proc "contextless" (c: ^Chan, p: rawptr) {
	v := p
	send(c, &v)
}

recvp :: proc "contextless" (c: ^Chan) -> rawptr {
	v: rawptr
	recv(c, &v)
	return v
}

sendul :: proc "contextless" (c: ^Chan, u: u64) {
	v := u
	send(c, &v)
}

recvul :: proc "contextless" (c: ^Chan) -> u64 {
	v: u64
	recv(c, &v)
	return v
}

nbsendp :: proc "contextless" (c: ^Chan, p: rawptr) -> bool {
	v := p
	return nbsend(c, &v)
}

nbrecvp :: proc "contextless" (c: ^Chan) -> (p: rawptr, ok: bool) {
	ok = nbrecv(c, &p)
	return
}

nbsendul :: proc "contextless" (c: ^Chan, u: u64) -> bool {
	v := u
	return nbsend(c, &v)
}

nbrecvul :: proc "contextless" (c: ^Chan) -> (u: u64, ok: bool) {
	ok = nbrecv(c, &u)
	return
}
