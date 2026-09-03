/*
Laying out a thread's first saved state.

A thread that never ran still has to look exactly like one something
interrupted. There is only one resume path, and it has no special case. So a
new thread gets the `Trap_Frame` and the float image written onto its own
stack, exactly where the trap tail would have left them. The first time a
hart takes it, an `sret` drops into `entry`.

The frame goes at the very top of the stack, because the tail closes a
kernel frame by adding its size to the stack pointer, and what it lands on
is what the thread runs on. The float image goes directly below the frame,
where the tail puts one, so `syscall_frame_fpu` has one rule for both.
*/
package riscv64

MIN_STACK_SIZE :: 4096

// f0..f31, then fcsr, rounded to sixteen.
FPU_AREA_SIZE :: 272
FPU_AREA_ALIGN :: 16

// The status a kernel thread starts with: supervisor mode after the return,
// interrupts on after the return, the float unit on, and supervisor access
// to a program's pages, which every copy in and out needs. UXL says 64-bit
// programs, which is what the bootloader set and what a write of zero
// might not keep.
SSTATUS_KERNEL :: SSTATUS_SPP | SSTATUS_SPIE | SSTATUS_FS_INITIAL | SSTATUS_SUM | u64(2) << 32

// The status a program starts with: user mode after the return, interrupts
// on after the return, the float unit on.
SSTATUS_USER :: SSTATUS_SPIE | SSTATUS_FS_INITIAL | SSTATUS_SUM | u64(2) << 32

@(private = "file")
align_down :: proc "contextless" (value: uintptr, align: uintptr) -> uintptr {
	return value & ~(align - 1)
}

kernel_stack_top :: proc "contextless" (stack: []u8) -> uintptr {
	return align_down(uintptr(raw_data(stack)) + uintptr(len(stack)), 16)
}

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
	frame.x[REG_SP] = u64(top)
	bytes := ([^]u8)(fpu_at)
	for i in 0 ..< FPU_AREA_SIZE {
		bytes[i] = 0
	}
	return frame, rawptr(fpu_at), true
}

// thread_resume_init writes a new kernel thread's saved state onto its
// stack. `arg` arrives in `a0`, and `on_return` in `ra`.
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
	frame.x[REG_A0] = u64(uintptr(arg))
	frame.x[REG_RA] = u64(uintptr(on_return))
	frame.sepc = u64(uintptr(entry))
	frame.sstatus = SSTATUS_KERNEL
	return Resume{frame = frame, fpu = fpu}, true
}

// thread_user_init lays out a thread whose first `sret` lands in a program,
// with three arguments in `a0` to `a2` and nothing else.
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
	frame.x[REG_A0] = arg0
	frame.x[REG_A0 + 1] = arg1
	frame.x[REG_A0 + 2] = arg2
	frame.x[REG_SP] = u64(sp)
	frame.sepc = u64(entry)
	frame.sstatus = SSTATUS_USER
	return Resume{frame = frame, fpu = fpu}, true
}

thread_user_clone :: proc "contextless" (stack: []u8, src: ^Trap_Frame) -> (resume: Resume, ok: bool) {
	if src == nil {
		return {}, false
	}
	frame, fpu, carved := carve(stack)
	if !carved {
		return {}, false
	}
	// The copy, with zero in the answer register: that is how the child
	// learns which of the two it is.
	frame^ = src^
	frame.x[REG_A0] = 0
	from := ([^]u8)(syscall_frame_fpu(src))
	to := ([^]u8)(fpu)
	for i in 0 ..< FPU_AREA_SIZE {
		to[i] = from[i]
	}
	return Resume{frame = frame, fpu = fpu}, true
}

frame_enter_user :: proc "contextless" (frame: ^Trap_Frame, entry: uintptr, sp: uintptr, arg0: u64) {
	vector := frame.vector
	frame^ = {}
	frame.vector = vector
	frame.x[REG_A0] = arg0
	frame.x[REG_SP] = u64(sp)
	frame.sepc = u64(entry)
	frame.sstatus = SSTATUS_USER
}

syscall_frame_fpu :: proc "contextless" (frame: ^Trap_Frame) -> rawptr {
	return rawptr(uintptr(rawptr(frame)) - FPU_AREA_SIZE)
}

/*
set_kernel_stack tells the trap entry where a trap from a program lands.

The entry reads `kernel_sp` out of the per-CPU record, because a trap on
this architecture switches no stack of its own. A stale value is a frame
written onto whatever the last thread's stack was, so the scheduler writes
this on every switch, before the incoming thread can reach user mode.
*/
set_kernel_stack :: proc "contextless" (top: uintptr) {
	this_cpu().kernel_sp = u64(top)
}

kernel_stack :: proc "contextless" () -> uintptr {
	return uintptr(this_cpu().kernel_sp)
}

// -- The other harts -----------------------------------------------------------

foreign {
	vectra_ap_switch :: proc "c" (stack_top: uintptr, entry: proc "c" (arg: rawptr) -> !, arg: rawptr) -> ! ---
	vectra_fpu_hold :: proc "c" (value: ^f64, flag: ^bool, out: ^f64, counter: ^u64) ---
}

ap_switch :: proc "contextless" (stack_top: uintptr, root: uintptr, entry: proc "c" (arg: rawptr) -> !, arg: rawptr) -> ! {
	load_address_space(root)
	vectra_ap_switch(stack_top, entry, arg)
}

fpu_hold :: proc "contextless" (value: ^f64, flag: ^bool, out: ^f64, counter: ^u64) {
	vectra_fpu_hold(value, flag, out, counter)
}
