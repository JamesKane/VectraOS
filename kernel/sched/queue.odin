/*
The run queues: one FIFO per priority level, per core.

Picking is "highest non-empty level, then round-robin within it", which is the
whole of the policy. Everything that makes the policy interesting -- decay,
boost, capacity-scaled slices -- happens elsewhere and shows up here only as
which queue a thread lands in.

Sixteen levels scanned downward rather than a bitmask and a bit-scan. At one
tick a millisecond, sixteen iterations of a loop that reads one pointer is not
where the time goes. The loop also says what it does. The bitmask is what this
becomes if the levels ever multiply.

Every procedure here requires interrupts to be off. They are called from the
timer handler, where that is already true, and from `ready`, which makes it
true. Nothing takes a lock, because on one core that is what "interrupts off"
already means -- see `kernel/sync`.
*/
package sched

import "kernel:arch"

Queue :: struct {
	head:  ^Thread,
	tail:  ^Thread,
	count: int,
}

Run_Queue :: struct {
	level: [PRIORITY_LEVELS]Queue,
	ready: int,
}

@(private)
queue_push :: proc "contextless" (q: ^Queue, t: ^Thread) {
	t.next = nil
	if q.tail == nil {
		q.head = t
	} else {
		q.tail.next = t
	}
	q.tail = t
	q.count += 1
}

@(private)
queue_pop :: proc "contextless" (q: ^Queue) -> ^Thread {
	t := q.head
	if t == nil {
		return nil
	}
	q.head = t.next
	if q.head == nil {
		q.tail = nil
	}
	q.count -= 1
	t.next = nil
	return t
}

/*
enqueue puts a ready thread on a core's queue at its current priority.

Onto the *tail*, always. A freshly preempted thread goes behind everything else
at its level, which is the round robin. A freshly boosted thread goes behind
everything at the level the boost took it to, which is usually nothing, so it
runs next.

The idle thread never joins a queue. It lives in `cpu.idle`, and only an empty
set of queues reaches it. On a queue it would sit in a level where `pick` could
take it ahead of a runnable thread.
*/
enqueue :: proc "contextless" (c: ^Cpu, t: ^Thread) #no_bounds_check {
	if t == nil || t == c.idle {
		return
	}

	level := clamp_priority(t.prio)
	queue_push(&c.runq.level[level], t)
	c.runq.ready += 1
	t.cpu = c
	t.state = .Ready
}

/*
dequeue_highest takes the next thread to run, or nil when there is none.

Nil means the idle thread, and that decision is the caller's rather than this
one's. `reschedule` has to know the difference, to keep the idle thread's
bookkeeping out of the round-robin statistics.
*/
dequeue_highest :: proc "contextless" (c: ^Cpu) -> ^Thread #no_bounds_check {
	if c.runq.ready == 0 {
		return nil
	}
	for level := PRIORITY_LEVELS - 1; level >= 0; level -= 1 {
		if t := queue_pop(&c.runq.level[level]); t != nil {
			c.runq.ready -= 1
			return t
		}
	}
	return nil
}

// remove unlinks a specific thread from whatever queue it is on. Linear in the
// length of its level, which is fine for the one caller. That caller kills a
// thread while it is merely ready, rather than running.
remove :: proc "contextless" (c: ^Cpu, t: ^Thread) -> bool #no_bounds_check {
	level := clamp_priority(t.prio)
	q := &c.runq.level[level]

	prev: ^Thread
	for cur := q.head; cur != nil; cur = cur.next {
		if cur == t {
			if prev == nil {
				q.head = cur.next
			} else {
				prev.next = cur.next
			}
			if q.tail == cur {
				q.tail = prev
			}
			q.count -= 1
			c.runq.ready -= 1
			t.next = nil
			return true
		}
		prev = cur
	}
	return false
}

/*
clamp_priority is the one place a priority becomes an array index.

Nothing should ever hand it an out-of-range value. If something does, the wrong
thread runs, and that is a far better outcome than an index off the end of a
core's queue array. That index would corrupt whatever the linker put next to it,
and surface as a fault somewhere unrelated.
*/
@(private)
clamp_priority :: proc "contextless" (p: Priority) -> int {
	if p < 0 {
		return 0
	}
	if p > PRIORITY_MAX {
		return int(PRIORITY_MAX)
	}
	return int(p)
}

// ready_count is what the boot self-test reports and what a future `/proc`
// will read: how many threads are waiting for this core right now.
ready_count :: proc "contextless" (c: ^Cpu) -> int {
	return c.runq.ready
}

/*
Which core a newly-runnable thread should land on.

The heterogeneous half of the scheduler, and the one place the `class` and
`capacity` fields on a `Cpu` do real work. `enqueue` puts a thread on a named
core. `pick_cpu` names it, at the two moments a thread arrives on the ready side
from nowhere: a `spawn`, and a wake. A thread the timer re-queues stays where it
ran. Moving it would throw away its warm cache and its half-spent slice.

The rule is two comparisons, in order:

  1. `affinity` is a hard filter. A thread that named a set of classes runs on
     one of them. If none is online, it runs on the boot core, which always
     dispatches. So a thread is never stranded on a class not here yet.
  2. Among the cores it may use, the least loaded wins, where load is per unit of
     capacity. A core at twice the capacity carries twice the threads before it
     is as loaded. That sends steady work to the big cores and keeps the little
     ones for the overflow. A tie goes to the faster core, so an idle machine
     uses its best core first.

On one core this returns that core every time, which is why it changed no
behaviour the day it landed. It earns its keep when a second core of a
different class comes online. `docs/SCHED.md` argues the policy, and
`kernel/sched/verify.odin` drives it against a fabricated three-class machine.
*/
pick_cpu :: proc "contextless" (affinity: Cpu_Classes, pool: []Cpu) -> ^Cpu #no_bounds_check {
	if len(pool) == 0 {
		return nil
	}

	best: ^Cpu
	for i in 0 ..< len(pool) {
		c := &pool[i]
		if !c.online || !class_allowed(affinity, c.class) {
			continue
		}
		if best == nil || better_host(c, best) {
			best = c
		}
	}

	// An affinity nothing online satisfies still has to run somewhere. The boot
	// core always dispatches, so it is the honest fallback until the class the
	// thread asked for is actually present. See `docs/SCHED.md`.
	if best == nil {
		return &pool[0]
	}
	return best
}

// better_host reports whether `a` is a better landing than `b`: less loaded per
// unit of capacity, and a tie to the faster core. See `pick_cpu`.
@(private = "file")
better_host :: proc "contextless" (a, b: ^Cpu) -> bool {
	la := load_ratio(a)
	lb := load_ratio(b)
	if la != lb {
		return la < lb
	}
	return a.capacity > b.capacity
}

// load_ratio is a core's ready count scaled to a common capacity, so two cores
// of different speeds compare on the same axis. A core with no capacity yet --
// a zero-value slot -- reads as fully loaded rather than as infinitely fast.
@(private = "file")
load_ratio :: proc "contextless" (c: ^Cpu) -> int {
	if c.capacity <= 0 {
		return max(int)
	}
	return c.runq.ready * arch.CAPACITY_FULL / c.capacity
}
