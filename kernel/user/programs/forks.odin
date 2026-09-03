// The ones that fork, by Plan 9's flag word, and what each half does.
package programs

import "base:intrinsics"
import "vsys:libuser"

// forker forks a plain child, which bumps a cell in its own copy of the page
// and exits with the result. The parent's copy stays at ten.
forker :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x464F524B464F524B
	cells[4] = 10
	pid := libuser.rfork(0x10)
	if pid == 0 {
		bump(cells, 4)
		libuser.exit(intrinsics.volatile_load(&cells[4]))
	}
	put(cells, 1, pid)
	put(cells, 3, libuser.wait(u64(pid)))
	libuser.exit(0)
}

// memfork forks a child that shares memory. The child writes a witness the
// parent can see, waits for a word from the kernel, and leaves.
memfork :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x4D454D464D454D46
	pid := libuser.rfork(0x30)
	if pid == 0 {
		intrinsics.volatile_store(&cells[2], 0xC0FFEEC0FFEE)
		if !wait_cell(cells, 3) {
			libuser.exit(0x99)
		}
		libuser.exit(0)
	}
	put(cells, 1, pid)
	libuser.exit(42)
}

// fdforker forks with the flags the self-test chose, and the child closes
// descriptor 1. Whether the parent's descriptor 1 survives is the answer.
fdforker :: proc "contextless" (cells: ^Cells, flags: u64) -> ! {
	cells[0] = 0x4644464B4644464B
	pid := libuser.rfork(flags)
	if pid == 0 {
		_ = libuser.close(1)
		libuser.exit(0)
	}
	put(cells, 2, libuser.wait(u64(pid)))
	put(cells, 3, libuser.close(1))
	libuser.exit(0)
}

// refuser asks for every flag word the kernel refuses, and records each
// refusal.
refuser :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x5245465552454655
	put(cells, 1, libuser.rfork(0x2))
	put(cells, 2, libuser.rfork(0x40))
	put(cells, 3, libuser.rfork(0x20))
	put(cells, 4, libuser.rfork(0x1014))
	put(cells, 5, libuser.rfork(0x4000))
	put(cells, 6, libuser.rfork(0))
	put(cells, 7, libuser.rfork(0x8))
	libuser.exit(0)
}

/*
grouper makes two children that never stop on their own, one in its own
note group and one in the parent's, and notes the group.

The first child, forked without RFNOTEG, counts in cell 8. The second,
forked with it, counts in cell 9. A note to the parent's group ends the
first and not the second, which the parent shows by watching cell 9 still
move, and then ends by name.
*/
grouper :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x4752555047525550
	first := libuser.rfork(0x30)
	if first == 0 {
		for _ in 0 ..< ROUNDS {
			bump(cells, 8)
		}
		libuser.exit(0x7C)
	}
	put(cells, 1, first)
	second := libuser.rfork(0x38)
	if second == 0 {
		for _ in 0 ..< ROUNDS {
			bump(cells, 9)
		}
		libuser.exit(0x7D)
	}
	put(cells, 2, second)

	_ = libuser.sleep(2)
	put(cells, 3, libuser.notepg(0, "die"))
	put(cells, 4, libuser.wait(u64(first)))

	before := intrinsics.volatile_load(&cells[9])
	_ = libuser.sleep(2)
	cells[5] = intrinsics.volatile_load(&cells[9]) - before

	put(cells, 6, libuser.note(u64(second), "die"))
	put(cells, 7, libuser.wait(u64(second)))
	libuser.exit(0)
}

// nowaiter forks a child nobody will wait for, which waits for a word from
// the kernel and leaves on its own. The parent's wait says there was
// nothing to collect.
nowaiter :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x4E4F57414E4F5741
	pid := libuser.rfork(0x50)
	if pid == 0 {
		intrinsics.volatile_store(&cells[8], 1)
		_ = wait_cell(cells, 9)
		libuser.exit(0x5A)
	}
	put(cells, 1, pid)
	put(cells, 2, libuser.wait(u64(pid)))
	libuser.exit(0)
}
