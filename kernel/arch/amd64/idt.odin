/*
The interrupt descriptor table, the entry stubs, and the dispatcher they land
in.

The protocol hands over an undefined IDT. Until this file runs, every fault is
a triple fault and a reset, with nothing to show for it. What it buys is
*diagnosis*, and not interrupt handling, because there is no timer and no PIC
yet. A fault can name itself, its address and the registers it happened with,
drawn onto the console the kernel already owns.

Entry is uniform. Each of the 256 vectors has its own sixteen-byte stub that
normalises the frame. It pushes a dummy error code for the vectors where the
CPU does not push a real one, then the vector number.

It then jumps to one common tail, which saves the general-purpose registers and
calls into Odin. So the dispatcher sees the same `Trap_Frame` regardless of
vector, and `iretq` sees the stack it expects regardless of which path built
it.

The assembler generates the stubs. Nothing writes them out 256 times, and
nothing generates a file of them. `.rept` emits them. `.balign 16` makes every
one exactly sixteen bytes wide, whether or not it pushed a dummy. `idt_init`
finds the nth by multiplication. That is the whole reason for the alignment: it
turns a table of 256 function pointers into one label and a shift.
*/
package amd64

import "base:intrinsics"

import "vsys:libodin"

VECTOR_COUNT :: 256

// Each stub is padded to this by `.balign 16` in the blob below, which is what
// makes stub(n) computable as `base + n * STUB_SIZE`. Changing one without the
// other silently aims every vector at the middle of another stub.
STUB_SIZE :: 16

GATE_INTERRUPT :: u8(0x0E) // Clears IF on entry; a trap gate (0x0F) would not
GATE_PRESENT :: u8(0x80)

IDT_Entry :: struct #packed {
	offset_low:  u16,
	selector:    u16,
	ist:         u8, // 0 means "keep the current stack"
	flags:       u8,
	offset_mid:  u16,
	offset_high: u32,
	reserved:    u32,
}

#assert(size_of(IDT_Entry) == 16)

/*
The register state at the point of the trap.

Field order is the memory layout the stubs build, from the lowest address up.
It is the one thing in this file that cannot move for tidiness.

The tail pushes r15 last, so r15 is at the lowest address. The CPU pushed SS
first, so SS is at the highest. `rsp` and `ss` are the *interrupted* stack, not
the handler's. That is the only reason a fault on a bad stack is recoverable
enough to report.
*/
Trap_Frame :: struct {
	r15, r14, r13, r12, r11, r10, r9, r8: u64,
	rbp, rdi, rsi, rdx, rcx, rbx, rax:    u64,

	// Pushed by the per-vector stub.
	vector:     u64,
	error_code: u64,

	// Pushed by the CPU.
	rip:    u64,
	cs:     u64,
	rflags: u64,
	rsp:    u64,
	ss:     u64,
}

#assert(size_of(Trap_Frame) == 176)

/*
Where to resume, which is not always where we came from.

The two halves of a thread's saved CPU state: the general-purpose and `iret`
registers in `frame`, the x87/SSE image in `fpu`. Both live on that thread's
own kernel stack, carved by the entry tail below. A thread switch is therefore
a switch of which `Resume` the tail gets back. The state travels with the
stack, rather than with any global.

Nothing here is per-CPU, which is deliberate. The day there is a second CPU,
this struct is already what each of them independently passes and receives.
*/
Resume :: struct {
	frame: ^Trap_Frame,
	fpu:   rawptr, // 512-byte FXSAVE image, 16-byte aligned
}

// The 512 bytes and 16-byte alignment FXSAVE requires. `FPU_AREA_RESERVE`
// includes room to align a pointer that arrived anywhere.
FPU_AREA_SIZE :: 512
FPU_AREA_ALIGN :: 16
FPU_AREA_RESERVE :: FPU_AREA_SIZE + FPU_AREA_ALIGN

/*
The three vectors Vectra drives itself.

The timer is the LAPIC's, placed just above the architectural exceptions. Yield
is a software interrupt, so a voluntary switch and a preemption arrive by the
same path. There is one context-switch mechanism rather than two. Spurious is
the LAPIC's own, and the architecture pins it to a vector whose low four bits
are all set.
*/
VECTOR_TIMER :: 0x20
VECTOR_YIELD :: 0x81
VECTOR_SPURIOUS :: 0xFF

/*
Where a device interrupt lands: `VECTOR_IRQ_BASE` plus the ISA line.

Above the 8259s' remapped range rather than inside it, and that is not
tidiness. `PIC1_VECTOR_BASE` is 32 and so is `VECTOR_TIMER`. The collision is
harmless while every 8259 line is masked, and a device routed into that range
would make it matter. Sixteen lines fit, which is every ISA interrupt there is.
*/
VECTOR_IRQ_BASE :: 0x30
VECTOR_IRQ_COUNT :: 16

/*
A neutral description of what went wrong.

`kind` is what the portable kernel branches on. `name` and `error_code` are
what it prints. Everything architecture-specific stays behind `frame`. Only
`register_line` and `describe_error` in this file ever look inside it.
`kernel/panic.odin` therefore reports an amd64 fault with no knowledge that it
is one.
*/
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
	Interrupt, // External, vector 32 and above
}

Trap :: struct {
	kind:          Trap_Kind,
	vector:        u64,
	name:          string,
	error_code:    u64,
	has_error:     bool,
	ip:            uintptr,
	sp:            uintptr,
	fault_address: uintptr, // CR2; meaningful only for a page fault
	frame:         ^Trap_Frame,

	// Whether the interrupted code was a program rather than the kernel. Read
	// out of the CS the CPU pushed, which is the only trustworthy answer: a
	// program cannot forge it, and the kernel cannot lose it.
	user:          bool,
}

/*
A handler returns true to resume the interrupted code and false to give up.

Resuming is what makes a breakpoint useful and what the boot self-test relies
on. A halt here, in the arch layer, prints nothing. A kernel that installs no
handler at all therefore still stops, rather than loops through the fault
forever.

It is the portable handler's job to say something first.
*/
Trap_Handler :: #type proc "contextless" (t: ^Trap) -> bool

/*
A fault that came from ring 3 is a different event from a fault in the kernel,
and this is the table that says so.

A kernel fault is a failure to report. The machine lost the argument, and
`Trap_Handler` above says what it can before halting. A fault in a program is
an ordinary outcome. The program is wrong, the kernel is not, and something has
to end the program and carry on.

Only the second one needs to change where execution resumes. That is why this
signature takes and returns a `Resume` and the one above does not. A handler
that returns the state it was given retries the faulting instruction, which for
a fault is a loop. One that returns another thread's ended this one.

With no handler installed a user fault falls through to `Trap_Handler` and
panics. That is the right default: an unclaimed fault in ring 3 means something
reached ring 3 that nothing was prepared to own.
*/
User_Trap_Handler :: #type proc "contextless" (t: ^Trap, r: Resume) -> Resume

@(private = "file") handler: Trap_Handler
@(private = "file") user_handler: User_Trap_Handler
@(private = "file") idt: [VECTOR_COUNT]IDT_Entry
@(private = "file") idtr: Descriptor_Pointer

/*
How many times the machine came back out of ring 3.

Every trap, not only every fault: a timer preemption of a program is counted
here too, and that is the useful half. It is the one number that says a program
is being interrupted rather than merely running.

Volatile, because an interrupt handler writes it and ordinary code reads it in
a loop that waits for it to move.
*/
@(private = "file") user_traps: u64

user_trap_count :: proc "contextless" () -> u64 {
	return intrinsics.volatile_load(&user_traps)
}

set_trap_handler :: proc "contextless" (h: Trap_Handler) {
	handler = h
}

set_user_trap_handler :: proc "contextless" (h: User_Trap_Handler) {
	user_handler = h
}

/*
frame_is_user reports whether the interrupted code was in ring 3.

The privilege is in the low two bits of the CS the CPU pushed. A read from
there rather than from anywhere else is what makes it unforgeable. The
interrupt wrote that value out of the segment register, before any of this code
ran.
*/
frame_is_user :: proc "contextless" (frame: ^Trap_Frame) -> bool {
	return frame != nil && u16(frame.cs) & 3 == RING_USER
}

// -- Vector metadata ---------------------------------------------------------

/*
vector_has_error_code lists the vectors for which the CPU pushes one itself.

This list and the `.if` in the stub blob below are the same list written twice,
in two languages, and they have to agree. If they disagree, the frame is off by
eight bytes, and every field in it reads as the one next door. There is no way
to share it. The assembler consumes one at build time, and Odin consumes the
other at run time. So it is written down here, next to the blob, rather than
somewhere the two could drift apart.
*/
vector_has_error_code :: proc "contextless" (vector: u64) -> bool {
	switch vector {
	case 8, 10, 11, 12, 13, 14, 17, 21, 29, 30:
		return true
	}
	return false
}

/*
vector_info names a vector and maps it onto a portable kind.

The names are the ones the manuals use, mnemonic first, because that is what a
search for the fault will match. Reserved vectors are named as such, rather
than left blank. A fault on vector 15 means something is wrong in a way
`unknown trap` would not convey.
*/
vector_info :: proc "contextless" (vector: u64) -> (name: string, kind: Trap_Kind) {
	switch vector {
	case 0:  return "#DE divide error", .Divide_By_Zero
	case 1:  return "#DB debug exception", .Debug
	case 2:  return "NMI non-maskable interrupt", .Non_Maskable
	case 3:  return "#BP breakpoint", .Breakpoint
	case 4:  return "#OF overflow", .Overflow
	case 5:  return "#BR bound range exceeded", .Bound_Range
	case 6:  return "#UD invalid opcode", .Invalid_Instruction
	case 7:  return "#NM device not available", .Device_Not_Available
	case 8:  return "#DF double fault", .Double_Fault
	case 9:  return "coprocessor segment overrun", .Unknown
	case 10: return "#TS invalid TSS", .Invalid_Task_State
	case 11: return "#NP segment not present", .Segment_Not_Present
	case 12: return "#SS stack-segment fault", .Stack_Fault
	case 13: return "#GP general protection fault", .Protection_Fault
	case 14: return "#PF page fault", .Page_Fault
	case 16: return "#MF x87 floating-point error", .Arithmetic_Fault
	case 17: return "#AC alignment check", .Alignment_Fault
	case 18: return "#MC machine check", .Machine_Check
	case 19: return "#XM SIMD floating-point error", .Arithmetic_Fault
	case 20: return "#VE virtualisation exception", .Unknown
	case 21: return "#CP control protection", .Control_Protection
	case 28: return "#HV hypervisor injection", .Unknown
	case 29: return "#VC VMM communication", .Unknown
	case 30: return "#SX security exception", .Unknown
	}
	if vector >= 32 {
		return "external interrupt", .Interrupt
	}
	return "reserved vector", .Unknown
}

// -- Bring-up ----------------------------------------------------------------

// The base of the generated stub table, defined by the assembler in the blob at
// the bottom of this file. `foreign` with no library: it has an address and no
// storage, and the address is the value.
foreign {
	vectra_isr_stubs: byte
}

/*
idt_init points all 256 vectors at their stubs and loads the table.

All 256, not just the 32 architectural exceptions. A spurious external
interrupt on a vector with no descriptor is itself a #GP. A #GP raised while
there is no #GP handler is a double fault.

So every vector gets a stub in advance. That is the cheapest way to make a
stray interrupt name itself, rather than reset the machine.

Three vectors get a stack of their own out of the TSS.

The double fault, because it is the one that must not fault again. NMI, because
it can arrive on any stack at any time, including inside another handler. And
the machine check, for the same reason.
*/
idt_init :: proc "contextless" () {
	base := uintptr(&vectra_isr_stubs)

	for vector in 0 ..< VECTOR_COUNT {
		ist := u8(0)
		switch vector {
		case 8:  ist = IST_DOUBLE_FAULT
		case 2:  ist = IST_NMI
		case 18: ist = IST_MACHINE_CHECK
		}
		set_gate(vector, base + uintptr(vector * STUB_SIZE), ist)
	}

	idtr = Descriptor_Pointer {
		limit = u16(size_of(idt) - 1),
		base  = u64(uintptr(&idt[0])),
	}
	asm(rawptr){"lidt ($0)", "r,~{memory}"}(&idtr)
}

@(private = "file")
set_gate :: proc "contextless" (vector: int, entry: uintptr, ist: u8) #no_bounds_check {
	address := u64(entry)
	idt[vector] = IDT_Entry {
		offset_low  = u16(address),
		selector    = KERNEL_CODE_SEL,
		ist         = ist,
		flags       = GATE_PRESENT | GATE_INTERRUPT,
		offset_mid  = u16(address >> 16),
		offset_high = u32(address >> 32),
	}
}

// breakpoint raises #BP. The one exception a kernel can raise deliberately and
// resume from. That makes it the only end-to-end test of this file that does
// not crash on purpose.
breakpoint :: proc "contextless" () {
	asm(){"int3", "~{memory}"}()
}

read_idt_limit :: proc "contextless" () -> u16 {
	pointer: Descriptor_Pointer
	asm(rawptr){"sidt ($0)", "r,~{memory}"}(&pointer)
	return pointer.limit
}

// -- Dispatch ----------------------------------------------------------------

/*
What a vector does, when something claims one.

Takes the state it interrupted, and returns the state to resume. A handler that
only services a device returns the same one. The scheduler returns a different
thread's. A returned decision, rather than one performed here, is what keeps
the switch in one place.

The tail below is the only code that reloads `rsp`. It does that for a
preemption, for a voluntary yield and for an ordinary interrupt return, and it
never learns which.

`contextless` and allocation-free, like everything on this path.
*/
Interrupt_Handler :: #type proc "contextless" (r: Resume) -> Resume

@(private = "file")
vectors: [VECTOR_COUNT]Interrupt_Handler

/*
set_interrupt_handler claims one vector.

Separate from `set_trap_handler`, which is the single fallback for the
architectural exceptions.

A fault is a failure to report. An interrupt is a device to service. A table
that mixed them would let a missing timer handler look like a working one.
*/
set_interrupt_handler :: proc "contextless" (vector: int, h: Interrupt_Handler) #no_bounds_check {
	if vector >= 0 && vector < VECTOR_COUNT {
		vectors[vector] = h
	}
}

/*
trap_dispatch is where every stub lands.

Called from the assembly tail below with the frame it just built, under an
interrupt gate so IF is already clear. It translates the frame into the neutral
`Trap` and hands it to whatever the portable kernel registered.

Not `contextless` in the Odin sense but in the practical one: nothing here
allocates, nothing here logs, and nothing here can afford to fault. The handler
it calls is what does the talking.
*/
@(export, link_name = "vectra_trap_dispatch")
trap_dispatch :: proc "sysv" (frame: ^Trap_Frame, fpu: rawptr, out: ^Resume) #no_bounds_check {
	// Resume where we came from unless something says otherwise. Written first,
	// so every path below leaves a valid answer behind it. That includes the
	// paths that do not return.
	out^ = Resume {
		frame = frame,
		fpu   = fpu,
	}

	from_user := frame_is_user(frame)
	if from_user {
		intrinsics.volatile_store(&user_traps, intrinsics.volatile_load(&user_traps) + 1)
	}

	if frame.vector < VECTOR_COUNT {
		if h := vectors[frame.vector]; h != nil {
			out^ = h(out^)
			return
		}
	}

	name, kind := vector_info(frame.vector)

	trap := Trap {
		kind       = kind,
		vector     = frame.vector,
		name       = name,
		error_code = frame.error_code,
		has_error  = vector_has_error_code(frame.vector),
		ip         = uintptr(frame.rip),
		sp         = uintptr(frame.rsp),
		frame      = frame,
		user       = from_user,
	}
	if kind == .Page_Fault {
		// CR2 is live only until the next page fault. An interrupt gate already
		// guarantees there will not be one before this reads it.
		trap.fault_address = read_cr2()
	}

	// A program's fault, to whatever owns programs. It answers with the state
	// to resume, which is how it ends a thread without this file knowing what a
	// thread is.
	if from_user && user_handler != nil {
		out^ = user_handler(&trap, out^)
		return
	}

	if handler != nil && handler(&trap) {
		return
	}
	halt_forever()
}

/*
fpu_init writes the FXSAVE image a thread starts life with.

Not zeroes. FXRSTOR faults on reserved bits set in MXCSR. A zeroed image would
also start the thread with every SSE exception *unmasked*, and the x87 control
word at 24-bit precision.

A new thread would then take a #XF on the first denormal, rather than behave
like every other thread on the machine.

These two words are what the CPU itself puts there after `finit` and a reset.
0x037F is 64-bit precision with all x87 exceptions masked. 0x1F80 is all SSE
exceptions masked, and round-to-nearest.
*/
fpu_init :: proc "contextless" (area: rawptr) {
	bytes := ([^]u8)(area)
	for i in 0 ..< FPU_AREA_SIZE {
		bytes[i] = 0
	}
	(^u16)(area)^ = 0x037F // FCW
	(^u32)(rawptr(uintptr(area) + 24))^ = 0x1F80 // MXCSR
}

// yield_trap raises the software interrupt the scheduler listens on. A
// voluntary switch takes the same path a preemption does, which is the whole
// reason it is an `int` and not a call.
yield_trap :: proc "contextless" () {
	asm(){"int $$0x81", "~{memory}"}()
}

// -- Reporting ---------------------------------------------------------------

// How many lines `register_line` will produce. The caller loops, rather than
// takes a block of text. The kernel log formats one line at a time into a
// fixed buffer, and has nowhere to put a block.
REGISTER_LINES :: 6

@(private = "file")
put_reg :: proc "contextless" (s: ^libodin.Sink, name: string, value: u64) {
	libodin.put_str(s, name)
	libodin.put_byte(s, '=')
	libodin.put_hex(s, value, 16)
	libodin.put_byte(s, ' ')
}

/*
register_line formats one line of the register dump into `s`.

Four registers to a line, which fits a 149-column console with room for the log
tag. The last line is the control registers, rather than general-purpose ones.

CR2 and CR3 are what turn `page fault` into `page fault on this address, in
this address space`. CR0 and CR4 are where a CPU that behaves mysteriously
usually has a bit clear.
*/
register_line :: proc "contextless" (s: ^libodin.Sink, t: ^Trap, index: int) {
	f := t.frame
	switch index {
	case 0:
		put_reg(s, "rax", f.rax)
		put_reg(s, "rbx", f.rbx)
		put_reg(s, "rcx", f.rcx)
		put_reg(s, "rdx", f.rdx)
	case 1:
		put_reg(s, "rsi", f.rsi)
		put_reg(s, "rdi", f.rdi)
		put_reg(s, "rbp", f.rbp)
		put_reg(s, "rsp", f.rsp)
	case 2:
		put_reg(s, " r8", f.r8)
		put_reg(s, " r9", f.r9)
		put_reg(s, "r10", f.r10)
		put_reg(s, "r11", f.r11)
	case 3:
		put_reg(s, "r12", f.r12)
		put_reg(s, "r13", f.r13)
		put_reg(s, "r14", f.r14)
		put_reg(s, "r15", f.r15)
	case 4:
		put_reg(s, "rip", f.rip)
		put_reg(s, " cs", f.cs)
		put_reg(s, "rfl", f.rflags)
		put_reg(s, " ss", f.ss)
	case 5:
		put_reg(s, "cr0", read_cr0())
		put_reg(s, "cr2", u64(read_cr2()))
		put_reg(s, "cr3", read_cr3())
		put_reg(s, "cr4", read_cr4())
	}
}

/*
describe_error decodes the error code into words.

Worth the code, because the raw value is the least readable thing on a panic
screen and the most informative once decoded.

Two bits separate a page fault at 0x0 that was a null dereference from one that
was a write to a read-only kernel mapping. A reader who takes them off in hex
at three in the morning makes a wrong diagnosis.
*/
describe_error :: proc "contextless" (s: ^libodin.Sink, t: ^Trap) {
	if !t.has_error {
		libodin.put_str(s, "none")
		return
	}

	code := t.error_code
	switch t.kind {
	case .Double_Fault:
		// Architecturally always zero. Saying so stops the next person reading
		// a meaning into a field that has none.
		libodin.put_str(s, "zero (a double fault carries no code)")

	case .Page_Fault:
		libodin.put_str(s, code & 1 != 0 ? "protection violation" : "page not present")
		libodin.put_str(s, code & 2 != 0 ? ", write" : ", read")
		libodin.put_str(s, code & 4 != 0 ? ", user" : ", supervisor")
		if code & 8 != 0 {
			libodin.put_str(s, ", reserved bit set")
		}
		if code & 16 != 0 {
			libodin.put_str(s, ", instruction fetch")
		}
		if code & 32 != 0 {
			libodin.put_str(s, ", protection key")
		}
		if code & 64 != 0 {
			libodin.put_str(s, ", shadow stack")
		}

	case .Protection_Fault,
	     .Stack_Fault,
	     .Segment_Not_Present,
	     .Invalid_Task_State,
	     .Control_Protection:
		if code == 0 {
			// A #GP with a zero error code is the common case, and does not mean
			// `selector zero`. It means the fault had no selector at all.
			libodin.put_str(s, "no selector")
			return
		}
		libodin.put_str(s, "selector ")
		libodin.put_hex(s, (code >> 3) & 0x1FFF, 0)
		switch (code >> 1) & 3 {
		case 0: libodin.put_str(s, " in GDT")
		case 1: libodin.put_str(s, " in IDT")
		case 2: libodin.put_str(s, " in LDT")
		case:   libodin.put_str(s, " in IDT")
		}
		if code & 1 != 0 {
			libodin.put_str(s, ", external")
		}

	case .Unknown,
	     .Divide_By_Zero,
	     .Debug,
	     .Non_Maskable,
	     .Breakpoint,
	     .Overflow,
	     .Bound_Range,
	     .Invalid_Instruction,
	     .Device_Not_Available,
	     .Arithmetic_Fault,
	     .Alignment_Fault,
	     .Machine_Check,
	     .Interrupt:
		libodin.put_hex(s, code, 0)
	}
}

// -- The entry stubs ---------------------------------------------------------

/*
Two hundred and fifty-six entry points and the tail they share, emitted by the
assembler.

`proc "naked"`, because there must be no prologue. The CPU already pushed an
interrupt frame, and anything the compiler adds before the first instruction
corrupts it. Nothing ever calls this procedure -- it is a container for the
symbols the blob defines, and the `retq` the compiler puts after it is
unreachable.

The tail saves the general-purpose registers *and* the x87 and SSE state. It is
also the only code in Vectra that reloads `rsp` from something other than a
`pop`. Those two facts are what make preemption possible, and they are worth
spelling out because the sequence looks arbitrary and is not:

  1. Fifteen pushes build the `Trap_Frame`. `rsp` now points at it, and that
     pointer is the first argument.
  2. 528 bytes are reserved below it and the pointer aligned down to 16.
     FXSAVE needs both, and it has to happen *here* rather than in Odin: the
     compiler uses XMM registers for ordinary struct moves, so the first line
     of the dispatcher would already destroy what this is trying to save.
  3. Sixteen more bytes are an out-slot for the answer, kept in `%r12` across
     the call because SysV makes the callee preserve it. Three arguments in and
     two pointers out, rather than a struct return -- Odin's multi-value ABI is
     not something to be guessing at from assembly.
  4. FXRSTOR from whatever image came back, *then* `rsp` from whatever frame
     came back. Both reads finish before the pops begin. A thread's saved state
     may therefore sit in stack it is about to run on.

A handler that returns the state it was given produces an ordinary interrupt
return. One that returns another thread's produces a context switch. The tail
cannot tell the difference and does not need to.

`cld`, because the System V ABI requires the direction flag clear on entry to
compiled code. An interrupt can land anywhere, including inside a `std`.
*/
@(export)
vectra_isr_blob :: proc "naked" () {
	asm(){`
.balign 16
.globl vectra_isr_common
vectra_isr_common:
	cld
	pushq %rax
	pushq %rbx
	pushq %rcx
	pushq %rdx
	pushq %rsi
	pushq %rdi
	pushq %rbp
	pushq %r8
	pushq %r9
	pushq %r10
	pushq %r11
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15

	movq %rsp, %rdi
	subq $$528, %rsp
	andq $$-16, %rsp
	fxsave (%rsp)
	movq %rsp, %rsi

	subq $$16, %rsp
	movq %rsp, %rdx
	movq %rsp, %r12
	call vectra_trap_dispatch

	movq 8(%r12), %rax
	fxrstor (%rax)
	movq 0(%r12), %rsp

	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %r11
	popq %r10
	popq %r9
	popq %r8
	popq %rbp
	popq %rdi
	popq %rsi
	popq %rdx
	popq %rcx
	popq %rbx
	popq %rax
	addq $$16, %rsp
	iretq

.balign 16
.globl vectra_isr_stubs
vectra_isr_stubs:
.set vector, 0
.rept 256
	.balign 16
	.if (vector==8)||(vector==10)||(vector==11)||(vector==12)||(vector==13)||(vector==14)||(vector==17)||(vector==21)||(vector==29)||(vector==30)
	.else
	pushq $$0
	.endif
	pushq $$vector
	jmp vectra_isr_common
.set vector, vector + 1
.endr
`, "~{memory}"}()
}
