/*
The system calls, as a ring 3 library.

Every program before this one wrote its calls as assembler immediates,
because every program was assembler. This package is the door's other side
in Odin: one wrapper per call, the numbers from `sys/abi`, and the two loop
helpers every byte-moving caller needs.

Two rules shape everything here:

  - **Everything is `contextless` and nothing allocates.** A program has no
    heap unless it builds one, and a library that quietly needs an allocator
    is a library a small server cannot use. Buffers are the caller's.
  - **Answers are the kernel's answers.** A wrapper returns the signed
    number the call produced -- a count or a descriptor when zero or more,
    `-errno` when negative -- and interprets nothing. The one exception is
    `pipe_ends`, which unpacks a packing `sys/abi` defines.

The asm expressions say exactly what the door promises: `rax`, `rcx` and
`r11` change, nothing else does. `~{memory}` is on every call, because any
call may read or write a buffer the program also touches.
*/
package libuser

import "vsys:abi"
import "vsys:vectra9"

// The six raw doors -- `raw1` to `raw6` -- are the architecture's, in
// `sys_<arch>.odin`. Everything below is what a program asks through them.

// -- The calls ---------------------------------------------------------------

write :: proc "contextless" (fd: int, data: []u8) -> i64 {
	return raw3(abi.SYS_WRITE, u64(fd), u64(uintptr(raw_data(data))), u64(len(data)))
}

read :: proc "contextless" (fd: int, buf: []u8) -> i64 {
	return raw3(abi.SYS_READ, u64(fd), u64(uintptr(raw_data(buf))), u64(len(buf)))
}

open :: proc "contextless" (path: string, flags: u64) -> i64 {
	return raw3(abi.SYS_OPEN, u64(uintptr(raw_data(path))), u64(len(path)), flags)
}

close :: proc "contextless" (fd: int) -> i64 {
	return raw1(abi.SYS_CLOSE, u64(fd))
}

// seek moves a descriptor's cursor to an absolute offset. There is no
// whence, which is the kernel's rule rather than an omission here.
seek :: proc "contextless" (fd: int, offset: u64) -> i64 {
	return raw2(abi.SYS_SEEK, u64(fd), offset)
}

create :: proc "contextless" (path: string, flags: u64, mode: u64) -> i64 {
	return raw4(abi.SYS_CREATE, u64(uintptr(raw_data(path))), u64(len(path)), flags, mode)
}

bind :: proc "contextless" (source: string, target: string, order: u64) -> i64 {
	return raw5(
		abi.SYS_BIND,
		u64(uintptr(raw_data(source))),
		u64(len(source)),
		u64(uintptr(raw_data(target))),
		u64(len(target)),
		order,
	)
}

mount :: proc "contextless" (source: string, target: string, order: u64) -> i64 {
	return raw5(
		abi.SYS_MOUNT,
		u64(uintptr(raw_data(source))),
		u64(len(source)),
		u64(uintptr(raw_data(target))),
		u64(len(target)),
		order,
	)
}

remove :: proc "contextless" (path: string) -> i64 {
	return raw2(abi.SYS_REMOVE, u64(uintptr(raw_data(path))), u64(len(path)))
}

pipe :: proc "contextless" () -> i64 {
	return raw1(abi.SYS_PIPE, 0)
}

spawn :: proc "contextless" (path: string, flags: u64) -> i64 {
	return raw3(abi.SYS_SPAWN, u64(uintptr(raw_data(path))), u64(len(path)), flags)
}

wait :: proc "contextless" (pid: u64) -> i64 {
	return raw1(abi.SYS_WAIT, pid)
}

/*
rfork is Plan 9's fork, flags from `sys/abi`'s RF words.

One wrapper, two callers answered. The parent hears the child's pid. The
child continues from the same call site, on its own copy of the stack, and
hears zero. `RFMEM` shares the data and bss between them. The kernel's
`rfork.odin` says what each flag means and which are refused.
*/
rfork :: proc "contextless" (flags: u64) -> i64 {
	return raw1(abi.SYS_RFORK, flags)
}

// exec replaces this program with the one at `path`, resolved in this
// process's own namespace. The descriptors and the namespace survive, and
// the text, data and stack are the new program's. It returns only on
// failure, because on success the old program is gone. The answer is then
// the errno that says why the new program could not load.
exec :: proc "contextless" (path: string) -> i64 {
	return raw2(abi.SYS_EXEC, u64(uintptr(raw_data(path))), u64(len(path)))
}

/*
segattach maps the device behind an open descriptor into this process, and
answers with the address it landed at.

The one call in this library that hands back memory rather than bytes. It is
for a server that *is* a device's cooked side. `/dev/fb` opened, attached, and
then written to at memory speed instead of a `Twrite` per row.

**The namespace decides.** A process that cannot open the file cannot attach
it, and one whose namespace binds something else over that name attaches the
something else. A file that is a stream answers `ENODEV`, which is almost
every file there is.

The mapping is writable, never executable, and lasts as long as the process.
Nothing releases one, because nothing needs to yet: a server that attaches a
card holds it until it exits.
*/
segattach :: proc "contextless" (fd: int) -> (addr: uintptr, err: i64) {
	r := raw1(abi.SYS_SEGATTACH, u64(fd))
	if r < 0 {
		return 0, r
	}
	return uintptr(r), 0
}

/*
segalloc asks the kernel for a run of anonymous memory, and answers with the
address it landed at.

**This is how a program holds something bigger than its own image.** Static
`bss` is all the format gives it, and the whole of a program is bounded at a
quarter of a megabyte. A window's pixels are two megabytes, so a program that
wants its own are a `segalloc` away and were unreachable before.

The memory is zero, writable, never executable, and lasts until the process
exits or `segdetach` gives it back. That call is the other half of this one
and of `segattach` alike.

`EINVAL` is a request of nothing or one past the kernel's bound. `ENOMEM` is
the machine having no run that long left, or this process holding as many
segments as it may.

`flags` is zero for a run of this process's own, shared under `RFMEM` and
copied otherwise. `abi.SEGSHARED` asks for Plan 9's shared class instead: a
run every fork shares whatever its flags say, and every exec keeps. That is
memory a process arranges for the program it is about to become, or for a
worker it forks without sharing everything else.
*/
segalloc :: proc "contextless" (bytes: int, flags: u64 = 0) -> (addr: uintptr, err: i64) {
	r := raw2(abi.SYS_SEGALLOC, u64(bytes), flags)
	if r < 0 {
		return 0, r
	}
	return uintptr(r), 0
}

/*
segbrk moves the top of a run this process already holds, which is Plan 9's
call of the same name.

`addr` is any address inside the run and `top` is where it should end. A `top`
of zero answers the run's base instead of moving anything, which is `ibrk`'s
query form.

**The address does not move.** A run that grows keeps its base and what was in
it, with zeroed pages above; a run that shrinks keeps its base and gives the
tail back. Only anonymous memory may be asked, which is what Plan 9's
`syssegbrk` refuses every other segment type by name to say.
*/
segbrk :: proc "contextless" (addr: uintptr, top: uintptr) -> i64 {
	return raw2(abi.SYS_SEGBRK, u64(addr), u64(top))
}

/*
segdetach takes a segment out of this process, which is Plan 9's call of the
same name and the other half of `segattach` and `segalloc`.

`addr` is any address inside the segment. The whole segment goes. Its pages
are unreachable when this returns. The memory behind them goes back to
whoever owned it: the allocator for a run of anonymous memory, nobody for a
card. A process may detach what it attached and what it allocated, and not
the image it was born with. Plan 9 refuses the stack by name, and this refuses
the text and data beside it for a reason `docs/USER.md` gives.

`EINVAL` is an address no segment covers, or one in a segment that may not
go.
*/
segdetach :: proc "contextless" (addr: uintptr) -> i64 {
	return raw1(abi.SYS_SEGDETACH, u64(addr))
}

// note posts a note to one of the caller's own children. With no handler
// the child ends at its next kernel boundary, and the wait status is
// EINTR. With a handler the child catches it instead -- see `notify`.
note :: proc "contextless" (pid: u64, text: string) -> i64 {
	return raw3(abi.SYS_NOTE, pid, u64(uintptr(raw_data(text))), u64(len(text)))
}

/*
notepg posts a note to every process in a note group but the caller, which
is a write to Plan 9's `/proc/n/notepg`.

`pid` names the group: zero for the caller's own, or one of the caller's
children for that child's group. A child forked without `RFNOTEG` is in its
parent's group, and one forked with it is in a group of one. So a program
forks a job's first process into its own group and the rest without the
flag, and the job is one note.

The answer is how many processes were noted, which is zero for a group with
nobody else in it. `ECHILD` is a pid that is not the caller's child.
*/
notepg :: proc "contextless" (pid: u64, text: string) -> i64 {
	return raw3(abi.SYS_NOTEPG, pid, u64(uintptr(raw_data(text))), u64(len(text)))
}

// notify registers the handler a note is delivered to, or clears it with a
// zero address. The handler is called with the saved frame and the note's
// text, and must end with `noted`. Until one is registered, a note is only
// ever an ending.
notify :: proc "contextless" (handler: uintptr) -> i64 {
	return raw1(abi.SYS_NOTIFY, u64(handler))
}

// noted finishes one delivery. `abi.NCONT` resumes the interrupted program
// from the frame the handler was handed. `abi.NDFLT` takes the default
// action, which is the ending the note always was. It does not return on
// either answer, so the `for` after it is unreachable.
noted :: proc "contextless" (how: u64) -> ! {
	_ = raw1(abi.SYS_NOTED, how)
	for {
	}
}

sleep :: proc "contextless" (ticks: u64) -> i64 {
	return raw1(abi.SYS_SLEEP, ticks)
}

// exit ends the program, and the `for` after it is unreachable. The compiler
// cannot know a system call never returns, and a wrapper that could fall
// through would run whatever bytes follow it.
exit :: proc "contextless" (status: u64) -> ! {
	_ = raw1(abi.SYS_EXIT, status)
	for {
	}
}

// -- What only the self-test asks --------------------------------------------
//
// Three calls with no use to a program and every use to the kernel's own
// checks: the door has to carry nothing, six arguments, and a number it
// does not know, and answer each the right way.

nop :: proc "contextless" () -> i64 {
	return raw1(abi.SYS_NOP, 0)
}

// args is the call that adds its six arguments up, which is the only thing
// that proves all six arrive.
args :: proc "contextless" (a0, a1, a2, a3, a4, a5: u64) -> i64 {
	return raw6(abi.SYS_ARGS, a0, a1, a2, a3, a4, a5)
}

// unknown is a number no call has, and the answer is ENOSYS.
unknown :: proc "contextless" () -> i64 {
	return raw1(9999, 0)
}

// try_noted is `noted` for a program that is not in a handler, where the
// kernel refuses it and answers. In a handler it does not return, and the
// answer is the interrupted program's.
try_noted :: proc "contextless" (how: u64) -> i64 {
	return raw1(abi.SYS_NOTED, how)
}

// -- The loops ---------------------------------------------------------------

/*
read_full fills the whole buffer, however many calls that takes.

A read answers with what is available, and the kernel also bounds one call's
copy. A caller that wants a frame therefore always loops, and this is that
loop, written once. False means the descriptor ended -- EOF or an error --
before the buffer filled.
*/
read_full :: proc "contextless" (fd: int, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		n := read(fd, buf[got:])
		if n <= 0 {
			return false
		}
		got += int(n)
	}
	return true
}

// write_full is the same loop outward. The kernel bounds one call's copy, so
// a frame longer than that bound crosses in pieces. False means the far side
// stopped accepting before the last byte.
write_full :: proc "contextless" (fd: int, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n := write(fd, data[sent:])
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

// stop_child is the forked reader's teardown. Note the child out of its
// parked read, and collect the EINTR that proves the ending was the one
// asked for. Every parent of a reader ends its child through this.
stop_child :: proc "contextless" (pid: u64) -> bool {
	if note(pid, "stop") != 0 {
		return false
	}
	return wait(pid) == -i64(vectra9.EINTR)
}
