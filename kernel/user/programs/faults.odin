// The five that end on a fault, or on the kernel's word. Each writes its
// mark first, so the self-test can tell a program that never ran from one
// that ran and was refused.
package programs

import "base:intrinsics"

// spin never makes a system call and never stops on its own. The tick has
// to catch it. The counter is written through memory every round, because
// the self-test reads it afterwards and checks the kernel stopped the loop
// short of its bound.
spin :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x5350494E5350494E
	for _ in 0 ..< ROUNDS {
		bump(cells, 1)
		if intrinsics.volatile_load(&cells[2]) != 0 {
			break
		}
	}
	die()
}

// poke writes to the address it was given, which is the kernel's, or its
// own text.
poke :: proc "contextless" (cells: ^Cells, at: u64) -> ! {
	cells[0] = 0x504F4B45504F4B45
	store64(uintptr(at), 1)
	die()
}

// peek reads from the address it was given and keeps what it read, which
// the self-test checks it never got.
peek :: proc "contextless" (cells: ^Cells, at: u64) -> ! {
	cells[0] = 0x5045454B5045454B
	cells[1] = load64(uintptr(at))
	die()
}

// priv masks interrupts, which a program may not. The instruction is the
// architecture's, as bytes, because the template checker knows none of the
// three as something a program would write.
priv :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x5052495650524956
	when ODIN_ARCH == .amd64 {
		asm() [#volatile, #clobber memory] { #byte 0xFA }() // cli
	} else when ODIN_ARCH == .arm64 {
		asm() [#volatile, #clobber memory] { #byte 0xDF, 0x42, 0x03, 0xD5 }() // msr daifset, #2
	} else {
		asm() [#volatile, #clobber memory] { csrrci %zero, 0x100, 2 }() // csrci sstatus, 2
	}
	die()
}

// jump goes to the address it was given, which is its own data page, and
// which is not executable.
jump :: proc "contextless" (cells: ^Cells, at: u64) -> ! {
	cells[0] = 0x4A554D504A554D50
	target := transmute(proc "contextless" ())uintptr(at)
	target()
	die()
}
