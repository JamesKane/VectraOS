/*
The saved frame `/proc/n/regs` answers, by name and by DWARF number.

The kernel writes its architecture's trap frame out as it is, and
`docs/PROC.md` says a debugger for that architecture knows the layout.
This file is where it knows it, once, for `servers/dbgfs` and anything
else that reads the file. The program counter and the stack pointer, a
register by the number a `.vxd` location names, and every register with a
name for a listing. The frames are `kernel/arch/<arch>/idt.odin`'s and
`traps.odin`'s, and the two must agree by hand.
*/
package libdebug

Reg :: struct {
	name:   string,
	offset: int, // In the frame
}

when ODIN_ARCH == .amd64 {
	FRAME_SIZE :: 176
	// The frame as `isr.S` pushes it: the general registers, the vector and
	// its error code, and what the CPU pushed.
	REGS := [?]Reg {
		{"r15", 0}, {"r14", 8}, {"r13", 16}, {"r12", 24}, {"r11", 32}, {"r10", 40}, {"r9", 48}, {"r8", 56},
		{"rbp", 64}, {"rdi", 72}, {"rsi", 80}, {"rdx", 88}, {"rcx", 96}, {"rbx", 104}, {"rax", 112},
		{"rip", 136}, {"rflags", 152}, {"rsp", 160},
	}
	// DWARF's numbering for this architecture: rax, rdx, rcx, rbx, rsi, rdi,
	// rbp, rsp, r8 to r15, then the return address column.
	DWARF_OFFSETS := [?]int{112, 88, 96, 104, 80, 72, 64, 160, 56, 48, 40, 32, 24, 16, 8, 0, 136}
	PC_OFFSET :: 136
	SP_OFFSET :: 160
} else when ODIN_ARCH == .arm64 {
	FRAME_SIZE :: 304
	REGS := [?]Reg {
		{"x0", 0}, {"x1", 8}, {"x2", 16}, {"x3", 24}, {"x4", 32}, {"x5", 40}, {"x6", 48}, {"x7", 56},
		{"x8", 64}, {"x9", 72}, {"x10", 80}, {"x11", 88}, {"x12", 96}, {"x13", 104}, {"x14", 112}, {"x15", 120},
		{"x16", 128}, {"x17", 136}, {"x18", 144}, {"x19", 152}, {"x20", 160}, {"x21", 168}, {"x22", 176}, {"x23", 184},
		{"x24", 192}, {"x25", 200}, {"x26", 208}, {"x27", 216}, {"x28", 224}, {"x29", 232}, {"x30", 240},
		{"sp", 248}, {"pc", 256}, {"spsr", 264},
	}
	// DWARF numbers x0 to x30 as 0 to 30 and the stack pointer as 31.
	DWARF_OFFSETS := [?]int {
		0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120,
		128, 136, 144, 152, 160, 168, 176, 184, 192, 200, 208, 216, 224, 232, 240, 248,
	}
	PC_OFFSET :: 256
	SP_OFFSET :: 248
} else {
	FRAME_SIZE :: 304
	REGS := [?]Reg {
		{"zero", 0}, {"ra", 8}, {"sp", 16}, {"gp", 24}, {"tp", 32}, {"t0", 40}, {"t1", 48}, {"t2", 56},
		{"s0", 64}, {"s1", 72}, {"a0", 80}, {"a1", 88}, {"a2", 96}, {"a3", 104}, {"a4", 112}, {"a5", 120},
		{"a6", 128}, {"a7", 136}, {"s2", 144}, {"s3", 152}, {"s4", 160}, {"s5", 168}, {"s6", 176}, {"s7", 184},
		{"s8", 192}, {"s9", 200}, {"s10", 208}, {"s11", 216}, {"t3", 224}, {"t4", 232}, {"t5", 240}, {"t6", 248},
		{"pc", 256}, {"sstatus", 264},
	}
	// DWARF numbers the integer registers x0 to x31 as 0 to 31.
	DWARF_OFFSETS := [?]int {
		0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120,
		128, 136, 144, 152, 160, 168, 176, 184, 192, 200, 208, 216, 224, 232, 240, 248,
	}
	PC_OFFSET :: 256
	SP_OFFSET :: 16
}

@(private = "file")
word_at :: proc "contextless" (f: []u8, at: int) -> u64 {
	return u64at(f, at)
}

@(private = "file")
put_word :: proc "contextless" (f: []u8, at: int, v: u64) #no_bounds_check {
	if at < 0 || at + 8 > len(f) {
		return
	}
	for i in 0 ..< 8 {
		f[at + i] = u8(v >> (8 * u64(i)))
	}
}

frame_pc :: proc "contextless" (f: []u8) -> u64 {
	return word_at(f, PC_OFFSET)
}

frame_set_pc :: proc "contextless" (f: []u8, pc: u64) {
	put_word(f, PC_OFFSET, pc)
}

frame_sp :: proc "contextless" (f: []u8) -> u64 {
	return word_at(f, SP_OFFSET)
}

// frame_reg answers a register by its DWARF number, which is what a
// `.vxd` variable row names.
frame_reg :: proc "contextless" (f: []u8, dwarf: u32) -> (v: u64, ok: bool) {
	if int(dwarf) >= len(DWARF_OFFSETS) {
		return 0, false
	}
	return word_at(f, DWARF_OFFSETS[dwarf]), true
}

// frame_named answers a register by its name, `$rip` or `$x0` in an
// expression.
frame_named :: proc "contextless" (f: []u8, name: string) -> (v: u64, ok: bool) {
	for r in REGS {
		if r.name == name {
			return word_at(f, r.offset), true
		}
	}
	return 0, false
}

reg_count :: proc "contextless" () -> int {
	return len(REGS)
}

reg_at :: proc "contextless" (f: []u8, i: int) -> (name: string, v: u64) {
	if i < 0 || i >= len(REGS) {
		return "", 0
	}
	return REGS[i].name, word_at(f, REGS[i].offset)
}

// The breakpoint a debugger writes through `/proc/n/mem`, and how far past
// it the trap leaves the counter: `kernel/arch/<arch>/frame.odin`'s
// `BREAKPOINT_CODE` and `BREAKPOINT_ADVANCE`, which a program cannot
// import. `HAS_STEP` is the kernel's too: where it is false an engine
// steps with a breakpoint on the next instruction, from the `dis` table.
//
// A breakpoint is never longer than the instruction it replaces. riscv64
// code has two-byte instructions among the four-byte ones. A four-byte
// `ebreak` over a two-byte one spills into the next, and a resume right
// after the short one then runs the spill by halves. So `break_code`
// answers `c.ebreak` for a short instruction, told by its low two bits.
// The kernel moves the counter four past either, and an engine puts it
// back at the breakpoint's own address.
BREAK_MAX :: 4

when ODIN_ARCH == .amd64 {
	BREAK_ADVANCE :: 1
	HAS_STEP :: true
	@(private = "file")
	ebreak := [?]u8{0xCC}

	break_code :: proc "contextless" (first: u8) -> []u8 {
		_ = first
		return ebreak[:]
	}
} else when ODIN_ARCH == .arm64 {
	BREAK_ADVANCE :: 0
	HAS_STEP :: false
	@(private = "file")
	ebreak := [?]u8{0x00, 0x00, 0x20, 0xD4}

	break_code :: proc "contextless" (first: u8) -> []u8 {
		_ = first
		return ebreak[:]
	}
} else {
	BREAK_ADVANCE :: 4
	HAS_STEP :: false
	@(private = "file")
	ebreak := [?]u8{0x73, 0x00, 0x10, 0x00}
	@(private = "file")
	c_ebreak := [?]u8{0x02, 0x90}

	break_code :: proc "contextless" (first: u8) -> []u8 {
		if first & 0x3 != 0x3 {
			return c_ebreak[:]
		}
		return ebreak[:]
	}
}
