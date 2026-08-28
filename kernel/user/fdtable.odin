/*
The descriptor table as an object: one group of open files, shared or not.

Until this file the table was a field, and the field was the sharing rule:
one process, one table, no question. `rfork` asks the question.

Plan 9's default is that a forked process *shares* its parent's descriptor
group.
Two processes advancing one cursor is a coordination tool, not an accident.
`RFFDG` is the flag that asks for a copy instead. A field cannot be
shared. An object with a count can.

Two locks guard two different things, and the split is deliberate:

    the pool lock     who owns a slot, and the reference counts
    the table lock    the entries of one table, and their cursors

Every mutation of a table was a bare read-modify-write when one thread per
table made that safe. Two sharers make every one of them a race: two opens
claiming one slot, a lost cursor update across a preemption. The table lock
is the answer, and it is a spinlock because nothing under it parks.

**What a caller gets is never a borrow.** `fd_take` hands back the chan with
a reference of its own, taken under the lock. The old accessor handed out a
pointer into the table. A sibling's `close` could free the chan while a
read was parked on it. The freed *slot* could then go to an unrelated
`open`, so the parked read's cursor update landed on a stranger.

Take a reference, use it, give it back. The cursor moves through
`fd_advance`, which looks the slot up again and declines quietly if the
descriptor changed hands in between.

**Release order is an invariant, not a habit.** The exit paths detach the
table and release it in thread context, where a clunk is legal, *before*
the exit record is published. `unload` releases only what is
still attached. One release per holder, whichever paths run.

Lock order: `/srv`'s spinlock is taken before a table's, never after.
`resolve_fd_chan` runs under `/srv`'s lock and takes the table's inside it.
*/
package user

import "kernel:sync"
import "kernel:vfs"

Fd_Table :: struct {
	refs: int,
	lock: sync.Spinlock,
	fds:  [MAX_FDS]Fd,
}

// One table per process at the ceiling, plus slack for a fork that holds
// a fresh copy beside the one it copies from.
MAX_FD_TABLES :: MAX_PROCESSES + 4

@(private = "file")
Fd_Table_Slot :: struct {
	table: Fd_Table,
	used:  bool,
}

@(private = "file")
fd_tables: [MAX_FD_TABLES]Fd_Table_Slot

@(private = "file")
fdt_pool_lock: sync.Spinlock

@(private = "file")
live_tables: int

// fdt_stats reports how many tables are claimed, for the balance checks.
fdt_stats :: proc "contextless" () -> int {
	guard := sync.acquire(&fdt_pool_lock)
	defer sync.release(&fdt_pool_lock, guard)
	return live_tables
}

// fdt_new claims an empty table with one reference.
@(private)
fdt_new :: proc "contextless" () -> ^Fd_Table #no_bounds_check {
	guard := sync.acquire(&fdt_pool_lock)
	defer sync.release(&fdt_pool_lock, guard)

	for i in 0 ..< MAX_FD_TABLES {
		if !fd_tables[i].used {
			fd_tables[i].used = true
			fd_tables[i].table = Fd_Table {
				refs = 1,
			}
			live_tables += 1
			return &fd_tables[i].table
		}
	}
	return nil
}

// fdt_incref is one more process on the same group.
@(private)
fdt_incref :: proc "contextless" (t: ^Fd_Table) {
	if t == nil {
		return
	}
	guard := sync.acquire(&fdt_pool_lock)
	t.refs += 1
	sync.release(&fdt_pool_lock, guard)
}

/*
fdt_release is one holder gone, and the last one closes what is open.

The closes happen with no lock held, because a clunk is a message and a
message may park. The entries are copied out and the slot given back first,
so a concurrent `fdt_new` finds a clean record. **Thread context only** --
the exit paths run it before they publish the exit record, and `unload` runs
it from a collector. A fault handler never touches a table.
*/
@(private)
fdt_release :: proc(t: ^Fd_Table) #no_bounds_check {
	if t == nil {
		return
	}

	guard := sync.acquire(&fdt_pool_lock)
	t.refs -= 1
	if t.refs > 0 {
		sync.release(&fdt_pool_lock, guard)
		return
	}
	held: [MAX_FDS]Fd = t.fds
	for i in 0 ..< MAX_FD_TABLES {
		if &fd_tables[i].table == t {
			fd_tables[i].used = false
			break
		}
	}
	live_tables -= 1
	sync.release(&fdt_pool_lock, guard)

	for i in 0 ..< MAX_FDS {
		if held[i].chan != nil {
			vfs.chan_close(held[i].chan)
		}
	}
}

// fdt_copy fills a fresh table with another's entries, number for number.
// Each chan referenced again, each cursor the copy's own from here on --
// `RFFDG`'s rule and `spawn`'s. The source's lock holds its table still
// while the numbers cross.
@(private)
fdt_copy :: proc "contextless" (src: ^Fd_Table) -> ^Fd_Table #no_bounds_check {
	fresh := fdt_new()
	if fresh == nil || src == nil {
		return fresh
	}
	guard := sync.acquire(&src.lock)
	for i in 0 ..< MAX_FDS {
		if src.fds[i].chan == nil {
			continue
		}
		fresh.fds[i] = Fd {
			chan   = vfs.chan_incref(src.fds[i].chan),
			offset = src.fds[i].offset,
		}
	}
	sync.release(&src.lock, guard)
	return fresh
}

// -- The per-descriptor operations, each one critical section ----------------

/*
fd_open puts a chan in the lowest free slot and reports the number.

Lowest free, which is the rule every system with a shell depends on. A
program that closes descriptor 1 and opens a file gets descriptor 1 back.
The chan's reference belongs to the table from here on.
*/
@(private)
fd_open :: proc "contextless" (p: ^Process, c: ^vfs.Chan) -> (int, bool) #no_bounds_check {
	if p == nil || p.fdt == nil || c == nil {
		return 0, false
	}
	guard := sync.acquire(&p.fdt.lock)
	defer sync.release(&p.fdt.lock, guard)

	for i in 0 ..< MAX_FDS {
		if p.fdt.fds[i].chan == nil {
			p.fdt.fds[i] = Fd {
				chan = c,
			}
			return i, true
		}
	}
	return 0, false
}

/*
fd_take is how a system call gets a descriptor's chan: with a reference of
its own, and a snapshot of the cursor. Never a pointer into the table -- see
the file comment for the close-under-a-parked-read story that rule buys off.
The caller closes the chan when the operation is done, whatever happened.
*/
@(private)
fd_take :: proc "contextless" (p: ^Process, fd: int) -> (c: ^vfs.Chan, offset: u64, ok: bool) #no_bounds_check {
	if p == nil || p.fdt == nil || fd < 0 || fd >= MAX_FDS {
		return nil, 0, false
	}
	guard := sync.acquire(&p.fdt.lock)
	defer sync.release(&p.fdt.lock, guard)

	if p.fdt.fds[fd].chan == nil {
		return nil, 0, false
	}
	return vfs.chan_incref(p.fdt.fds[fd].chan), p.fdt.fds[fd].offset, true
}

/*
fd_advance moves the cursor after an operation, if the descriptor still
means what it meant. The chan is the identity check: a slot closed and
reopened holds a different one, and the update declines rather than move a
stranger's cursor. An advance lost this way is the shared-table semantic,
not an error -- the close that raced it was allowed to win.
*/
@(private)
fd_advance :: proc "contextless" (p: ^Process, fd: int, c: ^vfs.Chan, delta: u64) #no_bounds_check {
	if p == nil || p.fdt == nil || fd < 0 || fd >= MAX_FDS {
		return
	}
	guard := sync.acquire(&p.fdt.lock)
	defer sync.release(&p.fdt.lock, guard)

	if p.fdt.fds[fd].chan == c {
		p.fdt.fds[fd].offset += delta
	}
}

// fd_seek sets the cursor outright, under the same identity rules a program
// already lives with: the slot it names is whatever the slot holds now.
@(private)
fd_seek :: proc "contextless" (p: ^Process, fd: int, offset: u64) -> bool #no_bounds_check {
	if p == nil || p.fdt == nil || fd < 0 || fd >= MAX_FDS {
		return false
	}
	guard := sync.acquire(&p.fdt.lock)
	defer sync.release(&p.fdt.lock, guard)

	if p.fdt.fds[fd].chan == nil {
		return false
	}
	p.fdt.fds[fd].offset = offset
	return true
}

// fd_close takes the entry out under the lock and closes the chan after.
// A clunk may park, and nothing may hold a spinlock across one.
@(private)
fd_close :: proc(p: ^Process, fd: int) -> bool #no_bounds_check {
	if p == nil || p.fdt == nil || fd < 0 || fd >= MAX_FDS {
		return false
	}
	guard := sync.acquire(&p.fdt.lock)
	c := p.fdt.fds[fd].chan
	p.fdt.fds[fd] = Fd{}
	sync.release(&p.fdt.lock, guard)

	if c == nil {
		return false
	}
	vfs.chan_close(c)
	return true
}

// fd_count reports how many descriptors a process holds, for a self-test
// that wants to say a close really closed one.
fd_count :: proc "contextless" (p: ^Process) -> int #no_bounds_check {
	if p == nil || p.fdt == nil {
		return 0
	}
	guard := sync.acquire(&p.fdt.lock)
	defer sync.release(&p.fdt.lock, guard)

	n := 0
	for i in 0 ..< MAX_FDS {
		if p.fdt.fds[i].chan != nil {
			n += 1
		}
	}
	return n
}
