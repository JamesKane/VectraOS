/*
Formatted printing for a tool.

`print` and `fprint` format through `core:fmt`'s buffer formatting, which
builds freestanding, into a buffer on the caller's stack, and write the
result in one call. `bio_print` formats into a `libuser.Bio`.

A package of its own rather than three procedures in `libuser`, because
importing `core:fmt` makes the runtime emit its 128-bit arithmetic helpers
into every program that links the importer, and the page-sized test programs
in `kernel/user/programs` cannot afford two kilobytes they never call. A
tool imports this; a program that fits a page does not.
*/
package libfmt

import "core:fmt"

import "vsys:libuser"

PRINT_MAX :: 1024

// print formats onto descriptor 1, and fprint onto the descriptor named.
// Both answer what `write` answered. A line longer than the buffer is cut.
print :: proc(format: string, fargs: ..any) -> i64 {
	return fprint(1, format, ..fargs)
}

fprint :: proc(fd: int, format: string, fargs: ..any) -> i64 {
	buf: [PRINT_MAX]u8
	s := fmt.bprintf(buf[:], format, ..fargs)
	return libuser.write(fd, transmute([]u8)s)
}

// bio_print formats into a buffered writer.
bio_print :: proc(b: ^libuser.Bio, format: string, fargs: ..any) -> bool {
	tmp: [PRINT_MAX]u8
	return libuser.bio_puts(b, fmt.bprintf(tmp[:], format, ..fargs))
}
