/*
A lock a thread may hold across a wait, and a rendezvous under it.

`libuser.Spin` parks nothing. A waiter yields the core and tries again.
A thread that holds one across a channel wait would stop every other
thread of the program that wants it.

`QLock` is the other kind. A waiter parks *the thread*, and its proc goes
on to the next. The release hands the lock to the oldest waiter and
readies it, from whichever proc lets go. Plan 9's `qlock`, in
`libthread`'s shape.

`Rendez` is a condition under a `QLock`: `rsleep` lets the lock go and
parks until an `rwakeup`, and holds the lock again when it returns. The
caller re-checks its condition, because a wake is a hint. `kernel/sync`
draws the same line, and `docs/STYLE.md` names it.
*/
package libthread

import "vsys:libuser"

QLock :: struct {
	l:     libuser.Spin, // Over the three fields below, for the length of a queue move
	owner: ^Thread,
	head:  ^Thread,
	tail:  ^Thread,
}

qlock :: proc "contextless" (q: ^QLock) {
	t := self()
	libuser.lock(&q.l)
	if q.owner == nil {
		q.owner = t
		libuser.unlock(&q.l)
		return
	}
	t.next = nil
	if q.head == nil {
		q.head = t
	} else {
		q.tail.next = t
	}
	q.tail = t
	libuser.unlock(&q.l)
	block()
	// The release made this thread the owner before it readied it.
}

// canqlock takes the lock if nobody holds it, and says whether it did.
canqlock :: proc "contextless" (q: ^QLock) -> bool {
	libuser.lock(&q.l)
	taken := q.owner == nil
	if taken {
		q.owner = self()
	}
	libuser.unlock(&q.l)
	return taken
}

// qunlock hands the lock to the oldest waiter, or frees it.
qunlock :: proc "contextless" (q: ^QLock) {
	libuser.lock(&q.l)
	t := q.head
	if t != nil {
		q.head = t.next
		if q.head == nil {
			q.tail = nil
		}
		t.next = nil
	}
	q.owner = t
	libuser.unlock(&q.l)
	if t != nil {
		threadready(t)
	}
}

Rendez :: struct {
	l:    ^QLock, // Held by every caller of the three procedures below
	head: ^Thread,
	tail: ^Thread,
}

// rsleep parks until an `rwakeup`, with `r.l` released meanwhile and held
// again on return.
rsleep :: proc "contextless" (r: ^Rendez) {
	t := self()
	t.next = nil
	if r.head == nil {
		r.head = t
	} else {
		r.tail.next = t
	}
	r.tail = t
	qunlock(r.l)
	block()
	qlock(r.l)
}

// rwakeup readies the oldest sleeper, and says whether there was one.
rwakeup :: proc "contextless" (r: ^Rendez) -> bool {
	t := r.head
	if t == nil {
		return false
	}
	r.head = t.next
	if r.head == nil {
		r.tail = nil
	}
	t.next = nil
	threadready(t)
	return true
}

// rwakeupall readies every sleeper, and answers how many.
rwakeupall :: proc "contextless" (r: ^Rendez) -> int {
	n := 0
	for rwakeup(r) {
		n += 1
	}
	return n
}
