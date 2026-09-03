// The ones that open files by name, in a namespace the self-test arranged.
// Paths and texts are staged in the data page at the slots `program.odin`
// names, and their lengths arrive as the two arguments.
package programs

import "vsys:libuser"

// namer opens a path, writes to it, closes it, writes to the closed
// descriptor, and opens a path that is not there. Five answers.
namer :: proc "contextless" (cells: ^Cells, path_len, text_len: u64) -> ! {
	cells[0] = 0x4E414D454E414D45
	fd := libuser.open(text(cells, 128, path_len), 1)
	put(cells, 1, fd)
	put(cells, 2, libuser.write(int(fd), slot(cells, 256, text_len)))
	put(cells, 3, libuser.close(int(fd)))
	put(cells, 4, libuser.write(int(fd), slot(cells, 256, text_len)))
	put(cells, 5, libuser.open(text(cells, 320, path_len), 0))
	libuser.exit(0)
}

// reader reads eight bytes into its own page, then asks for eight into its
// text, which the kernel may not write. Cell 8 starts as all ones so a read
// that lands shows.
reader :: proc "contextless" (cells: ^Cells, path_len: u64) -> ! {
	cells[0] = 0x5245414452454144
	cells[8] = ~u64(0)
	fd := libuser.open(text(cells, 128, path_len), 0)
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
	put(cells, 1, libuser.bind(text(cells, 128, path_len), text(cells, 192, path_len), 0))
	fd := libuser.open(text(cells, 192, path_len), 1)
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
	fd := libuser.open(text(cells, 128, path_len), 2)
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

// bulkio moves four thousand bytes out and back through one descriptor,
// which is more than one call's copy bound.
bulkio :: proc "contextless" (cells: ^Cells, path_len, offset: u64) -> ! {
	cells[0] = 0x42554C4B42554C4B
	fd := libuser.open(text(cells, 32, path_len), 2)
	put(cells, 1, fd)
	_ = libuser.seek(int(fd), offset)
	put(cells, 2, libuser.write(int(fd), slot(cells, 96, 4000)))
	_ = libuser.seek(int(fd), offset)
	put(cells, 3, libuser.read(int(fd), slot(cells, 96, 4000)))
	_ = libuser.close(int(fd))
	libuser.exit(0)
}
