// The ones that ask the kernel for something rather than have it refuse
// them.
package programs

import "base:intrinsics"
import "vsys:libuser"

// hello writes the line the self-test staged at slot A and exits with a
// status it chose.
hello :: proc "contextless" (cells: ^Cells, length: u64) -> ! {
	cells[0] = 0x48454C4C48454C4C
	put(cells, 1, libuser.write(1, slot(cells, 128, length)))
	libuser.exit(0x2A)
}

/*
probe makes one of every kind of call the door has to get right.

A call that does nothing, one that takes six arguments and adds them, one
whose number means nothing, a write of eight bytes from an address the
self-test chose, and a sleep of four ticks that answers with the four. Then three
values held across a call -- the assembly version pinned them in registers,
and the compiler is free to do the same -- and a loop the tick has to
interrupt without disturbing.
*/
probe :: proc "contextless" (cells: ^Cells, text_at: u64) -> ! {
	cells[0] = 0x50524F4250524F42
	put(cells, 1, libuser.nop())
	put(cells, 2, libuser.sum_args(1, 2, 4, 8, 16, 32))
	put(cells, 3, libuser.unknown())
	put(cells, 4, libuser.write(1, ([^]u8)(uintptr(text_at))[:8]))
	put(cells, 5, libuser.sleep(4))

	a := u64(0x1234)
	b := u64(0x5678)
	f := transmute(f64)u64(0x9ABC)
	_ = libuser.nop()
	cells[6] = intrinsics.volatile_load(&a)
	cells[7] = intrinsics.volatile_load(&b)
	cells[8] = transmute(u64)intrinsics.volatile_load(&f)

	count := u64(0)
	for _ in 0 ..< 20_000_000 {
		count += 1
	}
	cells[9] = intrinsics.volatile_load(&count)
	libuser.exit(0)
}

// shadow waits for the kernel to put a pointer in cell 2, then writes eight
// bytes from wherever it points. The self-test decides what the pointer
// names and reads the answer.
shadow :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x5348414453484144
	for _ in 0 ..< 100_000_000 {
		at := intrinsics.volatile_load(&cells[2])
		if at != 0 {
			put(cells, 1, libuser.write(1, ([^]u8)(uintptr(at))[:8]))
			libuser.exit(0)
		}
	}
	libuser.exit(1)
}
