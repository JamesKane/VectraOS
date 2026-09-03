/*
The exception vectors, the frame they build, and the dispatcher they land in.

The protocol hands over `VBAR_EL1` pointing at whatever the bootloader had.
Until this file runs, a fault is the bootloader's to misreport. What it buys
first is *diagnosis*: a fault can name itself, its address and the registers
it happened with. What it buys next is everything else, because on this
architecture there is one door into the kernel. A program's system call, the
timer, another core's kick and a page fault all arrive through the same
sixteen entries in `vectors.S`, and this file sorts them.

## How an arrival becomes a vector

amd64 has a number per interrupt, pushed by a stub. Here the number has to
be found. An IRQ asks the GIC, and the answer is the interrupt id: a
software-generated interrupt from another core is 0..15, a per-core
peripheral like the timer is 16..31, and a shared peripheral is 32 and up. A
synchronous exception carries its class in `ESR_EL1`, and a supervisor call
carries a sixteen-bit immediate the kernel chose. So:

    0 .. 1019    GIC interrupt ids, as they are
    1023         the GIC's `nothing pending`, which is the spurious vector
    0x400        a program's `svc`, whatever its immediate: the door
    0x401        `svc #0x401` from the kernel: yield
    0x402        `svc #0x402` from the kernel: the interrupt bracket's test

Everything that is not an interrupt or a supervisor call is a trap, sorted
by exception class into the same neutral `Trap_Kind` the other architectures
report, so `kernel/panic.odin` and `kernel/user` read one vocabulary.
*/
package arm64

import "base:intrinsics"

import "vsys:libodin"

VECTOR_COUNT :: 0x410

// The three software-generated interrupts, by GIC id. The wake is the kick an
// idle core gets, the shootdown is a translation another core dropped, and
// the stop is what the panic path sends. None of them is non-maskable here,
// which `docs/PORTS.md` records.
VECTOR_WAKE :: 1
VECTOR_SHOOT :: 2
VECTOR_NMI :: 3

// The EL1 physical timer's private interrupt: PPI 14, id 30.
VECTOR_TIMER :: 30

// Where a shared peripheral lands: id 32 plus the line. The `virt` board's
// GIC has 224 of them.
VECTOR_IRQ_BASE :: 32
VECTOR_IRQ_COUNT :: 224

VECTOR_SPURIOUS :: 1023

VECTOR_SYSCALL :: 0x400
VECTOR_YIELD :: 0x401
VECTOR_TEST :: 0x402

// The entry that took the exception: the kind in bits 3:2 and the source in
// bits 1:0, as `vectors.S` writes them. The dispatcher reads them once and
// replaces them with the vector.
ENTRY_SYNC :: 0
ENTRY_IRQ :: 1
ENTRY_FIQ :: 2
ENTRY_SERROR :: 3

/*
The register state at the point of the exception.

Field order is the memory layout the tail builds, and it is the one thing in
this file that cannot move for tidiness. `sp` is the *interrupted* stack:
SP_EL0 for a program, the frame's own end for the kernel. `elr` is where to
resume and `spsr` is the PSTATE to resume with, including the exception
level, which is what makes a program's frame distinguishable from the
kernel's without either being able to forge it.
*/
Trap_Frame :: struct {
	x:          [31]u64,
	sp:         u64,
	elr:        u64,
	spsr:       u64,
	esr:        u64,
	far:        u64,
	vector:     u64,
	error_code: u64,
}

#assert(size_of(Trap_Frame) == 304)

// Where to resume: the two halves of a thread's saved state, both on its
// own stack. See the amd64 file of the same name.
Resume :: struct {
	frame: ^Trap_Frame,
	fpu:   rawptr, // 528-byte vector image, 16-byte aligned
}

// The neutral vocabulary, the same list on every architecture, because the
// portable kernel switches over it.
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
	vector:        u64, // The exception class, or the interrupt id
	name:          string,
	error_code:    u64, // The syndrome's instruction-specific half
	has_error:     bool,
	ip:            uintptr,
	sp:            uintptr,
	fault_address: uintptr, // FAR_EL1; meaningful for an abort
	frame:         ^Trap_Frame,
	user:          bool,
}

Trap_Handler :: #type proc "contextless" (t: ^Trap) -> bool
User_Trap_Handler :: #type proc "contextless" (t: ^Trap, r: Resume) -> Resume
Interrupt_Handler :: #type proc "contextless" (r: Resume) -> Resume

@(private = "file") handler: Trap_Handler
@(private = "file") user_handler: User_Trap_Handler
@(private = "file") vectors: [VECTOR_COUNT]Interrupt_Handler
@(private = "file") user_traps: u64

foreign {
	vectra_vectors: byte
}

// The system call dispatcher, which `kernel/user` registers. A pointer
// rather than a symbol, because the portable kernel's exported name is
// something a `.S` file may reference and this package may not: a foreign
// declaration of a symbol the same image defines is a symbol the linker
// never sees.
Syscall_Dispatcher :: #type proc "c" (frame: ^Trap_Frame)

@(private = "file") syscall_dispatcher: Syscall_Dispatcher

set_syscall_dispatcher :: proc "contextless" (h: Syscall_Dispatcher) {
	syscall_dispatcher = h
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

set_interrupt_handler :: proc "contextless" (vector: int, h: Interrupt_Handler) #no_bounds_check {
	if vector >= 0 && vector < VECTOR_COUNT {
		vectors[vector] = h
	}
}

// frame_is_user reads the exception level out of the saved PSTATE. The M
// field is zero for EL0, and the CPU wrote it before any of this code ran.
frame_is_user :: proc "contextless" (frame: ^Trap_Frame) -> bool {
	return frame != nil && frame.spsr & 0xF == 0
}

// -- Bring-up ------------------------------------------------------------------

// vectors_init points this core at the one table.
vectors_init :: proc "contextless" () {
	write_vbar(u64(uintptr(&vectra_vectors)))
	isb()
}

/*
describe_traps writes the table as this core sees it, and reports whether it
is the kernel's own: VBAR names our table, and the core is at EL1, which is
the level every encoding in this package assumes.
*/
describe_traps :: proc "contextless" (s: ^libodin.Sink) -> bool {
	vbar := read_vbar()
	el := current_el()
	libodin.put_str(s, "vbar ")
	libodin.put_hex(s, vbar, 16)
	libodin.put_str(s, ", el")
	libodin.put_uint(s, el)
	libodin.put_str(s, ", 16 entries")
	return vbar == u64(uintptr(&vectra_vectors)) && el == 1
}

// -- Dispatch ------------------------------------------------------------------

// handle_vector runs the handler claimed for `vector`, inside the bracket
// that makes `in_interrupt` true, and reports whether there was one.
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
trap_dispatch is where every entry lands.

Called from the tail with the frame it just built, with IRQs masked, because
an exception masks them. It finds the vector as the file comment describes,
runs a claimed handler if there is one, and otherwise builds the neutral
`Trap` and hands it to whatever the portable kernel registered.

A program's supervisor call is the one arrival that runs with IRQs open: the
dispatcher on the other side is ordinary thread context, and a long call has
to be preemptible. They are masked again before the tail restores anything.

A breakpoint that the handler resumes is stepped over here. `BRK` leaves
`ELR` on itself, unlike `int3`, and a frame resumed as it stands would take
the same exception forever.
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

	entry := frame.vector >> 2
	trap := Trap {
		ip    = uintptr(frame.elr),
		sp    = uintptr(frame.sp),
		frame = frame,
		user  = from_user,
	}

	switch entry {
	case ENTRY_IRQ:
		iar := gic_acknowledge()
		id := u64(iar & 0x3FF)
		frame.vector = id
		if id >= 1020 {
			frame.vector = VECTOR_SPURIOUS
			_ = handle_vector(VECTOR_SPURIOUS, out)
			return
		}
		if handle_vector(id, out) {
			return
		}
		// Nobody claimed it. Retire it at the controller, so the report
		// below is the last word rather than the first of many.
		gic_eoi(iar)
		trap.kind = .Interrupt
		trap.name = "external interrupt"
		trap.vector = id

	case ENTRY_SYNC:
		ec := frame.esr >> 26 & 0x3F
		iss := frame.esr & 0x1FF_FFFF
		if ec == EC_SVC64 {
			if from_user && syscall_dispatcher != nil {
				frame.vector = VECTOR_SYSCALL
				sti()
				syscall_dispatcher(frame)
				cli()
				return
			}
			frame.vector = iss & 0xFFFF
			if handle_vector(frame.vector, out) {
				return
			}
			trap.kind = .Unknown
			trap.name = "supervisor call with no handler"
			trap.vector = frame.vector
			break
		}
		trap.name, trap.kind = class_info(ec)
		trap.vector = ec
		trap.error_code = iss
		trap.has_error = true
		frame.vector = ec
		if trap.kind == .Page_Fault {
			trap.fault_address = uintptr(frame.far)
		}

	case ENTRY_FIQ:
		trap.kind = .Unknown
		trap.name = "fast interrupt"
		frame.vector = 0

	case ENTRY_SERROR:
		trap.kind = .Machine_Check
		trap.name = "system error"
		trap.error_code = frame.esr & 0x1FF_FFFF
		trap.has_error = true
		frame.vector = 0
	}

	if from_user && user_handler != nil {
		out^ = user_handler(&trap, out^)
		return
	}
	if handler != nil && handler(&trap) {
		if trap.kind == .Breakpoint {
			frame.elr += 4
		}
		return
	}
	halt_forever()
}

// -- Exception classes -----------------------------------------------------------

EC_UNKNOWN :: u64(0x00)
EC_WFX :: u64(0x01)
EC_FP_ACCESS :: u64(0x07)
EC_ILLEGAL_STATE :: u64(0x0E)
EC_SVC64 :: u64(0x15)
EC_SYSREG :: u64(0x18)
EC_IABORT_LOWER :: u64(0x20)
EC_IABORT :: u64(0x21)
EC_PC_ALIGN :: u64(0x22)
EC_DABORT_LOWER :: u64(0x24)
EC_DABORT :: u64(0x25)
EC_SP_ALIGN :: u64(0x26)
EC_FP_TRAP :: u64(0x2C)
EC_SERROR :: u64(0x2F)
EC_BREAKPOINT_LOWER :: u64(0x30)
EC_BREAKPOINT :: u64(0x31)
EC_STEP_LOWER :: u64(0x32)
EC_STEP :: u64(0x33)
EC_WATCHPOINT_LOWER :: u64(0x34)
EC_WATCHPOINT :: u64(0x35)
EC_BRK64 :: u64(0x3C)

// class_info names an exception class and maps it onto the neutral kind.
// The names are the manual's, so a search for the fault will match.
class_info :: proc "contextless" (ec: u64) -> (name: string, kind: Trap_Kind) {
	switch ec {
	case EC_UNKNOWN:          return "unknown reason (undefined instruction)", .Invalid_Instruction
	case EC_WFX:              return "wfi/wfe trapped", .Protection_Fault
	case EC_FP_ACCESS:        return "fp/simd access trapped", .Device_Not_Available
	case EC_ILLEGAL_STATE:    return "illegal execution state", .Protection_Fault
	case EC_SYSREG:           return "system register access trapped", .Protection_Fault
	case EC_IABORT_LOWER:     return "instruction abort from el0", .Page_Fault
	case EC_IABORT:           return "instruction abort", .Page_Fault
	case EC_PC_ALIGN:         return "pc alignment fault", .Alignment_Fault
	case EC_DABORT_LOWER:     return "data abort from el0", .Page_Fault
	case EC_DABORT:           return "data abort", .Page_Fault
	case EC_SP_ALIGN:         return "sp alignment fault", .Alignment_Fault
	case EC_FP_TRAP:          return "floating-point exception", .Arithmetic_Fault
	case EC_SERROR:           return "system error", .Machine_Check
	case EC_BREAKPOINT_LOWER, EC_BREAKPOINT: return "hardware breakpoint", .Debug
	case EC_STEP_LOWER, EC_STEP:             return "software step", .Debug
	case EC_WATCHPOINT_LOWER, EC_WATCHPOINT: return "watchpoint", .Debug
	case EC_BRK64:            return "brk breakpoint", .Breakpoint
	}
	return "unhandled exception class", .Unknown
}

// -- Reporting -------------------------------------------------------------------

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
		" x0", " x1", " x2", " x3", " x4", " x5", " x6", " x7", " x8", " x9",
		"x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x18", "x19",
		"x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29",
		"x30",
	}
	return names[i]
}

// register_line formats one line of the register dump: eight lines of four
// general registers, the exception registers, and the translation control.
register_line :: proc "contextless" (s: ^libodin.Sink, t: ^Trap, index: int) #no_bounds_check {
	f := t.frame
	switch index {
	case 0 ..= 7:
		for i in 0 ..< 4 {
			r := index * 4 + i
			if r < 31 {
				put_reg(s, reg_name(r), f.x[r])
			} else {
				put_reg(s, " sp", f.sp)
			}
		}
	case 8:
		put_reg(s, "elr", f.elr)
		put_reg(s, "spsr", f.spsr)
		put_reg(s, "esr", f.esr)
		put_reg(s, "far", f.far)
	case 9:
		put_reg(s, "ttbr0", read_ttbr0())
		put_reg(s, "ttbr1", read_ttbr1())
		put_reg(s, "tcr", read_tcr())
		put_reg(s, "sctlr", read_sctlr())
	}
}

/*
describe_error decodes the syndrome into words.

For an abort the fault status code says what kind of fault at which level,
and the write bit says which way the access went. Two bits separate a
translation fault at level 3, which is a page that is not there, from a
permission fault at level 3, which is a page that is there and says no.
*/
describe_error :: proc "contextless" (s: ^libodin.Sink, t: ^Trap) {
	if !t.has_error {
		libodin.put_str(s, "none")
		return
	}
	iss := t.error_code
	if t.kind != .Page_Fault {
		libodin.put_hex(s, iss, 0)
		return
	}
	fsc := iss & 0x3F
	level := fsc & 3
	switch fsc >> 2 {
	case 0: libodin.put_str(s, "address size fault")
	case 1: libodin.put_str(s, "translation fault")
	case 2: libodin.put_str(s, "access flag fault")
	case 3: libodin.put_str(s, "permission fault")
	case:
		switch fsc {
		case 0x10: libodin.put_str(s, "synchronous external abort")
		case 0x21: libodin.put_str(s, "alignment fault")
		case:
			libodin.put_str(s, "fault status ")
			libodin.put_hex(s, fsc, 0)
		}
		return
	}
	libodin.put_str(s, ", level ")
	libodin.put_uint(s, level)
	if t.vector == EC_DABORT || t.vector == EC_DABORT_LOWER {
		libodin.put_str(s, iss & (1 << 6) != 0 ? ", write" : ", read")
	} else {
		libodin.put_str(s, ", instruction fetch")
	}
	libodin.put_str(s, t.user ? ", user" : ", supervisor")
}
