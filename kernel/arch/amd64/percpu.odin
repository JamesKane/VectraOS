/*
Per-CPU state, and the segment base that finds it.

Long mode has almost no segmentation left, and what survives is two base
addresses that no descriptor supplies. `FS` and `GS` take theirs from MSRs.
That is the whole mechanism a 64-bit kernel has for `where is this core's
state`. It is also why `gdt_init` loads a null selector into both rather than a
data selector. On Intel a non-null selector clears the base MSR under you.

Vectra needs it now for one reason. `syscall` changes the privilege level and
changes nothing else. It does not switch stacks, it does not push a frame, and
it leaves RSP pointing at whatever the program chose. So the entry stub has to
find a kernel stack with no register to trust and no memory to name.

`%gs:8` names one. That is the whole argument for this file.

## Which base is live, and when

    in ring 0     GS_BASE = this core's record, KERNEL_GS_BASE = the program's
    in ring 3     GS_BASE = the program's,      KERNEL_GS_BASE = this core's

`swapgs` exchanges the two, and every crossing does exactly one. The syscall
stub does one on entry and one before `sysretq`. The interrupt tail in
`idt.odin` does one on entry and one before `iretq`. It does neither unless the
frame in front of it names ring 3.

**A crossing that swaps twice is the hazard, and there is one.** An NMI can
arrive between the syscall stub's `swapgs` and its next instruction. It finds a
frame that says ring 3, so the tail swaps again and the kernel runs with the
program's base. Nothing in Vectra reads `GS` inside a handler, so the two swaps
cancel on the way out and nothing is damaged. This stops being true the day a
handler wants per-CPU state. The answer then is what Linux calls a paranoid
entry: read the base rather than infer it from the frame.
*/
package amd64

MSR_FS_BASE :: u32(0xC000_0100)
MSR_GS_BASE :: u32(0xC000_0101)
MSR_KERNEL_GS_BASE :: u32(0xC000_0102)

/*
What one core keeps behind `GS`.

Small on purpose. This is reached from assembly, by a numeric offset, at a
moment when nothing else is reachable. Every field earns its place by being
needed before the kernel has a stack.

`self` is at offset zero and holds this record's own address. It costs eight
bytes and it makes `%gs:0` a readback. That is the only way a self-test can say
the base took, rather than infer it from the absence of a crash.

`kernel_rsp` is the same number the TSS holds, and `set_kernel_stack` writes
both. The TSS is what an *interrupt* from ring 3 uses. This is what `syscall`
uses, because `syscall` does not consult the TSS at all.

`user_rsp` is scratch, and it is scratch that has to live somewhere other than
a register. The stub has none to spare between `swapgs` and the stack switch.
*/
Percpu :: struct {
	self:       u64,
	kernel_rsp: u64,
	user_rsp:   u64,
	cpu_id:     u64,
}

/*
The offsets the entry stub uses, written here and again as immediates in the
assembly.

The same problem `vector_has_error_code` has, and the same answer. The
assembler consumes one at build time and Odin consumes the other at run time,
so they cannot share a definition. What they can share is a file and an
`#assert`. The assert makes a disagreement a build error rather than a wild
store.
*/
PERCPU_SELF :: 0
PERCPU_KERNEL_RSP :: 8
PERCPU_USER_RSP :: 16

#assert(offset_of(Percpu, self) == PERCPU_SELF)
#assert(offset_of(Percpu, kernel_rsp) == PERCPU_KERNEL_RSP)
#assert(offset_of(Percpu, user_rsp) == PERCPU_USER_RSP)

// One record per core, statically. Cores are counted in `kernel/sched`, and
// this table only has to be at least as large. It is static because the first
// thing that reads it runs before `kernel/mem` exists.
PERCPU_MAX :: 8

@(private = "file")
percpu: [PERCPU_MAX]Percpu

/*
percpu_init points this core's `GS` at its own record.

Both MSRs, and in the state ring 0 wants: `GS_BASE` is the record, and
`KERNEL_GS_BASE` is what a program will get. A program has no base of its own
yet, so it gets zero.

Safe before `kernel/mem`, and called from `init_traps` for that reason. The
storage is static and the write is two MSRs.
*/
percpu_init :: proc "contextless" (id: int) #no_bounds_check {
	if id < 0 || id >= PERCPU_MAX {
		return
	}
	p := &percpu[id]
	p.self = u64(uintptr(p))
	p.cpu_id = u64(id)
	write_msr(MSR_GS_BASE, p.self)
	write_msr(MSR_KERNEL_GS_BASE, 0)
}

// this_cpu returns the record `GS` currently points at, by reading offset zero
// through the segment rather than by indexing the table. That is the readback
// the self-test wants: it answers with what the CPU thinks, not with what this
// file remembers.
this_cpu :: proc "contextless" () -> ^Percpu {
	base := asm() -> u64 {"movq %gs:0, $0", "=r"}()
	return (^Percpu)(uintptr(base))
}

// percpu_kernel_stack and percpu_id read this core's record back through the
// segment. For a self-test that wants to say the base is live, and that it
// points at the right thing.
percpu_kernel_stack :: proc "contextless" () -> uintptr {
	return uintptr(this_cpu().kernel_rsp)
}

percpu_id :: proc "contextless" () -> int {
	return int(this_cpu().cpu_id)
}
