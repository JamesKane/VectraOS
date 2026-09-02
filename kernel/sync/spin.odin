/*
The lock that masks, as opposed to the lock that sleeps.

Vectra has exactly one CPU running exactly one thread at a time, and the only
thing that can interrupt either is a trap. So a critical section is `interrupts
off`, and `Spinlock` is a name for that with the nesting handled. `acquire`
reports what the interrupt flag was and `release` puts it back. A lock taken
inside a handler that was already masked therefore does not turn interrupts on
when it finishes.

`Mutex` in `sleep.odin` is the other one, and the two are not interchangeable.
This one may be held anywhere, and must be released within a few instructions.
That one may be held across a wait, and must never be taken inside this one.
`can_sleep` below is how that rule is checked rather than remembered.

There is no lock *word* yet, and that is the honest state of things rather than
an oversight. A second CPU would need one. Added now, it would be a field
nothing reads, guarding an invariant nothing can violate. What matters is that
this tree already found and wrapped every site that will need the word. When the
word arrives it goes in this struct and in these two procedures, and no caller
changes.

    lock := sync.acquire(&heap_lock)
    defer sync.release(&heap_lock, lock)

`Guard` is deliberately not a nil-able handle. A forgotten `defer` leaves
interrupts masked for the rest of the boot, which is loud. The alternative is a
lock that unlocks itself when it leaves scope, and that needs a destructor Odin
does not have.
*/
package sync

import "kernel:arch"

Spinlock :: struct {
	// The lock word goes here. Empty until there is a second CPU to contend
	// for it. See the file comment for why that is a decision rather than a
	// gap.
	//
	// `depth` is not that word. It counts nesting so that `held` stays honest
	// through a re-entrant acquire -- which happens for real: `resize` calls
	// `alloc`, and both take the heap lock.
	depth: int,
}

// Guard carries what `release` has to put back. Opaque on purpose. A caller
// that inspects it is a caller who reasons about the interrupt flag, and that
// is the thing the lock exists to stop.
Guard :: struct {
	interrupts_were_on: bool,
}

acquire :: proc "contextless" (l: ^Spinlock) -> Guard {
	// A nested acquire is safe with no count here. The inner `irq_save` finds
	// interrupts already masked, so its guard says `leave them off`, and only
	// the outermost release turns them back on.
	g := Guard {
		interrupts_were_on = arch.irq_save(),
	}
	l.depth += 1
	critical_depth += 1
	return g
}

release :: proc "contextless" (l: ^Spinlock, g: Guard) {
	l.depth -= 1
	critical_depth -= 1
	arch.irq_restore(g.interrupts_were_on)
}

// held reports whether a lock is currently taken, for an assertion in code
// that must run inside one. It is meaningless on SMP without the word, and the
// callers that use it say so.
held :: proc "contextless" (l: ^Spinlock) -> bool {
	return l.depth > 0
}

/*
How many spinlocks this CPU is inside, counting all of them together.

Not per lock -- `Spinlock.depth` is that. This is a property of the CPU, and it
answers exactly one question. May the code running right now stop running? A
thread inside any spinlock has interrupts masked. If that thread leaves the CPU,
the interrupt flag stays clear and nothing will set it again. That is a hang
with no error, at a point arbitrarily far from the code that caused it.

So every sleeping wait checks this first, and `kernel/vfs` checks it before it
sends a 9P message. See `rpc_begin`. One counter rather than one per CPU,
because there is one CPU. It becomes per-CPU state at the same moment `Spinlock`
grows a word, and for the same reason.

A spinlock is not the only thing that forbids a park. A top half holds none and still may not sleep. It runs on a thread it does not
own, and cannot be the thing put to sleep. That half of the answer is `arch.in_interrupt`, which
the trap dispatcher brackets a handler with, and `can_sleep` reads both.
*/
@(private)
critical_depth: int

// can_sleep reports whether the caller is free to block. It is false inside any
// spinlock, and false inside a top half, which holds no spinlock and still may
// not park. The
// interrupt half of the answer is `arch`'s, because the trap dispatcher is
// where an interrupt is entered and left. See `arch.in_interrupt`.
can_sleep :: proc "contextless" () -> bool {
	return critical_depth == 0 && !arch.in_interrupt()
}
