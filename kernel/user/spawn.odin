/*
A process that starts another one.

Everything before this file makes processes out of the kernel's own
decisions. `load` takes bytes only the kernel can see, from a caller only the
kernel can be. This file is the other arrangement, the one the handoff calls
the step before `servers/` stops being empty. **A process names a file in its
own namespace, and the kernel builds a process out of what the file says.**

## Spawn, which is fork and exec with the seam half cut

Plan 9 starts a process with `rfork` and then `exec`. The seam between them
is where a shell rearranges the child: point descriptors somewhere, bind a
namespace into shape, then replace the program. `rfork.odin` cut the seam
from the creating side, exactly as this file promised: a copied trap
frame, copied user pages, removal rather than redesign. What `spawn`
remains is the whole arc as one call: a new process, running a named file,
inheriting what its parent chose. The `exec` that replaces a running image
is the half still fused, and a shell is what will demand it.

## What a child inherits

Three things, each by its own rule:

    the namespace     shared, copied, or clean -- the caller says which
    the descriptors   copied: same chans, referenced again, own cursors
    the program       none of it -- text, data and stack are fresh

Sharing a namespace means a `bind` in either process moves both, which is how
a shell's bind reaches its children. Copying means the child starts identical
and diverges. Clean means the child can name nothing until someone binds it a
world. The loader reads through the *parent's* namespace, so a clean child
still loads. It just cannot open what it did not inherit.

The descriptors are copied rather than shared: the chan is referenced again,
the offset is the child's own from there on. Two processes advancing one
shared cursor is a coordination tool Plan 9 keeps, and it arrived with
`rfork` -- a fork without `RFFDG` shares the group. Spawn keeps the copy.

## Wait, and who reaps

A parent collects a child by pid: `wait` reports how the child ended and only
then takes its record down. That closing step is the answer to a question
`destroy`'s file comment left open -- when nothing is watching a process, who
gives its space back? Now the parent is the watcher of record, and a child
nobody waits for stays, visibly, in `stats().live`. The kernel still reaps
what it started itself, in the self-tests, the same way it always has.

`wait` parks on the exit rendezvous, and every path out of a process wakes
it. The wake from a fault is legal because `sync.wakeup_all` masks rather
than enables. A noted child answers EINTR, a faulted one EIO, and a
deliberate one its own status.
*/
package user

import "base:intrinsics"

import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:abi"
import "vsys:vectra9"

/*
What a spawned child gets for a namespace, as bits a program can pass.

The default, zero, is share -- `ns_fork`'s own default, and Plan 9's. Copy and
clean are the other two of its three cases. Copy-and-clean together means
clean, which `ns_fork` already decides. The bits are not re-judged here.
*/
SPAWN_NS_COPY :: abi.SPAWN_NS_COPY
SPAWN_NS_CLEAN :: abi.SPAWN_NS_CLEAN

// And whether it gets the descriptors. Zero copies them, which is what every
// child that prints wants. The bit gives a child nothing at all -- Plan 9's
// RFCFDG -- for a parent building a sandbox.
SPAWN_FD_CLEAN :: abi.SPAWN_FD_CLEAN

/*
How long `wait` watches before it reports nothing happened.

A bound for the same reason `SLEEP_MAX` is one. A call that can park a thread
for ever is a call that can park it past the end of the boot. A parent whose
child outlives the bound gets EAGAIN and may ask again, which every caller of
a bounded wait already handles.
*/
WAIT_PATIENCE :: 500

/*
spawn_path builds a process out of a file, on behalf of another process.

`parent` may be nil, which is the kernel launching -- the self-tests use it,
and it is what `load` is to the baked blobs. A nil parent reads through the
boot namespace and marks the child as the kernel's own, so no process can
`wait` it away.

The order below is the order that can fail safely. The image is read before
the thread exists, so a bad file costs an empty process record and nothing
runs. The descriptors are copied before the thread too, because the child's
first instruction may write to one.
*/
spawn_path :: proc(parent: ^Process, path: string, flags: u64 = 0) -> (^Process, vfs.Errno) {
	source := parent != nil ? parent.ns : vfs.boot_namespace
	if source == nil || len(path) == 0 || len(path) > PATH_MAX {
		return nil, vectra9.EINVAL
	}

	// Collect any detached orphan whose record is still held, so a spawn is
	// never refused for a slot a dead worker is sitting on. See `reap_orphans`.
	reap_orphans()

	p := free_slot()
	if p == nil {
		// The table is full, which is a resource the caller can wait for
		// rather than a request that can never work.
		return nil, vectra9.EAGAIN
	}

	space, merr := mem.space_new()
	if merr != .None {
		return nil, vectra9.ENOMEM
	}
	p^ = Process {
		space      = space,
		live       = true,
		pid        = next_pid,
		parent     = parent != nil ? parent.pid : 0,
		note_group = parent != nil ? parent.note_group : next_pid,
	}
	next_pid += 1

	// The path, copied home. The caller's string may live on a syscall
	// stack, and this record outlives that stack by the child's lifetime.
	for i in 0 ..< len(path) {
		p.name_buf[i] = path[i]
	}
	p.name = string(p.name_buf[:len(path)])

	ns_flags: vfs.Fork_Flags
	if flags & SPAWN_NS_COPY != 0 {
		ns_flags += {.Copy}
	}
	if flags & SPAWN_NS_CLEAN != 0 {
		ns_flags += {.Clean}
	}
	p.ns = vfs.ns_fork(source, ns_flags)
	if p.ns == nil {
		unload(p)
		return nil, vectra9.ENOMEM
	}

	// The loader, reading through the parent's namespace rather than the
	// child's. The child's may be clean, and an exec reads through the
	// namespace of whoever asked. Which shape the process gets -- three
	// named pages, or segments and a deeper stack -- is the file's to say.
	// See `load_program`.
	entry, sp, arg0, lerr := load_program(p, source, path)
	if lerr != vfs.OK {
		unload(p)
		return nil, lerr
	}

	// A table exists whichever flag was passed. Clean means empty, not
	// absent -- a child with no descriptors can still open. Spawn's rule is
	// a copy, which is `RFFDG`'s. Sharing is `rfork`'s default, not this
	// call's.
	if flags & SPAWN_FD_CLEAN == 0 && parent != nil {
		p.fdt = fdt_copy(parent.fdt)
	} else {
		p.fdt = fdt_new()
	}
	if p.fdt == nil {
		unload(p)
		return nil, vectra9.ENOMEM
	}
	if flags & SPAWN_FD_CLEAN == 0 && parent == nil {
		open_standard(p)
	}

	p.thread = sched.spawn_user(p.name, space, entry, sp, arg0, 0, 0, p)
	if p.thread == nil {
		unload(p)
		return nil, vectra9.ENOMEM
	}
	p.kstack_lo = uintptr(raw_data(p.thread.stack))
	p.kstack_hi = p.thread.kstack_top

	loaded += 1
	if parent != nil {
		spawned += 1
	}
	return p, vfs.OK
}

/*
wait_pid collects one ended child, and reports how it ended.

Only a child, by the `parent` field, and only the caller's. A pid that is
somebody else's child gets ECHILD exactly like a pid that never existed. A
process therefore learns nothing about the table by waiting. The answer is
the child's own exit status when it asked to stop, and EIO when a fault
stopped it. Those are two endings a parent has different plans for.

Collecting is destroying. After this returns, the pid names nothing and a
second wait on it is ECHILD. The child's space, frames, namespace and files
are the machine's again. A child that has not ended within the bound stays
fully alive, and the caller hears EAGAIN rather than waits for ever.
*/
wait_pid :: proc(caller_pid: u64, pid: u64, patience: int) -> i64 {
	child := find_child(caller_pid, pid)
	if child == nil {
		return -i64(vectra9.ECHILD)
	}

	// Parked rather than polled, at last. Every path out of a process wakes
	// the exit rendezvous. The condition is this child's own record, so a
	// wake for a stranger's child costs one re-check.
	if !sync.sleep_for(&exit_rendez, exit_done, child, u64(patience)) {
		return -i64(vectra9.EAGAIN)
	}

	answer: i64
	switch {
	case child.exit.noted:
		// A note ended it, and EINTR is that sentence in one word. Distinct
		// from EIO on purpose: a parent that noted its own child expects
		// this, where a fault it did not ask for is news.
		answer = -i64(vectra9.EINTR)
	case child.exit.deliberate:
		// The low half, so a status can never wander into the negative
		// numbers where the errnos live. Nothing exits with 4 GiB to say.
		answer = i64(u32(child.exit.status))
	case:
		answer = -i64(vectra9.EIO)
	}

	// The child ended and this thread saw it end, which is what `collect`
	// demands. On one core the dying thread left for good before anything
	// else ran. `collect` re-checks the record all the same, by the pid this
	// caller named rather than by the slot.
	_ = collect(child, pid)
	return answer
}

/*
find_child looks a live child up by pid, on the caller's behalf.

Linear over a table of twelve, like every lookup in this package. The `live`
check and the pid check together are what slot reuse demands. A slot holds a
new process the moment the old one goes. The pid is the field that never
lies about which tenant answered.
*/
@(private)
find_child :: proc "contextless" (caller_pid: u64, pid: u64) -> ^Process #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if p.live && p.pid == pid && p.parent == caller_pid {
			return p
		}
	}
	return nil
}
