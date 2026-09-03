/*
Laying out a thread's first saved state.

A thread that never ran still has to look exactly like one something
interrupted. There is only one resume path, and it has no special case. So a
new thread gets the `Trap_Frame` and the vector image written onto its own
stack, exactly where the trap tail would have left them. The first time a
core takes it, an `eret` drops into `entry`, as though it returned from an
exception that never happened.

The frame goes at the very top of the stack, because the tail closes a frame
by adding its size to the stack pointer, and what it lands on is what the
thread runs on. The vector image goes directly below the frame, where the
tail puts one, so `syscall_frame_fpu` has one rule for both.
*/
package arm64

MIN_STACK_SIZE :: 4096

// The vector image: q0..q31, then fpsr and fpcr. What the tail saves below
// every frame.
FPU_AREA_SIZE :: 528
FPU_AREA_ALIGN :: 16

// PSTATE for a kernel thread: EL1 on SP_EL1, debug, SError and FIQ masked,
// IRQ open. A thread whose first frame had IRQs masked would run its whole
// first slice unpreemptable, and on a thread that never yields, forever.
SPSR_EL1H :: u64(0x345)

// PSTATE for a program: EL0, the same masks. The M field is zero, which is
// what `frame_is_user` reads.
SPSR_EL0 :: u64(0x340)

@(private = "file")
align_down :: proc "contextless" (value: uintptr, align: uintptr) -> uintptr {
	return value & ~(align - 1)
}

// kernel_stack_top is the sixteen-byte-aligned end of a stack, which is what
// SP has to be whenever it is used as a base here.
kernel_stack_top :: proc "contextless" (stack: []u8) -> uintptr {
	return align_down(uintptr(raw_data(stack)) + uintptr(len(stack)), 16)
}

// carve puts an empty frame and a zeroed vector image at the top of `stack`,
// and answers both. False when the stack is too small to hold them.
@(private = "file")
carve :: proc "contextless" (stack: []u8) -> (frame: ^Trap_Frame, fpu: rawptr, ok: bool) {
	if len(stack) < MIN_STACK_SIZE {
		return nil, nil, false
	}
	top := kernel_stack_top(stack)
	frame_at := top - size_of(Trap_Frame)
	fpu_at := frame_at - FPU_AREA_SIZE
	if fpu_at <= uintptr(raw_data(stack)) {
		return nil, nil, false
	}
	frame = (^Trap_Frame)(frame_at)
	frame^ = {}
	frame.sp = u64(top)
	bytes := ([^]u8)(fpu_at)
	for i in 0 ..< FPU_AREA_SIZE {
		bytes[i] = 0
	}
	return frame, rawptr(fpu_at), true
}

/*
thread_resume_init writes a new kernel thread's saved state onto its stack.

`arg` arrives in `x0`, so an entry procedure is an ordinary `proc "c"
(arg: rawptr)`. `on_return` goes in the link register, so a fall off the end
of the entry procedure lands somewhere deliberate.
*/
thread_resume_init :: proc "contextless" (
	stack: []u8,
	entry: rawptr,
	arg: rawptr,
	on_return: rawptr,
) -> (
	resume: Resume,
	ok: bool,
) {
	if entry == nil {
		return {}, false
	}
	frame, fpu, carved := carve(stack)
	if !carved {
		return {}, false
	}
	frame.x[0] = u64(uintptr(arg))
	frame.x[30] = u64(uintptr(on_return))
	frame.elr = u64(uintptr(entry))
	frame.spsr = SPSR_EL1H
	return Resume{frame = frame, fpu = fpu}, true
}

/*
thread_user_init lays out a thread whose first `eret` lands in a program.

The frame names EL0, the program's own stack in `sp`, and three arguments in
`x0` to `x2`. Everything else is zero, so nothing of the kernel's leaks into
a program's first registers.
*/
thread_user_init :: proc "contextless" (
	stack: []u8,
	entry: uintptr,
	sp: uintptr,
	arg0, arg1, arg2: u64,
) -> (
	resume: Resume,
	ok: bool,
) {
	if entry == 0 || sp == 0 {
		return {}, false
	}
	frame, fpu, carved := carve(stack)
	if !carved {
		return {}, false
	}
	frame.x[0] = arg0
	frame.x[1] = arg1
	frame.x[2] = arg2
	frame.sp = u64(sp)
	frame.elr = u64(entry)
	frame.spsr = SPSR_EL0
	return Resume{frame = frame, fpu = fpu}, true
}

/*
thread_user_clone duplicates a running thread's state onto a new stack.

The frame is the caller's own, copied whole, and the vector image is the one
the tail parked below it. The copy is the child of a fork: same registers,
same program counter, and whatever answer the caller writes into the frame
afterwards is what the child wakes up with.
*/
thread_user_clone :: proc "contextless" (stack: []u8, src: ^Trap_Frame) -> (resume: Resume, ok: bool) {
	if src == nil {
		return {}, false
	}
	frame, fpu, carved := carve(stack)
	if !carved {
		return {}, false
	}
	frame^ = src^
	from := ([^]u8)(syscall_frame_fpu(src))
	to := ([^]u8)(fpu)
	for i in 0 ..< FPU_AREA_SIZE {
		to[i] = from[i]
	}
	return Resume{frame = frame, fpu = fpu}, true
}

// frame_enter_user rewrites a frame in place so the return from the door
// lands in a new program. Every register but the one argument is cleared.
frame_enter_user :: proc "contextless" (frame: ^Trap_Frame, entry: uintptr, sp: uintptr, arg0: u64) {
	vector := frame.vector
	frame^ = {}
	frame.vector = vector
	frame.x[0] = arg0
	frame.sp = u64(sp)
	frame.elr = u64(entry)
	frame.spsr = SPSR_EL0
}

// syscall_frame_fpu names the vector image the tail parked with a frame,
// which sits directly below it.
syscall_frame_fpu :: proc "contextless" (frame: ^Trap_Frame) -> rawptr {
	return rawptr(uintptr(rawptr(frame)) - FPU_AREA_SIZE)
}

/*
set_kernel_stack records where a trap from a program will land.

The hardware needs no telling. A trap from EL0 takes SP_EL1, and the trap
tail leaves SP_EL1 at the top of the frame it returned through, which is the
top of that thread's kernel stack by the layout above. The record is for the
self-test that reads it back, and for the day something wants to know
without a frame in hand.
*/
set_kernel_stack :: proc "contextless" (top: uintptr) {
	this_cpu().kernel_sp = u64(top)
}

kernel_stack :: proc "contextless" () -> uintptr {
	return uintptr(this_cpu().kernel_sp)
}

// -- The other cores ------------------------------------------------------------

foreign {
	vectra_ap_switch :: proc "c" (stack_top: uintptr, entry: proc "c" (arg: rawptr) -> !, arg: rawptr) -> ! ---
}

/*
ap_switch takes an arriving core off the bootloader's stack and tables.

The tables first, from Odin, which works because the bootloader's stack is
memory the kernel's tables map too. Then the stack, in `ap.S`, because no
Odin procedure can change its own. The entry runs on the new stack and never
returns.
*/
ap_switch :: proc "contextless" (stack_top: uintptr, root: uintptr, entry: proc "c" (arg: rawptr) -> !, arg: rawptr) -> ! {
	load_address_space(root)
	vectra_ap_switch(stack_top, entry, arg)
}

// -- The vector unit, held live -----------------------------------------------

foreign {
	vectra_fpu_hold :: proc "c" (value: ^f64, flag: ^bool, out: ^f64, counter: ^u64) ---
}

// fpu_hold loads four vector registers from `value`, spins until `flag`
// while counting rounds in `counter`, and writes the sum of the four to
// `out`. `fpu_hold.S` is the loop; `docs/TESTING.md` says why it is assembly.
fpu_hold :: proc "contextless" (value: ^f64, flag: ^bool, out: ^f64, counter: ^u64) {
	vectra_fpu_hold(value, flag, out, counter)
}
