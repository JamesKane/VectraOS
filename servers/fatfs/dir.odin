/*
Directories: 32-byte entries, short names, and the long names before them.

A FAT directory is an array of 32-byte entries. One entry is a file: an
uppercase 8.3 name, an attribute byte, the first cluster and the size. A
name longer than that, or one with a case the 8.3 form cannot keep, is
spelled out in *long-name entries* placed before the file's own, thirteen
UTF-16 characters each, last piece first, each carrying a checksum of the
short name so a directory edited by something that never heard of long
names can be caught out. This file reads and writes both.

## Where a directory's bytes are

The root directory of a FAT12 or FAT16 volume is a fixed run of sectors
before the data region, with a fixed number of entries. Every other
directory -- and the FAT32 root -- is a cluster chain like a file's, and
grows by a cluster when its entries run out. `Dir` names either by its
first cluster, zero for the fixed root, and `slot` finds the sector and
offset of entry `i` in either, so nothing above this file knows which kind
it is reading.

## Names

Long names are UTF-16 on the disk and UTF-8 everywhere else in this
program. Matching is case-insensitive for ASCII, as FAT is: `Echo` and
`echo` are the same file, and a create that would make the second is an
`EEXIST`. A new file gets a long name whenever its name is not already a
valid uppercase 8.3 name, and a short name built the way Windows builds one:
the name uppercased and squeezed, cut to six characters, and `~n` for the
smallest `n` that no entry in the directory has yet.
*/
package fatfs

// Attribute bits.
ATTR_READ_ONLY :: u8(0x01)
ATTR_HIDDEN :: u8(0x02)
ATTR_SYSTEM :: u8(0x04)
ATTR_VOLUME :: u8(0x08)
ATTR_DIRECTORY :: u8(0x10)
ATTR_ARCHIVE :: u8(0x20)
ATTR_LONG_NAME :: u8(0x0F)

// The NT reserved byte's case flags, which a short-name-only writer uses
// to keep a lowercase name without a long-name entry.
NT_LOWER_BASE :: u8(0x08)
NT_LOWER_EXT :: u8(0x10)

ENTRY :: 32
LFN_CHARS :: 13
LFN_LAST :: u8(0x40)

// The longest name this program accepts, in bytes of UTF-8, and the most
// long-name entries that can take: 255 UTF-16 units is FAT's own limit.
NAME_MAX :: 255
LFN_MAX_ENTRIES :: 20

// A directory, named by its first cluster; zero is the FAT12/16 fixed root.
Dir :: distinct u32

// What one file's entries say, as this program reads them.
Entry :: struct {
	name:    string, // On the heap, UTF-8
	dir:     bool,
	attr:    u8,
	cluster: u32,
	size:    u32,
	slot:    int, // Index of the 8.3 entry
	nslots:  int, // Long-name entries before it, plus one
}

// -- Finding an entry's bytes ---------------------------------------------------

/*
Walk keeps the chain position of the last slot looked up, so a scan that
asks for slots in order steps the chain once per cluster rather than from
the start per entry.
*/
Walk :: struct {
	dir:         Dir,
	cluster:     u32, // The cluster holding `index`'s first slot
	first_index: int, // The slot index that cluster begins at
}

walk_start :: proc "contextless" (d: Dir) -> Walk {
	return Walk{dir = d, cluster = u32(d), first_index = 0}
}

@(private = "file")
slots_per_cluster :: proc "contextless" () -> int {
	return int(vol.cluster_bytes / ENTRY)
}

/*
slot locates entry `i`: the sector it is in and its offset within, through
the cache. `exists` is false past the end of the directory -- past the
fixed root's last entry, or past the last cluster of a chain -- and `ok` is
false on a disk error or a corrupt chain. `w` is advanced along the chain
and must be used with ascending `i` between resets.
*/
slot :: proc "contextless" (w: ^Walk, i: int) -> (bytes: []u8, sec: u32, exists: bool, ok: bool) #no_bounds_check {
	if w.dir == 0 && vol.kind != .FAT32 {
		if i < 0 || u32(i) >= vol.root_entries {
			return nil, 0, false, true
		}
		off := u32(i) * ENTRY
		sec = vol.root_sector + off / SECTOR
		s := sector(sec)
		if s == nil {
			return nil, 0, false, false
		}
		at := int(off % SECTOR)
		return s[at:at + ENTRY], sec, true, true
	}

	per := slots_per_cluster()
	if i < w.first_index {
		w.cluster = u32(w.dir)
		w.first_index = 0
	}
	for i >= w.first_index + per {
		next, end, good := next_cluster(w.cluster)
		if !good {
			return nil, 0, false, false
		}
		if end {
			return nil, 0, false, true
		}
		w.cluster = next
		w.first_index += per
	}
	within := u32(i - w.first_index) * ENTRY
	sec = u32(cluster_offset(w.cluster) / SECTOR) + within / SECTOR
	s := sector(sec)
	if s == nil {
		return nil, 0, false, false
	}
	at := int(within % SECTOR)
	return s[at:at + ENTRY], sec, true, true
}

// grow_dir adds a cluster to a chain directory so `slot` has more to find,
// zeroed, so its entries read as end-of-directory until written.
grow_dir :: proc(w: ^Walk) -> bool {
	if w.dir == 0 && vol.kind != .FAT32 {
		return false // The fixed root cannot grow.
	}
	// Find the chain's last cluster.
	last := w.cluster
	for {
		next, end, ok := next_cluster(last)
		if !ok {
			return false
		}
		if end {
			break
		}
		last = next
	}
	fresh, ok := alloc_cluster(last)
	if !ok {
		return false
	}
	return zero_cluster(fresh)
}

// -- Reading entries ------------------------------------------------------------

@(private = "file")
le16 :: proc "contextless" (b: []u8) -> u32 #no_bounds_check {
	return u32(b[0]) | u32(b[1]) << 8
}

@(private = "file")
le32 :: proc "contextless" (b: []u8) -> u32 #no_bounds_check {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private = "file")
put16 :: proc "contextless" (b: []u8, v: u32) #no_bounds_check {
	b[0] = u8(v)
	b[1] = u8(v >> 8)
}

@(private = "file")
put32 :: proc "contextless" (b: []u8, v: u32) #no_bounds_check {
	b[0] = u8(v)
	b[1] = u8(v >> 8)
	b[2] = u8(v >> 16)
	b[3] = u8(v >> 24)
}

// entry_cluster reads the first cluster out of an 8.3 entry, both halves on
// FAT32 and the low one otherwise, where the high half is reserved.
entry_cluster :: proc "contextless" (e: []u8) -> u32 #no_bounds_check {
	lo := le16(e[26:])
	if vol.kind == .FAT32 {
		return le16(e[20:]) << 16 | lo
	}
	return lo
}

@(private = "file")
set_entry_cluster :: proc "contextless" (e: []u8, c: u32) #no_bounds_check {
	put16(e[26:], c & 0xFFFF)
	if vol.kind == .FAT32 {
		put16(e[20:], c >> 16)
	} else {
		put16(e[20:], 0)
	}
}

// checksum is the long-name checksum of an 11-byte short name.
@(private = "file")
checksum :: proc "contextless" (short: []u8) -> u8 #no_bounds_check {
	sum := u8(0)
	for i in 0 ..< 11 {
		sum = (sum >> 1 | sum << 7) + short[i]
	}
	return sum
}

/*
Scan reads a directory entry by entry. Each call to `scan_next` answers the
next file, with its long name assembled from the entries before it, or
`more` false at the end. Volume labels and orphaned long-name pieces are
skipped, as are `.` and `..`, which the namespace handles itself.
*/
Scan :: struct {
	w:     Walk,
	index: int,
}

scan_start :: proc "contextless" (d: Dir) -> Scan {
	return Scan{w = walk_start(d)}
}

// scan_next fills `e` with the next file's entry. `e.name` is on the heap
// and the caller owns it. `more` false is the end; `ok` false is an error.
scan_next :: proc(s: ^Scan, e: ^Entry) -> (more: bool, ok: bool) #no_bounds_check {
	pieces: [LFN_MAX_ENTRIES][LFN_CHARS]u16
	have := 0 // Long-name pieces collected, counted from the last
	want_sum := u8(0)
	first_slot := -1

	for {
		bytes, _, exists, good := slot(&s.w, s.index)
		if !good {
			return false, false
		}
		if !exists || bytes[0] == 0 {
			return false, true
		}
		i := s.index
		s.index += 1

		if bytes[0] == 0xE5 {
			have = 0
			first_slot = -1
			continue
		}
		attr := bytes[11]
		if attr & ATTR_LONG_NAME == ATTR_LONG_NAME {
			seq := bytes[0]
			n := int(seq & 0x1F)
			if n == 0 || n > LFN_MAX_ENTRIES {
				have = 0
				first_slot = -1
				continue
			}
			if seq & LFN_LAST != 0 {
				have = n
				want_sum = bytes[13]
				first_slot = i
			} else if have == 0 || bytes[13] != want_sum {
				have = 0
				first_slot = -1
				continue
			}
			p := &pieces[n - 1]
			for k in 0 ..< 5 {
				p[k] = u16(le16(bytes[1 + 2 * k:]))
			}
			for k in 0 ..< 6 {
				p[5 + k] = u16(le16(bytes[14 + 2 * k:]))
			}
			p[11] = u16(le16(bytes[28:]))
			p[12] = u16(le16(bytes[30:]))
			continue
		}
		if attr & ATTR_VOLUME != 0 {
			have = 0
			first_slot = -1
			continue
		}
		if bytes[0] == '.' {
			// `.` and `..` are the namespace's business.
			have = 0
			first_slot = -1
			continue
		}

		// An 8.3 entry: the file.
		e.attr = attr
		e.dir = attr & ATTR_DIRECTORY != 0
		e.cluster = entry_cluster(bytes)
		e.size = le32(bytes[28:])
		named := false
		if have > 0 && checksum(bytes[:11]) == want_sum && first_slot >= 0 {
			e.name = long_name(pieces[:have])
			e.slot = i
			e.nslots = i - first_slot + 1
			named = e.name != ""
		}
		if !named {
			e.name = short_name(bytes)
			e.slot = i
			e.nslots = 1
		}
		return true, true
	}
}

// long_name joins collected pieces into a UTF-8 string on the heap, stopping
// at the first NUL or 0xFFFF pad.
@(private = "file")
long_name :: proc(pieces: [][LFN_CHARS]u16) -> string {
	out := make([dynamic]u8, 0, len(pieces) * LFN_CHARS * 3)
	for p in pieces {
		for u in p {
			if u == 0 || u == 0xFFFF {
				return string(out[:])
			}
			put_utf8(&out, rune(u))
		}
	}
	return string(out[:])
}

// short_name spells an 8.3 entry as `base.ext`, lowercased where the NT byte
// says the writer meant it so, on the heap.
@(private = "file")
short_name :: proc(e: []u8) -> string #no_bounds_check {
	out := make([dynamic]u8, 0, 13)
	nt := e[12]
	base_end := 8
	for base_end > 0 && e[base_end - 1] == ' ' {
		base_end -= 1
	}
	for i in 0 ..< base_end {
		c := e[i]
		if i == 0 && c == 0x05 {
			c = 0xE5 // KANJI escape for a name that begins with E5
		}
		if nt & NT_LOWER_BASE != 0 {
			c = lower(c)
		}
		append(&out, c)
	}
	ext_end := 11
	for ext_end > 8 && e[ext_end - 1] == ' ' {
		ext_end -= 1
	}
	if ext_end > 8 {
		append(&out, '.')
		for i in 8 ..< ext_end {
			c := e[i]
			if nt & NT_LOWER_EXT != 0 {
				c = lower(c)
			}
			append(&out, c)
		}
	}
	return string(out[:])
}

@(private = "file")
lower :: proc "contextless" (c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

@(private = "file")
upper :: proc "contextless" (c: u8) -> u8 {
	if c >= 'a' && c <= 'z' {
		return c - 32
	}
	return c
}

// names_equal compares two names the way FAT does: case-insensitively for
// ASCII letters, exactly otherwise.
names_equal :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if lower(a[i]) != lower(b[i]) {
			return false
		}
	}
	return true
}

// -- UTF-8 and UTF-16 -----------------------------------------------------------

@(private = "file")
put_utf8 :: proc(out: ^[dynamic]u8, r: rune) {
	switch {
	case r < 0x80:
		append(out, u8(r))
	case r < 0x800:
		append(out, u8(0xC0 | r >> 6), u8(0x80 | r & 0x3F))
	case:
		append(out, u8(0xE0 | r >> 12), u8(0x80 | (r >> 6) & 0x3F), u8(0x80 | r & 0x3F))
	}
}

// next_rune decodes one UTF-8 character at `s[i:]`, answering it and how
// many bytes it took; a malformed sequence is one byte of U+FFFD.
@(private = "file")
next_rune :: proc "contextless" (s: string, i: int) -> (r: rune, n: int) {
	c := s[i]
	switch {
	case c < 0x80:
		return rune(c), 1
	case c & 0xE0 == 0xC0 && i + 1 < len(s):
		return rune(c & 0x1F) << 6 | rune(s[i + 1] & 0x3F), 2
	case c & 0xF0 == 0xE0 && i + 2 < len(s):
		return rune(c & 0x0F) << 12 | rune(s[i + 1] & 0x3F) << 6 | rune(s[i + 2] & 0x3F), 3
	}
	return 0xFFFD, 1
}

// -- Writing entries ------------------------------------------------------------

// valid_name accepts what FAT accepts in a long name, less the characters a
// Plan 9 namespace could not carry anyway.
valid_name :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > NAME_MAX || name == "." || name == ".." {
		return false
	}
	for i in 0 ..< len(name) {
		switch name[i] {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0:
			return false
		}
		if name[i] < 0x20 {
			return false
		}
	}
	return true
}

/*
fits_short reports whether `name` is already a valid uppercase 8.3 name, so
an entry for it needs no long-name pieces. Any lowercase letter fails it:
the NT case bits exist, but a long-name entry is what every other writer
makes and what every reader expects.
*/
@(private = "file")
fits_short :: proc "contextless" (name: string) -> bool {
	dot := -1
	for i in 0 ..< len(name) {
		if name[i] == '.' {
			if dot >= 0 {
				return false
			}
			dot = i
		}
	}
	base := dot < 0 ? name : name[:dot]
	ext := dot < 0 ? "" : name[dot + 1:]
	if len(base) == 0 || len(base) > 8 || len(ext) > 3 {
		return false
	}
	if dot >= 0 && len(ext) == 0 {
		return false
	}
	for i in 0 ..< len(name) {
		if !short_char(name[i]) && name[i] != '.' {
			return false
		}
	}
	return true
}

// short_char is a character that may stand in an 8.3 name as it is.
@(private = "file")
short_char :: proc "contextless" (c: u8) -> bool {
	switch {
	case c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	case c == '$', c == '%', c == '\'', c == '-', c == '_', c == '@', c == '~', c == '`', c == '!', c == '(', c == ')', c == '{', c == '}', c == '^', c == '#', c == '&':
		return true
	}
	return false
}

/*
make_short builds the 11-byte short name for `name` in `out`: the base
uppercased and squeezed of what a short name cannot hold, cut to six
characters and given `~n` when a long name is needed at all, the extension
the same to three. `n` is the caller's, who tries 1, 2, 3... until the
directory has no entry with the result.
*/
@(private = "file")
make_short :: proc "contextless" (name: string, n: int, out: []u8) #no_bounds_check {
	for i in 0 ..< 11 {
		out[i] = ' '
	}
	dot := -1
	for i := len(name) - 1; i >= 0; i -= 1 {
		if name[i] == '.' {
			dot = i
			break
		}
	}
	base := dot < 0 ? name : name[:dot]
	ext := dot < 0 ? "" : name[dot + 1:]

	if fits_short(name) {
		for i in 0 ..< len(base) {
			out[i] = base[i]
		}
		for i in 0 ..< len(ext) {
			out[8 + i] = ext[i]
		}
		return
	}

	// Squeeze the base: uppercase what fits, drop what does not, stop at six
	// so the tail fits.
	bi := 0
	for i in 0 ..< len(base) {
		if bi >= 6 {
			break
		}
		c := upper(base[i])
		if c == ' ' || c == '.' {
			continue
		}
		if !short_char(c) {
			c = '_'
		}
		out[bi] = c
		bi += 1
	}
	if bi == 0 {
		out[0] = '_'
		bi = 1
	}
	// The tail: ~n, taking as many digits as n needs.
	digits: [8]u8
	nd := 0
	v := n
	for {
		digits[nd] = u8('0' + v % 10)
		nd += 1
		v /= 10
		if v == 0 {
			break
		}
	}
	room := 8 - (nd + 1)
	if bi > room {
		bi = room
	}
	out[bi] = '~'
	for i in 0 ..< nd {
		out[bi + 1 + i] = digits[nd - 1 - i]
	}

	ei := 0
	for i in 0 ..< len(ext) {
		if ei >= 3 {
			break
		}
		c := upper(ext[i])
		if c == ' ' || c == '.' {
			continue
		}
		if !short_char(c) {
			c = '_'
		}
		out[8 + ei] = c
		ei += 1
	}
}

// short_taken reports whether any 8.3 entry in the directory has `short`.
@(private = "file")
short_taken :: proc "contextless" (d: Dir, short: []u8) -> (taken: bool, ok: bool) #no_bounds_check {
	w := walk_start(d)
	for i := 0;; i += 1 {
		bytes, _, exists, good := slot(&w, i)
		if !good {
			return false, false
		}
		if !exists || bytes[0] == 0 {
			return false, true
		}
		if bytes[0] == 0xE5 || bytes[11] & ATTR_LONG_NAME == ATTR_LONG_NAME {
			continue
		}
		same := true
		for k in 0 ..< 11 {
			if bytes[k] != short[k] {
				same = false
				break
			}
		}
		if same {
			return true, true
		}
	}
}

// utf16_len is how many UTF-16 units `name` takes, which is how many
// characters its long-name entries must carry.
@(private = "file")
utf16_len :: proc "contextless" (name: string) -> int {
	n := 0
	for i := 0; i < len(name); {
		_, w := next_rune(name, i)
		i += w
		n += 1
	}
	return n
}

/*
find_free finds `need` consecutive free entries -- deleted, or past the end
-- and answers the index of the first, growing a chain directory by a
cluster when it has to. The fixed root cannot grow and answers false when
full.
*/
@(private = "file")
find_free :: proc(d: Dir, need: int) -> (first: int, ok: bool) #no_bounds_check {
	w := walk_start(d)
	run := 0
	start := 0
	for i := 0;; i += 1 {
		bytes, _, exists, good := slot(&w, i)
		if !good {
			return 0, false
		}
		if !exists {
			// Past the end of the chain: grow it and keep counting the run,
			// which continues into the fresh zeroed cluster.
			if !grow_dir(&w) {
				return 0, false
			}
			i -= 1
			continue
		}
		free := bytes[0] == 0 || bytes[0] == 0xE5
		if free {
			if run == 0 {
				start = i
			}
			run += 1
			if run == need {
				return start, true
			}
		} else {
			run = 0
		}
	}
}

/*
add_entry writes a new file's entries into directory `d`: long-name pieces
first, last piece first, then the 8.3 entry with the attributes, first
cluster and size given. Answers where the 8.3 entry landed and how many
entries the file took, for the record above this file to keep.
*/
add_entry :: proc(d: Dir, name: string, attr: u8, cluster: u32, size: u32) -> (e: Entry, ok: bool) #no_bounds_check {
	short: [11]u8
	long := !fits_short(name)
	if long {
		for n := 1;; n += 1 {
			make_short(name, n, short[:])
			taken, good := short_taken(d, short[:])
			if !good {
				return {}, false
			}
			if !taken {
				break
			}
			if n > 999_999 {
				return {}, false
			}
		}
	} else {
		make_short(name, 1, short[:])
		taken, good := short_taken(d, short[:])
		if !good || taken {
			return {}, false
		}
	}

	pieces := 0
	if long {
		pieces = (utf16_len(name) + LFN_CHARS - 1) / LFN_CHARS
		if pieces > LFN_MAX_ENTRIES {
			return {}, false
		}
	}
	need := pieces + 1
	first, found := find_free(d, need)
	if !found {
		return {}, false
	}

	// The long-name pieces, from the last piece down to the first, so the
	// piece nearest the 8.3 entry is number one.
	w := walk_start(d)
	touched: Touched
	if long {
		units: [LFN_MAX_ENTRIES * LFN_CHARS]u16
		n := 0
		for i := 0; i < len(name); {
			r, wd := next_rune(name, i)
			i += wd
			units[n] = u16(r)
			n += 1
		}
		// Terminate with NUL, pad with 0xFFFF.
		total := pieces * LFN_CHARS
		if n < total {
			units[n] = 0
			for k in n + 1 ..< total {
				units[k] = 0xFFFF
			}
		}
		sum := checksum(short[:])
		for p := pieces; p >= 1; p -= 1 {
			idx := first + (pieces - p)
			bytes, sec, exists, good := slot(&w, idx)
			if !good || !exists {
				return {}, false
			}
			for k in 0 ..< ENTRY {
				bytes[k] = 0
			}
			seq := u8(p)
			if p == pieces {
				seq |= LFN_LAST
			}
			bytes[0] = seq
			bytes[11] = ATTR_LONG_NAME
			bytes[13] = sum
			base := (p - 1) * LFN_CHARS
			for k in 0 ..< 5 {
				put16(bytes[1 + 2 * k:], u32(units[base + k]))
			}
			for k in 0 ..< 6 {
				put16(bytes[14 + 2 * k:], u32(units[base + 5 + k]))
			}
			put16(bytes[28:], u32(units[base + 11]))
			put16(bytes[30:], u32(units[base + 12]))
			touch(&touched, sec)
		}
	}

	// The 8.3 entry.
	idx := first + pieces
	bytes, sec, exists, good := slot(&w, idx)
	if !good || !exists {
		return {}, false
	}
	for k in 0 ..< ENTRY {
		bytes[k] = 0
	}
	for k in 0 ..< 11 {
		bytes[k] = short[k]
	}
	if bytes[0] == 0xE5 {
		bytes[0] = 0x05
	}
	bytes[11] = attr
	set_entry_cluster(bytes, cluster)
	put32(bytes[28:], size)
	// A fixed date, 1980-01-01, for want of a clock.
	put16(bytes[16:], 0x0021)
	put16(bytes[18:], 0x0021)
	put16(bytes[24:], 0x0021)
	touch(&touched, sec)

	// Every sector once, after every entry is in place, so a host watching
	// the volume never sees long-name pieces without the file they name.
	for i in 0 ..< touched.count {
		if !sector_flush(touched.sectors[i]) {
			return {}, false
		}
	}

	e = Entry {
		name    = clone_string(name),
		dir     = attr & ATTR_DIRECTORY != 0,
		attr    = attr,
		cluster = cluster,
		size    = size,
		slot    = idx,
		nslots  = need,
	}
	return e, true
}

// Touched collects the sectors an entry's pieces landed in: a file's entries
// span three sectors at most, and each is written once.
Touched :: struct {
	sectors: [4]u32,
	count:   int,
}

@(private = "file")
touch :: proc "contextless" (t: ^Touched, sec: u32) #no_bounds_check {
	for i in 0 ..< t.count {
		if t.sectors[i] == sec {
			return
		}
	}
	if t.count < len(t.sectors) {
		t.sectors[t.count] = sec
		t.count += 1
	}
}

clone_string :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

// update_entry rewrites an existing file's first cluster and size.
update_entry :: proc(d: Dir, e: ^Entry) -> bool #no_bounds_check {
	w := walk_start(d)
	bytes, sec, exists, good := slot(&w, e.slot)
	if !good || !exists {
		return false
	}
	set_entry_cluster(bytes, e.cluster)
	put32(bytes[28:], e.size)
	bytes[11] = e.attr
	return sector_flush(sec)
}

// remove_entry marks a file's entries deleted, long-name pieces included.
remove_entry :: proc(d: Dir, e: ^Entry) -> bool #no_bounds_check {
	w := walk_start(d)
	for i := e.slot - e.nslots + 1; i <= e.slot; i += 1 {
		bytes, sec, exists, good := slot(&w, i)
		if !good || !exists {
			return false
		}
		bytes[0] = 0xE5
		if !sector_flush(sec) {
			return false
		}
	}
	return true
}

// dir_empty reports whether a chain directory holds nothing but `.` and `..`.
dir_empty :: proc(d: Dir) -> (empty: bool, ok: bool) #no_bounds_check {
	w := walk_start(d)
	for i := 0;; i += 1 {
		bytes, _, exists, good := slot(&w, i)
		if !good {
			return false, false
		}
		if !exists || bytes[0] == 0 {
			return true, true
		}
		if bytes[0] == 0xE5 || bytes[0] == '.' {
			continue
		}
		if bytes[11] & ATTR_LONG_NAME == ATTR_LONG_NAME {
			continue
		}
		return false, true
	}
}

/*
init_dir writes `.` and `..` into a fresh directory cluster, which
`zero_cluster` already emptied. `..` names the parent's first cluster, and
zero when the parent is the root, as the specification says even on FAT32.
*/
init_dir :: proc(c: u32, parent: Dir) -> bool #no_bounds_check {
	w := walk_start(Dir(c))
	parent_cluster := u32(parent)
	if vol.kind == .FAT32 && parent_cluster == vol.root_cluster {
		parent_cluster = 0
	}
	for i in 0 ..< 2 {
		bytes, sec, exists, good := slot(&w, i)
		if !good || !exists {
			return false
		}
		for k in 0 ..< ENTRY {
			bytes[k] = 0
		}
		for k in 0 ..< 11 {
			bytes[k] = ' '
		}
		bytes[0] = '.'
		if i == 1 {
			bytes[1] = '.'
		}
		bytes[11] = ATTR_DIRECTORY
		set_entry_cluster(bytes, i == 0 ? c : parent_cluster)
		if !sector_flush(sec) {
			return false
		}
	}
	return true
}
