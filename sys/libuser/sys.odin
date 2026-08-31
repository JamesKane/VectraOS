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

@(private)
raw1 :: proc "contextless" (nr: u64, a0: u64) -> i64 {
	return asm(u64, u64) -> i64 {
		"syscall",
		"={rax},{rax},{rdi},~{rcx},~{r11},~{memory}",
	}(nr, a0)
}

@(private)
raw2 :: proc "contextless" (nr: u64, a0: u64, a1: u64) -> i64 {
	return asm(u64, u64, u64) -> i64 {
		"syscall",
		"={rax},{rax},{rdi},{rsi},~{rcx},~{r11},~{memory}",
	}(nr, a0, a1)
}

@(private)
raw3 :: proc "contextless" (nr: u64, a0: u64, a1: u64, a2: u64) -> i64 {
	return asm(u64, u64, u64, u64) -> i64 {
		"syscall",
		"={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}",
	}(nr, a0, a1, a2)
}

@(private)
raw4 :: proc "contextless" (nr: u64, a0: u64, a1: u64, a2: u64, a3: u64) -> i64 {
	return asm(u64, u64, u64, u64, u64) -> i64 {
		"syscall",
		"={rax},{rax},{rdi},{rsi},{rdx},{r10},~{rcx},~{r11},~{memory}",
	}(nr, a0, a1, a2, a3)
}

@(private)
raw5 :: proc "contextless" (nr: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64) -> i64 {
	return asm(u64, u64, u64, u64, u64, u64) -> i64 {
		"syscall",
		"={rax},{rax},{rdi},{rsi},{rdx},{r10},{r8},~{rcx},~{r11},~{memory}",
	}(nr, a0, a1, a2, a3, a4)
}

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

// note posts a note to one of the caller's own children. With no handler
// the child ends at its next kernel boundary, and the wait status is
// EINTR. With a handler the child catches it instead -- see `notify`.
note :: proc "contextless" (pid: u64, text: string) -> i64 {
	return raw3(abi.SYS_NOTE, pid, u64(uintptr(raw_data(text))), u64(len(text)))
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
