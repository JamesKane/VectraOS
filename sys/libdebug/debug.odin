/*
The debug file a build makes beside a program, read on the machine.

`docs/DEVTOOLS.md` section 6: the `.vx` image carries no symbols, and the
information a debugger wants is a second file, `build/user/<name>.vxd`,
staged at `/lib/debug/<name>.vxd`. `elf_to_debug` in `build.odin` writes
it from the linked ELF's DWARF and symbol table, and this package reads it.
The kernel's own, `vectra.vxd`, is a Limine module, and `kernel/debuginfo`
reads it through the same code.

## Tables with sorted keys

The file is a header, a directory of tables, and the tables. Every entry
is fixed-size and little-endian, and every name is an offset into one
string pool. Every table a lookup walks is sorted on its key. A reader binary
searches and never parses, which is what lets the kernel resolve a name in
a panic handler with no allocator.

    header    magic `VXD1`, version, architecture, table count
    dir       per table: kind, entry size, count, offset
    units     name, directory, language, line-program offset
    files     unit, path
    procs     low, high, name, unit          sorted by low
    lines     address, file, line            sorted by address
    names     name, proc                     sorted by name
    dis       address, text                  sorted by address
    strings   NUL-terminated, referenced by offset

A `lines` row with file zero and line zero is the end of a sequence. An
address past it and before the next row has no source. A table may be
absent, in which case its lookup answers false.

Nothing here does I/O or allocates, so the kernel and a program both
compile it. A consumer reads the whole file into memory it owns and hands
the bytes to `open`.
*/
package libdebug

MAGIC :: u32(0x3144_5856) // "VXD1"
VERSION :: u32(1)

Table :: enum u32 {
	Units   = 1,
	Files   = 2,
	Procs   = 3,
	Lines   = 4,
	Names   = 5,
	Dis     = 6,
	Strings = 7,
}

MAX_TABLES :: 8
HEADER_SIZE :: 16
DIR_ENTRY_SIZE :: 24

UNIT_SIZE :: 16
FILE_SIZE :: 8
PROC_SIZE :: 24
LINE_SIZE :: 16
NAME_SIZE :: 8
DIS_SIZE :: 16

Dir :: struct {
	entry:  u32,
	count:  u64,
	offset: u64,
}

Debug :: struct {
	data: []u8,
	arch: u32,
	dirs: [MAX_TABLES]Dir, // by `Table`, zero where absent
}

@(private)
u32at :: proc "contextless" (b: []u8, at: int) -> u32 #no_bounds_check {
	if at < 0 || at + 4 > len(b) {
		return 0
	}
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

@(private)
u64at :: proc "contextless" (b: []u8, at: int) -> u64 #no_bounds_check {
	if at < 0 || at + 8 > len(b) {
		return 0
	}
	return u64(u32at(b, at)) | u64(u32at(b, at + 4)) << 32
}

// open checks the header and reads the directory. False for bytes that are
// not a debug file this reader knows, which a build newer than the reader
// would be.
open :: proc "contextless" (data: []u8) -> (d: Debug, ok: bool) {
	if len(data) < HEADER_SIZE || u32at(data, 0) != MAGIC || u32at(data, 4) != VERSION {
		return {}, false
	}
	d.data = data
	d.arch = u32at(data, 8)
	n := int(u32at(data, 12))
	if n > MAX_TABLES || HEADER_SIZE + n * DIR_ENTRY_SIZE > len(data) {
		return {}, false
	}
	for i in 0 ..< n {
		at := HEADER_SIZE + i * DIR_ENTRY_SIZE
		kind := u32at(data, at)
		entry := u32at(data, at + 4)
		count := u64at(data, at + 8)
		offset := u64at(data, at + 16)
		if kind == 0 || kind >= MAX_TABLES {
			return {}, false
		}
		if offset + count * u64(entry) > u64(len(data)) {
			return {}, false
		}
		d.dirs[kind] = Dir{entry = entry, count = count, offset = offset}
	}
	return d, true
}

// str answers the string at `off` in the pool, up to its NUL.
str :: proc "contextless" (d: ^Debug, off: u32) -> string #no_bounds_check {
	pool := d.dirs[Table.Strings]
	start := int(pool.offset) + int(off)
	end := int(pool.offset + pool.count)
	if start < int(pool.offset) || start >= end || end > len(d.data) {
		return ""
	}
	n := start
	for n < end && d.data[n] != 0 {
		n += 1
	}
	return string(d.data[start:n])
}

@(private)
entry_at :: proc "contextless" (d: ^Debug, t: Table, i: int) -> int {
	dir := d.dirs[t]
	return int(dir.offset) + i * int(dir.entry)
}

count :: proc "contextless" (d: ^Debug, t: Table) -> int {
	return int(d.dirs[t].count)
}

// last_at_most finds the last row of a table whose leading u64 key is at
// most `key`: the row an address lookup wants. -1 when none is.
@(private)
last_at_most :: proc "contextless" (d: ^Debug, t: Table, key: u64) -> int {
	lo, hi := 0, count(d, t)
	for lo < hi {
		mid := (lo + hi) / 2
		if u64at(d.data, entry_at(d, t, mid)) <= key {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

// proc_at names the procedure an address is inside, and where it starts.
proc_at :: proc "contextless" (d: ^Debug, addr: u64) -> (name: string, low: u64, ok: bool) {
	i := last_at_most(d, .Procs, addr)
	// Procedures do not nest, but aliases share a start: walk back to the
	// first row that still covers the address.
	for i >= 0 {
		at := entry_at(d, .Procs, i)
		lo := u64at(d.data, at)
		hi := u64at(d.data, at + 8)
		if addr >= lo && addr < hi {
			return str(d, u32at(d.data, at + 16)), lo, true
		}
		if lo < addr - min(addr, 1 << 20) {
			break
		}
		i -= 1
	}
	return "", 0, false
}

// proc_row answers the fields of the nth procedure.
proc_row :: proc "contextless" (d: ^Debug, i: int) -> (name: string, low, high: u64, unit: u32) {
	at := entry_at(d, .Procs, i)
	return str(d, u32at(d.data, at + 16)), u64at(d.data, at), u64at(d.data, at + 8), u32at(d.data, at + 20)
}

// line_at answers the source file and line an address was compiled from.
// False past the end of a sequence, or for an address no unit covers.
line_at :: proc "contextless" (d: ^Debug, addr: u64) -> (file: string, line: u32, ok: bool) {
	i := last_at_most(d, .Lines, addr)
	if i < 0 {
		return "", 0, false
	}
	at := entry_at(d, .Lines, i)
	f := u32at(d.data, at + 8)
	l := u32at(d.data, at + 12)
	if f == 0 && l == 0 {
		return "", 0, false
	}
	return file_path(d, int(f)), l, true
}

// file_path answers the nth file's path.
file_path :: proc "contextless" (d: ^Debug, i: int) -> string {
	if i < 0 || i >= count(d, .Files) {
		return ""
	}
	return str(d, u32at(d.data, entry_at(d, .Files, i) + 4))
}

// unit_name answers the nth compilation unit's name.
unit_name :: proc "contextless" (d: ^Debug, i: int) -> string {
	if i < 0 || i >= count(d, .Units) {
		return ""
	}
	return str(d, u32at(d.data, entry_at(d, .Units, i)))
}

@(private)
compare :: proc "contextless" (a, b: string) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return a[i] < b[i] ? -1 : 1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return len(a) < len(b) ? -1 : 1
}

// lookup finds a procedure by its full name and answers its range.
lookup :: proc "contextless" (d: ^Debug, name: string) -> (low, high: u64, ok: bool) {
	lo, hi := 0, count(d, .Names)
	for lo < hi {
		mid := (lo + hi) / 2
		at := entry_at(d, .Names, mid)
		c := compare(str(d, u32at(d.data, at)), name)
		if c == 0 {
			p := int(u32at(d.data, at + 4))
			pat := entry_at(d, .Procs, p)
			return u64at(d.data, pat), u64at(d.data, pat + 8), true
		}
		if c < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return 0, 0, false
}

// dis_at answers the instruction text at exactly `addr`, when the file
// carries disassembly.
dis_at :: proc "contextless" (d: ^Debug, addr: u64) -> (text: string, ok: bool) {
	i := last_at_most(d, .Dis, addr)
	if i < 0 {
		return "", false
	}
	at := entry_at(d, .Dis, i)
	if u64at(d.data, at) != addr {
		return "", false
	}
	return str(d, u32at(d.data, at + 8)), true
}

// dis_next answers the address of the instruction after the one at `addr`.
// An engine on an architecture with no step plants its breakpoint there.
// False at the end of the table.
dis_next :: proc "contextless" (d: ^Debug, addr: u64) -> (next: u64, ok: bool) {
	i := last_at_most(d, .Dis, addr)
	if i < 0 || i + 1 >= count(d, .Dis) {
		return 0, false
	}
	return u64at(d.data, entry_at(d, .Dis, i + 1)), true
}
