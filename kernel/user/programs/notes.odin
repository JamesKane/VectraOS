// The ones that post a note, catch one, or take the default.
package programs

import "base:intrinsics"
import "vsys:abi"
import "vsys:libuser"

// noter spawns the spinner, which never stops on its own, and notes it. The
// wait answers with the kernel's word for a note that ended a child. Then it
// notes a pid that is nobody's child.
noter :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x4E4F54524E4F5452
	pid := libuser.spawn("/bin/spin", 1)
	put(cells, 1, pid)
	put(cells, 2, libuser.note(u64(pid), "stop"))
	put(cells, 3, libuser.wait(u64(pid)))
	put(cells, 4, libuser.note(9999, "stop"))
	libuser.exit(0)
}

/*
catcher registers a handler and waits to be noted, twice.

The first delivery interrupts the counting loop, and the second a sleep.
The handler counts deliveries in cell 4, keeps the note's first eight bytes
in cell 5, and continues. What the program held before the note is what it
holds after, and cell 6 says so.
*/
catcher :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x4354434843544348
	put(cells, 1, libuser.try_noted(abi.NCONT))
	put(cells, 2, libuser.notify(uintptr(rawptr(catcher_handler))))

	witness := u64(0x13C0FFEE13C0FFEE)
	caught := false
	for _ in 0 ..< ROUNDS {
		bump(cells, 3)
		if intrinsics.volatile_load(&cells[4]) >= 1 {
			caught = true
			break
		}
	}
	if !caught {
		libuser.exit(0x7A)
	}

	caught = false
	for _ in 0 ..< 2000 {
		if intrinsics.volatile_load(&cells[4]) >= 2 {
			caught = true
			break
		}
		_ = libuser.sleep(1)
	}
	if !caught {
		libuser.exit(0x7B)
	}
	cells[6] = intrinsics.volatile_load(&witness)
	libuser.exit(0)
}

// catcher_handler is what the kernel calls with the saved frame and the
// note's text. It finds the cells at the data page's fixed address, because
// a handler is called with nothing else.
@(private = "file")
catcher_handler :: proc "c" (ureg: rawptr, note: ^u64) {
	_ = ureg
	cells := (^Cells)(DATA_VA)
	bump(cells, 4)
	cells[5] = note^
	libuser.noted(abi.NCONT)
}

// dfltnote registers a handler that takes the default action, which is the
// ending the note always was. The count in cell 3 says the handler ran.
dfltnote :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x44464C5444464C54
	put(cells, 1, libuser.notify(uintptr(rawptr(dfltnote_handler))))
	for _ in 0 ..< ROUNDS {
		bump(cells, 2)
	}
	libuser.exit(0x7A)
}

@(private = "file")
dfltnote_handler :: proc "c" (ureg: rawptr, note: ^u64) {
	_, _ = ureg, note
	cells := (^Cells)(DATA_VA)
	bump(cells, 3)
	libuser.noted(abi.NDFLT)
}
