// The ones that hold memory no file serves, or a device's.
package programs

import "base:intrinsics"
import "vsys:abi"
import "vsys:libuser"

@(private = "file") WITNESS :: u64(0x57494E4457494E44)
@(private = "file") SPOILED :: u64(0x0BAD0BAD0BAD0BAD)

@(private = "file")
attach :: proc "contextless" (fd: int) -> i64 {
	addr, err := libuser.segattach(fd)
	return seg_result(addr, err)
}

@(private = "file")
alloc :: proc "contextless" (size: int, flags: u64 = 0) -> i64 {
	addr, err := libuser.segalloc(size, flags)
	return seg_result(addr, err)
}

/*
mapper attaches the device behind a descriptor, twice, and writes a pixel
into the first mapping at the corner the self-test named. The second
mapping is grown, which a device refuses, and detached. Then a descriptor
nobody opened, and a file that is a stream, neither of which attaches.
*/
mapper :: proc "contextless" (cells: ^Cells, corner: u64) -> ! {
	cells[0] = 0x4D4150504D415050
	fd := libuser.open(text(cells, 128, 7), abi.O_WRONLY)
	put(cells, 1, fd)
	first := attach(int(fd))
	put(cells, 2, first)
	intrinsics.volatile_store((^u32)(uintptr(first) + uintptr(corner)), 0x00FF00FF)

	second := attach(int(fd))
	put(cells, 3, second)
	put(cells, 6, libuser.segbrk(uintptr(second), uintptr(second) + 0x2000))
	put(cells, 7, libuser.segdetach(uintptr(second)))

	put(cells, 4, attach(99))
	stream := libuser.open(text(cells, 192, 9), abi.O_WRONLY)
	put(cells, 5, attach(int(stream)))
	libuser.exit(0)
}

/*
anon takes memory of its own and exercises every edge of it.

A run of `size` bytes, read and written at both ends. A second run, grown
past its end and written there, then shrunk. A hole below a live run, which
the next run of that size fills. Detaches of addresses no run covers, a run
too big to have, and a run of nothing. Then a fork without RFMEM: the child
gets its own copy of the first run, spoils it, and exits, and the parent's
copy is what it was.
*/
anon :: proc "contextless" (cells: ^Cells, size: u64) -> ! {
	cells[0] = 0x414E4F4E414E4F4E
	first := alloc(int(size))
	put(cells, 1, first)
	base := uintptr(first)
	cells[2] = load64(base)
	store64(base, WITNESS)
	store64(base + uintptr(size) - 8, WITNESS)
	cells[3] = load64(base + uintptr(size) - 8)

	second := alloc(int(size))
	put(cells, 4, second)
	grown := uintptr(second)
	_ = wait_cell(cells, 12)
	put(cells, 9, libuser.segbrk(grown, grown + uintptr(size) + 0x4000))
	store64(grown + uintptr(size) + 0x4000 - 8, WITNESS)
	cells[10] = load64(grown + uintptr(size) + 0x4000 - 8)
	put(cells, 11, libuser.segbrk(grown, grown + uintptr(size) + 0x2000))

	// A one-page run X, and a second one-page run Y just above it. Detach
	// X, the lower, and leave Y holding the ground above the hole. Ask
	// again at the same size: first fit finds the hole below Y and hands it
	// back, where a bump would answer above Y.
	x := alloc(0x1000)
	put(cells, 13, x)
	y := alloc(0x1000)
	put(cells, 14, libuser.segdetach(uintptr(x)))
	again := alloc(0x1000)
	put(cells, 17, again)
	_ = libuser.segdetach(uintptr(y))
	_ = libuser.segdetach(uintptr(again))

	put(cells, 15, libuser.segdetach(0x400000))
	put(cells, 16, libuser.segdetach(0x1000))
	put(cells, 5, alloc(0x40000000))
	put(cells, 6, alloc(0))

	pid := libuser.rfork(abi.RFPROC)
	if pid == 0 {
		own := alloc(int(size))
		if own < 0 {
			libuser.exit(8)
		}
		store64(uintptr(own), SPOILED)
		if load64(base) != WITNESS {
			libuser.exit(8)
		}
		store64(base, SPOILED)
		libuser.exit(7)
	}
	put(cells, 8, libuser.wait(u64(pid)))
	cells[7] = load64(base)
	libuser.exit(0)
}

/*
sharer: a run shared under RFMEM, grown and then shrunk by the parent.

The parent takes two pages, forks a sharer, grows the run to three pages,
writes a witness into the third, and raises a flag in the data page. The
child waits for the flag, reads the witness through its own tables, and
writes what it read. The parent then shrinks the run to one page and raises
a second flag. The child touches the third page again: a page fault ends it
if the shrink reached its tables, and a word in cell 6 says the mapping
survived if it did not. Cells are the data page's, shared.
*/
sharer :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x5348415253484152
	run := alloc(8192)
	if run < 0 {
		libuser.exit(0x98)
	}
	base := uintptr(run)
	put(cells, 1, run)

	pid := libuser.rfork(abi.RFPROC | abi.RFMEM)
	if pid == 0 {
		if !wait_cell(cells, 2) {
			libuser.exit(0x99)
		}
		cells[3] = load64(base + 4096)
		if !wait_cell(cells, 4) {
			libuser.exit(0x9A)
		}
		cells[6] = load64(base + 4096)
		libuser.exit(0x9B)
	}
	if pid < 0 {
		libuser.exit(0x98)
	}
	put(cells, 5, pid)
	if libuser.segbrk(base, base + 12288) != 0 {
		libuser.exit(0x98)
	}
	store64(base + 4096, 0xBEEF)
	intrinsics.volatile_store(&cells[2], 1)
	if !wait_cell(cells, 3) {
		libuser.exit(0x97)
	}
	if libuser.segbrk(base, base + 4096) != 0 {
		libuser.exit(0x98)
	}
	intrinsics.volatile_store(&cells[4], 1)
	libuser.exit(0)
}

/*
sharedseg: the shared class, across a fork without RFMEM and an exec.

Two pages: one asked for with SEGSHARED, one without. Both seeded, then a
fork with RFPROC alone. The child writes a witness into each and exits. The
parent waits, reads both back into the shared page -- the data page will
not survive what comes next -- and execs /bin/child. What the kernel finds
in the shared page afterwards is the whole answer: the child's witness in
the first word, the parent's reading of it in the second, and the private
seed untouched in the third.
*/
sharedseg :: proc "contextless" (cells: ^Cells) -> ! {
	_ = cells
	shared := alloc(4096, abi.SEGSHARED)
	if shared < 0 {
		libuser.exit(0x98)
	}
	private := alloc(4096)
	if private < 0 {
		libuser.exit(0x98)
	}
	store64(uintptr(shared), 0x11)
	store64(uintptr(private), 0x22)

	pid := libuser.rfork(abi.RFPROC)
	if pid < 0 {
		libuser.exit(0x98)
	}
	if pid == 0 {
		store64(uintptr(shared), 0x1111)
		store64(uintptr(private), 0x2222)
		libuser.exit(0)
	}
	_ = libuser.wait(u64(pid))
	store64(uintptr(shared) + 8, load64(uintptr(shared)))
	store64(uintptr(shared) + 16, load64(uintptr(private)))
	_ = libuser.exec("/bin/child")
	libuser.exit(0x98)
}
