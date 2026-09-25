/*
The volume: a superblock, a bitmap, an inode table, and blocks.

    block 0            the superblock: where everything else is
    bitmap             one bit per block of the volume, set when taken
    inode table        128 bytes per file: mode, size, version, twelve
                       direct block numbers and one indirect
    data               everything else, handed out by the bitmap

Every number is little-endian and every structure is a whole number of
4 KiB blocks, so a block is the unit of every read and write and nothing
straddles two. An inode's twelve direct blocks and one indirect block of
1024 more make a file of a little over four megabytes, which is the limit
the day something wants a bigger one raises by adding a second level.

## The order, the transaction, and the journal

The order of writes is the one that leaves the volume consistent if the
machine stops between any two: a block is marked taken before anything
points at it, a file's inode is written after its blocks hold what the
size says, and a directory entry is written after the inode it names is
whole. On top of that order, every request that changes the volume is one
transaction: its writes are held in an overlay until the request has
succeeded, then landed through the journal -- a header and a log between
the inode table and the data -- all at once, so a stop leaves every one of
them or none, and a mount replays a commit a stop interrupted. `Txn`,
`txn_commit` and `journal_replay` below; `docs/KFS.md` has the argument.
`kfs -c` (fsck.odin) is the mark and sweep for a volume from before.

## The cache

256 blocks as 32 sets of 8 ways, least recently used first out of a set.
The superblock, the bitmap and the inode table are the blocks touched again
and again, and eight ways keep an inode table block from being evicted by a
data block that shares its residue, which one way per set could not. A way
holds bytes the caller may change; `bwrite` records the change -- into the
transaction's overlay inside a request, to the disk outside one. The overlay
is the truth for a block the request has written and `bread` answers from it
first, which is what lets writes be held without a block evicted and read
again coming back stale. A way is good until its block is evicted, which is
why an inode is still copied out of its block into an `Inode` and back rather
than edited in place.
*/
package kfs

import "vsys:libuser"

BLOCK :: 4096
// "VKFS0002": the second layout, with a journal between the inode table and
// the data. A volume with the first magic has no journal and is reamed.
MAGIC :: u64(0x3230_3030_5346_4B56)

/*
The journal: a run of blocks a transaction's writes are logged to before
they land where they belong, so a stop between the two leaves either all
of them or none. One header block, then room for the largest transaction.
`MAX_TXN` bounds the distinct blocks one 9P request may dirty; a write
dirties a data block or two, an inode and a bitmap block, a create an
inode block and a directory block, a truncate a bitmap block, an inode and
the one table it cuts through. Thirty-two is many times any of them.
*/
JOURNAL_BLOCKS :: 40
MAX_TXN :: 32
#assert(JOURNAL_BLOCKS > MAX_TXN)
JOURNAL_COMMIT :: u64(0x54494D4D_4F435F4A) // "J_COMMIT"
JOURNAL_EMPTY :: u64(0)

INODE_SIZE :: 128
INODES_PER_BLOCK :: BLOCK / INODE_SIZE
DIRECT :: 12
INDIRECT_ENTRIES :: BLOCK / 4
// Where the single indirect table's blocks begin, and where the double's
// do. A file is direct blocks, then one table of them, then a table of
// tables: 12 + 1024 + 1024*1024 blocks, four gigabytes at 4 KiB a block.
SINGLE_START :: DIRECT
DOUBLE_START :: DIRECT + INDIRECT_ENTRIES
MAX_FILE_BLOCKS :: DOUBLE_START + INDIRECT_ENTRIES * INDIRECT_ENTRIES

/*
How many inodes a ream makes: one per file the volume can hold. One for every
four blocks of the volume, never fewer than `INODES_MIN`, and a whole number
of table blocks. The count was a fixed 1024 once, whatever the disk. A 64 MiB
scratch volume ran out of files with nine tenths of its blocks free.
The superblock records the count, so a volume reamed before this keeps its
1024 and reads as it did. `docs/LIMITS.md`.
*/
INODES_MIN :: 1024
INODES_PER_DATA :: 4

inode_count :: proc "contextless" (blocks: u32) -> u32 {
	n := max(blocks / INODES_PER_DATA, INODES_MIN)
	return (n + INODES_PER_BLOCK - 1) / INODES_PER_BLOCK * INODES_PER_BLOCK
}

ROOT_INODE :: u32(1)

// Plan 9's bit for a directory, in a mode.
DMDIR :: u32(1) << 31

Superblock :: struct {
	blocks:        u32, // Of the whole volume
	bitmap_start:  u32,
	bitmap_blocks: u32,
	inode_start:   u32,
	inode_blocks:  u32,
	data_start:    u32,
	inodes:        u32,
	generation:    u64, // Reams so far, so a reformatted disk is a new one
	journal_start:  u32, // The journal's header block; the log follows it
	journal_blocks: u32,
}

Inode :: struct {
	mode:     u32, // Zero is a free inode
	version:  u32,
	size:     u64,
	mtime:    u64,
	direct:   [DIRECT]u32,
	indirect: u32,
	// A second level: a block of pointers to blocks of pointers, so a file
	// runs to a thousand times what one indirect table reaches. Byte 92 of
	// the record, a slot that was spare; zero on a volume from before it,
	// and zero means absent, as it does for every block number here.
	double:   u32,
	// Whose file it is: the user that made it, bytes 96 to 123 of the
	// record, zero-padded. A volume from before owners has zeroes there,
	// and a file with no owner is open to whoever the mode lets in.
	owner:    [OWNER_MAX]u8,
	olen:     int,
}

OWNER_MAX :: 28
OWNER_AT :: 96

Volume :: struct {
	fd:         int,
	sb:         Superblock,
	free:       u32, // Free blocks, counted at mount and kept
	next_block: u32, // Where the next allocation looks first
	replayed:   int, // Blocks the journal landed at mount: a stop's commit, finished
	cache:      []Cached, // CACHE_BLOCKS of them, on the heap: see `cache_init`
}

/*
The cache: 256 blocks, a megabyte, as 32 sets of 8 ways. A block belongs to
the set its number selects and may sit in any of that set's ways; the way
to evict is the one least recently used. That is what a direct-mapped cache
of 32 slots could not do: two hot blocks whose numbers agreed modulo 32 --
an inode table block and a data block, say -- evicted each other on every
touch, and the check walked the inode table through that. Eight ways means
a block leaves only when eight others of its set have been touched since,
and 256 blocks hold the whole of a small volume's tables with room over.

The contract callers were written to is kept and strengthened: a slice
`bread` hands out is good until its block is evicted, which was `until the
next read that maps to the slot` and is now `until eight reads of its set`.
The tight read-change-write a caller does is unchanged.

A megabyte does not fit a program's static image -- `MAX_PROGRAM_FRAMES`
bounds that at half of it -- so the cache is one heap allocation, made at
startup by `cache_init`. The heap grows to `SEGALLOC_MAX`, far past this,
and a file server is exactly the program the static bound was not meant to
hold a cache for. Nil until `cache_init`, so nothing reads a block before
the boot has made it.
*/
CACHE_SETS :: 32
CACHE_WAYS :: 8
CACHE_BLOCKS :: CACHE_SETS * CACHE_WAYS

Cached :: struct {
	block: u32,
	valid: bool,
	age:   u32, // The clock at last touch; the smallest in a set is the one to evict
	data:  [BLOCK]u8,
}

// cache_init allocates the cache on the heap. Answers false when the heap
// cannot hold a megabyte, which is a machine too small to serve from.
cache_init :: proc() -> bool {
	vol.cache = make([]Cached, CACHE_BLOCKS)
	return vol.cache != nil
}

@(private = "file")
cache_clock: u32

// cache_find answers the way holding block `b`, touched now, or nil.
@(private = "file")
cache_find :: proc "contextless" (b: u32) -> ^Cached #no_bounds_check {
	set := (b % CACHE_SETS) * CACHE_WAYS
	for w in 0 ..< CACHE_WAYS {
		c := &vol.cache[set + u32(w)]
		if c.valid && c.block == b {
			cache_clock += 1
			c.age = cache_clock
			return c
		}
	}
	return nil
}

// cache_take answers a way for block `b`: the one holding it, else an empty
// way of its set, else the set's least recently used, claimed for `b` and
// not yet valid -- the caller fills it and says so.
@(private = "file")
cache_take :: proc "contextless" (b: u32) -> ^Cached #no_bounds_check {
	if c := cache_find(b); c != nil {
		return c
	}
	set := (b % CACHE_SETS) * CACHE_WAYS
	// An empty way first; failing that, the least recently touched.
	victim: ^Cached
	for w in 0 ..< CACHE_WAYS {
		c := &vol.cache[set + u32(w)]
		if !c.valid {
			victim = c
			break
		}
		if victim == nil || c.age < victim.age {
			victim = c
		}
	}
	cache_clock += 1
	victim.block = b
	victim.valid = false
	victim.age = cache_clock
	return victim
}

vol: Volume

// -- Bytes ------------------------------------------------------------------------

@(private = "file")
le32 :: proc "contextless" (b: []u8) -> u32 #no_bounds_check {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private = "file")
le64 :: proc "contextless" (b: []u8) -> u64 #no_bounds_check {
	return u64(le32(b)) | u64(le32(b[4:])) << 32
}

@(private = "file")
put32 :: proc "contextless" (b: []u8, v: u32) #no_bounds_check {
	b[0] = u8(v)
	b[1] = u8(v >> 8)
	b[2] = u8(v >> 16)
	b[3] = u8(v >> 24)
}

@(private = "file")
put64 :: proc "contextless" (b: []u8, v: u64) #no_bounds_check {
	put32(b, u32(v))
	put32(b[4:], u32(v >> 32))
}

// -- The disk, by block ------------------------------------------------------------

@(private = "file")
read_block_raw :: proc "contextless" (block: u32, buf: []u8) -> bool {
	off := u64(block) * BLOCK
	done := 0
	for done < BLOCK {
		n := libuser.pread(vol.fd, buf[done:BLOCK], off + u64(done))
		if n <= 0 {
			return false
		}
		done += int(n)
	}
	return true
}

@(private = "file")
write_block_raw :: proc "contextless" (block: u32, buf: []u8) -> bool {
	off := u64(block) * BLOCK
	done := 0
	for done < BLOCK {
		n := libuser.pwrite(vol.fd, buf[done:BLOCK], off + u64(done))
		if n <= 0 {
			return false
		}
		done += int(n)
	}
	return true
}

// -- The transaction ----------------------------------------------------------------

/*
A transaction is one 9P request's writes, held back until the request has
succeeded and then landed all at once, through the journal, so a stop leaves
either every one of them on the disk or none.

**This is also what makes the cache safe to write through.** The cache is
thirty-two slots direct-mapped by block number, and a slot is good only
until the next read that maps to it. With every write going straight to the
disk that was harmless: a block evicted and read again came back with its
change. With writes held back it would not -- a block changed, evicted and
read again would come back as the disk still has it, and the change would
be lost inside the very request that made it. A bitmap block a truncate
clears bit after bit is exactly that case. So a transaction keeps its own
copy of every block it has written, and `bread` answers from that copy first.
The overlay is the truth for a block the request changed, whatever the cache
holds; the cache is a read accelerator and nothing more. When the transaction
ends, committed or not, the cache is dropped whole, so it cannot serve a copy
it took before an eviction and a re-read.

The journal is a header block and a log. Commit writes the changed blocks to
the log, then the header -- the block numbers, a count, and a magic at each
end, so a header torn mid-write does not read as a commit -- then the blocks
to their homes, then clears the header. A mount that finds a committed header
copies the log home before anything else reads the volume; one that finds a
torn or empty header has nothing to do, because nothing reached a home block
before the header was whole. There is no barrier between the log and the
header write, which real hardware would want; QEMU's disk is ordered enough
for the story to be checked, and the gap is named in `docs/KFS.md`.
*/
Txn :: struct {
	active:   bool,
	overflow: bool, // More distinct blocks than the log holds: written straight home, not atomic
	n:        int,
	block:    [MAX_TXN]u32,
	data:     [MAX_TXN][BLOCK]u8,
}

txn: Txn

@(private = "file")
txn_find :: proc "contextless" (b: u32) -> int {
	for i in 0 ..< txn.n {
		if txn.block[i] == b {
			return i
		}
	}
	return -1
}

// txn_begin opens a transaction. Every `bwrite` until `txn_commit` or
// `txn_abort` is held in the overlay rather than written home.
txn_begin :: proc "contextless" () {
	txn.active = true
	txn.overflow = false
	txn.n = 0
}

// txn_note is `bwrite` inside a transaction: the cache slot's bytes for
// block `b` -- which the caller has just changed -- are copied into the
// overlay, added if `b` is new to it. The overlay is now the block's truth.
@(private = "file")
txn_note :: proc "contextless" (b: u32) -> bool #no_bounds_check {
	c := cache_find(b)
	if c == nil {
		return false
	}
	i := txn_find(b)
	if i < 0 {
		if txn.n >= MAX_TXN {
			// Past what the log holds. Written home at once: the request is
			// no longer atomic, which the analysis above says never happens.
			txn.overflow = true
			return write_block_raw(b, c.data[:])
		}
		i = txn.n
		txn.n += 1
		txn.block[i] = b
	}
	copy(txn.data[i][:], c.data[:])
	return true
}

// cache_drop forgets every cached block, so the next read of any of them
// comes from the disk. The end of every transaction.
@(private = "file")
cache_drop :: proc "contextless" () {
	for i in 0 ..< CACHE_BLOCKS {
		vol.cache[i].valid = false
	}
}

@(private = "file")
journal_header_write :: proc "contextless" (magic: u64) -> bool #no_bounds_check {
	hdr: [BLOCK]u8
	put64(hdr[:], magic)
	put32(hdr[8:], u32(txn.n))
	for i in 0 ..< txn.n {
		put32(hdr[12 + 4 * i:], txn.block[i])
	}
	put64(hdr[BLOCK - 8:], magic)
	return write_block_raw(vol.sb.journal_start, hdr[:])
}

/*
txn_commit lands the transaction: the log, the header, the homes, and the
header cleared. Anything that fails before the header is written leaves the
volume untouched; anything after it is finished by replay at the next mount.
An overflowed transaction has already written itself home block by block,
and only the cache is dropped.
*/
txn_commit :: proc "contextless" () -> bool #no_bounds_check {
	// The cache is kept, not dropped: every block the request changed it
	// also wrote, so each dirty way already holds what lands home -- `bwrite`
	// keeps the way in step with the overlay -- and an evicted dirty simply
	// misses and re-reads the committed disk. So a block two requests touch
	// is read once, which a drop here threw away. Only `txn_abort` drops,
	// because an abandoned request's edits are in the ways and uncommitted.
	defer {
		txn.active = false
		txn.n = 0
	}
	if txn.overflow {
		// The overlay's blocks went home as they overflowed; land the rest.
		for i in 0 ..< txn.n {
			if !write_block_raw(txn.block[i], txn.data[i][:]) {
				return false
			}
		}
		return true
	}
	if txn.n == 0 {
		return true
	}
	for i in 0 ..< txn.n {
		if !write_block_raw(vol.sb.journal_start + 1 + u32(i), txn.data[i][:]) {
			return false
		}
	}
	if !journal_header_write(JOURNAL_COMMIT) {
		return false
	}
	// Committed. From here the blocks land, now or at the next mount.
	for i in 0 ..< txn.n {
		if !write_block_raw(txn.block[i], txn.data[i][:]) {
			return false
		}
	}
	return journal_header_write(JOURNAL_EMPTY)
}

// txn_abort discards the transaction: nothing reached the log or a home
// block, and the cache is dropped so no way keeps a change that was never
// made -- the one case a way can hold what the disk does not.
txn_abort :: proc "contextless" () {
	txn.active = false
	txn.n = 0
	cache_drop()
}

/*
journal_replay finishes a commit a stop interrupted. A header with the
commit magic whole at both ends names blocks the log holds that may not all
have reached home; each is copied there again -- copying one that already
arrived changes nothing -- and the header is cleared. Any other header is
nothing to do: a torn one means the commit never happened, and no home block
was touched before the header was whole. Answers how many blocks it landed.
*/
journal_replay :: proc "contextless" () -> (landed: int, ok: bool) #no_bounds_check {
	hdr: [BLOCK]u8
	if !read_block_raw(vol.sb.journal_start, hdr[:]) {
		return 0, false
	}
	if le64(hdr[:]) != JOURNAL_COMMIT || le64(hdr[BLOCK - 8:]) != JOURNAL_COMMIT {
		return 0, true
	}
	count := int(le32(hdr[8:]))
	if count <= 0 || count > MAX_TXN {
		return 0, true
	}
	buf: [BLOCK]u8
	for i in 0 ..< count {
		home := le32(hdr[12 + 4 * i:])
		if home >= vol.sb.blocks {
			return landed, false
		}
		if !read_block_raw(vol.sb.journal_start + 1 + u32(i), buf[:]) ||
		   !write_block_raw(home, buf[:]) {
			return landed, false
		}
		landed += 1
	}
	txn.n = 0
	if !journal_header_write(JOURNAL_EMPTY) {
		return landed, false
	}
	return landed, true
}

/*
journal_selftest is the journal's negative control: the stop that hurts is
one after the commit record and before the blocks land, and this makes
exactly that. A free block is chosen; a recognisable page is written into
the log, and a committed header naming that block, and nothing to the block
itself -- the disk now looks like a commit interrupted at the worst moment.
`journal_replay` must then land the page on the block and clear the header.
The block is zeroed after, so the volume is as it was. Answers the block
and whether every step held; a replay that missed it answers false.
*/
journal_selftest :: proc "contextless" () -> (block: u32, ok: bool) #no_bounds_check {
	// A free data block, found the way the check finds one.
	for b := vol.sb.data_start; b < vol.sb.blocks; b += 1 {
		taken, got := bit_read(b)
		if !got {
			return 0, false
		}
		if !taken {
			block = b
			break
		}
	}
	if block == 0 {
		return 0, false
	}
	page: [BLOCK]u8
	for i in 0 ..< BLOCK {
		page[i] = u8(0xA5) ~ u8(i & 0xFF)
	}
	// The log and the header, as a commit writes them; the home untouched.
	if !write_block_raw(vol.sb.journal_start + 1, page[:]) {
		return block, false
	}
	txn.n = 1
	txn.block[0] = block
	committed := journal_header_write(JOURNAL_COMMIT)
	txn.n = 0
	if !committed {
		return block, false
	}
	// The next mount's first act, done now.
	landed, rok := journal_replay()
	if !rok || landed != 1 {
		return block, false
	}
	cache_drop()
	got := bread(block)
	if got == nil {
		return block, false
	}
	for i in 0 ..< BLOCK {
		if got[i] != page[i] {
			return block, false
		}
	}
	hdr: [BLOCK]u8
	if !read_block_raw(vol.sb.journal_start, hdr[:]) || le64(hdr[:]) != JOURNAL_EMPTY {
		return block, false
	}
	// As it was: the block free and zero.
	ok = bzero(block)
	cache_drop()
	return block, ok
}

/*
cache_writeback_test is the control for the cache that survives a commit.
A free block is written a pattern through a real transaction; after the
commit the same block is read again, and the read must not touch the disk
(the way is still there, warm) and must hold the pattern (the way is not
stale). A cache dropped at commit would miss the read; a cache that kept a
pre-write copy would hold the wrong bytes. The block is freed to zero after,
so the volume is as it was. Answers the block and whether both held.
*/
cache_writeback_test :: proc "contextless" () -> (block: u32, ok: bool) #no_bounds_check {
	for b := vol.sb.data_start; b < vol.sb.blocks; b += 1 {
		taken, got := bit_read(b)
		if !got {
			return 0, false
		}
		if !taken {
			block = b
			break
		}
	}
	if block == 0 {
		return 0, false
	}
	txn_begin()
	d := bread(block)
	if d == nil {
		txn_abort()
		return block, false
	}
	for i in 0 ..< BLOCK {
		d[i] = 0x5A
	}
	if !bwrite(block) || !txn_commit() {
		return block, false
	}
	// The read the commit did not throw away: a hit, and the pattern.
	misses := cache_misses
	got := bread(block)
	warm := cache_misses == misses
	coherent := got != nil && got[0] == 0x5A && got[BLOCK - 1] == 0x5A
	ok = warm && coherent
	// As it was.
	_ = bzero(block)
	cache_drop()
	return block, ok
}

// -- The cache -----------------------------------------------------------------------

// bread answers block `b`'s bytes: from the transaction's overlay when the
// request has written `b`, else through the cache, good until the next
// bread that maps to the same slot. Nil on a read error.
bread :: proc "contextless" (b: u32) -> []u8 {
	if txn.active {
		if i := txn_find(b); i >= 0 {
			return txn.data[i][:]
		}
	}
	if c := cache_find(b); c != nil {
		cache_hits += 1
		return c.data[:]
	}
	cache_misses += 1
	c := cache_take(b)
	if !read_block_raw(b, c.data[:]) {
		c.valid = false
		return nil
	}
	c.valid = true
	return c.data[:]
}

// How the cache is doing: reads answered from it, and reads that went to
// the disk. Counted since the program started, reported by `kfs -t`.
cache_hits: u64
cache_misses: u64

/*
cache_probe measures the one thing associativity is for. It reads eight
blocks that share a set -- consecutive multiples of CACHE_SETS, the way
consecutive inode table blocks and a data block can share a residue -- and
then reads them again, and answers how many of the sixteen went to the disk.
A direct-mapped cache of one way per set evicts each with the next and
misses all sixteen; eight ways hold the eight and miss only the first pass.
The blocks are the volume's own tables and data, read and not written, so
this changes nothing. Reported beside the hit rate, which on a small volume
says little, since the hazard this cures is a collision and not a capacity.
*/
// How many blocks the probe reads: eight, whatever the cache's shape, so
// the same probe measures a one-way cache and an eight-way one alike.
PROBE_BLOCKS :: 8

cache_probe :: proc "contextless" () -> (misses: u64) {
	cache_drop() // From cold, so what the controls left cached does not count.
	before := cache_misses
	for pass in 0 ..< 2 {
		for i := u32(0); i < PROBE_BLOCKS; i += 1 {
			b := i * CACHE_SETS
			if b >= vol.sb.blocks {
				break
			}
			_ = bread(b)
		}
		_ = pass
	}
	return cache_misses - before
}

/*
bwrite records that the caller changed the bytes `bread` handed it for
block `b`. Inside a transaction the change is held in the overlay until
commit; outside one -- a ream, a check, the boot -- it goes to the disk now.
A caller that was handed the overlay's own bytes has already changed the
overlay, and the note is a copy of the copy, harmless.
*/
bwrite :: proc "contextless" (b: u32) -> bool {
	if txn.active {
		if i := txn_find(b); i >= 0 {
			// The caller wrote through the overlay slice `bread` gave it.
			// The cache way, if it holds `b`, may be stale; refresh it so
			// a `txn_note` from a later cache-side edit starts from truth.
			if c := cache_find(b); c != nil {
				copy(c.data[:], txn.data[i][:])
			}
			return true
		}
		return txn_note(b)
	}
	c := cache_find(b)
	if c == nil {
		return false
	}
	return write_block_raw(b, c.data[:])
}

// bzero fills block `b` with zeros, on the disk and in the cache.
bzero :: proc "contextless" (b: u32) -> bool #no_bounds_check {
	c := cache_take(b)
	for i in 0 ..< BLOCK {
		c.data[i] = 0
	}
	c.valid = true
	return write_block_raw(b, c.data[:])
}

// -- The superblock ----------------------------------------------------------------

@(private = "file")
read_superblock :: proc "contextless" () -> (sb: Superblock, ok: bool) #no_bounds_check {
	b := bread(0)
	if b == nil || le64(b) != MAGIC || le32(b[8:]) != BLOCK {
		return {}, false
	}
	sb.blocks = le32(b[12:])
	sb.bitmap_start = le32(b[16:])
	sb.bitmap_blocks = le32(b[20:])
	sb.inode_start = le32(b[24:])
	sb.inode_blocks = le32(b[28:])
	sb.data_start = le32(b[32:])
	sb.inodes = le32(b[36:])
	sb.generation = le64(b[48:])
	sb.journal_start = le32(b[56:])
	sb.journal_blocks = le32(b[60:])
	if sb.blocks == 0 || sb.data_start >= sb.blocks || sb.inodes == 0 {
		return {}, false
	}
	if sb.journal_blocks == 0 || sb.journal_start + sb.journal_blocks > sb.data_start {
		return {}, false
	}
	return sb, true
}

@(private = "file")
write_superblock :: proc "contextless" () -> bool #no_bounds_check {
	c := cache_take(0)
	for i in 0 ..< BLOCK {
		c.data[i] = 0
	}
	c.valid = true
	b := c.data[:]
	put64(b, MAGIC)
	put32(b[8:], BLOCK)
	put32(b[12:], vol.sb.blocks)
	put32(b[16:], vol.sb.bitmap_start)
	put32(b[20:], vol.sb.bitmap_blocks)
	put32(b[24:], vol.sb.inode_start)
	put32(b[28:], vol.sb.inode_blocks)
	put32(b[32:], vol.sb.data_start)
	put32(b[36:], vol.sb.inodes)
	put32(b[40:], ROOT_INODE)
	put64(b[48:], vol.sb.generation)
	put32(b[56:], vol.sb.journal_start)
	put32(b[60:], vol.sb.journal_blocks)
	return write_block_raw(0, b)
}

/*
mount_volume reads the superblock and counts the free blocks. `size` is the
device's length in bytes; a volume whose superblock claims more blocks than
the device has is refused rather than trusted.
*/
mount_volume :: proc(fd: int, size: u64) -> (ok: bool, why: string) {
	vol.fd = fd
	sb, good := read_superblock()
	if !good {
		return false, "no kfs superblock"
	}
	if u64(sb.blocks) * BLOCK > size {
		return false, "superblock claims more than the device holds"
	}
	vol.sb = sb
	// A commit a stop interrupted is finished here, before the bitmap is
	// counted: one of the blocks it lands may be a bitmap block.
	if landed, rok := journal_replay(); !rok {
		return false, "the journal would not replay"
	} else {
		vol.replayed = landed
	}
	cache_drop()
	vol.free = 0
	for b := sb.data_start; b < sb.blocks; b += 1 {
		taken, got := bit_read(b)
		if !got {
			return false, "cannot read the bitmap"
		}
		if !taken {
			vol.free += 1
		}
	}
	vol.next_block = sb.data_start
	return true, ""
}

/*
ream lays a fresh volume on a device of `size` bytes: the superblock, a
bitmap with the metadata blocks taken, an inode table with every inode
free, and a root directory, inode one, that is empty. Plan 9's word for
formatting, kept because `format` means a string here.
*/
ream :: proc(fd: int, size: u64, generation: u64) -> (ok: bool, why: string) {
	vol.fd = fd
	blocks := u32(size / BLOCK)
	if blocks < 64 {
		return false, "too small to hold a volume"
	}
	bitmap_blocks := (blocks + BLOCK * 8 - 1) / (BLOCK * 8)
	inodes := inode_count(blocks)
	inode_blocks := inodes / INODES_PER_BLOCK
	journal_start := 1 + bitmap_blocks + inode_blocks
	vol.sb = Superblock {
		blocks         = blocks,
		bitmap_start   = 1,
		bitmap_blocks  = bitmap_blocks,
		inode_start    = 1 + bitmap_blocks,
		inode_blocks   = inode_blocks,
		journal_start  = journal_start,
		journal_blocks = JOURNAL_BLOCKS,
		data_start     = journal_start + JOURNAL_BLOCKS,
		inodes         = inodes,
		generation     = generation,
	}
	if vol.sb.data_start >= blocks {
		return false, "too small for its own tables"
	}
	// Every table block cleared, the journal's header among them: a zero
	// header is an empty journal, so a fresh volume has nothing to replay.
	for b := vol.sb.bitmap_start; b < vol.sb.data_start; b += 1 {
		if !bzero(b) {
			return false, "cannot clear a table block"
		}
	}
	// The metadata blocks are taken before anything else is.
	for b := u32(0); b < vol.sb.data_start; b += 1 {
		if !bit_mark(b, true) {
			return false, "cannot write the bitmap"
		}
	}
	vol.free = blocks - vol.sb.data_start
	vol.next_block = vol.sb.data_start
	if !write_superblock() {
		return false, "cannot write the superblock"
	}

	// The root: a directory with one empty block, so a listing has a block
	// to read and a create has a slot to take.
	root := Inode {
		mode    = DMDIR | 0o777,
		version = 1,
		size    = BLOCK,
	}
	first, got := alloc_block(true)
	if !got {
		return false, "no block for the root"
	}
	root.direct[0] = first
	if !put_inode(ROOT_INODE, &root) {
		return false, "cannot write the root inode"
	}
	return true, ""
}

// -- The bitmap ----------------------------------------------------------------------

@(private = "file")
bit_read :: proc "contextless" (b: u32) -> (taken: bool, ok: bool) #no_bounds_check {
	blk := vol.sb.bitmap_start + b / (BLOCK * 8)
	data := bread(blk)
	if data == nil {
		return false, false
	}
	bit := b % (BLOCK * 8)
	return data[bit / 8] & (1 << (bit % 8)) != 0, true
}

@(private = "file")
bit_mark :: proc "contextless" (b: u32, taken: bool) -> bool #no_bounds_check {
	blk := vol.sb.bitmap_start + b / (BLOCK * 8)
	data := bread(blk)
	if data == nil {
		return false
	}
	bit := b % (BLOCK * 8)
	if taken {
		data[bit / 8] |= 1 << (bit % 8)
	} else {
		data[bit / 8] &= ~(u8(1) << (bit % 8))
	}
	return bwrite(blk)
}

/*
alloc_block takes a free block, marks it in the bitmap, and zeroes it when
`zero` is set, which every caller today asks for: a directory or indirect
block must read as empty, and a data block a partial write lands in must
read as zeros around it. The search starts where the last one ended and
wraps once.
*/
alloc_block :: proc "contextless" (zero: bool) -> (b: u32, ok: bool) {
	if vol.free == 0 {
		return 0, false
	}
	start := max(vol.next_block, vol.sb.data_start)
	cand := start
	for {
		taken, got := bit_read(cand)
		if !got {
			return 0, false
		}
		if !taken {
			break
		}
		cand += 1
		if cand >= vol.sb.blocks {
			cand = vol.sb.data_start
		}
		if cand == start {
			return 0, false
		}
	}
	if !bit_mark(cand, true) {
		return 0, false
	}
	vol.free -= 1
	vol.next_block = cand + 1
	if zero && !bzero(cand) {
		return 0, false
	}
	return cand, true
}

free_block :: proc "contextless" (b: u32) -> bool {
	if b < vol.sb.data_start || b >= vol.sb.blocks {
		return false
	}
	if !bit_mark(b, false) {
		return false
	}
	vol.free += 1
	if b < vol.next_block {
		vol.next_block = b
	}
	return true
}

// -- Inodes ------------------------------------------------------------------------

@(private = "file")
inode_place :: proc "contextless" (ino: u32) -> (block: u32, at: int) {
	return vol.sb.inode_start + (ino / INODES_PER_BLOCK), int(ino % INODES_PER_BLOCK) * INODE_SIZE
}

// get_inode copies inode `ino` out of its table block.
get_inode :: proc "contextless" (ino: u32, out: ^Inode) -> bool #no_bounds_check {
	if ino >= vol.sb.inodes {
		return false
	}
	block, at := inode_place(ino)
	b := bread(block)
	if b == nil {
		return false
	}
	e := b[at:at + INODE_SIZE]
	out.mode = le32(e)
	out.version = le32(e[4:])
	out.size = le64(e[8:])
	out.mtime = le64(e[16:])
	for i in 0 ..< DIRECT {
		out.direct[i] = le32(e[40 + 4 * i:])
	}
	out.indirect = le32(e[88:])
	out.double = le32(e[92:])
	out.olen = 0
	for i in 0 ..< OWNER_MAX {
		c := e[OWNER_AT + i]
		if c == 0 {
			break
		}
		out.owner[i] = c
		out.olen = i + 1
	}
	return true
}

// put_inode writes inode `ino` back into its table block, and the block to
// the disk.
put_inode :: proc "contextless" (ino: u32, in_: ^Inode) -> bool #no_bounds_check {
	if ino >= vol.sb.inodes {
		return false
	}
	block, at := inode_place(ino)
	b := bread(block)
	if b == nil {
		return false
	}
	e := b[at:at + INODE_SIZE]
	for i in 0 ..< INODE_SIZE {
		e[i] = 0
	}
	put32(e, in_.mode)
	put32(e[4:], in_.version)
	put64(e[8:], in_.size)
	put64(e[16:], in_.mtime)
	for i in 0 ..< DIRECT {
		put32(e[40 + 4 * i:], in_.direct[i])
	}
	put32(e[88:], in_.indirect)
	put32(e[92:], in_.double)
	for i in 0 ..< OWNER_MAX {
		e[OWNER_AT + i] = i < in_.olen ? in_.owner[i] : 0
	}
	return bwrite(block)
}

// alloc_inode finds a free inode, from two, and answers its number. Inode
// zero is never handed out, so zero can mean "no file" in a directory entry.
alloc_inode :: proc "contextless" () -> (ino: u32, ok: bool) {
	scratch: Inode
	for i := u32(2); i < vol.sb.inodes; i += 1 {
		if !get_inode(i, &scratch) {
			return 0, false
		}
		if scratch.mode == 0 {
			return i, true
		}
	}
	return 0, false
}

/*
bmap answers the block holding file block `idx` of `in_`, zero for a hole.
With `alloc` set a hole is filled: a data block taken, and the indirect
block first if the index needs one. The inode is changed in memory and the
caller writes it, after the data is in place.
*/
/*
A pointer table is read afresh for every slot it answers, rather than held
as a slice across the call. `alloc_block` and `free_block` touch the bitmap,
and the cache may evict the table to make room, so a slice taken before an
allocation can point at another block after it. The single-level code
re-read after each allocation for that reason; with two levels of table the
simplest correct rule is to never hold one. A read hits the cache, so this
costs nothing the old care did not.
*/
@(private = "file")
table_get :: proc "contextless" (table: u32, slot: u32) -> (block: u32, ok: bool) #no_bounds_check {
	t := bread(table)
	if t == nil {
		return 0, false
	}
	return le32(t[slot * 4:]), true
}

@(private = "file")
table_set :: proc "contextless" (table: u32, slot: u32, block: u32) -> bool #no_bounds_check {
	t := bread(table)
	if t == nil {
		return false
	}
	put32(t[slot * 4:], block)
	return bwrite(table)
}

// table_slot answers the block in `slot` of `table`, allocating one there
// when it is empty and `alloc` says so. A table being filled is a table of
// zeroes, so a fresh block is zeroed too.
@(private = "file")
table_slot :: proc "contextless" (table: u32, slot: u32, alloc: bool) -> (block: u32, ok: bool) {
	have, got := table_get(table, slot)
	if !got {
		return 0, false
	}
	if have == 0 && alloc {
		b, made := alloc_block(true)
		if !made {
			return 0, false
		}
		if !table_set(table, slot, b) {
			return 0, false
		}
		have = b
	}
	return have, true
}

/*
bmap answers the disk block that holds file block `idx`, allocating it and
any table on the way when `alloc` is set. A block that does not exist and is
not to be made answers zero with `ok`, which a read treats as a hole.

Three regions, by index: the twelve direct blocks in the inode, then the
single indirect table's thousand, then the double's -- a table whose entries
are each a table of a thousand more.
*/
bmap :: proc "contextless" (in_: ^Inode, idx: u32, alloc: bool) -> (block: u32, ok: bool) #no_bounds_check {
	if idx >= MAX_FILE_BLOCKS {
		return 0, false
	}
	if idx < DIRECT {
		if in_.direct[idx] == 0 && alloc {
			b, got := alloc_block(true)
			if !got {
				return 0, false
			}
			in_.direct[idx] = b
		}
		return in_.direct[idx], true
	}
	if idx < DOUBLE_START {
		if in_.indirect == 0 {
			if !alloc {
				return 0, true
			}
			b, got := alloc_block(true)
			if !got {
				return 0, false
			}
			in_.indirect = b
		}
		return table_slot(in_.indirect, idx - SINGLE_START, alloc)
	}
	// The double level: an outer table of inner tables.
	if in_.double == 0 {
		if !alloc {
			return 0, true
		}
		b, got := alloc_block(true)
		if !got {
			return 0, false
		}
		in_.double = b
	}
	rel := idx - DOUBLE_START
	inner, iok := table_slot(in_.double, rel / INDIRECT_ENTRIES, alloc)
	if !iok || inner == 0 {
		return 0, iok
	}
	return table_slot(inner, rel % INDIRECT_ENTRIES, alloc)
}

/*
free_table gives back every block a pointer table names from slot `start`
on, and answers whether any slot below `start` still holds one. The table
block itself is the caller's to free or keep on that answer. Slots are read
fresh through `table_get`, for the reason `table_slot` gives.
*/
@(private = "file")
free_table :: proc "contextless" (table: u32, start: u32) -> (live: bool, ok: bool) {
	for i := u32(0); i < INDIRECT_ENTRIES; i += 1 {
		b, got := table_get(table, i)
		if !got {
			return false, false
		}
		if b == 0 {
			continue
		}
		if i < start {
			live = true
			continue
		}
		if !free_block(b) || !table_set(table, i, 0) {
			return false, false
		}
	}
	return live, true
}

/*
free_blocks_from gives back every block of the file from block index `from`
on, and each pointer table when nothing below it remains: the single
indirect table, each inner table of the double level, and the double's
outer table last of all.
*/
free_blocks_from :: proc "contextless" (in_: ^Inode, from: u32) -> bool #no_bounds_check {
	for i := from; i < DIRECT; i += 1 {
		if in_.direct[i] != 0 {
			if !free_block(in_.direct[i]) {
				return false
			}
			in_.direct[i] = 0
		}
	}

	if in_.indirect != 0 {
		start := from > SINGLE_START ? from - SINGLE_START : 0
		live, ok := free_table(in_.indirect, start)
		if !ok {
			return false
		}
		if !live {
			if !free_block(in_.indirect) {
				return false
			}
			in_.indirect = 0
		}
	}

	if in_.double == 0 {
		return true
	}
	// Each inner table covers INDIRECT_ENTRIES file blocks. An inner table
	// wholly below `from` is kept whole; one wholly above is freed whole;
	// the one `from` falls inside is trimmed from its slot on.
	rel := from > DOUBLE_START ? from - DOUBLE_START : 0
	outer_live := false
	for oi := u32(0); oi < INDIRECT_ENTRIES; oi += 1 {
		inner, got := table_get(in_.double, oi)
		if !got {
			return false
		}
		if inner == 0 {
			continue
		}
		first := oi * INDIRECT_ENTRIES // This inner table's first file block, from DOUBLE_START
		if first + INDIRECT_ENTRIES <= rel {
			outer_live = true
			continue
		}
		start := rel > first ? rel - first : 0
		live, ok := free_table(inner, start)
		if !ok {
			return false
		}
		if live {
			outer_live = true
			continue
		}
		if !free_block(inner) || !table_set(in_.double, oi, 0) {
			return false
		}
	}
	if outer_live {
		return true
	}
	if !free_block(in_.double) {
		return false
	}
	in_.double = 0
	return true
}
