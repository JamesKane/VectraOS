/*
rfork: a process that continues from the call site, by Plan 9's rules.

`spawn` is fork and exec as one arc, and its file says cutting the seam is
removal rather than redesign. This file is the cut's first half. A process
calls `rfork(RFPROC)` and two processes return from it. The parent gets
the child's pid and the child gets zero, both at the instruction after the
`syscall`. The other half, an `exec` in place, stays where the seam
documents left it.

## What continuing from the call site costs

Three copies, none of them optional:

    the trap frame     every register the door saved, answered rax = 0
    the FXSAVE image   the caller's FPU state at the door
    the stack          the frames behind it, at the same addresses

The frame and image go onto the child's own kernel stack, in the layout
every thread resumes from -- `arch.thread_user_clone`. The stack copy is
what makes the copied RSP mean something: the child's stack addresses are
the parent's, backed by the child's own frames. **That is also why the
stack is never shared, whatever the flags say.** Two threads returning
through one stack would unwind each other. Plan 9's rule is the same, for
the same reason: `RFMEM` shares data and bss, and every proc keeps a
private stack.

## What each flag means here

    RFPROC     make a child -- without it the flags act on the caller
    RFMEM      share writable data segments rather than copy them
               -- data and anonymous memory alike, which are the same
               question in two shapes
    RFFDG      copy the descriptor group rather than share it
    RFCFDG     a clean descriptor group, holding nothing
    RFNAMEG    copy the namespace rather than share it
    RFCNAMEG   a clean namespace, naming nothing
    RFNOTEG    a new note group of one
    RFENVG     copy the environment group rather than share it
    RFCENVG    a clean environment group, holding nothing

Text and read-only segments are shared always -- nothing can write them, so
a copy would buy isolation from nothing. Descriptors default to *shared*,
which is Plan 9's fork and not `spawn`'s. Two processes advancing one
cursor is a coordination tool, and `fdtable.odin` is what made it safe to
hold.

`RFNOTEG` is a group of one, and `notepg` is what a group is for: a note
posted to every process in it but the poster. A child forked without the
flag hears its parent's group notes, and one forked with it does not. The
environment follows the descriptors' rule exactly: shared unless the word
says copy or clean, and `kernel/env` is the directory a group is. The
rest -- `RFREND`, `RFNOMNT` -- name machinery Vectra does not have
(rendezvous groups, mount control). They are refused rather than skipped.
A flag that is quietly ignored can never mean anything later.

## Who collects an rfork child

Its parent, by `wait`, like any spawned child. A parent that exits first
leaves an orphan no `wait` can ever reach, because pids never reuse and
nothing reparents. The leak is honest in `stats().live`. The showpiece server
tears down child-first for exactly that reason, and reparenting is named in
`docs/HANDOFF.md` beside `RFNOWAIT`, whose day it shares.
*/
package user

import "kernel:arch"
import "kernel:env"
import "kernel:mem"
import "kernel:sched"
import "kernel:vfs"
import "vsys:abi"
import "vsys:vectra9"

RFNAMEG :: abi.RFNAMEG
RFENVG :: abi.RFENVG
RFFDG :: abi.RFFDG
RFNOTEG :: abi.RFNOTEG
RFPROC :: abi.RFPROC
RFMEM :: abi.RFMEM
RFNOWAIT :: abi.RFNOWAIT
RFCNAMEG :: abi.RFCNAMEG
RFCENVG :: abi.RFCENVG
RFCFDG :: abi.RFCFDG
RFREND :: abi.RFREND
RFNOMNT :: abi.RFNOMNT

// The bits this kernel implements. Everything else in the word is refused,
// including bits Plan 9 has and Vectra does not yet honour.
@(private = "file")
RFORK_KNOWN :: RFPROC | RFMEM | RFFDG | RFCFDG | RFNAMEG | RFCNAMEG | RFENVG | RFCENVG | RFNOTEG | RFNOWAIT | RFREND

/*
sys_rfork is the call, dispatched with the frame because the frame is the
child. Validation first, and all of it before anything is built, so a
refused word costs nothing.
*/
@(private)
sys_rfork :: proc(frame: ^arch.Trap_Frame, flags: u64) -> i64 {
	p := current()
	if p == nil {
		return -i64(vectra9.EINVAL)
	}
	if flags & ~u64(RFORK_KNOWN) != 0 {
		return -i64(vectra9.EINVAL)
	}
	// Two flags asking for both answers to one question, and a share of
	// memory with nobody to share it with. Plan 9 refuses all three.
	if flags & RFFDG != 0 && flags & RFCFDG != 0 {
		return -i64(vectra9.EINVAL)
	}
	if flags & RFNAMEG != 0 && flags & RFCNAMEG != 0 {
		return -i64(vectra9.EINVAL)
	}
	if flags & RFENVG != 0 && flags & RFCENVG != 0 {
		return -i64(vectra9.EINVAL)
	}
	if flags & RFPROC == 0 {
		// `RFNOWAIT` detaches a child, and there is no child to detach.
		if flags & (RFMEM | RFNOWAIT) != 0 {
			return -i64(vectra9.EINVAL)
		}
		return rfork_self(p, flags)
	}
	return rfork_proc(p, frame, flags)
}

/*
rfork_self is the flags acting on the caller: unshare or empty what the
word names, in place. Plan 9's `rfork(RFNAMEG)` after the fact, for a
process that decided to stop sharing later than it forked.

Each swap builds the replacement before releasing what it replaces, so a
pool that is momentarily full fails the call and changes nothing.
*/
@(private = "file")
rfork_self :: proc(p: ^Process, flags: u64) -> i64 {
	if flags & (RFNAMEG | RFCNAMEG) != 0 {
		how: vfs.Fork_Flags = flags & RFCNAMEG != 0 ? {.Clean} : {.Copy}
		fresh := vfs.ns_fork(p.ns, how)
		if fresh == nil {
			return -i64(vectra9.ENOMEM)
		}
		old := p.ns
		p.ns = fresh
		vfs.ns_close(old)
	}

	if flags & (RFFDG | RFCFDG) != 0 {
		fresh := flags & RFCFDG != 0 ? fdt_new() : fdt_copy(p.fdt)
		if fresh == nil {
			return -i64(vectra9.ENOMEM)
		}
		old := p.fdt
		p.fdt = fresh
		fdt_release(old)
	}

	if flags & (RFENVG | RFCENVG) != 0 {
		fresh := flags & RFCENVG != 0 ? env.new_group() : env.copy_group(p.env)
		if fresh == nil {
			return -i64(vectra9.ENOMEM)
		}
		old := p.env
		p.env = fresh
		env.release(old)
	}

	if flags & RFNOTEG != 0 {
		p.note_group = p.pid
	}
	if flags & RFREND != 0 {
		p.rend_group = p.pid
	}
	return 0
}

/*
rfork_proc builds the child, in the order that can fail safely.

Everything that can refuse happens before the thread exists: the slot, the
space, the namespace, the table, every segment copy. A failed fork is an
`unload`, and nothing ran. The thread is the last act, because
`spawn_user_clone` enqueues, and the next interrupt may dispatch the child
into the middle of whatever is not finished.
*/
@(private = "file")
rfork_proc :: proc(parent: ^Process, frame: ^arch.Trap_Frame, flags: u64) -> i64 {
	// A detached worker that ended holds a slot until something collects it.
	// A concurrent server forks one per blocking request, so the moment a new
	// fork wants a slot is the moment to reap the dead ones. See
	// `reap_orphans`.
	reap_orphans()

	// `RFNOWAIT` hands the child to the kernel at birth: no parent to wait
	// for it, and `reap_orphans` collects it when it ends. Plan 9's detached
	// child, and the answer to the orphan leak from the side that chooses
	// it up front. `RFNOTEG` is a note group of the child's own.
	child := claim_slot(
		parent = flags & RFNOWAIT != 0 ? 0 : parent.pid,
		detached = flags & RFNOWAIT != 0,
		note_group = flags & RFNOTEG != 0 ? 0 : parent.note_group,
	)
	if child == nil {
		return -i64(vectra9.EAGAIN)
	}
	// The rendezvous group follows the note group's rule: inherited, or a
	// group of one under RFREND.
	if flags & RFREND == 0 {
		child.rend_group = parent.rend_group
	}

	space, merr := mem.space_new()
	if merr != .None {
		unload(child)
		return -i64(vectra9.ENOMEM)
	}
	child.space = space
	// The child inherits the parent's runs as its own segment list, below, so
	// its first `segalloc` searches those and lands clear of them. There is no
	// high-water mark to carry over: the list is the map, and the child has a
	// copy of it the moment `fork_segments` returns.

	// The parent's name, copied home like a spawned path. Two processes of
	// one name tell a boot log less than they might. The pid is the field
	// that disambiguates, which is the answer `/srv`'s listing gives.
	for i in 0 ..< len(parent.name) {
		child.name_buf[i] = parent.name[i]
	}
	child.name = string(child.name_buf[:len(parent.name)])
	child.args_buf = parent.args_buf
	child.args_len = parent.args_len
	_ = set_directory(child, current_directory(parent))

	ns_how: vfs.Fork_Flags
	if flags & RFNAMEG != 0 {
		ns_how = {.Copy}
	}
	if flags & RFCNAMEG != 0 {
		ns_how = {.Clean}
	}
	child.ns = vfs.ns_fork(parent.ns, ns_how)
	if child.ns == nil {
		unload(child)
		return -i64(vectra9.ENOMEM)
	}

	switch {
	case flags & RFCFDG != 0:
		child.fdt = fdt_new()
	case flags & RFFDG != 0:
		child.fdt = fdt_copy(parent.fdt)
	case:
		fdt_incref(parent.fdt)
		child.fdt = parent.fdt
	}
	if child.fdt == nil {
		unload(child)
		return -i64(vectra9.ENOMEM)
	}

	switch {
	case flags & RFCENVG != 0:
		child.env = env.new_group()
	case flags & RFENVG != 0:
		child.env = env.copy_group(parent.env)
	case:
		env.incref(parent.env)
		child.env = parent.env
	}
	if child.env == nil {
		unload(child)
		return -i64(vectra9.ENOMEM)
	}

	if !fork_segments(child, parent, flags & RFMEM != 0) {
		unload(child)
		return -i64(vectra9.ENOMEM)
	}

	child.thread = sched.spawn_user_clone(child.name, space, frame, child)
	if child.thread == nil {
		unload(child)
		return -i64(vectra9.ENOMEM)
	}
	child.kstack_lo = uintptr(raw_data(child.thread.stack))
	child.kstack_hi = child.thread.kstack_top

	loaded += 1
	spawned += 1
	return i64(child.pid)
}

/*
fork_segments gives the child the parent's memory, segment by segment.

The rule per kind is the file comment's: text shared, data shared only
under `share`, the stack copied always. Sharing is an increment and a
mapping of the same frames. Copying is new frames with the parent's bytes,
through the direct map. The parent is parked inside this call, which is
the one moment its writable pages hold still.

The staging aliases copy across by identity. Whichever frame the parent's
alias named, the child's alias names the child's frame in the same seat:
the shared frame itself, or its copy. A blob child's data cell is then
readable from the kernel side whichever way the flags went, which is what
the isolation checks read.
*/
@(private = "file")
fork_segments :: proc(child: ^Process, parent: ^Process, share: bool) -> bool {
	for i in 0 ..< parent.seg_count {
		s := parent.segs[i]
		/*
		Device memory is shared whatever the flags say, and it is the one kind
		with no other option. There is one framebuffer. A private copy of a
		card is a contradiction, and `RFMEM` is a question about a program's
		own writable pages rather than about hardware.

		Anonymous memory is the opposite case, and answers `RFMEM` like data,
		because that is what it is. A program that asked the kernel for a run
		of pages holds writable memory of its own. Only the shape it carries
		makes it something other than a `.Data` segment.
		*/
		writable_data := s.kind == .Data || s.kind == .Anon
		shared := s.kind == .Text || s.kind == .Device || s.kind == .Shared || (writable_data && share)

		if shared {
			// A sharer sees the segment's frames as they are, so none of
			// them may still be a copy-on-write child's too: a write by
			// either would move the frame out from under the other.
			if share && !resolve_cow(parent, s) {
				return false
			}
			segment_incref(s)
			if !proc_add_segment(child, s) {
				return false
			}
			for j in 0 ..< s.pages {
				va := s.va + uintptr(j) * uintptr(arch.PAGE_SIZE)
				frame := segment_frame(s, j)
				if frame == 0 {
					continue
				}
				if mem.map_user(child.space, va, frame, s.flags, 1) != .None {
					return false
				}
				// A run segment is hundreds of pages and the alias table
				// holds a handful. Nothing stages through a card or through
				// memory a program asked for after it started, in any case.
				if !s.run {
					alias_frame(child, parent, frame, frame)
				}
			}
			continue
		}

		/*
		A segment with one holder is copied on write: the child's record
		names the parent's frames, both map them read-only, and the first
		write to any page by either side copies that page and no other.
		This is Plan 9's `dupseg`, and the reason a fork costs nothing until
		something is written.

		A segment with several holders -- shared under `RFMEM` and now
		forked without it -- is copied eagerly instead. Its holders keep
		writing through the same frames, and a copy-on-write reference held
		against frames that change is not a snapshot. That case is rare
		and the copy is what it always was.
		*/
		if s.refs > 1 {
			if !copy_segment(child, parent, s) {
				return false
			}
			continue
		}

		fresh := segment_new(s.va, s.flags, s.kind)
		if fresh == nil || !proc_add_segment(child, fresh) {
			return false
		}
		read_only := s.flags - {.Write}
		for j in 0 ..< s.pages {
			frame := segment_frame(s, j)
			if !segment_add_frame(fresh, frame) {
				return false
			}
			if frame == 0 {
				continue
			}
			mem.frame_share(frame)
			va := s.va + uintptr(j) * uintptr(arch.PAGE_SIZE)
			if mem.map_user(child.space, va, frame, read_only, 1) != .None {
				return false
			}
			if !s.run {
				alias_frame(child, parent, frame, frame)
			}
		}
		// The parent's own pages go read-only too, and every core that
		// translates through the parent is told.
		if mem.protect_user(parent.space, s.va, s.pages, read_only) != .None {
			return false
		}
		mem.shoot(mem.space_root(parent.space), s.va, s.pages)
		cow_forks += 1
	}
	return true
}

// copy_segment is the eager copy: fresh frames, the bytes moved, the
// child's mapping made. What every fork did before copy-on-write, kept for
// the segment several processes already share.
@(private = "file")
copy_segment :: proc(child: ^Process, parent: ^Process, s: ^Segment) -> bool {
	fresh := segment_new(s.va, s.flags, s.kind)
	if fresh == nil || !proc_add_segment(child, fresh) {
		return false
	}
	for j in 0 ..< s.pages {
		from := segment_frame(s, j)
		if from == 0 {
			if !segment_add_frame(fresh, 0) {
				return false
			}
			continue
		}
		frame, ok := mem.alloc_page_zeroed()
		if !ok {
			return false
		}
		if !segment_add_frame(fresh, frame) {
			mem.free_page(frame)
			return false
		}
		src := (cast([^]u8)mem.phys_to_virt(from))[:arch.PAGE_SIZE]
		dst := (cast([^]u8)mem.phys_to_virt(frame))[:arch.PAGE_SIZE]
		for k in 0 ..< arch.PAGE_SIZE {
			dst[k] = src[k]
		}
		va := s.va + uintptr(j) * uintptr(arch.PAGE_SIZE)
		if mem.map_user(child.space, va, frame, s.flags, 1) != .None {
			return false
		}
		if !s.run {
			alias_frame(child, parent, from, frame)
		}
	}
	return true
}

/*
resolve_cow makes every page of a segment the process's own, copying the
ones a copy-on-write child still holds, so a sharer joining now under
`RFMEM` sees frames that will not move. A run with a shared frame becomes
a list first, because a run's frames cannot be replaced one at a time.
*/
@(private = "file")
resolve_cow :: proc(p: ^Process, s: ^Segment) -> bool {
	if s.kind == .Device || s.kind == .Text {
		return true
	}
	for j in 0 ..< s.pages {
		frame := segment_frame(s, j)
		if frame == 0 || mem.frame_holders(frame) <= 1 {
			continue
		}
		va := s.va + uintptr(j) * uintptr(arch.PAGE_SIZE)
		if !cow_copy(p, s, j, va) {
			return false
		}
	}
	return true
}

// alias_frame carries one staging alias from parent to child, matched by
// the frame the parent's alias names. Left at zero, `cell` on the child
// would answer zero and a check would pass with nothing behind it.
@(private = "file")
alias_frame :: proc "contextless" (child: ^Process, parent: ^Process, was: uintptr, now: uintptr) {
	if parent.text == was {
		child.text = now
	}
	if parent.data == was {
		child.data = now
	}
	if parent.stack == was {
		child.stack = now
	}
}
