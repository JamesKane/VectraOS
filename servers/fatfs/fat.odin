/*
The volume: its geometry, its allocation table, and its sectors.

A FAT volume is three regions in a row. The reserved sectors, of which the
first is the BIOS parameter block that says where everything else is. The
file allocation table, one entry per cluster, each entry naming the next
cluster of the same file or an end mark, kept in two copies. And the data
region, clusters of a few sectors each, numbered from two. FAT12, FAT16 and
FAT32 differ in the width of a table entry and in where the root directory
lives: a fixed run of sectors before the data on the first two, a cluster
chain like any directory on the third. Everything else is the same, and this
file is where the difference is absorbed.

## Sectors through a cache

Table and directory sectors are read through a small direct-mapped cache
and written through it, straight to the disk. A write of one table entry
touches a byte or two of a sector that will be touched again a moment later,
and a directory listing reads the same sectors a walk just read. The cache
is small because the working set is: the table's first sectors, the
directory being worked in. File data goes around it, whole clusters at a
time, because a file read once is not a file read again soon.

Write-through rather than write-back because the host may be looking. The
volume is QEMU's view of a directory, and a change the host cannot see
until a flush is a change that may never reach it.
*/
package fatfs

import "vsys:libuser"

SECTOR :: 512

// A direct-mapped cache of table and directory sectors.
CACHE_SECTORS :: 64

Kind :: enum {
	FAT12,
	FAT16,
	FAT32,
}

Volume :: struct {
	fd:            int,
	kind:          Kind,
	sectors_per_cluster: u32,
	cluster_bytes: u32,
	reserved:      u32, // Sectors before the first table
	fats:          u32, // Copies of the table
	fat_sectors:   u32, // Sectors in one copy
	root_entries:  u32, // FAT12/16: entries in the fixed root directory
	root_sector:   u32, // FAT12/16: where it starts
	root_sectors:  u32, // FAT12/16: how long it is
	root_cluster:  u32, // FAT32: the root's first cluster
	data_sector:   u32, // Where cluster 2 starts
	clusters:      u32, // Data clusters, so the last is clusters + 1
	free_clusters: u32, // Counted at mount, kept after
	next_free:     u32, // Where the next allocation starts looking

	cache:         [CACHE_SECTORS]Cached,
}

Cached :: struct {
	sector: u32,
	valid:  bool,
	data:   [SECTOR]u8,
}

vol: Volume

// End-of-chain and bad-cluster marks, per kind. A table entry at or above
// END is the end of a chain.
END12 :: u32(0xFF8)
END16 :: u32(0xFFF8)
END32 :: u32(0x0FFF_FFF8)

// The mark this driver writes at the end of a chain it makes.
end_mark :: proc "contextless" () -> u32 {
	switch vol.kind {
	case .FAT12:
		return 0xFFF
	case .FAT16:
		return 0xFFFF
	case .FAT32:
		return 0x0FFF_FFFF
	}
	return 0xFFFF
}

// is_end reports whether a table entry ends a chain.
is_end :: proc "contextless" (v: u32) -> bool {
	switch vol.kind {
	case .FAT12:
		return v >= END12
	case .FAT16:
		return v >= END16
	case .FAT32:
		return v >= END32
	}
	return true
}

// -- The disk, by byte ----------------------------------------------------------

// read_at fills `buf` from byte `off` of the volume, looping over short
// answers. False if the device stopped short.
read_at :: proc "contextless" (off: u64, buf: []u8) -> bool {
	done := 0
	for done < len(buf) {
		n := libuser.pread(vol.fd, buf[done:], off + u64(done))
		if n <= 0 {
			return false
		}
		done += int(n)
	}
	return true
}

write_at :: proc "contextless" (off: u64, data: []u8) -> bool {
	done := 0
	for done < len(data) {
		n := libuser.pwrite(vol.fd, data[done:], off + u64(done))
		if n <= 0 {
			return false
		}
		done += int(n)
	}
	return true
}

// -- The sector cache -----------------------------------------------------------

// sector reads sector `s` through the cache and answers its bytes, which
// stay valid until the next call that may evict them. Nil on a read error.
sector :: proc "contextless" (s: u32) -> []u8 {
	c := &vol.cache[s % CACHE_SECTORS]
	if !c.valid || c.sector != s {
		if !read_at(u64(s) * SECTOR, c.data[:]) {
			c.valid = false
			return nil
		}
		c.sector = s
		c.valid = true
	}
	return c.data[:]
}

// sector_flush writes the cached sector `s` back to the disk. The caller
// changed the bytes `sector` handed it and calls this before anything else
// could evict them.
sector_flush :: proc "contextless" (s: u32) -> bool {
	c := &vol.cache[s % CACHE_SECTORS]
	if !c.valid || c.sector != s {
		return false
	}
	return write_at(u64(s) * SECTOR, c.data[:])
}

// -- Bring-up -------------------------------------------------------------------

@(private = "file")
le16 :: proc "contextless" (b: []u8) -> u32 #no_bounds_check {
	return u32(b[0]) | u32(b[1]) << 8
}

@(private = "file")
le32 :: proc "contextless" (b: []u8) -> u32 #no_bounds_check {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

/*
mount_volume reads the BIOS parameter block and lays the volume out.

The kind is decided by the cluster count, as the specification says and not
by the label the formatter wrote, because the label is advisory and the
count is what the table's width follows from. Fewer than 4085 clusters is
FAT12, fewer than 65525 is FAT16, and the rest is FAT32.
*/
mount_volume :: proc(fd: int) -> (ok: bool, why: string) #no_bounds_check {
	vol.fd = fd
	b := sector(0)
	if b == nil {
		return false, "cannot read the boot sector"
	}
	if b[510] != 0x55 || b[511] != 0xAA {
		return false, "no boot signature"
	}
	bytes_per_sector := le16(b[11:])
	if bytes_per_sector != SECTOR {
		return false, "sector size is not 512"
	}
	spc := u32(b[13])
	if spc == 0 || spc & (spc - 1) != 0 || spc > 128 {
		return false, "bad sectors per cluster"
	}
	vol.sectors_per_cluster = spc
	vol.cluster_bytes = spc * SECTOR
	vol.reserved = le16(b[14:])
	vol.fats = u32(b[16])
	vol.root_entries = le16(b[17:])
	total := le16(b[19:])
	if total == 0 {
		total = le32(b[32:])
	}
	vol.fat_sectors = le16(b[22:])
	if vol.fat_sectors == 0 {
		vol.fat_sectors = le32(b[36:])
	}
	if vol.reserved == 0 || vol.fats == 0 || vol.fat_sectors == 0 || total == 0 {
		return false, "bad parameter block"
	}

	vol.root_sectors = (vol.root_entries * 32 + SECTOR - 1) / SECTOR
	vol.root_sector = vol.reserved + vol.fats * vol.fat_sectors
	vol.data_sector = vol.root_sector + vol.root_sectors
	if vol.data_sector >= total {
		return false, "no data region"
	}
	vol.clusters = (total - vol.data_sector) / spc

	switch {
	case vol.clusters < 4085:
		vol.kind = .FAT12
	case vol.clusters < 65525:
		vol.kind = .FAT16
	case:
		vol.kind = .FAT32
		vol.root_cluster = le32(b[44:])
		if vol.root_cluster < 2 {
			return false, "bad root cluster"
		}
	}

	// Count the free clusters once. Every allocation and release keeps the
	// count after, so `statfs` never walks the table again.
	vol.free_clusters = 0
	for c := u32(2); c < vol.clusters + 2; c += 1 {
		v, got := fat_get(c)
		if !got {
			return false, "cannot read the table"
		}
		if v == 0 {
			vol.free_clusters += 1
		}
	}
	vol.next_free = 2
	return true, ""
}

kind_name :: proc "contextless" () -> string {
	switch vol.kind {
	case .FAT12:
		return "FAT12"
	case .FAT16:
		return "FAT16"
	case .FAT32:
		return "FAT32"
	}
	return "FAT"
}

// -- The allocation table -------------------------------------------------------

/*
fat_get reads cluster `c`'s table entry from the first copy.

FAT12 packs two entries into three bytes, so an entry may straddle a sector
boundary; the two bytes are read one at a time for that reason. FAT16 and
FAT32 entries are aligned and read whole. A FAT32 entry keeps its top four
bits out of the value, as the specification reserves them.
*/
fat_get :: proc "contextless" (c: u32) -> (v: u32, ok: bool) #no_bounds_check {
	if c >= vol.clusters + 2 {
		return 0, false
	}
	switch vol.kind {
	case .FAT12:
		off := u32(c) + u32(c) / 2
		lo, ok1 := fat_byte(off)
		hi, ok2 := fat_byte(off + 1)
		if !ok1 || !ok2 {
			return 0, false
		}
		raw := u32(lo) | u32(hi) << 8
		if c & 1 != 0 {
			return raw >> 4, true
		}
		return raw & 0xFFF, true
	case .FAT16:
		off := c * 2
		s := sector(vol.reserved + off / SECTOR)
		if s == nil {
			return 0, false
		}
		return le16(s[off % SECTOR:]), true
	case .FAT32:
		off := c * 4
		s := sector(vol.reserved + off / SECTOR)
		if s == nil {
			return 0, false
		}
		return le32(s[off % SECTOR:]) & 0x0FFF_FFFF, true
	}
	return 0, false
}

@(private = "file")
fat_byte :: proc "contextless" (off: u32) -> (u8, bool) #no_bounds_check {
	s := sector(vol.reserved + off / SECTOR)
	if s == nil {
		return 0, false
	}
	return s[off % SECTOR], true
}

/*
fat_set writes cluster `c`'s entry into every copy of the table. The first
copy is written through the cache; the others are written straight to the
disk from the same bytes, because nothing reads them and caching them would
only cost slots.
*/
fat_set :: proc "contextless" (c: u32, v: u32) -> bool #no_bounds_check {
	if c >= vol.clusters + 2 {
		return false
	}
	switch vol.kind {
	case .FAT12:
		off := c + c / 2
		lo, ok1 := fat_byte(off)
		hi, ok2 := fat_byte(off + 1)
		if !ok1 || !ok2 {
			return false
		}
		raw := u32(lo) | u32(hi) << 8
		if c & 1 != 0 {
			raw = raw & 0x000F | (v & 0xFFF) << 4
		} else {
			raw = raw & 0xF000 | v & 0xFFF
		}
		if !fat_put_byte(off, u8(raw)) || !fat_put_byte(off + 1, u8(raw >> 8)) {
			return false
		}
		return true
	case .FAT16:
		off := c * 2
		sec := vol.reserved + off / SECTOR
		s := sector(sec)
		if s == nil {
			return false
		}
		s[off % SECTOR] = u8(v)
		s[off % SECTOR + 1] = u8(v >> 8)
		return flush_fat_sector(sec)
	case .FAT32:
		off := c * 4
		sec := vol.reserved + off / SECTOR
		s := sector(sec)
		if s == nil {
			return false
		}
		old := le32(s[off % SECTOR:]) & 0xF000_0000
		nv := old | v & 0x0FFF_FFFF
		s[off % SECTOR] = u8(nv)
		s[off % SECTOR + 1] = u8(nv >> 8)
		s[off % SECTOR + 2] = u8(nv >> 16)
		s[off % SECTOR + 3] = u8(nv >> 24)
		return flush_fat_sector(sec)
	}
	return false
}

@(private = "file")
fat_put_byte :: proc "contextless" (off: u32, b: u8) -> bool #no_bounds_check {
	sec := vol.reserved + off / SECTOR
	s := sector(sec)
	if s == nil {
		return false
	}
	s[off % SECTOR] = b
	return flush_fat_sector(sec)
}

// flush_fat_sector writes a first-copy table sector back, and the same bytes
// to every mirror.
@(private = "file")
flush_fat_sector :: proc "contextless" (sec: u32) -> bool {
	if !sector_flush(sec) {
		return false
	}
	c := &vol.cache[sec % CACHE_SECTORS]
	for i in 1 ..< vol.fats {
		if !write_at(u64(sec + i * vol.fat_sectors) * SECTOR, c.data[:]) {
			return false
		}
	}
	return true
}

// -- Clusters -------------------------------------------------------------------

// cluster_offset is where cluster `c`'s bytes begin on the volume.
cluster_offset :: proc "contextless" (c: u32) -> u64 {
	return u64(vol.data_sector + (c - 2) * vol.sectors_per_cluster) * SECTOR
}

// next_cluster follows the chain one step. `end` is true at the last
// cluster, and `ok` false when the table would not read or the entry names
// a cluster outside the volume, which is a corrupt chain.
next_cluster :: proc "contextless" (c: u32) -> (next: u32, end: bool, ok: bool) {
	v, got := fat_get(c)
	if !got {
		return 0, true, false
	}
	if is_end(v) {
		return 0, true, true
	}
	if v < 2 || v >= vol.clusters + 2 {
		return 0, true, false
	}
	return v, false, true
}

/*
alloc_cluster claims a free cluster, marks it the end of a chain, and links
it after `prev` when `prev` is not zero. The search starts where the last
one left off and wraps once, so a volume with free space near its start is
not scanned from the top every time. The cluster's bytes are not cleared;
a directory that needs zeros clears them itself.
*/
alloc_cluster :: proc "contextless" (prev: u32) -> (c: u32, ok: bool) {
	if vol.free_clusters == 0 {
		return 0, false
	}
	last := vol.clusters + 2
	start := max(vol.next_free, 2)
	cand := start
	for {
		v, got := fat_get(cand)
		if !got {
			return 0, false
		}
		if v == 0 {
			break
		}
		cand += 1
		if cand >= last {
			cand = 2
		}
		if cand == start {
			return 0, false
		}
	}
	if !fat_set(cand, end_mark()) {
		return 0, false
	}
	if prev != 0 {
		if !fat_set(prev, cand) {
			return 0, false
		}
	}
	vol.free_clusters -= 1
	vol.next_free = cand + 1
	return cand, true
}

// free_chain gives every cluster from `first` on back to the volume.
free_chain :: proc "contextless" (first: u32) -> bool {
	c := first
	for c >= 2 && c < vol.clusters + 2 {
		next, end, ok := next_cluster(c)
		if !ok {
			return false
		}
		if !fat_set(c, 0) {
			return false
		}
		vol.free_clusters += 1
		if c < vol.next_free {
			vol.next_free = c
		}
		if end {
			break
		}
		c = next
	}
	return true
}

// zero_cluster clears cluster `c` on the disk, for a directory that must
// start empty.
zero_cluster :: proc(c: u32) -> bool {
	zeros: [SECTOR]u8
	off := cluster_offset(c)
	for i in 0 ..< vol.sectors_per_cluster {
		if !write_at(off + u64(i) * SECTOR, zeros[:]) {
			return false
		}
	}
	// Any cached copy of these sectors is stale now.
	first := vol.data_sector + (c - 2) * vol.sectors_per_cluster
	for i in 0 ..< vol.sectors_per_cluster {
		cached := &vol.cache[(first + i) % CACHE_SECTORS]
		if cached.valid && cached.sector == first + i {
			cached.valid = false
		}
	}
	return true
}

// invalidate_data drops any cached copy of the sectors in `[off, off+len)`,
// for a data write that went around the cache into a cluster a directory
// listing may have cached.
invalidate_range :: proc "contextless" (off: u64, length: int) {
	first := u32(off / SECTOR)
	last := u32((off + u64(length) + SECTOR - 1) / SECTOR)
	for s := first; s < last; s += 1 {
		cached := &vol.cache[s % CACHE_SECTORS]
		if cached.valid && cached.sector == s {
			cached.valid = false
		}
	}
}
