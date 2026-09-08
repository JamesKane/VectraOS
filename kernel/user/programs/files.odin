// The ones that open files by name, in a namespace the self-test arranged.
// Paths and texts are staged in the data page at the slots `program.odin`
// names, and their lengths arrive as the two arguments.
package programs

import "vsys:abi"
import "vsys:libuser"

// namer opens a path, writes to it, closes it, writes to the closed
// descriptor, and opens a path that is not there. Five answers.
namer :: proc "contextless" (cells: ^Cells, path_len, text_len: u64) -> ! {
	cells[0] = 0x4E414D454E414D45
	fd := libuser.open(text(cells, 128, path_len), abi.O_WRONLY)
	put(cells, 1, fd)
	put(cells, 2, libuser.write(int(fd), slot(cells, 256, text_len)))
	put(cells, 3, libuser.close(int(fd)))
	put(cells, 4, libuser.write(int(fd), slot(cells, 256, text_len)))
	put(cells, 5, libuser.open(text(cells, 320, path_len), abi.O_RDONLY))
	libuser.exit(0)
}

// reader reads eight bytes into its own page, then asks for eight into its
// text, which the kernel may not write. Cell 8 starts as all ones so a read
// that lands shows.
reader :: proc "contextless" (cells: ^Cells, path_len: u64) -> ! {
	cells[0] = 0x5245414452454144
	cells[8] = ~u64(0)
	fd := libuser.open(text(cells, 128, path_len), abi.O_RDONLY)
	put(cells, 1, fd)
	put(cells, 2, libuser.read(int(fd), slot(cells, 64, 8)))
	own_text := ([^]u8)(uintptr(0x400000))
	put(cells, 3, libuser.read(int(fd), own_text[:8]))
	put(cells, 4, libuser.close(int(fd)))
	libuser.exit(0)
}

// binder binds one path over another in its own namespace, writes through
// the new name, and then through descriptor 1, which it opened before.
binder :: proc "contextless" (cells: ^Cells, path_len, text_len: u64) -> ! {
	cells[0] = 0x42494E4442494E44
	put(cells, 1, libuser.bind(text(cells, 128, path_len), text(cells, 192, path_len), abi.ORDER_REPLACE))
	fd := libuser.open(text(cells, 192, path_len), abi.O_WRONLY)
	put(cells, 2, fd)
	put(cells, 3, libuser.write(int(fd), slot(cells, 256, text_len)))
	put(cells, 4, libuser.close(int(fd)))
	put(cells, 5, libuser.write(1, slot(cells, 256, text_len)))
	libuser.exit(0)
}

// painter seeks to the offset in cell 24, writes the same bytes twice,
// seeks back, and reads what landed.
painter :: proc "contextless" (cells: ^Cells, path_len, text_len: u64) -> ! {
	cells[0] = 0x5041494E5041494E
	fd := libuser.open(text(cells, 128, path_len), abi.O_RDWR)
	put(cells, 1, fd)
	offset := cells[24]
	put(cells, 2, libuser.seek(int(fd), offset))
	put(cells, 3, libuser.write(int(fd), slot(cells, 256, text_len)))
	put(cells, 4, libuser.write(int(fd), slot(cells, 256, text_len)))
	put(cells, 5, libuser.seek(int(fd), offset))
	put(cells, 6, libuser.read(int(fd), slot(cells, 320, text_len)))
	put(cells, 7, libuser.close(int(fd)))
	libuser.exit(0)
}

/*
storetest attaches its window's shared store and paints it, no draw verb
between the pixels and the glass -- the handoff `docs/DEVTOOLS.md` step 1 names.

The kernel has already read the store file and staged its id and geometry into
cells 3..6 (a report the freestanding parse could not be trusted to read here).
This `shmattach`es those frames, writes a square of `COLOR` into the client
area, and opens the store to write the flush line staged at 320, which composits
it. The cell indices and the square's colour and place must match
`program.odin`'s `STORE_*`, the way every program here agrees with its checker.
*/
storetest :: proc "contextless" (cells: ^Cells, path_len, cmd_len: u64) -> ! {
	COLOR :: u32(0x00AB_CDEF)
	BX :: 8
	BY :: 8
	SZ :: 24
	id := cells[3]
	stride := int(cells[4])
	cx := int(cells[5])
	cy := int(cells[6])
	cells[0] = 0x53_54_4F_52_53_54_4F_52 // STORSTOR, the mark

	addr, aerr := libuser.shmattach(id)
	put(cells, 9, seg_result(addr, aerr))
	if aerr == 0 {
		store := ([^]u32)(addr)
		for row in 0 ..< SZ {
			base := (cy + BY + row) * stride + cx + BX
			for col in 0 ..< SZ {
				store[base + col] = COLOR
			}
		}
	}
	// Flush: open the store and write the staged `x y w h`, through a
	// multipointer for the write's buffer.
	fd := libuser.open(text(cells, 128, path_len), abi.O_RDWR)
	put(cells, 1, fd)
	if fd >= 0 {
		fbuf := ([^]u8)(uintptr(cells) + 320)
		put(cells, 10, libuser.write(int(fd), fbuf[:cmd_len]))
	}
	libuser.exit(0)
}

// bulkio moves four thousand bytes out and back through one descriptor,
// which is more than one call's copy bound.
bulkio :: proc "contextless" (cells: ^Cells, path_len, offset: u64) -> ! {
	cells[0] = 0x42554C4B42554C4B
	fd := libuser.open(text(cells, 32, path_len), abi.O_RDWR)
	put(cells, 1, fd)
	_ = libuser.seek(int(fd), offset)
	put(cells, 2, libuser.write(int(fd), slot(cells, 96, 4000)))
	_ = libuser.seek(int(fd), offset)
	put(cells, 3, libuser.read(int(fd), slot(cells, 96, 4000)))
	_ = libuser.close(int(fd))
	libuser.exit(0)
}
