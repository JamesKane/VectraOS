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
treemmio attaches a device's register window through its `#t` `mmio` file and
reads one register. The path is staged at 128, its length the first argument,
and the register's offset the second. It reports the descriptor, the attach,
and the word it read -- which for the RTC's id register is a fixed number the
self-test knows, proof that segattach mapped the hardware and a load reached it.
*/
treemmio :: proc "contextless" (cells: ^Cells, path_len: u64, offset: u64) -> ! {
	cells[0] = 0x54_4D_4D_4F_54_4D_4D_4F // TMMOTMMO
	fd := libuser.open(text(cells, 128, path_len), abi.O_RDONLY)
	put(cells, 1, fd)
	if fd < 0 {
		libuser.exit(0)
	}
	addr, aerr := libuser.segattach(int(fd))
	put(cells, 2, seg_result(addr, aerr))
	if aerr == 0 {
		v := intrinsics.volatile_load((^u32)(uintptr(addr) + uintptr(offset)))
		put(cells, 3, i64(v))
	}
	libuser.exit(0)
}

/*
treeirq waits for a device interrupt through its `#t` `irq` file. It attaches the
RTC's register window (the mmio path staged at 128, its length the first
argument), arms the alarm one tick ahead and enables the device's interrupt, then
opens the `irq` file (the path staged at 192, its length the second argument) and
reads it. The read parks until the alarm fires; the kernel's handler masks the
line, acknowledges and wakes it, and the read answers the fire count. Then it
clears the source and reports the read and the raw status left behind -- zero,
the interrupt serviced. This is the whole handshake `docs/HARDWARE.md` section 3
names, driven from ring 3 with nothing but files and a mapping.

PL031 registers: the data register at `0x000` is the running count, the match at
`0x004` is where the alarm fires, the interrupt mask at `0x010` enables it, the
clear at `0x01C` retires the source, and the raw status at `0x014` reads it.
*/
treeirq :: proc "contextless" (cells: ^Cells, mmio_len: u64, irq_len: u64) -> ! {
	cells[0] = 0x54_49_52_51_54_49_52_51 // TIRQTIRQ
	mfd := libuser.open(text(cells, 128, mmio_len), abi.O_RDONLY)
	put(cells, 1, mfd)
	if mfd < 0 {
		libuser.exit(0)
	}
	base, aerr := libuser.segattach(int(mfd))
	put(cells, 2, seg_result(base, aerr))
	if aerr != 0 {
		libuser.exit(0)
	}

	// Arm the alarm one tick ahead of the running count, and let the device
	// raise its line. The GIC side stays masked until the read below unmasks it.
	now := intrinsics.volatile_load((^u32)(base + 0x000))
	intrinsics.volatile_store((^u32)(base + 0x004), now + 1)
	intrinsics.volatile_store((^u32)(base + 0x010), 1)

	ifd := libuser.open(text(cells, 192, irq_len), abi.O_RDONLY)
	put(cells, 3, ifd)
	if ifd < 0 {
		libuser.exit(0)
	}
	// The park. The read returns when the alarm fires, one tick out, with the
	// count of fires the kernel counted written as text.
	n := libuser.read(int(ifd), slot(cells, 256, 16))
	put(cells, 4, n)
	if n > 0 {
		put(cells, 5, i64(intrinsics.volatile_load(&bytes(cells)[256])))
	}

	// Retire the source at the device and disable it, then read the raw status
	// back: zero says the line the handler serviced is truly quiet again.
	intrinsics.volatile_store((^u32)(base + 0x01C), 1)
	intrinsics.volatile_store((^u32)(base + 0x010), 0)
	put(cells, 6, i64(intrinsics.volatile_load((^u32)(base + 0x014))))
	libuser.exit(0)
}

/*
treedma binds a device's stream to its own space through a `dma` file, and
tries every way the line can be wrong. `docs/SMMU.md` section 10's ring 3
half. The file's path is staged at 128, its length the argument. Slot 16 is
the scratch disk's requester id on `virt`, bus 0 device 2 function 0.

It opens the file and attaches slot 16 to itself. It attaches it again,
which is busy. It attaches it to pid 1, which holds nothing of ours and is
refused. It attaches slot 70000, past the map, which is invalid.

Then it detaches. It attaches once more and exits with the slot still bound,
so the kernel can check that the last close gave it back. Each write's answer
is a cell.
*/
treedma :: proc "contextless" (cells: ^Cells, path_len: u64) -> ! {
	cells[0] = 0x54_44_4D_41_54_44_4D_41 // TDMATDMA
	fd := libuser.open(text(cells, 128, path_len), abi.O_RDWR)
	put(cells, 1, fd)
	if fd < 0 {
		libuser.exit(0)
	}
	pid := libuser.getpid()

	line := slot(cells, 256, 64)
	n := put_text(line, 0, "attach 16 ")
	n = put_dec(line, n, pid)
	put(cells, 2, libuser.write(int(fd), line[:n]))
	put(cells, 3, libuser.write(int(fd), line[:n]))

	n = put_text(line, 0, "attach 16 1")
	put(cells, 4, libuser.write(int(fd), line[:n]))

	n = put_text(line, 0, "attach 70000 ")
	n = put_dec(line, n, pid)
	put(cells, 5, libuser.write(int(fd), line[:n]))

	n = put_text(line, 0, "detach 16")
	put(cells, 6, libuser.write(int(fd), line[:n]))
	put(cells, 7, libuser.write(int(fd), line[:n]))

	n = put_text(line, 0, "attach 16 ")
	n = put_dec(line, n, pid)
	put(cells, 8, libuser.write(int(fd), line[:n]))
	libuser.exit(0)
}

@(private = "file")
put_text :: proc "contextless" (b: []u8, at: int, s: string) -> int {
	n := at
	for i in 0 ..< len(s) {
		if n >= len(b) {
			break
		}
		b[n] = s[i]
		n += 1
	}
	return n
}

@(private = "file")
put_dec :: proc "contextless" (b: []u8, at: int, v: u64) -> int {
	tmp: [20]u8
	k := 0
	x := v
	for {
		tmp[k] = u8('0' + x % 10)
		k += 1
		x /= 10
		if x == 0 {
			break
		}
	}
	n := at
	for i := k - 1; i >= 0 && n < len(b); i -= 1 {
		b[n] = tmp[i]
		n += 1
	}
	return n
}

/*
fixedseg allocates a run at the address named as the argument, writes a witness
into it and reads it back, then asks for a second run at the same address, which
the kernel refuses because the first one is there. It reports the placed address,
the witness, and the refusal.
*/
fixedseg :: proc "contextless" (cells: ^Cells, at: u64) -> ! {
	cells[0] = 0x46_49_58_53_46_49_58_53 // FIXSFIXS
	a1, e1 := libuser.segalloc(4096, 0, uintptr(at))
	put(cells, 1, seg_result(a1, e1))
	if e1 == 0 {
		store64(a1, 0x1234_5678)
		put(cells, 2, i64(load64(a1)))
	}
	a2, e2 := libuser.segalloc(4096, 0, uintptr(at))
	put(cells, 3, seg_result(a2, e2))
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
