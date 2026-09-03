/*
exec: a program replaces itself, and the seam's other half is cut.

`spawn` was fork and exec as one arc. `rfork` took the creating half out of
it, so two processes could return from one call. This is the replacing half.
A process names a file, and the program running becomes that file's. Same
process, same pid, same descriptors, same namespace, and new text, new data,
new stack. A shell wants exactly this between an `rfork` and the command it
runs: arrange the child, then replace it.

## What survives, and what does not

    the pid            the process is the same one, so `wait` still names it
    the descriptors    exec keeps them -- that is what a shell's redirect is
    the namespace      kept too, so a bind made before exec still holds
    the note handler   gone: it pointed into text that no longer exists
    text, data, stack  the new program's, and nothing of the old remains

Keeping the descriptors and the namespace is the whole point. Plan 9's shell
opens a file, `dup`s it onto descriptor 1, and then `exec`s, so the redirect
outlives the replace. The note handler is the one piece of state exec drops.
A registered handler is an address in the old text, and the old text is gone.

## The order, which is the whole correctness argument

The new image is built in a *fresh* space before anything of the old one is
touched. A file that is not a program, or a machine out of memory, costs a
scratch space and leaves the caller running with the errno. Only once the
new image is whole does exec commit, and past the commit nothing may fail:

  1. release the old segments -- the last holder frees their frames
  2. move the new space, segments and entry into the process record
  3. point the thread at the new space and load its CR3
  4. free the old space, which the machine no longer translates through
  5. rewrite the syscall frame to enter the new program

The frame rewrite is `arch.frame_enter_user`. The call came through the door,
so the door's return -- a `sysretq` -- reads `rip`, `rflags` and `rsp` back
out of the frame. Setting those three to the new program's entry is what
makes the return land in a new image. exec therefore returns only on
failure, and on success the value it would have returned is never read.
*/
package user

import "kernel:arch"
import "kernel:mem"
import "kernel:sched"
import "kernel:vfs"
import "vsys:vectra9"

/*
sys_exec loads a new program over the calling process, or leaves it running
with an errno.

`frame` is the syscall frame, rewritten in place on success the way
`sys_rfork` rewrites the child's. The path is copied in first, while the old
space is still the one the machine translates through, because `copy_in`
reads through it.
*/
@(private)
sys_exec :: proc(frame: ^arch.Trap_Frame, addr: uintptr, length: int, argv_addr: uintptr, argc: int) -> i64 {
	// Returns only on failure, with the errno; on success the answer below
	// is the new program's and this call is over.
	p := current()
	if p == nil || p.ns == nil {
		return -i64(vectra9.EBADF)
	}

	path_buf: [PATH_MAX]u8
	path, perr := copy_path(p, addr, length, path_buf[:])
	if perr != vectra9.Errno(0) {
		return -i64(perr)
	}
	// The arguments, copied in before anything is torn down: they live in
	// the image this call is about to replace.
	argv := new(Argv)
	if argv == nil {
		return -i64(vectra9.ENOMEM)
	}
	defer free(argv)
	if !copy_argv(argv_addr, argc, argv) {
		return -i64(vectra9.EFAULT)
	}

	/*
	The new image goes into a scratch record with a space of its own, so a
	load that fails anywhere leaves the running process untouched.
	`load_program` writes the space, the segments and the staging aliases into
	whatever record it is handed. A stack-local one then collects exactly what
	a commit must move and a failure must release.
	*/
	space, merr := mem.space_new()
	if merr != .None {
		return -i64(vectra9.ENOMEM)
	}
	scratch: Process
	scratch.space = space

	entry, sp, arg0, lerr := load_program(&scratch, p.ns, path)
	if lerr != vfs.OK {
		for i in 0 ..< scratch.seg_count {
			segment_release(scratch.segs[i])
		}
		mem.space_destroy(space)
		return -i64(lerr)
	}
	if arg0 == 0 {
		staged_sp, block, staged := stage_args(stack_segment(&scratch), sp, argv)
		if !staged {
			for i in 0 ..< scratch.seg_count {
				segment_release(scratch.segs[i])
			}
			mem.space_destroy(space)
			return -i64(vectra9.E2BIG)
		}
		sp = staged_sp
		arg0 = u64(block)
	}

	/*
	The shared class crosses. Plan 9's `SG_SHARED` survives an exec, the way a
	descriptor does, and for the same use. A process arranges memory that a
	program it is about to become will find. Each such segment is added to the
	new image as one more holder and mapped at its own address. No image
	reaches that address, because `MAPPING_BASE` is above every fixed segment.
	This is before the commit, so a mapping that fails leaves the caller
	running.
	*/
	for i in 0 ..< p.seg_count {
		s := p.segs[i]
		if s == nil || s.kind != .Shared {
			continue
		}
		segment_incref(s)
		if !proc_add_segment(&scratch, s) || !map_run(&scratch, s) {
			for j in 0 ..< scratch.seg_count {
				segment_release(scratch.segs[j])
			}
			mem.space_destroy(space)
			return -i64(vectra9.ENOMEM)
		}
	}

	// -- The commit. Nothing below here may fail. ----------------------------

	// The old segments go first. Each release drops one holder. The last one
	// -- this process, unless an rfork child still shares a frame -- frees the
	// frames the old program ran on.
	old_space := p.space
	for i in 0 ..< p.seg_count {
		segment_release(p.segs[i])
	}

	// The new image moves in by value, segment pointers and staging aliases
	// alike. The scratch record is abandoned after this, so nothing is shared
	// between the two.
	p.space = space
	p.seg_count = scratch.seg_count
	for i in 0 ..< scratch.seg_count {
		p.segs[i] = scratch.segs[i]
	}
	p.text = scratch.text
	p.data = scratch.data
	p.stack = scratch.stack

	// The name follows the program, the way Plan 9 keeps `argv[0]`. Copied
	// home, because the path sits on this call's syscall stack and the record
	// outlives it.
	for i in 0 ..< len(path) {
		p.name_buf[i] = path[i]
	}
	p.name = string(p.name_buf[:len(path)])

	// The handler pointed into text that is gone. A note from here on is an
	// ending again, until the new program registers one of its own.
	p.handler = 0
	p.notified = false
	p.note_sp = 0

	// The thread translates through the new space from the next reload, and
	// this is that reload. `space_destroy` after the switch finds a CR3 that
	// no longer names the old tree, so it frees it rather than switching away.
	if t := sched.current(); t != nil {
		t.space = space
	}
	mem.space_switch(space)
	mem.space_destroy(old_space)

	// The door's return now lands in the new program. Every register but the
	// three arguments is cleared, so nothing of the old image leaks across.
	// The answer is whatever the frame now holds in the answer register: on
	// an architecture where that register is also the first argument's, it
	// is the new program's data page, and the dispatcher writing it back is
	// what keeps the frame the new program's first state. `noted` makes the
	// same promise the same way.
	arch.frame_enter_user(frame, entry, sp, arg0)
	return arch.syscall_result(frame)
}
