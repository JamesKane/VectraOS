/*
The trap entry, the frame it builds, and the dispatcher it lands in.

The protocol hands over `stvec` cleared. Until this file runs, a fault
vectors to address zero, and there is nothing there. What it buys is what
the other two architectures' files buy: first a fault that names itself,
then the one door every arrival comes through. A program's environment
call, the timer, another hart's software interrupt and a page fault all
arrive at `vectra_vectors`, and this file sorts them by `scause`.

## How an arrival becomes a vector

    0 .. 15      an exception, by its cause code: a trap, reported
    16 + cause   an interrupt, by its cause code: 17 is software, 21 is the
                 timer, 25 is external, which is the PLIC
    32 + source  a PLIC source, once the external interrupt has asked which
    0x81 ..      the software vectors: an `ebreak` from supervisor mode
                 carries one in `a7`, and a software interrupt carries a set
                 of them in the per-CPU record. An `ecall` cannot carry
                 one -- from supervisor mode it is the firmware's door, and
                 the firmware answers it
    0x100        a program's `ecall`: the door

The exception causes are sorted into the same neutral `Trap_Kind` the other
architectures report.
*/
package riscv64

import "base:intrinsics"

import "vsys:libodin"

VECTOR_COUNT :: 256

VECTOR_INTERRUPT_BASE :: 16
VECTOR_SOFTWARE_INTERRUPT :: VECTOR_INTERRUPT_BASE + 1
VECTOR_TIMER :: VECTOR_INTERRUPT_BASE + 5
VECTOR_EXTERNAL :: VECTOR_INTERRUPT_BASE + 9

// Where a PLIC source lands: 32 plus the source number. The `virt` board's
// PLIC has 96 sources, of which source 0 is nothing.
VECTOR_IRQ_BASE :: 32
VECTOR_IRQ_COUNT :: 96

VECTOR_YIELD :: 0x81
VECTOR_TEST :: 0x82
VECTOR_WAKE :: 0x83
VECTOR_SHOOT :: 0x84
VECTOR_NMI :: 0x85
VECTOR_SPURIOUS :: 0xFF
VECTOR_SYSCALL :: 0x100

// The interrupt-enable and interrupt-pending bits, for `sie` and `sip`.
SIE_SSIE :: u64(1) << 1
SIE_STIE :: u64(1) << 5
SIE_SEIE :: u64(1) << 9
SIP_SSIP :: u64(1) << 1

// The exception causes.
CAUSE_INTERRUPT :: u64(1) << 63
CAUSE_INSN_MISALIGNED :: u64(0)
CAUSE_INSN_ACCESS :: u64(1)
CAUSE_ILLEGAL :: u64(2)
CAUSE_BREAKPOINT :: u64(3)
CAUSE_LOAD_MISALIGNED :: u64(4)
CAUSE_LOAD_ACCESS :: u64(5)
CAUSE_STORE_MISALIGNED :: u64(6)
CAUSE_STORE_ACCESS :: u64(7)
CAUSE_ECALL_USER :: u64(8)
CAUSE_ECALL_SUPERVISOR :: u64(9)
CAUSE_INSN_PAGE :: u64(12)
CAUSE_LOAD_PAGE :: u64(13)
CAUSE_STORE_PAGE :: u64(15)

/*
The register state at the point of the trap.

Field order is the memory layout the entry builds. `x[2]` is the interrupted
stack pointer and `x[4]` the interrupted thread pointer, both kept for a
program and neither restored for the kernel -- see `vectors.S`. `sstatus`
carries the mode the trap came from, which is what makes a program's frame
distinguishable from the kernel's without either being able to forge it.
*/
Trap_Frame :: struct {
	x:          [32]u64,
	sepc:       u64,
	sstatus:    u64,
	scause:     u64,
	stval:      u64,
	vector:     u64,
	error_code: u64,
}

#assert(size_of(Trap_Frame) == 304)

Resume :: struct {
	frame: ^Trap_Frame,
	fpu:   rawptr, // 272-byte float image, 16-byte aligned
}

Trap_Kind :: enum {
	Unknown,
	Divide_By_Zero,
	Debug,
	Non_Maskable,
	Breakpoint,
	Overflow,
	Bound_Range,
	Invalid_Instruction,
	Device_Not_Available,
	Double_Fault,
	Invalid_Task_State,
	Segment_Not_Present,
	Stack_Fault,
	Protection_Fault,
	Page_Fault,
	Arithmetic_Fault,
	Alignment_Fault,
	Machine_Check,
	Control_Protection,
	Interrupt,
}

Trap :: struct {
	kind:          Trap_Kind,
	vector:        u64,
	name:          string,
	error_code:    u64,
	has_error:     bool,
	ip:            uintptr,
	sp:            uintptr,
	fault_address: uintptr, // stval; meaningful for a fault
	frame:         ^Trap_Frame,
	user:          bool,
}

Trap_Handler :: #type proc "contextless" (t: ^Trap) -> bool
User_Trap_Handler :: #type proc "contextless" (t: ^Trap, r: Resume) -> Resume
Interrupt_Handler :: #type proc "contextless" (r: Resume) -> Resume
Syscall_Dispatcher :: #type proc "c" (frame: ^Trap_Frame)

@(private = "file") handler: Trap_Handler
@(private = "file") user_handler: User_Trap_Handler
@(private = "file") syscall_dispatcher: Syscall_Dispatcher
@(private = "file") vectors: [VECTOR_COUNT]Interrupt_Handler
@(private = "file") user_traps: u64

foreign {
	vectra_vectors: byte
}

in_interrupt :: proc "contextless" () -> bool {
	return this_cpu().interrupt_depth > 0
}

user_trap_count :: proc "contextless" () -> u64 {
	return intrinsics.volatile_load(&user_traps)
}

set_trap_handler :: proc "contextless" (h: Trap_Handler) {
	handler = h
}

set_user_trap_handler :: proc "contextless" (h: User_Trap_Handler) {
	user_handler = h
}

set_syscall_dispatcher :: proc "contextless" (h: Syscall_Dispatcher) {
	syscall_dispatcher = h
}

set_interrupt_handler :: proc "contextless" (vector: int, h: Interrupt_Handler) #no_bounds_check {
	if vector >= 0 && vector < VECTOR_COUNT {
		vectors[vector] = h
	}
}

// frame_is_user reads the previous privilege out of the saved status. SPP
// clear is user mode, and the hart wrote it before any of this code ran.
frame_is_user :: proc "contextless" (frame: ^Trap_Frame) -> bool {
	return frame != nil && frame.sstatus & SSTATUS_SPP == 0
}

// -- Bring-up --------------------------------------------------------------------

// vectors_init points this hart at the entry, in direct mode: every trap to
// one address, with `scause` to say which.
vectors_init :: proc "contextless" () {
	write_stvec(u64(uintptr(&vectra_vectors)))
}

describe_traps :: proc "contextless" (s: ^libodin.Sink) -> bool {
	stvec := read_stvec()
	libodin.put_str(s, "stvec ")
	libodin.put_hex(s, stvec, 16)
	libodin.put_str(s, " direct, hart ")
	libodin.put_uint(s, percpu_hart())
	return stvec == u64(uintptr(&vectra_vectors))
}

// -- Dispatch --------------------------------------------------------------------

@(private = "file")
handle_vector :: proc "contextless" (vector: u64, out: ^Resume) -> bool #no_bounds_check {
	if vector >= VECTOR_COUNT {
		return false
	}
	h := vectors[vector]
	if h == nil {
		return false
	}
	this_cpu().interrupt_depth += 1
	out^ = h(out^)
	this_cpu().interrupt_depth -= 1
	return true
}

/*
trap_dispatch is where the entry lands.

Called from the tail with the frame it just built, with interrupts masked,
because a trap masks them. It finds the vector as the file comment
describes, runs a claimed handler if there is one, and otherwise builds the
neutral `Trap` and hands it to whatever the portable kernel registered.

An `ecall` and an `ebreak` both leave `sepc` on themselves, unlike an `svc`
or a `syscall`, so the return address is stepped past them here, before
the dispatcher sees a frame whose `ip` it may copy and before a handler can
resume it. A program's environment call is the one arrival that runs with
interrupts open, because the dispatcher on the other side is ordinary thread
context and a long call has to be preemptible.

A software interrupt carries no number, so the sender leaves a set of
vectors in the receiver's per-CPU record and this takes them out atomically,
oldest first by bit.
*/
@(export, link_name = "vectra_trap_dispatch")
trap_dispatch :: proc "c" (frame: ^Trap_Frame, fpu: rawptr, out: ^Resume) #no_bounds_check {
	out^ = Resume {
		frame = frame,
		fpu   = fpu,
	}

	from_user := frame_is_user(frame)
	if from_user {
		intrinsics.volatile_store(&user_traps, intrinsics.volatile_load(&user_traps) + 1)
	}

	cause := frame.scause
	trap := Trap {
		ip    = uintptr(frame.sepc),
		sp    = uintptr(frame.x[REG_SP]),
		frame = frame,
		user  = from_user,
	}

	if cause & CAUSE_INTERRUPT != 0 {
		code := cause &~ CAUSE_INTERRUPT
		frame.vector = VECTOR_INTERRUPT_BASE + code
		switch frame.vector {
		case VECTOR_SOFTWARE_INTERRUPT:
			clear_sip(SIP_SSIP)
			pending := intrinsics.atomic_exchange(&this_cpu().ipi, 0)
			this_cpu().irq = 0
			for bit in u64(0) ..< 64 {
				if pending & (u64(1) << bit) != 0 {
					_ = handle_vector(IPI_VECTOR_BASE + bit, out)
				}
			}
			return
		case VECTOR_TIMER:
			this_cpu().irq = VECTOR_TIMER
			if handle_vector(VECTOR_TIMER, out) {
				return
			}
			// Nobody listening: the timer stays quiet rather than fault
			// once a millisecond.
			timer_stop()
			trap.kind = .Interrupt
			trap.name = "timer interrupt with no handler"
		case VECTOR_EXTERNAL:
			source := plic_claim()
			if source == 0 {
				frame.vector = VECTOR_SPURIOUS
				_ = handle_vector(VECTOR_SPURIOUS, out)
				return
			}
			frame.vector = VECTOR_IRQ_BASE + u64(source)
			this_cpu().irq = u32(frame.vector)
			if handle_vector(frame.vector, out) {
				return
			}
			plic_complete(source)
			this_cpu().irq = 0
			trap.kind = .Interrupt
			trap.name = "external interrupt"
		case:
			trap.kind = .Interrupt
			trap.name = "interrupt with no handler"
		}
		trap.vector = frame.vector
	} else {
		switch cause {
		case CAUSE_ECALL_USER:
			frame.sepc += 4
			frame.vector = VECTOR_SYSCALL
			if syscall_dispatcher != nil {
				sti()
				syscall_dispatcher(frame)
				cli()
				return
			}
			trap.kind = .Unknown
			trap.name = "environment call from a program, with no door"
			trap.vector = cause
		case CAUSE_BREAKPOINT:
			frame.sepc += 4
			number := frame.x[REG_A7]
			if !from_user && number >= IPI_VECTOR_BASE {
				frame.vector = number
				if handle_vector(number, out) {
					return
				}
				trap.kind = .Unknown
				trap.name = "software trap with no handler"
				trap.vector = number
				break
			}
			trap.kind = .Breakpoint
			trap.name = "breakpoint"
			trap.vector = cause
			frame.vector = cause
		case:
			trap.name, trap.kind = cause_info(cause)
			// An illegal instruction whose opcode is SYSTEM is a program
			// touching a control register it may not, which every other
			// architecture reports as a privilege violation and so does this.
			if cause == CAUSE_ILLEGAL && frame.stval & 0x7F == 0x73 {
				trap.name, trap.kind = "privileged instruction", .Protection_Fault
			}
			trap.vector = cause
			trap.error_code = frame.stval
			trap.has_error = trap.kind == .Page_Fault || trap.kind == .Protection_Fault || trap.kind == .Alignment_Fault
			trap.fault_address = uintptr(frame.stval)
			frame.vector = cause
			// Whether the page was there is not in the cause, and the tables
			// that say are the ones loaded now, not the ones a reader of the
			// record has later. So the walk is made here, and its answer rides
			// in the top bit of the code, above any address. See `fault_bits`.
			if trap.kind == .Page_Fault && mapped(uintptr(frame.stval)) {
				trap.error_code |= FAULT_PRESENT
			}
		}
	}

	if from_user && user_handler != nil {
		out^ = user_handler(&trap, out^)
		return
	}
	if handler != nil && handler(&trap) {
		return
	}
	halt_forever()
}

// cause_info names an exception cause and maps it onto the neutral kind.
cause_info :: proc "contextless" (cause: u64) -> (name: string, kind: Trap_Kind) {
	switch cause {
	case CAUSE_INSN_MISALIGNED:  return "instruction address misaligned", .Alignment_Fault
	case CAUSE_INSN_ACCESS:      return "instruction access fault", .Protection_Fault
	case CAUSE_ILLEGAL:          return "illegal instruction", .Invalid_Instruction
	case CAUSE_BREAKPOINT:       return "breakpoint", .Breakpoint
	case CAUSE_LOAD_MISALIGNED:  return "load address misaligned", .Alignment_Fault
	case CAUSE_LOAD_ACCESS:      return "load access fault", .Protection_Fault
	case CAUSE_STORE_MISALIGNED: return "store address misaligned", .Alignment_Fault
	case CAUSE_STORE_ACCESS:     return "store access fault", .Protection_Fault
	case CAUSE_INSN_PAGE:        return "instruction page fault", .Page_Fault
	case CAUSE_LOAD_PAGE:        return "load page fault", .Page_Fault
	case CAUSE_STORE_PAGE:       return "store page fault", .Page_Fault
	}
	return "unhandled exception", .Unknown
}

// -- Reporting ---------------------------------------------------------------------

REGISTER_LINES :: 10

@(private = "file")
put_reg :: proc "contextless" (s: ^libodin.Sink, name: string, value: u64) {
	libodin.put_str(s, name)
	libodin.put_byte(s, '=')
	libodin.put_hex(s, value, 16)
	libodin.put_byte(s, ' ')
}

@(private = "file")
reg_name :: proc "contextless" (i: int) -> string {
	names := [?]string{
		"zero", "  ra", "  sp", "  gp", "  tp", "  t0", "  t1", "  t2",
		"  s0", "  s1", "  a0", "  a1", "  a2", "  a3", "  a4", "  a5",
		"  a6", "  a7", "  s2", "  s3", "  s4", "  s5", "  s6", "  s7",
		"  s8", "  s9", " s10", " s11", "  t3", "  t4", "  t5", "  t6",
	}
	return names[i]
}

// register_line formats one line of the register dump: eight lines of four
// general registers by ABI name, the trap registers, and the two the panic
// path most wants beside them.
register_line :: proc "contextless" (s: ^libodin.Sink, t: ^Trap, index: int) #no_bounds_check {
	f := t.frame
	switch index {
	case 0 ..= 7:
		for i in 0 ..< 4 {
			r := index * 4 + i
			put_reg(s, reg_name(r), f.x[r])
		}
	case 8:
		put_reg(s, "sepc", f.sepc)
		put_reg(s, "sstatus", f.sstatus)
		put_reg(s, "scause", f.scause)
		put_reg(s, "stval", f.stval)
	case 9:
		put_reg(s, "satp", read_satp())
		put_reg(s, "sie", read_sie())
		put_reg(s, "sip", read_sip())
		put_reg(s, "stvec", read_stvec())
	}
}

// describe_error says what the fault was about. The cause already says
// which kind of access, so what is left to add is the address, which is
// `stval`, and whether a program did it.
describe_error :: proc "contextless" (s: ^libodin.Sink, t: ^Trap) {
	if !t.has_error {
		libodin.put_str(s, "none")
		return
	}
	switch t.vector {
	case CAUSE_INSN_PAGE, CAUSE_INSN_ACCESS: libodin.put_str(s, "instruction fetch")
	case CAUSE_LOAD_PAGE, CAUSE_LOAD_ACCESS, CAUSE_LOAD_MISALIGNED: libodin.put_str(s, "read")
	case CAUSE_STORE_PAGE, CAUSE_STORE_ACCESS, CAUSE_STORE_MISALIGNED: libodin.put_str(s, "write")
	case: libodin.put_str(s, "access")
	}
	libodin.put_str(s, " at ")
	libodin.put_hex(s, t.error_code &~ FAULT_PRESENT, 16)
	libodin.put_str(s, t.user ? ", user" : ", supervisor")
}
