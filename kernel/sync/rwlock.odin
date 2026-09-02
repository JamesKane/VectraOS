/*
The read/write lock that sleeps, which is Plan 9's `RWlock` to the line.

`kernel/sync/sleep.odin` is a mutex: one holder, and the losers park. A union
search needs something a mutex cannot give. Every walker of a mount point reads the member list and sends a message per
member. It must see the same list at the end that it saw at the start. Many walkers may do that at once,
and a `bind` has to wait for all of them and then have the list to itself.
That is a reader/writer lock, held across messages, which only a lock that
sleeps can be.

**The design is `port/qlock.c`'s, and nothing here is new.** Vectra had a
counter instead, `Mount_Point.generation`, because its only lock was the
interrupt flag and a search could not hold that across a message. The mutex
retired that reason and this file retires the counter. Plan 9's rules, in
Plan 9's order:

    rlock      no writer and nobody queued: one more reader, straight in.
               Otherwise queue, behind whoever is already there.
    runlock    the last reader out starts the writer at the head of the
               queue, and there is always a writer there if anyone is.
    wlock      no readers and no writer: take it. Otherwise queue.
    wunlock    a writer at the head takes over. Otherwise every reader at
               the head goes in together, up to the first writer.

Two consequences are the whole policy. A reader arriving behind a queued
writer waits, so a stream of readers cannot starve a writer. And the queue is
served in arrival order, so a writer cannot starve readers.

**Arrival order, and not the mutex's priority handoff.** `sleep.odin` hands a
mutex to the highest-priority waiter, for reasons `wait.odin` argues. This
lock does not, and the reason is what the queue holds. A mutex queue holds
one kind of waiter. This one holds two, and the rules above are statements
about *position*. A reader waits because a writer is ahead of it, and a
writer runs because it reached the head.

A best-first scan would have to decide whether a high-priority reader may
pass a queued writer. That is a policy Plan 9 never needed and this tree does
not want to invent. The wake is still `unpark` rather than `ready`, because
a lock's waiter queued behind another thread doing exactly what it was
doing. That is the scheduler's distinction and not the lock's.

Nodes live on the waiting thread's stack, interrupts stand in for `q->use`,
and the scheduler comes through `hooks`, all as `wait.odin` says.
*/
package sync


RW_Lock :: struct {
	readers: int,
	writer:  bool,
	owner:   Waiter, // The writer, so a thread that deadlocks against itself is named
	queue:   Wait_Queue,
}

/*
rlock takes the lock for reading, and parks behind anyone already queued.

The second condition is the one that matters: a reader that finds the lock
free of writers but the queue not empty still waits. What is queued is a writer, or readers behind a writer. A reader that passed
them would keep the writer out for as long as readers kept arriving. Plan 9's `rlock` has
exactly this test, `q->writer == 0 && q->head == nil`.
*/
rlock :: proc "contextless" (l: ^RW_Lock) {
	if !can_sleep() {
		fail("read lock taken inside a spinlock")
	}
	g := acquire(&wait_lock)

	if !l.writer && !waiting(&l.queue) {
		l.readers += 1
		release(&wait_lock, g)
		return
	}
	if !have_sched {
		release(&wait_lock, g)
		fail("read lock contended before there is a scheduler to park on")
	}
	me := hooks.current()
	if l.writer && me != nil && l.owner == me {
		release(&wait_lock, g)
		fail("read lock taken by the thread that holds it for writing")
	}

	node := Wait_Node {
		waiter  = me,
		writing = false,
	}
	push(&l.queue, &node)
	sleeps += 1
	release(&wait_lock, g)

	// Park unless the wake came first. Whoever woke this thread counted it
	// as a reader before the wake, so there is nothing to re-check. See
	// `wunlock`.
	hooks.block(cast(^rawptr)&node.queue)
}

/*
runlock releases one reader, and the last one out starts the writer.

If anyone is queued while readers hold the lock, the head of the queue is a
writer: readers only queue behind one. So the last reader hands the lock to
that writer directly, the way `mutex_unlock` hands a mutex over, and the
writer wakes owning it.
*/
runlock :: proc "contextless" (l: ^RW_Lock) {
	g := acquire(&wait_lock)

	if l.readers <= 0 {
		release(&wait_lock, g)
		fail("read lock released while free")
	}
	l.readers -= 1
	if l.readers > 0 || !waiting(&l.queue) {
		release(&wait_lock, g)
		return
	}

	n := take_first(&l.queue)
	if !n.writing {
		release(&wait_lock, g)
		fail("a reader was queued behind no writer")
	}
	w := n.waiter
	l.writer = true
	l.owner = w
	handoffs += 1
	release(&wait_lock, g)
	hooks.unpark(w)
}

// wlock takes the lock for writing: alone, after every reader and writer
// ahead of it.
wlock :: proc "contextless" (l: ^RW_Lock) {
	if !can_sleep() {
		fail("write lock taken inside a spinlock")
	}
	g := acquire(&wait_lock)

	me := have_sched ? hooks.current() : nil

	if l.readers == 0 && !l.writer {
		l.writer = true
		l.owner = me
		release(&wait_lock, g)
		return
	}
	if have_sched && me != nil && l.writer && l.owner == me {
		release(&wait_lock, g)
		fail("write lock taken twice by the same thread")
	}
	if !have_sched {
		release(&wait_lock, g)
		fail("write lock contended before there is a scheduler to park on")
	}

	node := Wait_Node {
		waiter  = me,
		writing = true,
	}
	push(&l.queue, &node)
	sleeps += 1
	release(&wait_lock, g)

	// Handed over, as a reader is: `runlock` or `wunlock` set `writer` and
	// `owner` before the wake, so a park that the wake beat is skipped and
	// a park it did not is ended by it.
	hooks.block(cast(^rawptr)&node.queue)
}

/*
wunlock releases the writer, and starts whoever is at the head of the queue.

A writer at the head takes over alone. Readers at the head go in together,
every one of them up to the first writer. Readers share, and there is no
reason to wake one and leave the next to wait for nothing. That run of
readers is what Plan 9's `wunlock` loop wakes, `while(q->head != nil &&
q->head->state == QueueingR)`.
*/
wunlock :: proc "contextless" (l: ^RW_Lock) {
	g := acquire(&wait_lock)

	if !l.writer {
		release(&wait_lock, g)
		fail("write lock released while free")
	}

	head := l.queue.head
	if head == nil {
		l.writer = false
		l.owner = nil
		release(&wait_lock, g)
		return
	}

	if head.writing {
		n := take_first(&l.queue)
		w := n.waiter
		l.owner = w
		handoffs += 1
		release(&wait_lock, g)
		hooks.unpark(w)
		return
	}

	// Every reader at the head goes in together. They are counted under the
	// list lock and started outside it, one at a time, because a start takes
	// the scheduler's lock and this package takes that one last.
	l.writer = false
	l.owner = nil
	for {
		if l.queue.head == nil || l.queue.head.writing {
			release(&wait_lock, g)
			return
		}
		n := take_first(&l.queue)
		w := n.waiter
		l.readers += 1
		handoffs += 1
		release(&wait_lock, g)
		hooks.unpark(w)
		g = acquire(&wait_lock)
	}
}

// rw_readers and rw_writer report the lock's state, for checks in code that
// must run inside it and for the self-test.
rw_readers :: proc "contextless" (l: ^RW_Lock) -> int {
	return l.readers
}

rw_writer :: proc "contextless" (l: ^RW_Lock) -> bool {
	return l.writer
}
