/*
Laying out a thread's first saved state, and saying what kind of core we are on.

A thread that has never run still has to look exactly like one that was
preempted, because there is only one resume path and it does not have a special
case. So creating a thread means writing, onto its own stack, the `Trap_Frame`
and FXSAVE image the entry tail would have left there -- and then the first time
it is scheduled, an `iretq` drops into `entry` as if returning from an interrupt
that never happened.
*/
package amd64

/*
The stack, from the top down.

    top                 16-byte aligned end of the region
    top-8               a return address, so an entry proc that returns
                        lands somewhere deliberate rather than in whatever
                        the allocator left behind. This is also what makes
                        the initial rsp 8 mod 16 -- the alignment a compiled
                        procedure expects on entry, because a `call` would
                        have pushed exactly this.
    ...                 FXSAVE image, aligned down to 16
    ...                 Trap_Frame
    base                everything below is the thread's to use

The frame and the image sit in stack the thread will immediately run over, and
that is fine: both are read in full by the resume sequence before the first
instruction of the thread executes.
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
returns -- there is no runtime underneath a kernel thread to catch that, so
falling off the end of one has to land on something the scheduler chose.

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
	top := align_down(base + uintptr(len(stack)), 16)

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

amd64 has one class today and arm64 will have up to three, so the vocabulary is
here rather than in the scheduler: a big.LITTLE part reports its cores honestly
and the run queues do the right thing without the scheduler learning what a
DynamIQ cluster is.

`capacity` is relative work per unit time, normalised so that the fastest class
on the machine is 1024 -- the same convention Linux's capacity-aware scheduling
uses, and the reason a time slice is scaled by it: a thread on a slower core
needs proportionally more ticks to get the same work done, and a scheduler that
handed out equal *time* would be handing out unequal *progress*.
*/
Cpu_Class :: enum {
	Efficiency,
	Performance,
	Prime,
}

CAPACITY_FULL :: 1024

/*
cpu_class reports what this core is.

Every amd64 core is `.Performance` at full capacity, including the ones that are
not. Alder Lake and later really do have two classes, and CPUID leaf 0x1A
reports which -- but acting on it needs frequency-invariant capacity numbers
that are not in CPUID, and guessing them would make the scheduler worse rather
than better on the exact machines it is meant to help. Reported honestly as one
class until there is a number worth trusting.
*/
cpu_class :: proc "contextless" () -> (class: Cpu_Class, capacity: int) {
	return .Performance, CAPACITY_FULL
}
