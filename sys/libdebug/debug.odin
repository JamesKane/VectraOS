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
	Types   = 8,
	Members = 9,
	Scopes  = 10,
	Vars    = 11,
}

MAX_TABLES :: 12
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

// -- Types, scopes and variables ------------------------------------------------

/*
The second half of the file: what a debugger shows beside an address.

    types     kind, name, size, target, count, first, encoding
    members   name, type, offset -- a struct's fields, or an enum's values
    scopes    low, high, parent, name, first, nvars   sorted by low, outer first
    vars      name, type, kind, reg, offset, low, high

A scope is a procedure with code, a block in it, or a call inlined into
it. The unit itself is one scope holding every global. Its variables are
a run of rows. A variable with a location list has one row per entry, and
each holds on its own range. A row with no range holds everywhere. `var_at`
walks from the innermost scope at an address outward and answers the first
row of a name that holds there.
*/
TYPE_SIZE :: 32
MEMBER_SIZE :: 16
SCOPE_SIZE :: 32
VAR_SIZE :: 40
NO_TYPE :: u32(0xffff_ffff)
NO_SCOPE :: u32(0xffff_ffff)

Type_Kind :: enum u32 {
	Unknown = 0,
	Base    = 1,
	Pointer = 2,
	Array   = 3,
	Struct  = 4,
	Union   = 5,
	Enum    = 6,
	Proc    = 7,
	Typedef = 8,
	Slice   = 9,
	String  = 10,
	Map     = 11,
}

Loc_Kind :: enum u32 {
	Gone  = 0, // No location at all
	Fbreg = 1, // At the frame base plus `offset`
	Reg   = 2, // In register `reg`, in DWARF's numbering for the architecture
	Breg  = 3, // At register `reg` plus `offset`
	Addr  = 4, // At the address `offset`
	Const = 5, // The value `offset` itself
	Other = 6, // An expression the file does not say: optimised away, to a debugger
}

Type :: struct {
	kind:   Type_Kind,
	name:   string,
	size:   u32,
	target: u32, // What it points at, holds or names; `NO_TYPE` for none
	count:  u32, // Members, enumerators, or an array's length
	first:  u32, // Its first member row
	enc:    u32, // A base type's DWARF encoding
}

Scope :: struct {
	low, high: u64,
	parent:    u32,
	name:      string,
	first:     u32,
	nvars:     u32,
}

Var :: struct {
	name:      string,
	type:      u32,
	kind:      Loc_Kind,
	reg:       u32,
	offset:    i64,
	low, high: u64,
}

type_row :: proc "contextless" (d: ^Debug, i: int) -> (t: Type, ok: bool) {
	if i < 0 || i >= count(d, .Types) {
		return {}, false
	}
	at := entry_at(d, .Types, i)
	t.kind = Type_Kind(u32at(d.data, at))
	t.name = str(d, u32at(d.data, at + 4))
	t.size = u32at(d.data, at + 8)
	t.target = u32at(d.data, at + 12)
	t.count = u32at(d.data, at + 16)
	t.first = u32at(d.data, at + 20)
	t.enc = u32at(d.data, at + 24)
	return t, true
}

// type_named finds a type by its full name, the first of that name. A
// linear scan: the table is small, and a name lookup is a person typing.
type_named :: proc "contextless" (d: ^Debug, name: string) -> (index: int, ok: bool) {
	for i in 0 ..< count(d, .Types) {
		if str(d, u32at(d.data, entry_at(d, .Types, i) + 4)) == name {
			return i, true
		}
	}
	return -1, false
}

// type_resolved follows typedefs to the type they name.
type_resolved :: proc "contextless" (d: ^Debug, i: int) -> (t: Type, index: int, ok: bool) {
	index = i
	for _ in 0 ..< 8 {
		t, ok = type_row(d, index)
		if !ok {
			return {}, -1, false
		}
		if t.kind != .Typedef || t.target == NO_TYPE {
			return t, index, true
		}
		index = int(t.target)
	}
	return t, index, true
}

member_row :: proc "contextless" (d: ^Debug, i: int) -> (name: string, type: u32, offset: u64, ok: bool) {
	if i < 0 || i >= count(d, .Members) {
		return "", NO_TYPE, 0, false
	}
	at := entry_at(d, .Members, i)
	return str(d, u32at(d.data, at)), u32at(d.data, at + 4), u64at(d.data, at + 8), true
}

scope_row :: proc "contextless" (d: ^Debug, i: int) -> (s: Scope, ok: bool) {
	if i < 0 || i >= count(d, .Scopes) {
		return {}, false
	}
	at := entry_at(d, .Scopes, i)
	s.low = u64at(d.data, at)
	s.high = u64at(d.data, at + 8)
	s.parent = u32at(d.data, at + 16)
	s.name = str(d, u32at(d.data, at + 20))
	s.first = u32at(d.data, at + 24)
	s.nvars = u32at(d.data, at + 28)
	return s, true
}

// scope_at answers the innermost scope an address is inside. Of the rows
// that cover it, that is the one that starts last and, at a tie, ends
// first. The unit's own scope covers everything, so an address in no
// procedure answers it.
scope_at :: proc "contextless" (d: ^Debug, addr: u64) -> (i: int, ok: bool) {
	best := -1
	best_low, best_high := u64(0), u64(0)
	i = last_at_most(d, .Scopes, addr)
	for i >= 0 {
		s, _ := scope_row(d, i)
		if addr >= s.low && addr < s.high {
			if best < 0 || s.low > best_low || (s.low == best_low && s.high < best_high) {
				best, best_low, best_high = i, s.low, s.high
			}
		}
		// Rows start in order. So once a row starts more than a large
		// procedure's length before the address, nothing earlier covers
		// it but a unit's row, and the first row is one.
		if s.low + (1 << 20) < addr && i != 0 {
			i = 0
			continue
		}
		i -= 1
	}
	return best, best >= 0
}

var_row :: proc "contextless" (d: ^Debug, i: int) -> (v: Var, ok: bool) {
	if i < 0 || i >= count(d, .Vars) {
		return {}, false
	}
	at := entry_at(d, .Vars, i)
	v.name = str(d, u32at(d.data, at))
	v.type = u32at(d.data, at + 4)
	v.kind = Loc_Kind(u32at(d.data, at + 8))
	v.reg = u32at(d.data, at + 12)
	v.offset = i64(u64at(d.data, at + 16))
	v.low = u64at(d.data, at + 24)
	v.high = u64at(d.data, at + 32)
	return v, true
}

// var_holds says whether a variable row is the one for an address: a row
// with no range holds everywhere.
var_holds :: proc "contextless" (v: Var, addr: u64) -> bool {
	return (v.low == 0 && v.high == 0) || (addr >= v.low && addr < v.high)
}

/*
var_at finds a variable by name as seen from an address. The innermost
scope is searched first, then each scope outward to the unit's globals,
then every unit's globals. Among the rows of one name, the one that holds
at the address wins. A name with rows that all hold elsewhere answers its
first row with the kind `Gone`. The caller can then still say the
variable exists and is not here.
*/
var_at :: proc "contextless" (d: ^Debug, addr: u64, name: string) -> (v: Var, ok: bool) {
	scope, found := scope_at(d, addr)
	if !found {
		return {}, false
	}
	for _ in 0 ..< 64 {
		s, sok := scope_row(d, scope)
		if !sok {
			break
		}
		seen := false
		fallback: Var
		for i in int(s.first) ..< int(s.first + s.nvars) {
			row, _ := var_row(d, i)
			if row.name != name {
				continue
			}
			if var_holds(row, addr) {
				return row, true
			}
			if !seen {
				fallback = row
				seen = true
			}
		}
		if seen {
			fallback.kind = .Gone
			return fallback, true
		}
		if s.parent == NO_SCOPE {
			break
		}
		scope = int(s.parent)
	}
	// Past the chain, every unit's globals. A program built at `-o:none`
	// is one object per package, and the compiler then keeps every global
	// of the program in the first unit, apart from the procedures that use
	// them. The unit rows hold everywhere, so they sort first.
	for i in 0 ..< count(d, .Scopes) {
		s, sok := scope_row(d, i)
		if !sok || s.parent != NO_SCOPE || s.low != 0 {
			break
		}
		for j in int(s.first) ..< int(s.first + s.nvars) {
			row, _ := var_row(d, j)
			if row.name == name {
				return row, true
			}
		}
	}
	return {}, false
}

// scope_proc answers the procedure a scope is in: the scope itself when it
// is one, or the nearest named scope above a block. The unit's row when
// nothing named is above.
scope_proc :: proc "contextless" (d: ^Debug, i: int) -> (index: int, s: Scope, ok: bool) {
	index = i
	for _ in 0 ..< 64 {
		s, ok = scope_row(d, index)
		if !ok {
			return -1, {}, false
		}
		if len(s.name) > 0 || s.parent == NO_SCOPE {
			return index, s, true
		}
		index = int(s.parent)
	}
	return index, s, true
}

// dis_index answers the row of the instruction at or before `addr`, for a
// listing around it, and dis_row answers one row.
dis_index :: proc "contextless" (d: ^Debug, addr: u64) -> (i: int, ok: bool) {
	i = last_at_most(d, .Dis, addr)
	return i, i >= 0
}

dis_row :: proc "contextless" (d: ^Debug, i: int) -> (addr: u64, text: string, ok: bool) {
	if i < 0 || i >= count(d, .Dis) {
		return 0, "", false
	}
	at := entry_at(d, .Dis, i)
	return u64at(d.data, at), str(d, u32at(d.data, at + 8)), true
}

// line_first answers the lowest address a file's line was compiled to, for
// a breakpoint by `file:line`. The file matches by its tail, so a name
// without its directory finds it.
line_first :: proc "contextless" (d: ^Debug, file: string, line: u32) -> (addr: u64, ok: bool) {
	best := u64(0)
	found := false
	for i in 0 ..< count(d, .Lines) {
		at := entry_at(d, .Lines, i)
		if u32at(d.data, at + 12) != line {
			continue
		}
		path := file_path(d, int(u32at(d.data, at + 8)))
		if len(path) < len(file) || path[len(path) - len(file):] != file {
			continue
		}
		if len(path) > len(file) && path[len(path) - len(file) - 1] != '/' {
			continue
		}
		a := u64at(d.data, at)
		if !found || a < best {
			best, found = a, true
		}
	}
	return best, found
}

// proc_named finds a procedure by its name's tail, `add` for
// `debuggee::add`, and answers where it starts.
proc_named :: proc "contextless" (d: ^Debug, name: string) -> (low: u64, ok: bool) {
	if l, _, exact := lookup(d, name); exact {
		return l, true
	}
	for i in 0 ..< count(d, .Procs) {
		pname, plow, _, _ := proc_row(d, i)
		if len(pname) > len(name) + 2 && pname[len(pname) - len(name):] == name && pname[len(pname) - len(name) - 2:len(pname) - len(name)] == "::" {
			return plow, true
		}
	}
	return 0, false
}

// u64_of reads a little-endian word out of bytes, for a consumer that
// took them from a target's memory.
u64_of :: proc "contextless" (b: []u8) -> u64 {
	if len(b) < 8 {
		v := u64(0)
		for i in 0 ..< len(b) {
			v |= u64(b[i]) << (8 * u64(i))
		}
		return v
	}
	return u64at(b, 0)
}
