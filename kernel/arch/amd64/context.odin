/*
Laying out a thread's first saved state, and saying what kind of core we are on.

A thread that never ran still has to look exactly like one something preempted.
There is only one resume path, and it has no special case. So a new thread gets
the `Trap_Frame` and FXSAVE image written onto its own stack, exactly where the
entry tail would have left them.

The first time a core takes it, an `iretq` drops into `entry`, as though it
returned from an interrupt that never happened.
*/
package amd64

/*
The stack, from the top down.

    top                 16-byte aligned end of the region
    top-8               a return address, so an entry proc that returns
                        lands somewhere deliberate rather than in whatever the
                        allocator left behind. This is also what makes the
                        initial rsp 8 mod 16. That is the alignment a compiled
                        procedure expects on entry, because a `call` would have
                        pushed exactly this.
    ...                 FXSAVE image, aligned down to 16
    ...                 Trap_Frame
    base                everything below is the thread's to use

The frame and the image sit in stack the thread will immediately run over, and
that is fine. The resume sequence reads both in full before the thread's first
instruction executes.
*/
MIN_STACK_SIZE :: 4096

@(private = "file")
align_down :: proc "contextless" (value: uintptr, align: uintptr) -> uintptr {
	return value & ~(align - 1)
}

/*
thread_resume_init writes a new thread's saved state onto its own stack.

`arg` arrives in the first argument register, so an entry procedure is an
ordinary `proc "sysv" (arg: rawptr)`. `on_return` is where it goes if it
returns. There is no runtime underneath a kernel thread to catch that. A fall
off the end of one has to land on something the scheduler chose.

RFLAGS starts at 0x202: bit 1 is reserved and reads as set, bit 9 is IF. A
thread whose first frame had interrupts clear would run its whole first slice
unpreemptable, and on a thread that never yields, forever.
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
	if len(stack) < MIN_STACK_SIZE || entry == nil {
		return {}, false
	}

	base := uintptr(raw_data(stack))
	top := kernel_stack_top(stack)

	sp := top - 8
	(^uintptr)(sp)^ = uintptr(on_return)

	fpu := align_down(sp - FPU_AREA_RESERVE, FPU_AREA_ALIGN)
	frame_at := align_down(fpu - size_of(Trap_Frame), 16)
	if frame_at <= base {
		return {}, false
	}

	fpu_init(rawptr(fpu))

	frame := (^Trap_Frame)(frame_at)
	frame^ = Trap_Frame {
		rdi    = u64(uintptr(arg)),
		rip    = u64(uintptr(entry)),
		cs     = u64(KERNEL_CODE_SEL),
		rflags = 0x202,
		rsp    = u64(sp),
		ss     = u64(KERNEL_DATA_SEL),
	}

	return Resume{frame = frame, fpu = rawptr(fpu)}, true
}

// -- What kind of core this is -----------------------------------------------

/*
Vectra schedules against a core's *class*, not its number.

amd64 has one class today, and arm64 will have up to three. The vocabulary is
therefore here rather than in the scheduler.

A big.LITTLE part reports its cores honestly, and the run queues do the right
thing. The scheduler never learns what a DynamIQ cluster is.

`capacity` is relative work per unit time, normalised so the fastest class on
the machine is 1024. Linux's capacity-aware scheduler uses the same convention.

It is also why a time slice scales by it. A thread on a slower core needs
proportionally more ticks for the same work. A scheduler that gave out equal
*time* would give out unequal *progress*.
*/
Cpu_Class :: enum {
	Efficiency,
	Performance,
	Prime,
}

CAPACITY_FULL :: 1024

/*
cpu_class reports what this core is.

Every amd64 core is `.Performance` at full capacity, including the ones that
are not. Alder Lake and later really do have two classes, and CPUID leaf 0x1A
reports which.

But a scheduler that acts on it needs frequency-invariant capacity numbers, and
CPUID does not carry those. A guess would make the scheduler worse rather than
better, on the exact machines it is meant to help. Reported honestly as one
class until there is a number worth trusting.
*/
cpu_class :: proc "contextless" () -> (class: Cpu_Class, capacity: int) {
	return .Performance, CAPACITY_FULL
}

/*
kernel_stack_top is the address the CPU pushes an interrupt frame below.

One definition, because two things need the same number. A disagreement between
them is silent. `thread_resume_init` lays the first frame out from it. The
scheduler puts it in the TSS, so a trap from ring 3 lands on the same stack.

Aligned down to 16, so the alignment comes out of the space above the stack
rather than out of the stack.
*/
kernel_stack_top :: proc "contextless" (stack: []u8) -> uintptr {
	return align_down(uintptr(raw_data(stack)) + uintptr(len(stack)), 16)
}

/*
thread_user_init lays out a thread whose first instruction is in ring 3.

The same shape as `thread_resume_init` above, and deliberately the same shape.
A thread that never ran looks like one something preempted. A thread that never
ran *in a program* looks like one something preempted **in a program**.

There is still one resume path. The first `iretq` a user thread takes is the
trap tail's. That is the same instruction every other thread returns through,
and the only difference is the selectors in the frame it reads.

`entry` and `user_sp` are addresses in the space the thread will translate
through, not in the kernel's. Nothing here dereferences either. The first thing
that does is the CPU, after the privilege level has already changed.

`stack` is still the *kernel* stack, and it is still where the frame is
written. That is not a spare copy of a program's stack. It is where the next
trap from ring 3 builds its frame. That is why `kernel_stack_top` and the TSS
have to agree about where it ends.

    cs = USER_CODE_SEL | 3     the RPL is what makes the `iretq` a privilege
    ss = USER_DATA_SEL | 3     change rather than a jump

RFLAGS is 0x202 for the same reason a kernel thread's is. A program entered
with IF clear cannot be preempted, and on a program that does not fault, the
machine never comes back.
*/
thread_user_init :: proc "contextless" (
	stack: []u8,
	entry: uintptr,
	user_sp: uintptr,
	arg0: u64,
	arg1: u64,
	arg2: u64,
) -> (
	resume: Resume,
	ok: bool,
) {
	if len(stack) < MIN_STACK_SIZE || entry == 0 || user_sp == 0 {
		return {}, false
	}

	base := uintptr(raw_data(stack))
	top := kernel_stack_top(stack)

	fpu := align_down(top - FPU_AREA_RESERVE, FPU_AREA_ALIGN)
	frame_at := align_down(fpu - size_of(Trap_Frame), 16)
	if frame_at <= base {
		return {}, false
	}

	fpu_init(rawptr(fpu))

	frame := (^Trap_Frame)(frame_at)
	frame^ = Trap_Frame {
		rdi    = arg0,
		rsi    = arg1,
		rdx    = arg2,
		rip    = u64(entry),
		cs     = u64(USER_CODE_RING3),
		rflags = 0x202,
		rsp    = u64(user_sp),
		ss     = u64(USER_DATA_RING3),
	}

	return Resume{frame = frame, fpu = rawptr(fpu)}, true
}
