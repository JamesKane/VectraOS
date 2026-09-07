/*
The debugger's doors into a process: `docs/DEVTOOLS.md` section 5, and the
rest of Plan 9's `proc(3)`.

`procinfo.odin` opened five doors for a shell. These are the ones a debugger
needs, and `kernel/procfs` serves each as a file:

    mem        the address space, at the address as the offset
    regs       the saved frame, while the process is stopped
    fpregs     the float image, the same way
    text       the program's file, read through its own namespace
    segment    one line per segment
    fd         one line per descriptor
    wait       the exit record of a child, as `await` gives it
    note       the note pending on a stopped process, and reading takes it

And the words `ctl` takes past `stop`, `start` and `kill`:

    startstop     run, and stop before the next note is delivered
    waitstop      answer when the process has stopped
    hang          stop at the next exec, before its first instruction
    nohang        withdraw that
    startsyscall  run, and stop at the next system call, in and out
    step          run one instruction and stop

## What a stop is, and who may read one

Every stop is the one `docs/PROC.md` already had: the ask on the record,
and the thread parked at the door or by the tick. The program's frame is
kept beside it. `stop_here` and `stop_in_trap` in `user.odin` are the two
parks, and `stop_frame` is what `regs` reads. A stop counts, so a caller
that started a process and waits for its *next* stop can tell it from the
one it left.

`regs`, `fpregs` and a write of `mem` want the process stopped, or not yet
launched. The frame is on the thread's own stack and the thread is parked,
which is the only moment it is anybody else's to write. A read of `mem`
takes no such care and answers whatever the pages hold as it copies them.

## A trap is a note, when somebody is watching

`docs/USER.md` argues that a fault ends a program, and it still does. But a
process under `startstop` stops *before* a note is delivered. A trap while
it is watched posts the note Plan 9 would, `sys: breakpoint` or `sys: trap:
...`, and parks. The debugger reads the note, which takes it away,
puts the frame right and starts the process. A process with the note still
pending when it starts meets it at the next boundary, and ends as it always
has. Nothing changes for a program nobody asked to watch.

**The kernel knows nothing about breakpoints.** A breakpoint is bytes a
debugger writes through `mem`, and the trap they raise is the CPU's. A fork's
child shares its parent's text. A write into shared text gives the process
its own copy first, so a breakpoint reaches one process and no other. That
is Plan 9's `procctlmemio` copying a text page.

## Pins

A collector frees a process's space, and a read through `mem` walks it.
`pin` holds the record against `collect` for the length of one copy, and
`collect` waits. A pinned process may still run and exit. Its pages stay
until the pin drops. Nothing sleeps under a pin but the copy itself.
*/
package user

import "base:intrinsics"

import "kernel:arch"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:libodin"
import "vsys:vectra9"

// -- Pins -----------------------------------------------------------------------

// pin finds a live process by pid and holds its record against collection.
// Nil for a pid that is gone, or one a collector already claimed.
@(private)
pin :: proc "contextless" (pid: u64) -> ^Process {
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	p := live_by_pid(pid)
	if p == nil || p.collecting {
		return nil
	}
	p.pins += 1
	return p
}

@(private)
unpin :: proc "contextless" (p: ^Process) {
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	p.pins -= 1
}

// -- The stop words --------------------------------------------------------------

// Ticks between looks, for a caller waiting on a stop. A stop from
// interrupt context wakes nobody, so the wait is a bounded poll.
@(private = "file")
STOP_POLL :: 2

/*
wait_stop answers when the process's stop count passes `gen`, the count the
caller read before it started the process. The answer is OK for a stop and
EIO for a process that ended instead. It is EINTR when a note is waiting for
the caller, and ESRCH for a pid that is gone.
*/
@(private = "file")
wait_stop :: proc(pid: u64, gen: u64) -> vfs.Errno {
	for {
		p := pin(pid)
		if p == nil {
			return vectra9.ESRCH
		}
		stops := intrinsics.atomic_load(&p.stops)
		done := intrinsics.volatile_load(&p.exit.done)
		unpin(p)
		if stops > gen {
			return vfs.OK
		}
		if done {
			return vectra9.EIO
		}
		if sched.thread_noted(sched.current()) {
			return vectra9.EINTR
		}
		sync.delay(STOP_POLL)
	}
}

/*
proc_debug_ctl is one of the debugger's words written to `/proc/n/ctl`.
Each ask is set on the record, the process is started if it was stopped,
and the words that promise a stop wait for it. Unknown words are EINVAL,
so the device can try the shell's words first and these after.
*/
proc_debug_ctl :: proc(pid: u64, word: string) -> vfs.Errno {
	p := pin(pid)
	if p == nil {
		return vectra9.ESRCH
	}
	gen := intrinsics.atomic_load(&p.stops)
	stopped := p.stopped
	done := intrinsics.volatile_load(&p.exit.done)
	err := vfs.OK
	run := false
	wait := false
	switch word {
	case "startstop":
		p.trace_note = true
		run, wait = true, true
	case "waitstop":
		if stopped {
			unpin(p)
			return vfs.OK
		}
		wait = true
	case "hang":
		p.hang = true
	case "nohang":
		p.hang = false
	case "startsyscall":
		p.trace_syscall = true
		run, wait = true, true
	case "step":
		switch {
		case !arch.HAS_STEP:
			err = vectra9.EOPNOTSUPP
		case !stopped || p.stop_frame == nil:
			err = vectra9.EBUSY
		case:
			arch.frame_set_step(p.stop_frame, true)
			p.stepping = true
			// A door stop is the syscall's frame, resumed by `sysretq`;
			// a tick's or a trap's is resumed by `iretq`. See the debug
			// trap in `user.odin` for why the door's is told apart.
			p.step_at_door = !p.stopped_in_tick
			p.step_from = arch.frame_ip(p.stop_frame)
			run, wait = true, true
		}
	case:
		if len(word) > 6 && word[:6] == "watch " {
			err = vectra9.EOPNOTSUPP
		} else {
			err = vectra9.EINVAL
		}
	}
	unpin(p)
	if err != vfs.OK {
		return err
	}
	if done {
		return vectra9.EIO
	}
	if run && stopped {
		_ = proc_start(pid)
	}
	if wait {
		return wait_stop(pid, gen)
	}
	return vfs.OK
}

/*
proc_note_take answers the note pending on a process and takes it away, as
Plan 9's read of `/proc/n/note` does. Empty when nothing is pending. The
flag a stop raised is not a note, and the kernel's kill is not one a
debugger may take.
*/
proc_note_take :: proc "contextless" (pid: u64, out: []u8) -> int {
	p := pin(pid)
	if p == nil {
		return 0
	}
	defer unpin(p)
	t := p.thread
	if t == nil || !sched.thread_noted(t) || p.stop_wake || intrinsics.volatile_load(&p.stopping) {
		return 0
	}
	n := copy(out, p.note_buf[:p.note_len])
	sched.clear_note(t)
	return n
}

/*
post_trap_note writes the note a trap would be on Plan 9 into the record
and raises the thread's flag. Interrupt context: no lock, no allocation.
`sys: breakpoint` for the instruction a debugger planted, and `sys: trap:
<kind> addr=... pc=...` for the rest.
*/
@(private)
post_trap_note :: proc "contextless" (p: ^Process, t: ^sched.Thread, trap: ^arch.Trap) {
	sink := libodin.sink_from(p.note_buf[:])
	if trap.kind == .Breakpoint {
		libodin.put_str(&sink, "sys: breakpoint")
	} else {
		libodin.put_str(&sink, "sys: trap: ")
		libodin.put_str(&sink, trap_kind_name(trap.kind))
		libodin.put_str(&sink, " addr=")
		libodin.put_hex(&sink, u64(trap.fault_address), 0)
		libodin.put_str(&sink, " pc=")
		libodin.put_hex(&sink, u64(trap.ip), 0)
	}
	p.note_len = len(libodin.str(&sink))
	intrinsics.volatile_store(&t.noted, true)
}

@(private = "file")
trap_kind_name :: proc "contextless" (kind: arch.Trap_Kind) -> string {
	#partial switch kind {
	case .Page_Fault:
		return "fault"
	case .Divide_By_Zero:
		return "divide"
	case .Invalid_Instruction:
		return "illegal instruction"
	case .Protection_Fault:
		return "protection"
	case .Debug:
		return "debug"
	}
	return "fault"
}

// -- Memory ---------------------------------------------------------------------

// A page of zeros, for a hole in a stack a debugger reads before the
// program reached it.
@(private = "file")
zero_page: [arch.PAGE_SIZE]u8

/*
page_source is where the bytes at `va` are, for a read. That is the frame
the process's tables name. When the tables are not filled yet, it is the
frame its segment names, or zeros for a stack page nothing touched. Nil for
an address the process cannot reach either.
*/
@(private = "file")
page_source :: proc "contextless" (p: ^Process, va: uintptr) -> rawptr {
	if p.space == nil || va >= mem.USER_MAX {
		return nil
	}
	page := uintptr(arch.PAGE_SIZE)
	base := va & ~(page - 1)
	if phys, ok := mem.translate(p.space, base); ok {
		if flags, _ := mem.permissions(p.space, base); .User in flags {
			return rawptr(uintptr(mem.phys_to_virt(phys)) + (va - base))
		}
		return nil
	}
	s := segment_covering(p, va)
	if s == nil || s.kind == .Device {
		return nil
	}
	j := int((base - s.va) / page)
	if frame := segment_frame(s, j); frame != 0 {
		return rawptr(uintptr(mem.phys_to_virt(frame)) + (va - base))
	}
	if s.kind == .Stack {
		return &zero_page[va - base]
	}
	return nil
}

/*
proc_mem_read copies out of a process's memory at `off`, the address. Stops
at the first byte the process could not reach itself, and answers EFAULT
only when that was the first one asked for.
*/
proc_mem_read :: proc "contextless" (pid: u64, off: u64, out: []u8) -> (n: int, err: vfs.Errno) {
	p := pin(pid)
	if p == nil {
		return 0, vectra9.ESRCH
	}
	defer unpin(p)
	page := uintptr(arch.PAGE_SIZE)
	for n < len(out) {
		va := uintptr(off) + uintptr(n)
		src := page_source(p, va)
		if src == nil {
			break
		}
		room := int(page - va & (page - 1))
		chunk := min(room, len(out) - n)
		bytes := (cast([^]u8)src)[:chunk]
		copy(out[n:n + chunk], bytes)
		n += chunk
	}
	if n == 0 && len(out) > 0 {
		return 0, vectra9.EFAULT
	}
	return n, vfs.OK
}

/*
proc_mem_write copies into a process's memory at `off`. Only a stopped
process, or one not yet launched, may be written. The copy lands on pages a
running thread could change under it, and a write of text is a write of
what it executes.

A writable page goes through the copy-on-write step a program's own store
would take. A read-only page, text, goes to the segment's frame through the
direct map. The process's mapping does not allow the write and the kernel's
does. If a fork shares the segment, it is made this process's own first.
Then the instruction side is told, on an architecture whose caches are two.
*/
proc_mem_write :: proc(pid: u64, off: u64, data: []u8) -> (n: int, err: vfs.Errno) {
	p := pin(pid)
	if p == nil {
		return 0, vectra9.ESRCH
	}
	defer unpin(p)
	if p.thread != nil && !p.stopped {
		return 0, vectra9.EBUSY
	}
	if p.space == nil {
		return 0, vectra9.EIO
	}
	page := uintptr(arch.PAGE_SIZE)
	for n < len(data) {
		va := uintptr(off) + uintptr(n)
		if va >= mem.USER_MAX {
			break
		}
		room := int(page - va & (page - 1))
		chunk := min(room, len(data) - n)
		s := segment_covering(p, va)
		if s == nil {
			break
		}
		dst: rawptr
		if .Write in s.flags || s.kind == .Device {
			cow_prepare(p, va, chunk)
			dst = page_source(p, va)
			if dst == nil && s.kind == .Stack {
				// A hole the program never reached: the write grows the
				// stack the way its own store would.
				if fix_fault(p, va, true) {
					dst = page_source(p, va)
				}
			}
		} else {
			if s.refs > 1 {
				s = privatise_segment(p, s)
				if s == nil {
					break
				}
			}
			j := int((va & ~(page - 1) - s.va) / page)
			frame := segment_frame(s, j)
			if frame != 0 {
				dst = rawptr(uintptr(mem.phys_to_virt(frame)) + (va & (page - 1)))
			}
		}
		if dst == nil {
			break
		}
		bytes := (cast([^]u8)dst)[:chunk]
		copy(bytes, data[n:n + chunk])
		if .Write not_in s.flags {
			arch.sync_text(dst, chunk)
		}
		n += chunk
	}
	if n == 0 && len(data) > 0 {
		return 0, vectra9.EFAULT
	}
	return n, vfs.OK
}

/*
privatise_segment gives a process its own copy of a segment a fork shares,
frame for frame, mapped where the shared one was. Then it lets the shared
one go. The answer is the copy, or nil when the machine has no frames for it,
in which case the process keeps what it had.
*/
@(private = "file")
privatise_segment :: proc(p: ^Process, s: ^Segment) -> ^Segment {
	fresh := segment_new(s.va, s.flags, s.kind)
	if fresh == nil {
		return nil
	}
	page := uintptr(arch.PAGE_SIZE)
	for j in 0 ..< s.pages {
		from := segment_frame(s, j)
		if from == 0 {
			if !segment_add_frame(fresh, 0) {
				segment_release(fresh)
				return nil
			}
			continue
		}
		frame, ok := mem.alloc_page()
		if !ok || !segment_add_frame(fresh, frame) {
			if ok {
				mem.free_page(frame)
			}
			segment_release(fresh)
			return nil
		}
		src := (cast([^]u8)mem.phys_to_virt(from))[:arch.PAGE_SIZE]
		dst := (cast([^]u8)mem.phys_to_virt(frame))[:arch.PAGE_SIZE]
		copy(dst, src)
		va := s.va + uintptr(j) * page
		if _, present := mem.permissions(p.space, va); present {
			if mem.remap_user(p.space, va, frame, s.flags) != .None {
				segment_release(fresh)
				return nil
			}
		} else if mem.map_user(p.space, va, frame, s.flags, 1) != .None {
			segment_release(fresh)
			return nil
		}
		if p.text == from {
			p.text = frame
		}
	}
	for i in 0 ..< p.seg_count {
		if p.segs[i] == s {
			p.segs[i] = fresh
			break
		}
	}
	segment_release(s)
	mem.shoot(mem.space_root(p.space), s.va, s.pages)
	return fresh
}

// -- Registers ------------------------------------------------------------------

/*
proc_regs_read copies the stopped process's frame out, as the architecture
lays it out: `arch.FRAME_REGS_SIZE` bytes. EBUSY for a process that is not
stopped, which is Plan 9's "process not stopped".
*/
proc_regs_read :: proc "contextless" (pid: u64, off: u64, out: []u8) -> (n: int, err: vfs.Errno) {
	p := pin(pid)
	if p == nil {
		return 0, vectra9.ESRCH
	}
	defer unpin(p)
	if !p.stopped || p.stop_frame == nil {
		return 0, vectra9.EBUSY
	}
	if off >= u64(arch.FRAME_REGS_SIZE) {
		return 0, vfs.OK
	}
	bytes := (cast([^]u8)p.stop_frame)[:arch.FRAME_REGS_SIZE]
	n = copy(out, bytes[off:])
	return n, vfs.OK
}

/*
proc_regs_write puts bytes into the stopped process's frame. The frame is
rebuilt rather than believed, as a frame handed back through `noted` is.
`arch.frame_sanitise_user` restores the selectors and the flags a program
does not own. The vector the frame arrived on stays what it was, and a step
in progress keeps its flag.
*/
proc_regs_write :: proc "contextless" (pid: u64, off: u64, data: []u8) -> (n: int, err: vfs.Errno) {
	p := pin(pid)
	if p == nil {
		return 0, vectra9.ESRCH
	}
	defer unpin(p)
	if !p.stopped || p.stop_frame == nil {
		return 0, vectra9.EBUSY
	}
	if off >= u64(arch.FRAME_REGS_SIZE) {
		return 0, vectra9.EINVAL
	}
	saved := p.stop_frame^
	bytes := (cast([^]u8)&saved)[:arch.FRAME_REGS_SIZE]
	n = copy(bytes[off:], data)
	saved.vector = p.stop_frame.vector
	saved.error_code = p.stop_frame.error_code
	arch.frame_sanitise_user(&saved)
	if p.stepping {
		arch.frame_set_step(&saved, true)
	}
	p.stop_frame^ = saved
	return n, vfs.OK
}

// proc_fpregs_read and proc_fpregs_write are `regs` for the float image,
// `arch.FPU_AREA_SIZE` bytes, with the image's reserved bits rebuilt on
// the way in.
proc_fpregs_read :: proc "contextless" (pid: u64, off: u64, out: []u8) -> (n: int, err: vfs.Errno) {
	p := pin(pid)
	if p == nil {
		return 0, vectra9.ESRCH
	}
	defer unpin(p)
	if !p.stopped || p.stop_fpu == nil {
		return 0, vectra9.EBUSY
	}
	if off >= u64(arch.FPU_AREA_SIZE) {
		return 0, vfs.OK
	}
	bytes := (cast([^]u8)p.stop_fpu)[:arch.FPU_AREA_SIZE]
	n = copy(out, bytes[off:])
	return n, vfs.OK
}

proc_fpregs_write :: proc "contextless" (pid: u64, off: u64, data: []u8) -> (n: int, err: vfs.Errno) {
	p := pin(pid)
	if p == nil {
		return 0, vectra9.ESRCH
	}
	defer unpin(p)
	if !p.stopped || p.stop_fpu == nil {
		return 0, vectra9.EBUSY
	}
	if off >= u64(arch.FPU_AREA_SIZE) {
		return 0, vectra9.EINVAL
	}
	bytes := (cast([^]u8)p.stop_fpu)[:arch.FPU_AREA_SIZE]
	n = copy(bytes[off:], data)
	arch.fpu_image_sanitise(p.stop_fpu)
	return n, vfs.OK
}

// -- The lists ------------------------------------------------------------------

@(private = "file")
SEGMENT_KIND_NAMES := [Segment_Kind]string {
	.Text   = "Text",
	.Data   = "Data",
	.Stack  = "Stack",
	.Device = "Device",
	.Anon   = "Anon",
	.Shared = "Shared",
}

// proc_segments writes one line per segment: kind, first address, end,
// and how many processes hold it. Answers the length, or -1 for no such
// process.
proc_segments :: proc "contextless" (pid: u64, out: []u8) -> int {
	p := pin(pid)
	if p == nil {
		return -1
	}
	defer unpin(p)
	sink := libodin.sink_from(out)
	for i in 0 ..< p.seg_count {
		s := p.segs[i]
		if s == nil {
			continue
		}
		libodin.put_str(&sink, SEGMENT_KIND_NAMES[s.kind])
		libodin.put_str(&sink, " ")
		libodin.put_hex(&sink, u64(s.va), 16)
		libodin.put_str(&sink, " ")
		libodin.put_hex(&sink, u64(s.va + uintptr(s.pages) * uintptr(arch.PAGE_SIZE)), 16)
		libodin.put_str(&sink, " ")
		libodin.put_int(&sink, i64(s.refs))
		libodin.put_str(&sink, "\n")
	}
	return len(libodin.str(&sink))
}

// proc_fds writes the process's directory on the first line, then one line
// per open descriptor. Each has the number, the server it is on, the qid
// path and the cursor. Answers the length, or -1 for no such process.
proc_fds :: proc "contextless" (pid: u64, out: []u8) -> int {
	p := pin(pid)
	if p == nil {
		return -1
	}
	defer unpin(p)
	sink := libodin.sink_from(out)
	libodin.put_str(&sink, current_directory(p))
	libodin.put_str(&sink, "\n")
	t := p.fdt
	if t == nil {
		return len(libodin.str(&sink))
	}
	guard := sync.acquire(&t.lock)
	defer sync.release(&t.lock, guard)
	for i in 0 ..< MAX_FDS {
		c := t.fds[i].chan
		if c == nil {
			continue
		}
		libodin.put_int(&sink, i64(i))
		libodin.put_str(&sink, " ")
		libodin.put_str(&sink, c.server != nil ? c.server.name : "?")
		libodin.put_str(&sink, " ")
		libodin.put_hex(&sink, c.qid.path, 0)
		libodin.put_str(&sink, " ")
		libodin.put_uint(&sink, t.fds[i].offset)
		libodin.put_str(&sink, "\n")
	}
	return len(libodin.str(&sink))
}

// proc_wait_read collects one ended child of the process and writes its
// exit record as `await` would, waiting for one to end. ECHILD when it has
// none, EINTR when a note is waiting for the reader.
proc_wait_read :: proc(pid: u64, out: []u8) -> (n: int, err: vfs.Errno) {
	for {
		n, err = await_pid(pid, 0, out)
		if err != vectra9.EAGAIN {
			return n, err
		}
		if sched.thread_noted(sched.current()) {
			return 0, vectra9.EINTR
		}
	}
}

// proc_text_read reads the program's file at `off`, through the process's
// own namespace, where its name means something.
// ENOENT for a program the kernel loaded from no file.
proc_text_read :: proc(pid: u64, off: u64, out: []u8) -> (n: int, err: vfs.Errno) {
	p := pin(pid)
	if p == nil {
		return 0, vectra9.ESRCH
	}
	name_buf: [PATH_MAX]u8
	name := string(name_buf[:copy(name_buf[:], p.name)])
	ns := p.ns != nil ? vfs.ns_incref(p.ns) : nil
	unpin(p)
	if ns == nil || len(name) == 0 || name[0] != '/' {
		if ns != nil {
			vfs.ns_close(ns)
		}
		return 0, vectra9.ENOENT
	}
	defer vfs.ns_close(ns)
	c, oerr := vfs.open_path(ns, name, vfs.O_RDONLY)
	if oerr != vfs.OK {
		return 0, oerr
	}
	defer vfs.chan_close(c)
	return vfs.chan_read(c, off, out)
}
