/*
The ring 3 note handler: what turns a note from a kill into a signal.

A note ended its target, and that was the whole of delivery. Plan 9's other
half is here now. A process registers a handler with `notify`. Delivery
pushes the interrupted frame and the note's text onto the user stack, then
redirects the program into the handler.

The handler ends with `noted`. NCONT restores the frame and the program
continues where it was. NDFLT takes the default action, which is the death
the note always was. An alarm, a hangup, or an interrupt a program can
catch stop being spelled `death`.

## Where delivery happens, and what each boundary costs

The same two boundaries that delivered the ending deliver the handler. The
door aborts the system call it was about to run, and the program's answer
is EINTR, Plan 9's rule for an interrupted call. The tick redirects the
frame it interrupted, in interrupt context. That is why `deliver_note`
takes no lock, allocates nothing, and checks every page before it writes.

A stack the frame does not fit on is the one thing delivery cannot survive.
The answer is the old one: the process ends, noted. A handler is a promise
the program keeps with its own stack.

## What the handler is handed, and what `noted` takes back

The user stack gets the note's text and a copy of the saved `Trap_Frame`,
and the handler gets both addresses as its first two arguments. The frame
is the program's own state, so the handler may read it and may change it.
Moving the resume point is how Plan 9's `notejmp` escapes a slow operation.

**`noted` trusts none of it.** The frame comes back through `copy_in` like
any pointer from ring 3, and the parts a program must not choose are
rebuilt. The selectors are ring 3's, the resume flags are a user's, and the
resume point has to be in the program's own half. A handler that hands back
garbage dies exactly as a program that faulted, because that is what it
did, one syscall removed.

One delivery at a time. A note posted while the handler runs stays flagged
on the thread and lands at the first boundary after `noted` finishes. The
latest text wins the buffer, which is the single-slot rule the note always
had.

## What is deliberately absent

No FPU state crosses. The frame carries the integer registers, and a
handler that computes in XMM clobbers what the interrupted code had there.
Plan 9's `Ureg` has the same shape and the same edge. It matters the day a
program mixes floating point and notes, and it is named here for that day.

The group fan-out is `sys_notepg`, in `syscall.odin`. It posts to every
process in a note group but the poster, which is Plan 9's `postnotepg` and
the other half of its `postnote`.
*/
package user

import "kernel:arch"
import "kernel:mem"
import "vsys:abi"
import "vsys:vectra9"

// The stack a delivery needs: the note's text, the saved frame, and the
// alignment between them. What `deliver_note` checks for before it writes.
@(private = "file")
NOTE_STACK :: NOTE_MAX + size_of(arch.Trap_Frame) + 16

/*
deliver_note pushes one note delivery onto the user stack and redirects
`frame` into the handler.

Contextless and lock-free on purpose: the tick calls this in interrupt
context. The writes go through the process's own mappings, live because the
caller delivers to the thread running right now, on the space loaded right
now. `reachable` checks every page first, exactly as `copy_out` would, so a
torn stack refuses rather than faults.

The layout, from high to low: the text, NUL-terminated, then the frame
copy, 16-aligned, which is where the new stack pointer lands. The handler
gets the frame's address as its first argument and the text's as its
second, in whatever registers the architecture's convention names, and
everything it pushes goes below both.

False means the stack has no room or no mapping, and the caller falls back
to the ending a note always was.
*/
@(private)
deliver_note :: proc "contextless" (p: ^Process, frame: ^arch.Trap_Frame) -> bool {
	sp := arch.frame_sp(frame)
	if sp < mem.USER_MIN + NOTE_STACK || sp > mem.USER_MAX {
		return false
	}

	text_va := sp - NOTE_MAX
	ureg_va := (text_va - size_of(arch.Trap_Frame)) & ~uintptr(15)
	if !reachable(ureg_va, int(sp - ureg_va), {.User, .Write}) {
		return false
	}

	text := cast([^]u8)text_va
	for i in 0 ..< p.note_len {
		text[i] = p.note_buf[i]
	}
	text[p.note_len] = 0

	(cast(^arch.Trap_Frame)ureg_va)^ = frame^

	arch.frame_call_handler(frame, p.handler, ureg_va, ureg_va, text_va)

	p.notified = true
	p.note_sp = ureg_va
	return true
}

/*
sys_notify registers the handler, or clears it with zero.

The address is range-checked and nothing more. Whether anything executable
lives there is the program's promise to keep. A handler pointing at garbage
faults in ring 3 at delivery, and the fault path ends the process like any
program that jumped wrong.

Refused while a delivery is in flight. The frame on the stack belongs to
the handler that is running, and swapping handlers under it would make
`noted`'s answer about somebody else's registration.
*/
@(private)
sys_notify :: proc "contextless" (addr: uintptr) -> i64 {
	p := current()
	if p == nil {
		return -i64(vectra9.EBADF)
	}
	if p.notified {
		return -i64(vectra9.EBUSY)
	}
	if addr != 0 && (addr < mem.USER_MIN || addr >= mem.USER_MAX) {
		return -i64(vectra9.EFAULT)
	}
	p.handler = addr
	return 0
}

/*
sys_noted finishes one delivery, the only way a handler has.

NCONT reads the frame back off the user stack and resumes it. NDFLT is the
default action: the ending the note always was, recorded as one. Anything
else Plan 9 defines -- NRSTR, NSAVE -- is refused until nested handling is
worth having. Anything Plan 9 does not define is refused because it means
nothing.

**The restored frame is rebuilt, not believed.** `copy_in` fetches it like
any user pointer. The resume point and the stack must sit in the program's
half, and `arch.frame_sanitise_user` rebuilds the parts a program must not
choose -- the privilege level, and the flags a program does not own -- from
the kernel's own constants. The hardware would fault on most of them anyway,
but a check that leans on the hardware refusing fails elsewhere, later, with
less to say.

The answer on success is the restored frame's own answer, because the
dispatcher writes the result into the frame after every call. Answering
anything else would overwrite the register the handler meant to hand back.
*/
@(private)
sys_noted :: proc(frame: ^arch.Trap_Frame, how: u64) -> i64 {
	p := current()
	if p == nil || !p.notified {
		return -i64(vectra9.EINVAL)
	}

	if how == abi.NDFLT {
		p.notified = false
		note_exit(frame)
	}
	if how != abi.NCONT {
		// Still in the handler, still holding the delivery. A word this
		// call does not know is not a reason to lose the program's frame.
		return -i64(vectra9.EINVAL)
	}

	saved: arch.Trap_Frame
	buf := (cast([^]u8)&saved)[:size_of(arch.Trap_Frame)]
	if !copy_in(p.note_sp, size_of(arch.Trap_Frame), buf) {
		// The handler lost the frame it was handed. There is nothing left
		// to resume, and the default action is all that remains.
		p.notified = false
		note_exit(frame)
	}

	ip, sp := arch.frame_ip(&saved), arch.frame_sp(&saved)
	if ip < mem.USER_MIN || ip >= mem.USER_MAX || sp < mem.USER_MIN || sp > mem.USER_MAX {
		p.notified = false
		note_exit(frame)
	}

	// The parts a program must not choose, rebuilt from the kernel's own
	// truth. Interrupts stay on -- a program that could resume with them
	// masked would own the machine -- and the privilege level is ring 3.
	arch.frame_sanitise_user(&saved)

	frame^ = saved
	p.notified = false
	return arch.syscall_result(frame)
}
