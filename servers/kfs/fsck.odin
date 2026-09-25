/*
fsck -- the check the write order left room for.

`docs/KFS.md` sets out the order every change is written in, so the volume is
whole between any two writes. The one thing a stop can leave behind is a
block the bitmap calls taken that no file reaches -- and, in the narrow
window a create opens, an inode written whole before its directory entry, so
an inode in use that no directory names. Neither is corruption a reader
trips over; both are space that never comes back on its own. A ream reclaims
them by throwing the whole volume away. This reclaims them and keeps it.

The method is Plan 9's `check`, and it is a mark and a sweep. Mark: walk
from the root, and every inode a directory names is live, and every block a
live inode reaches is used. Sweep: an inode in use that the mark did not
reach is an orphan, and its inode is cleared; the bitmap is rewritten from
the used set, so a block nothing reached is free again. The free count is
whatever is left.

It runs with the volume mounted and nothing else serving it -- `kfs -c` does
the mount, the check, and exits, so the one process that has the device open
is the one repairing it. A journal, which would make a group of writes
atomic rather than reclaim after the fact, is still `docs/SHELL.md`'s to
want; this is the half that pays for the crash the write order already
survives.
*/
package kfs

import "base:intrinsics"

import "vsys:libodin"
import "vsys:libuser"

// What a check found and did. Every count is a fact about the volume, and
// on a clean one the two that matter -- `leaked` and `orphans` -- are zero.
Check :: struct {
	inodes:  u32, // In use and reachable from the root
	dirs:    u32, // Of those, directories
	blocks:  u32, // Data blocks a live inode reaches
	leaked:  u32, // Blocks the bitmap held that nothing reaches -- reclaimed
	orphans: u32, // Inodes in use that no directory names -- cleared
	dangling: u32, // Entries naming a free inode -- reported, left alone
	ok:      bool,
}

@(private = "file")
seen: []u8 // One bit per inode, set when the mark reaches it
@(private = "file")
used: []u8 // One bit per block, set for metadata and every reached block

@(private = "file")
bset :: proc "contextless" (bits: []u8, i: u32) #no_bounds_check {
	bits[i / 8] |= 1 << (i % 8)
}

@(private = "file")
bget :: proc "contextless" (bits: []u8, i: u32) -> bool #no_bounds_check {
	return bits[i / 8] & (1 << (i % 8)) != 0
}

// slot reads pointer `i` out of a table block, copying the word so the next
// `bread` may evict the block -- the rule `disk.odin` keeps for the same
// reason.
@(private = "file")
slot :: proc "contextless" (table: u32, i: u32) -> u32 #no_bounds_check {
	t := bread(table)
	if t == nil {
		return 0
	}
	b := t[i * 4:]
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

// mark_table marks every data block a single indirect table names.
@(private = "file")
mark_table :: proc "contextless" (c: ^Check, table: u32) #no_bounds_check {
	for i := u32(0); i < INDIRECT_ENTRIES; i += 1 {
		b := slot(table, i)
		if b != 0 {
			bset(used, b)
			c.blocks += 1
		}
	}
}

// mark_blocks marks every block inode `in_` reaches: the direct blocks, the
// indirect table and its blocks, and the double table, its inner tables and
// theirs. The table blocks themselves are used too, not only the data.
@(private = "file")
mark_blocks :: proc "contextless" (c: ^Check, in_: ^Inode) #no_bounds_check {
	for d in in_.direct {
		if d != 0 {
			bset(used, d)
			c.blocks += 1
		}
	}
	if in_.indirect != 0 {
		bset(used, in_.indirect)
		mark_table(c, in_.indirect)
	}
	if in_.double != 0 {
		bset(used, in_.double)
		for oi := u32(0); oi < INDIRECT_ENTRIES; oi += 1 {
			inner := slot(in_.double, oi)
			if inner != 0 {
				bset(used, inner)
				mark_table(c, inner)
			}
		}
	}
}

/*
check_volume walks the mounted volume, reclaims what a crash can leak, and
answers what it found. `seen` and `used` are one bit per inode and per block,
allocated on the heap this program has, so the walk holds the whole truth in
memory and reconciles the disk to it once.
*/
check_volume :: proc() -> Check {
	c: Check
	seen = make([]u8, (vol.sb.inodes + 7) / 8)
	used = make([]u8, (vol.sb.blocks + 7) / 8)
	if seen == nil || used == nil {
		return c
	}
	defer delete(seen)
	defer delete(used)

	// The tables are used by definition: the superblock, the bitmap and the
	// inode table, block 0 up to the first data block.
	for b := u32(0); b < vol.sb.data_start; b += 1 {
		bset(used, b)
	}

	// The mark: a worklist of directory inodes, starting at the root. An
	// inode is put on it once, when a directory first names it, and its own
	// blocks are marked when it comes off -- so the root's blocks are marked
	// too, though nothing names it.
	work: [dynamic]u32
	defer delete(work)
	append(&work, ROOT_INODE)
	bset(seen, ROOT_INODE)

	for len(work) > 0 {
		ino := pop(&work)
		in_: Inode
		if !get_inode(ino, &in_) || in_.mode == 0 {
			continue
		}
		c.inodes += 1
		mark_blocks(&c, &in_)
		if in_.mode & DMDIR == 0 {
			continue
		}
		c.dirs += 1

		// Its entries. A block is re-read per entry, because reading a
		// child's inode may evict it -- `load_children`'s rule.
		nblocks := u32((in_.size + BLOCK - 1) / BLOCK)
		for bi := u32(0); bi < nblocks; bi += 1 {
			blk, ok := bmap(&in_, bi, false)
			if !ok || blk == 0 {
				continue
			}
			for s := 0; s < DIRENTS_PER_BLOCK; s += 1 {
				data := bread(blk)
				if data == nil {
					break
				}
				e := data[s * DIRENT:(s + 1) * DIRENT]
				cino := u32(e[0]) | u32(e[1]) << 8 | u32(e[2]) << 16 | u32(e[3]) << 24
				if cino == 0 || cino >= vol.sb.inodes {
					continue
				}
				length := int(e[4])
				if length == 0 || length > NAME_MAX {
					continue
				}
				cin: Inode
				if !get_inode(cino, &cin) || cin.mode == 0 {
					// An entry naming a free inode. The write order does
					// not make one; report it and leave the entry, rather
					// than guess which of the two is the truth.
					c.dangling += 1
					continue
				}
				if bget(seen, cino) {
					continue // Seen already: a second name, or a cycle.
				}
				bset(seen, cino)
				append(&work, cino)
			}
		}
	}

	// The sweep of the inode table: an inode in use the mark never reached
	// is an orphan. Its blocks are already absent from `used`, so clearing
	// its record is the whole of freeing it -- the bitmap rewrite below
	// reclaims the blocks.
	for ino := u32(1); ino < vol.sb.inodes; ino += 1 {
		in_: Inode
		if !get_inode(ino, &in_) || in_.mode == 0 {
			continue
		}
		if !bget(seen, ino) {
			c.orphans += 1
			empty: Inode
			_ = put_inode(ino, &empty)
		}
	}

	// The bitmap, rewritten from `used`. The on-disk bitmap and `used` share
	// a layout -- bit b of block b -- so a bitmap block's bytes are a run of
	// `used`. Before overwriting, count the bits the disk held that `used`
	// does not: those are the leaked blocks, reclaimed by this write.
	live := u32(0)
	for j := u32(0); j < vol.sb.bitmap_blocks; j += 1 {
		blk := vol.sb.bitmap_start + j
		data := bread(blk)
		if data == nil {
			return c
		}
		for i := 0; i < BLOCK; i += 1 {
			idx := int(j) * BLOCK + i
			want: u8 = idx < len(used) ? used[idx] : 0
			have := data[i]
			c.leaked += u32(intrinsics.count_ones(have & ~want))
			live += u32(intrinsics.count_ones(want))
			data[i] = want
		}
		if !bwrite(blk) {
			return c
		}
	}

	// The free count is whatever the used set left. Kept in memory; a mount
	// counts it afresh, so nothing on disk holds it.
	vol.free = vol.sb.blocks - live
	vol.next_block = vol.sb.data_start
	c.ok = true
	return c
}

// report_check writes the survey to descriptor 2, one line, so a boot that
// runs `kfs -c` says what it found whether or not it found anything.
report_check :: proc "contextless" (device: string, c: ^Check) {
	buf: [256]u8
	sink := libodin.sink_from(buf[:])
	libodin.put_str(&sink, "kfs -c ")
	libodin.put_str(&sink, device)
	if !c.ok {
		libodin.put_str(&sink, ": the check could not finish\n")
		_ = libuser.write(2, transmute([]u8)libodin.str(&sink))
		return
	}
	libodin.put_str(&sink, ": ")
	put_u32(&sink, c.inodes)
	libodin.put_str(&sink, " files (")
	put_u32(&sink, c.dirs)
	libodin.put_str(&sink, " dirs), ")
	put_u32(&sink, c.blocks)
	libodin.put_str(&sink, " blocks; ")
	put_u32(&sink, c.leaked)
	libodin.put_str(&sink, " leaked reclaimed, ")
	put_u32(&sink, c.orphans)
	libodin.put_str(&sink, " orphans cleared")
	if c.dangling > 0 {
		libodin.put_str(&sink, ", ")
		put_u32(&sink, c.dangling)
		libodin.put_str(&sink, " dangling entries")
	}
	libodin.put_str(&sink, "\n")
	_ = libuser.write(2, transmute([]u8)libodin.str(&sink))
}

@(private = "file")
put_u32 :: proc "contextless" (sink: ^libodin.Sink, v: u32) {
	libodin.put_uint(sink, u64(v))
}

// -- The negative control ----------------------------------------------------

/*
check_selftest proves the sweep reclaims, rather than only that it reports
zero on a volume with nothing to reclaim. A test that cannot fail proves
nothing -- `docs/TESTING.md` -- so this makes something to find: it marks
one free block taken, a leak nothing points at, runs the check, and requires
that block back. The mark and the reclaim cancel, so the volume is as it was
after; a checker that missed the leak leaves it taken and this answers false,
which the boot turns into a warning.
*/
// run_selftest runs the control and writes its one line to descriptor 2,
// answering whether it passed so the caller can serve or warn.
run_selftest :: proc(device: string) -> bool {
	leak, reclaimed, ok := check_selftest()
	buf: [192]u8
	sink := libodin.sink_from(buf[:])
	libodin.put_str(&sink, "kfs -t ")
	libodin.put_str(&sink, device)
	if ok {
		libodin.put_str(&sink, ": control passed -- a leak at block ")
		put_u32(&sink, leak)
		libodin.put_str(&sink, " was the one the check reclaimed\n")
	} else {
		libodin.put_str(&sink, ": CONTROL FAILED -- injected block ")
		put_u32(&sink, leak)
		libodin.put_str(&sink, " not the only leak reclaimed (")
		put_u32(&sink, reclaimed)
		libodin.put_str(&sink, " found)\n")
	}
	_ = libuser.write(2, transmute([]u8)libodin.str(&sink))
	return ok
}

check_selftest :: proc() -> (leak: u32, reclaimed: u32, ok: bool) {
	leak = first_free_block()
	if leak == 0 {
		return 0, 0, false // No free block to leak: a full volume, not a checker fault.
	}
	if !bit_take(leak) {
		return leak, 0, false
	}
	c := check_volume()
	if !c.ok {
		return leak, c.leaked, false
	}
	// Exactly the injected block must have been reclaimed -- one, not more
	// -- so the control affirms both that the sweep reclaims and that the
	// volume was otherwise clean. The block must read free again.
	taken, got := bit_taken(leak)
	ok = c.leaked == 1 && got && !taken
	return leak, c.leaked, ok
}

// first_free_block answers the first data block the bitmap calls free, or
// zero when the volume is full. Block zero is the superblock, never free, so
// zero is a safe `none`.
@(private = "file")
first_free_block :: proc "contextless" () -> u32 #no_bounds_check {
	for b := vol.sb.data_start; b < vol.sb.blocks; b += 1 {
		taken, ok := bit_taken(b)
		if !ok {
			return 0
		}
		if !taken {
			return b
		}
	}
	return 0
}

@(private = "file")
bit_taken :: proc "contextless" (b: u32) -> (taken: bool, ok: bool) #no_bounds_check {
	data := bread(vol.sb.bitmap_start + b / (BLOCK * 8))
	if data == nil {
		return false, false
	}
	bit := b % (BLOCK * 8)
	return data[bit / 8] & (1 << (bit % 8)) != 0, true
}

@(private = "file")
bit_take :: proc "contextless" (b: u32) -> bool #no_bounds_check {
	blk := vol.sb.bitmap_start + b / (BLOCK * 8)
	data := bread(blk)
	if data == nil {
		return false
	}
	bit := b % (BLOCK * 8)
	data[bit / 8] |= 1 << (bit % 8)
	return bwrite(blk)
}
