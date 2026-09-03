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

## Write-through

A block that changes is written when it changes. There is no journal, and
the order of writes is the order that leaves the volume consistent if the
machine stops between any two: a block is marked taken before anything
points at it, a file's inode is written after its blocks hold what the
size says, and a directory entry is written after the inode it names is
whole. A crash loses the last operation and nothing before it, and a
block that was taken and never pointed at is the one kind of leak, which
a scan at the next ream would reclaim. `docs/SHELL.md` step 7 says a
journal comes when a crash costs something, and this is the shape it
would journal.

## The cache

Thirty-two blocks, direct-mapped by block number, in this program's own
memory. The superblock, the bitmap and the inode table are the blocks
touched again and again; file data passes through the same slots because
a 9P read is two blocks and a second read of the same file is rare. A
slot holds bytes the caller may change, and `bwrite` puts them on the
disk; the slot is good until the next `bread` that maps to it, which is
why an inode is copied out of its block into an `Inode` and back rather
than edited in place.
*/
package kfs

import "vsys:libuser"

BLOCK :: 4096
MAGIC :: u64(0x3130_3030_5346_4B56) // "VKFS0001"

INODE_SIZE :: 128
INODES_PER_BLOCK :: BLOCK / INODE_SIZE
DIRECT :: 12
INDIRECT_ENTRIES :: BLOCK / 4
MAX_FILE_BLOCKS :: DIRECT + INDIRECT_ENTRIES

// How many inodes a ream makes: one per file the volume can hold.
INODES :: 1024
INODE_BLOCKS :: INODES / INODES_PER_BLOCK

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
}

Inode :: struct {
	mode:     u32, // Zero is a free inode
	version:  u32,
	size:     u64,
	mtime:    u64,
	direct:   [DIRECT]u32,
	indirect: u32,
}

Volume :: struct {
	fd:         int,
	sb:         Superblock,
	free:       u32, // Free blocks, counted at mount and kept
	next_block: u32, // Where the next allocation looks first
	cache:      [CACHE_BLOCKS]Cached,
}

CACHE_BLOCKS :: 32

Cached :: struct {
	block: u32,
	valid: bool,
	data:  [BLOCK]u8,
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

// bread answers block `b`'s bytes through the cache, good until the next
// bread that maps to the same slot. Nil on a read error.
bread :: proc "contextless" (b: u32) -> []u8 {
	c := &vol.cache[b % CACHE_BLOCKS]
	if !c.valid || c.block != b {
		if !read_block_raw(b, c.data[:]) {
			c.valid = false
			return nil
		}
		c.block = b
		c.valid = true
	}
	return c.data[:]
}

// bwrite puts the cached block `b` on the disk, after the caller changed
// the bytes `bread` handed it.
bwrite :: proc "contextless" (b: u32) -> bool {
	c := &vol.cache[b % CACHE_BLOCKS]
	if !c.valid || c.block != b {
		return false
	}
	return write_block_raw(b, c.data[:])
}

// bzero fills block `b` with zeros, on the disk and in the cache.
bzero :: proc "contextless" (b: u32) -> bool #no_bounds_check {
	c := &vol.cache[b % CACHE_BLOCKS]
	for i in 0 ..< BLOCK {
		c.data[i] = 0
	}
	c.block = b
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
	if sb.blocks == 0 || sb.data_start >= sb.blocks || sb.inodes == 0 {
		return {}, false
	}
	return sb, true
}

@(private = "file")
write_superblock :: proc "contextless" () -> bool #no_bounds_check {
	c := &vol.cache[0]
	for i in 0 ..< BLOCK {
		c.data[i] = 0
	}
	c.block = 0
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
	vol.sb = Superblock {
		blocks        = blocks,
		bitmap_start  = 1,
		bitmap_blocks = bitmap_blocks,
		inode_start   = 1 + bitmap_blocks,
		inode_blocks  = INODE_BLOCKS,
		data_start    = 1 + bitmap_blocks + INODE_BLOCKS,
		inodes        = INODES,
		generation    = generation,
	}
	if vol.sb.data_start >= blocks {
		return false, "too small for its own tables"
	}
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
	table := bread(in_.indirect)
	if table == nil {
		return 0, false
	}
	slot := int(idx - DIRECT) * 4
	block = le32(table[slot:])
	if block == 0 && alloc {
		b, got := alloc_block(true)
		if !got {
			return 0, false
		}
		// `alloc_block` may have evicted the table; read it again.
		table = bread(in_.indirect)
		if table == nil {
			return 0, false
		}
		put32(table[slot:], b)
		if !bwrite(in_.indirect) {
			return 0, false
		}
		block = b
	}
	return block, true
}

// free_blocks_from gives back every block of the file from block index
// `from` on, and the indirect block when nothing below it remains.
free_blocks_from :: proc "contextless" (in_: ^Inode, from: u32) -> bool #no_bounds_check {
	for i := from; i < DIRECT; i += 1 {
		if in_.direct[i] != 0 {
			if !free_block(in_.direct[i]) {
				return false
			}
			in_.direct[i] = 0
		}
	}
	if in_.indirect == 0 {
		return true
	}
	table := bread(in_.indirect)
	if table == nil {
		return false
	}
	start := from > DIRECT ? from - DIRECT : 0
	live := false
	for i := u32(0); i < INDIRECT_ENTRIES; i += 1 {
		b := le32(table[i * 4:])
		if b == 0 {
			continue
		}
		if i < start {
			live = true
			continue
		}
		if !free_block(b) {
			return false
		}
		// `free_block` touched the bitmap and may have evicted the table.
		table = bread(in_.indirect)
		if table == nil {
			return false
		}
		put32(table[i * 4:], 0)
	}
	if live {
		return bwrite(in_.indirect)
	}
	if !free_block(in_.indirect) {
		return false
	}
	in_.indirect = 0
	return true
}
