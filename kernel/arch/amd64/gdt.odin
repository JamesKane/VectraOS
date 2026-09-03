/*
The global descriptor table and the task state segment.

Long mode barely uses segmentation. Base and limit are ignored for code and
data. The descriptors exist mostly to carry a privilege level, and the `this is
64-bit code` bit. So this table is small, and almost all of its content is
there for two things that still matter:

  - The TSS, which is how the CPU finds a stack to fault onto. Without one,
    a fault that happens *because* the stack is bad has nowhere to push its
    frame. The result is a triple fault with nothing to show for it. The
    interrupt stack table below is the whole reason this file exists before
    userland does.
  - The selector layout, which SYSCALL/SYSRET will read out of the STAR MSR and
    cannot be renumbered later without breaking it.

Limine leaves us a GDT of its own in bootloader-reclaimable memory. It works,
but it has no TSS, and it is memory worth reclaiming. So the first thing the
kernel does with traps is stop depending on it.
*/
package amd64

/*
Selector layout, fixed by what SYSCALL and SYSRET expect.

`SYSCALL` loads CS from `STAR[47:32]` and SS from that plus 8, so the kernel
pair has to be adjacent in that order. `SYSRET` to 64-bit code loads CS from
`STAR[63:48]` plus 16, and SS from plus 8. The user side therefore has to read
[code32, data, code64]. code32 is present even though nothing will ever load
it. An error here is not a link error, and not a fault at boot. It is the first
system call returning to the wrong privilege level, years from now.

The TSS descriptor is sixteen bytes and therefore occupies two slots.
*/
NULL_SEL :: u16(0x00)
KERNEL_CODE_SEL :: u16(0x08)
KERNEL_DATA_SEL :: u16(0x10)
USER_CODE32_SEL :: u16(0x18) // Placeholder: never loaded, required by SYSRET
USER_DATA_SEL :: u16(0x20)
USER_CODE_SEL :: u16(0x28)
TSS_SEL :: u16(0x30) // And 0x38, which is its upper half

/*
The privilege level in the low two bits of a selector.

A descriptor carries the privilege a segment *may* be used at. A selector
carries the privilege it is being used *at*, and the CPU takes the weaker of
the two. A user segment loaded with RPL 0 therefore still runs at ring 3,
because the descriptor says DPL 3. A kernel segment loaded with RPL 3 does not
become a kernel segment.

`iretq` reads the RPL out of the CS it pops, to decide whether the return is a
privilege change. A user frame with RPL 0 in CS returns to ring 0 code that
lives in a ring 3 descriptor. That is neither an error nor userland.
*/
RING_KERNEL :: u16(0)
RING_USER :: u16(3)

USER_CODE_RING3 :: USER_CODE_SEL | RING_USER
USER_DATA_RING3 :: USER_DATA_SEL | RING_USER

GDT_SLOTS :: 8

// -- Descriptor encoding -----------------------------------------------------
//
// Access byte:  P | DPL(2) | S | E | DC | RW | A
// Flags nibble: G | D/B | L | AVL

ACCESS_PRESENT :: u8(1) << 7
ACCESS_USER :: u8(3) << 5 // DPL 3
ACCESS_SEGMENT :: u8(1) << 4 // Code or data, as opposed to a system descriptor
ACCESS_EXECUTE :: u8(1) << 3
ACCESS_RW :: u8(1) << 1

ACCESS_TSS_AVAILABLE :: u8(0x9) // System descriptor type: 64-bit TSS, not busy

FLAG_GRANULARITY :: u8(1) << 3
FLAG_DB :: u8(1) << 2 // 32-bit operand size; must be 0 alongside FLAG_LONG
FLAG_LONG :: u8(1) << 1

Descriptor_Pointer :: struct #packed {
	limit: u16,
	base:  u64,
}

/*
The 64-bit task state segment.

Nothing in here is a task in the 32-bit sense -- hardware task switching is gone
in long mode. What survives is two stack tables. `rsp` holds the stack the CPU
switches to when an interrupt raises the privilege level, which matters only
once there is userland. `ist` holds seven stacks an interrupt gate can name
unconditionally, which matters now.

`iomap_base` is set past the end of the segment, which is how you say "no I/O
permission bitmap". Leaving it zero means the CPU reads the bitmap out of the
bytes that follow, which are whatever happens to be there.
*/
TSS :: struct #packed {
	reserved0:  u32,
	rsp:        [3]u64, // rsp0..rsp2, by target privilege level
	reserved1:  u64,
	ist:        [7]u64, // ist1..ist7; index 0 in an IDT entry means "none"
	reserved2:  u64,
	reserved3:  u16,
	iomap_base: u16,
}

#assert(size_of(TSS) == 104)

/*
Dedicated fault stacks.

Static, in `.bss`, and deliberately not from the page allocator. Traps go in
before `kernel/mem` exists, precisely so a fault *during* memory bring-up has
somewhere to land. 16 KiB each is generous for a handler that formats a few
lines and halts. The generosity is the point. The stack a double fault lands on
is the last one the machine has.

IST1 takes the double fault, which is the one that cannot be allowed to fault
again. IST2 takes NMI, which can arrive on any stack at any time including
inside another handler. IST3 takes the machine check, for the same reason.
*/
FAULT_STACK_SIZE :: 16 * 1024

IST_DOUBLE_FAULT :: 1
IST_NMI :: 2
IST_MACHINE_CHECK :: 3

// One of everything per core. A TSS names the stacks a core switches to, so
// two cores sharing one would land their faults on the same stack. The GDT
// holds the TSS descriptor, which `ltr` marks busy, so two cores cannot share
// that either. Indexed by the core id `percpu_init` records, and static
// because the first core loads its own before there is an allocator.
@(private = "file") double_fault_stack: [PERCPU_MAX][FAULT_STACK_SIZE]u8
@(private = "file") nmi_stack: [PERCPU_MAX][FAULT_STACK_SIZE]u8
@(private = "file") machine_check_stack: [PERCPU_MAX][FAULT_STACK_SIZE]u8

@(private = "file") gdt: [PERCPU_MAX][GDT_SLOTS]u64
@(private = "file") tss: [PERCPU_MAX]TSS
@(private = "file") gdtr: [PERCPU_MAX]Descriptor_Pointer

/*
stack_top returns a 16-byte-aligned top-of-stack for a static array.

Aligned downward from the end, so the alignment comes out of the unused space
above the stack pointer, rather than out of the stack itself. The CPU requires
the value in an IST slot to be 16-byte aligned. It does not reject a misaligned
one. It just makes every frame pushed onto it misaligned too, and the first SSE
instruction in the handler faults.
*/
@(private = "file")
stack_top :: proc "contextless" (stack: []u8) -> u64 {
	end := u64(uintptr(raw_data(stack))) + u64(len(stack))
	return end &~ u64(15)
}

@(private = "file")
segment_descriptor :: proc "contextless" (access, flags: u8) -> u64 {
	// Base 0, limit 4 GiB. Long mode ignores both for code and data segments.
	// They go in in the classic flat form anyway, so a descriptor dumped in a
	// debugger reads the way the manuals draw it.
	limit := u64(0xF_FFFF)
	return(
		(limit & 0xFFFF) |
		(u64(access) << 40) |
		(((limit >> 16) & 0xF) << 48) |
		(u64(flags) << 52) \
	)
}

/*
gdt_init builds the table, loads it, and reloads every selector from it.

The reload is not optional. `lgdt` only changes where the CPU looks up
descriptors. The segment registers still hold Limine's selectors, whose indices
may not even exist in this table. CS in particular cannot be assigned. Only a
control transfer changes it, which is why the loader below returns through a
far pointer it pushes itself.
*/
gdt_init :: proc "contextless" (id: int) #no_bounds_check {
	if id < 0 || id >= PERCPU_MAX {
		return
	}
	gdt := &gdt[id]
	tss := &tss[id]
	gdtr := &gdtr[id]

	gdt[0] = 0
	gdt[1] = segment_descriptor(
		ACCESS_PRESENT | ACCESS_SEGMENT | ACCESS_EXECUTE | ACCESS_RW,
		FLAG_GRANULARITY | FLAG_LONG,
	)
	gdt[2] = segment_descriptor(
		ACCESS_PRESENT | ACCESS_SEGMENT | ACCESS_RW,
		FLAG_GRANULARITY | FLAG_DB,
	)
	gdt[3] = segment_descriptor(
		ACCESS_PRESENT | ACCESS_USER | ACCESS_SEGMENT | ACCESS_EXECUTE | ACCESS_RW,
		FLAG_GRANULARITY | FLAG_DB,
	)
	gdt[4] = segment_descriptor(
		ACCESS_PRESENT | ACCESS_USER | ACCESS_SEGMENT | ACCESS_RW,
		FLAG_GRANULARITY | FLAG_DB,
	)
	gdt[5] = segment_descriptor(
		ACCESS_PRESENT | ACCESS_USER | ACCESS_SEGMENT | ACCESS_EXECUTE | ACCESS_RW,
		FLAG_GRANULARITY | FLAG_LONG,
	)

	tss^ = TSS {
		iomap_base = size_of(TSS), // Past the end: no I/O permission bitmap
	}
	tss.ist[IST_DOUBLE_FAULT - 1] = stack_top(double_fault_stack[id][:])
	tss.ist[IST_NMI - 1] = stack_top(nmi_stack[id][:])
	tss.ist[IST_MACHINE_CHECK - 1] = stack_top(machine_check_stack[id][:])

	install_tss_descriptor(&gdt[6], tss)

	gdtr^ = Descriptor_Pointer {
		limit = u16(size_of(gdt^) - 1),
		base  = u64(uintptr(&gdt[0])),
	}
	load_gdt(gdtr)
	load_tr(TSS_SEL)
}

/*
install_tss_descriptor writes the sixteen-byte system descriptor for a TSS.

Unlike a code or data descriptor, this one's base and limit are real. The CPU
reads the TSS through them. A wrong base is therefore a fault at the first
interrupt that needs an IST stack, rather than at load time.
*/
@(private = "file")
install_tss_descriptor :: proc "contextless" (slot: ^u64, entry: ^TSS) {
	base := u64(uintptr(entry))
	limit := u64(size_of(TSS) - 1)

	low :=
		(limit & 0xFFFF) |
		((base & 0xFF_FFFF) << 16) |
		(u64(ACCESS_PRESENT | ACCESS_TSS_AVAILABLE) << 40) |
		(((limit >> 16) & 0xF) << 48) |
		(((base >> 24) & 0xFF) << 56)

	slot^ = low
	// The upper half is the top 32 bits of the base and nothing else. The
	// selector arithmetic treats it as a separate GDT slot. That is why a gap
	// follows TSS_SEL, rather than another segment.
	(cast([^]u64)slot)[1] = base >> 32
}

/*
load_gdt installs the table and reloads CS, then the data selectors.

To reload CS, push a selector and a return address, then execute a far return
into the next instruction. That is the only way to load CS outside a call gate
or an interrupt return. Everything after the `lretq` is running under the new
code descriptor.

FS and GS are set to the null selector rather than to kernel data. Their bases
come from MSRs in long mode, and per-CPU state will live behind GS. On Intel, a
non-null selector loaded into either one *clears* the corresponding base MSR.
Null keeps that from being a surprise the day GS starts meaning something.
*/
/*
load_gdt is `vectra_load_gdt` in `gdt.S`: `lgdt`, a far return that reloads
CS, and the data selectors after it.

Assembly in a file rather than a template. The far return needs the
address of its own landing label, and a template's labels are jump targets
only. It takes the pointer, the code selector and the data selector in the
System V argument registers. That is the one calling convention this kernel
and clang agree on.
*/
foreign {
	vectra_load_gdt :: proc "c" (pointer: ^Descriptor_Pointer, code: u64, data: u64) ---
}

@(private = "file")
load_gdt :: proc "contextless" (pointer: ^Descriptor_Pointer) {
	vectra_load_gdt(pointer, u64(KERNEL_CODE_SEL), u64(KERNEL_DATA_SEL))
}

// load_tr points the CPU at our TSS. Marks the descriptor busy as a side
// effect, which is why gdt_init must not be run twice against the same table.
@(private = "file")
load_tr :: proc "contextless" (selector: u16) {
	asm(s: u16) [#volatile, #clobber memory] { ltr s }(selector)
}

// read_cs and read_tr exist so the boot self-test can confirm the reload took,
// rather than assuming it because nothing crashed.
read_cs :: proc "contextless" () -> u16 {
	return asm() -> (r: u16) [#volatile] { mov r, %cs }()
}

read_tr :: proc "contextless" () -> u16 {
	return asm() -> (r: u16) [#volatile] { str r }()
}

/*
set_kernel_stack tells the CPU where to push an interrupt frame that arrives
from ring 3.

`rsp0` is read at exactly one moment: an interrupt or an exception that raises
the privilege level. The CPU loads it into RSP before it pushes anything. The
frame therefore lands on a stack the kernel trusts, rather than on one a
program chose. Nothing else in long mode reads the TSS.

**A stale value here is not a fault. It is a triple fault**, because the push
that reports the problem is the push that has nowhere to go. So the scheduler
writes this on every switch, from the incoming thread's own kernel stack, and
does it before that thread can reach ring 3.

The value is the *top* of that stack. A thread in ring 3 has nothing on its
kernel stack, so the whole of it is available to the frame.

**Two places hold the same number, and both are written here.** The TSS is what
an interrupt from ring 3 uses. `Percpu.kernel_rsp` is what `syscall` uses,
because `syscall` does not consult the TSS at all. One writer, so they cannot
drift.
*/
set_kernel_stack :: proc "contextless" (top: uintptr) #no_bounds_check {
	me := this_cpu()
	tss[me.cpu_id].rsp[0] = u64(top)
	me.kernel_rsp = u64(top)
}

// kernel_stack reads the slot back, so a self-test can say the scheduler wrote
// it rather than assume it from the absence of a triple fault.
kernel_stack :: proc "contextless" () -> uintptr #no_bounds_check {
	return uintptr(tss[this_cpu().cpu_id].rsp[0])
}
