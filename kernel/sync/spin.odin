/*
The one lock type.

Vectra has exactly one CPU running exactly one thread at a time, and the only
thing that can interrupt either is a trap. So a critical section is "interrupts
off", and `Spinlock` is a name for that with the nesting handled -- `acquire`
reports what the interrupt flag was and `release` puts it back, so a lock taken
inside a handler that was already masked does not turn interrupts on when it
finishes.

There is no lock *word* yet, and that is the honest state of things rather than
an oversight: a second CPU would need one, and adding it now would be a field
nothing reads guarding an invariant nothing can violate. What matters is that
every site that will need the word has already been found and wrapped. When the
word arrives it goes in this struct and in these two procedures, and no caller
changes.

    lock := sync.acquire(&heap_lock)
    defer sync.release(&heap_lock, lock)

`Guard` is deliberately not a nil-able handle: forgetting the `defer` leaves
interrupts masked for the rest of the boot, which is loud, and the alternative
-- a lock that unlocks itself when it goes out of scope -- needs a destructor
Odin does not have.
*/
package sync

import "kernel:arch"

Spinlock :: struct {
	// The lock word goes here. Empty until there is a second CPU to contend
	// for it; see the file comment for why that is a decision rather than a
	// gap.
	//
	// `depth` is not that word. It counts nesting so that `held` stays honest
	// through a re-entrant acquire -- which happens for real: `resize` calls
	// `alloc`, and both take the heap lock.
	depth: int,
}

// Guard carries what `release` has to put back. Opaque on purpose -- a caller
// that inspects it is a caller reasoning about the interrupt flag, which is
// the thing the lock exists to stop them doing.
Guard :: struct {
	interrupts_were_on: bool,
}

acquire :: proc "contextless" (l: ^Spinlock) -> Guard {
	// Nesting is safe without counting anything here: the inner `irq_save`
	// finds interrupts already masked, so its guard says "leave them off" and
	// only the outermost release turns them back on.
	g := Guard {
		interrupts_were_on = arch.irq_save(),
	}
	l.depth += 1
	return g
}

release :: proc "contextless" (l: ^Spinlock, g: Guard) {
	l.depth -= 1
	arch.irq_restore(g.interrupts_were_on)
}

// held reports whether a lock is currently taken, for an assertion in code
// that must run inside one. Meaningless on SMP without the word; the callers
// that use it say so.
held :: proc "contextless" (l: ^Spinlock) -> bool {
	return l.depth > 0
}
