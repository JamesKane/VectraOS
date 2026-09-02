/*
SYSCALL and SYSRET: the door a program knocks on.

An interrupt is the expensive way into the kernel. The CPU consults the IDT,
reads a descriptor, switches stacks out of the TSS and pushes five words. That
is what a fault needs, because a fault can arrive anywhere. A program asking
for something is not that, and `syscall` is the instruction that says so.

**`syscall` changes almost nothing.** It puts RIP in RCX and RFLAGS in R11,
loads CS and SS from `STAR`, masks the flags in `SFMASK`, and jumps to `LSTAR`.
It does not switch stacks. It does not push. RSP still points wherever the
program left it, so the first instruction of the stub has to find a kernel
stack with nothing to trust.

`%gs:8` is what it finds one with. See `percpu.odin`.

## The four registers that configure it

    EFER.SCE   the instruction faults as undefined without this bit
    STAR       the selectors, and the layout `gdt.odin` was built around
    LSTAR      where the entry stub is
    SFMASK     the RFLAGS bits the CPU clears on the way in

`STAR` is the one that cannot be fixed later. Bits 47:32 are the kernel pair,
and SS comes from that plus 8. Bits 63:48 are the user base, and a 64-bit
`sysretq` takes CS from that plus 16 and SS from that plus 8. That is why the
GDT reads [code32, data, code64] on the user side, with a 32-bit descriptor
nothing will ever load.

`SFMASK` clears IF, and that is not a detail. The stub runs its first four
instructions on a stack a program chose. An interrupt there would push a frame
onto it, in ring 0.

## What the stub builds, and why it is a Trap_Frame

The same struct the interrupt stubs build, filled from the registers `syscall`
left behind. It costs fifteen pushes and it buys three things.

Every register survives, because the frame holds every register. A syscall can
therefore promise a program that it clobbers only RAX, RCX and R11, and keep
the promise by construction rather than by counting.

A syscall can block. The dispatcher is ordinary Odin on the thread's own kernel
stack. A lock that parks parks, and the yield builds its own frame below this
one. When the scheduler comes back, the pops below run and the program resumes.
Nothing about that is special-cased, which is the point.

And a fault inside a syscall reports like every other fault, because the state
it reports is in the shape the reporting code already reads.
*/
package amd64

/*
The vector a syscall frame carries, which is deliberately not a vector.

256 is one past the last IDT entry, so nothing can dispatch on it and nothing
can collide with it. A frame that reports this number came through the door
rather than through the table.
*/
VECTOR_SYSCALL :: 0x100

MSR_STAR :: u32(0xC000_0081)
MSR_LSTAR :: u32(0xC000_0082)
MSR_SFMASK :: u32(0xC000_0084)

/*
The RFLAGS bits the CPU clears on entry.

IF, because the stub's first instructions run on the program's stack. TF and RF,
so a program cannot single-step the kernel. DF, because the System V ABI
requires the direction flag clear and a program is under no obligation to
oblige. NT and IOPL, because neither means anything good in a kernel that
inherited them from ring 3.
*/
SFMASK_BITS :: u64(0x4_7700)

foreign {
	vectra_syscall_entry: byte
}

// syscall_available asks CPUID whether the instruction exists. Every amd64
// part has it, and the check costs one leaf. A kernel that armed a missing
// instruction faults as undefined on the first call. The panic screen then
// names a program's address, with no hint about the cause.
syscall_available :: proc "contextless" () -> bool {
	return has_feature(CPUID_EXT_FEATURES, .EDX, 11)
}

/*
syscall_init arms the instruction and points it at the stub.

`STAR` before `EFER.SCE`, so the instruction is never enabled with selectors
that are not yet written. The order costs nothing and removes a window that
would be one instruction wide and impossible to reproduce.

Returns false when the CPU does not have the instruction. That is not fatal to
a kernel, only to programs, and the caller has to say which.
*/
syscall_init :: proc "contextless" () -> bool {
	if !syscall_available() {
		return false
	}

	write_msr(MSR_STAR, (u64(USER_CODE32_SEL) << 48) | (u64(KERNEL_CODE_SEL) << 32))
	write_msr(MSR_LSTAR, u64(uintptr(&vectra_syscall_entry)))
	write_msr(MSR_SFMASK, SFMASK_BITS)
	write_efer(read_efer() | EFER_SCE)
	return true
}

syscall_armed :: proc "contextless" () -> bool {
	return read_efer() & EFER_SCE != 0 && read_msr(MSR_LSTAR) == u64(uintptr(&vectra_syscall_entry))
}

/*
syscall_masks_interrupts reports whether `SFMASK` clears `IF` on entry.

The stub's first four instructions run on the program's stack, before it
swaps in a kernel one. An interrupt there would push onto that stack and run with
the program's `GS`. That is the four-instruction window `docs/TESTING.md`
records as uncaught.

An interrupt almost never lands in it, so a control that left `IF` out of
`SFMASK` failed nothing. This makes the mask a check. `IF` is
bit nine, and it must be one of the bits the CPU clears.
*/
syscall_masks_interrupts :: proc "contextless" () -> bool {
	return read_msr(MSR_SFMASK) & (u64(1) << 9) != 0
}

// syscall_entry_address is where `LSTAR` should point, so a self-test can
// compare the MSR against the symbol rather than against itself.
syscall_entry_address :: proc "contextless" () -> uintptr {
	return uintptr(&vectra_syscall_entry)
}

/*
The entry stub, in `syscall_entry.S`.

Assembly in a file rather than a template. It defines the global symbol
`syscall_init` hands to `LSTAR`, and the CPU enters it rather than calls
it. `syscall` arrives with the program's RSP still live, and nothing may run
before the first instruction. A file of assembly guarantees that, and a
template inside a procedure cannot.

The sequence, and the two places it looks arbitrary and is not:

  1. `swapgs`, then the program's RSP into this core's record, then this
     thread's kernel stack out of it. Three instructions, no register spare,
     which is what `percpu.odin` exists for.
  2. Seven pushes build the half of `Trap_Frame` an interrupt would have
     pushed. They take it from what `syscall` left in RCX and R11, and from the
     two selectors `STAR` fixes. Fifteen more pushes build the rest.
  3. 512 bytes for the FXSAVE image, with no realignment. `Trap_Frame` is 176
     bytes, the seven words above it are 56, and a kernel stack top is aligned
     to 16. So RSP is already aligned here, and the `#assert` on the frame size
     is what keeps that true.
  4. `sti` around the call only. The dispatcher is ordinary thread context and
     a long syscall has to be preemptible. `cli` before the exit sequence,
     because the last instruction before `sysretq` puts a program's stack
     pointer in RSP while still in ring 0.

`sysretq` needs RIP back in RCX and RFLAGS back in R11. That is why those two
are read out of the frame after the pops, rather than left as the pops found
them. It also faults in ring 0 if RCX is not canonical. Nothing here writes
`frame.rip`, and anything that ever does has to check.
*/

/*
syscall_frame_fpu names the FXSAVE image the stub above parked with a frame.

The `subq $$512` before `fxsave` is the only thing that knows the image sits
directly below the frame, and it is four lines up. A caller that wrote the
`-512` itself would be copying stub layout into another package, where the
next change to the stub cannot find it. `thread_user_clone` is the caller,
the day a fork copies a running thread's state.
*/
syscall_frame_fpu :: proc "contextless" (frame: ^Trap_Frame) -> rawptr {
	return rawptr(uintptr(rawptr(frame)) - FPU_AREA_SIZE)
}
