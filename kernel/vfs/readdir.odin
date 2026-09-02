/*
Reading a directory, including one that is several directories.

Treaddir on a union concatenates its members' entries, in mount order.

**Duplicates are not filtered.** If `/tmp/bin` and `/bin` both contain `ls`, a
directory read shows `ls` twice, while *opening* `/bin/ls` gets the first. A
filter would mean every name already emitted held for the life of the read.
That is unbounded in the size of the directory, in the kernel, on behalf of a
client that may not care. Plan 9 made this call and it was right.

The offset is an opaque cookie, which 9P2000.L already requires. A Treaddir
offset must be zero, or a value an Rreaddir entry returned earlier. It is never
an arbitrary byte position. That requirement is what lets the union hide which
member it is partway through in the high bits.
*/
package vfs

import "kernel:sync"

import "vsys:vectra9"

/*
    cookie = member_id << 32 | member_offset

The high half is the member's id, the low half its own cookie. **The id is
not the member's position.** A position shifts when a `bind` or an `unmount`
between two `readdir` calls adds or removes an earlier member. The client
then resumes reading the wrong tree.

An id is monotonic and never reused, so `resume after this member` means the
same member however the list moved. `kernel/srv` is the directory this
treatment was written for, and its document argues it. `docs/NAMESPACE.md`
named the union as the place that could have it, and now does.

The split gives each half thirty-two bits. A mount point rebound more than
four billion times over its life runs its member id out. A `bind` then
answers `ENOSPC` rather than reuse one, which is `kernel/srv`'s rule for its
own id. A member server whose own cookie needs more than thirty-two bits is
refused too, with `EPROTO`. Neither is a real number for the servers this
tree has: every one numbers its entries by a small ordinal.
*/
UNION_MEMBER_SHIFT :: 32
UNION_OFFSET_MASK :: (u64(1) << UNION_MEMBER_SHIFT) - 1

/*
readdir fills `buf` with directory entries starting at `offset`.

`c` must be open. Zero bytes with no error is the end of the directory. That
includes the end of the last member of a union, which is the only end a caller
ever sees.

Returns raw Rreaddir payload: `qid[13] offset[8] type[1] name[s]` repeated.
Decode it with `vectra9.next_dirent` over a cursor.
*/
readdir :: proc(c: ^Chan, offset: u64, buf: []u8) -> (n: int, err: Errno) {
	if c == nil {
		return 0, vectra9.EBADF
	}
	if !chan_is_dir(c) {
		return 0, vectra9.ENOTDIR
	}
	if len(buf) == 0 {
		return 0, OK
	}

	mp := c.union_head
	if mp == nil {
		return readdir_one(c, offset, buf)
	}
	// Held across the whole listing, the way a walk holds it across the
	// whole search. A union that loses a member mid-call is a listing that
	// counted the wrong entries, and the write lock waits for this instead.
	sync.rlock(&mp.lock)
	defer sync.runlock(&mp.lock)
	if member_count(mp) < 2 {
		return readdir_one(c, offset, buf)
	}
	return readdir_union(c, mp, offset, buf)
}

// readdir_one is the ordinary case: one server, its own cookies, no rewriting.
@(private)
readdir_one :: proc(c: ^Chan, offset: u64, buf: []u8) -> (n: int, err: Errno) {
	count := u32(min(len(buf), max_payload(c.server)))
	request := vectra9.Msg(vectra9.Treaddir{fid = c.fid, offset = offset, count = count})
	reply: vectra9.Msg

	// `buf` is where the entries are built rather than where they are copied
	// afterwards. The caller's buffer is the server's for the length of the
	// message, and nobody else's ever.
	if e := rpc(c.server, &request, &reply, buf); e != OK {
		return 0, e
	}
	answer, ok := reply.(vectra9.Rreaddir)
	if !ok {
		return 0, vectra9.EPROTO
	}

	// The server was told how much room there is, so a payload that does not fit
	// is a server bug. A truncation would cut an entry in half, and hand the
	// caller a cursor that fails mid-name. A refusal says which side is wrong.
	if len(answer.data) > len(buf) {
		return 0, vectra9.EPROTO
	}
	return take_payload(buf, answer.data), OK
}

/*
readdir_union concatenates members, rewriting each entry's cookie as it goes.

Members after the first are opened and clunked inside this call rather than
held open across it. That costs three messages per member per call, and it buys
the property that matters here. The cookie is absolute, so nothing carries
between calls.

A caller may therefore abandon a listing halfway through, and leak no fid on
any tree it touched. When there is a process to hang the state off, this is
where a cached per-member fid goes.

A union rebound part-way through a listing is undefined. The member index in a
cookie names a position in a list that moved. Plan 9 has the same property, for
the same reason.
*/
@(private)
readdir_union :: proc(
	c: ^Chan,
	mp: ^Mount_Point,
	offset: u64,
	buf: []u8,
) -> (n: int, err: Errno) {
	resume_id := u32(offset >> UNION_MEMBER_SHIFT)
	member_offset := offset & UNION_OFFSET_MASK

	out := vectra9.cursor_from(buf)

	// The member the cookie named, then every member with a higher id, in id
	// order. `min_id` walks up. The first pass resumes the named member at its
	// own cookie, and each spent member hands the next its whole listing from
	// the start.
	min_id := resume_id
	for {
		member, _, id, present := member_at_or_after(mp, min_id)
		if !present {
			break // No member at that id or above: the union is exhausted.
		}
		defer chan_close(member)

		// The member the cookie named resumes at its own offset. Every member
		// past it is one this listing has not reached, and starts at zero.
		start := id == resume_id ? member_offset : 0

		/*
		The caller's chan is already open on whichever member `cross_mounts`
		substituted, so that member is read through it rather than opened a second
		time. Matched by (server, qid.path), rather than assumed to be member zero.
		The assumption is true today, and is exactly the kind that stops being true
		quietly. A listing would then read one member's entries under another
		member's id.
		*/
		src := c
		borrowed := true
		if member.server != c.server || member.qid.path != c.qid.path {
			src, err = chan_clone(member)
			if err != OK {
				return 0, err
			}
			if e := chan_open(src, O_RDONLY | O_DIRECTORY); e != OK {
				chan_close(src)
				return 0, e
			}
			borrowed = false
		}

		wrote: int
		wrote, err = union_pass(src, id, start, &out)
		if !borrowed {
			chan_close(src)
		}
		if err != OK {
			return 0, err
		}
		if wrote > 0 {
			return out.pos, OK
		}

		// This member is spent. Move to the next id up *within this call*, so
		// a caller never sees a zero-length read that is not the end.
		min_id = id + 1
	}

	return out.pos, OK
}

/*
union_pass takes one member's entries into `out`, restamping the cookies where
they lie.

The member answers into the room `out` leaves, which is the caller's own buffer
at the point this listing reached. Nothing is copied. Only the cookie has to
change, and it is eight bytes at a known place inside an entry that is otherwise
already exactly right.

That is the whole of what the old re-encode did, and the old comment said as
much. The re-encode was exact, only `offset` differed, and the payload was the
same length it arrived as. The payload now arrives here rather than in the
server's own buffer, so there is no second copy of it to read from.

It is also why the request may ask for exactly the room left and be sure the
answer fits.
*/
@(private)
union_pass :: proc(
	src: ^Chan,
	member_id: u32,
	member_offset: u64,
	out: ^vectra9.Cursor,
) -> (wrote: int, err: Errno) {
	room := vectra9.remaining(out)
	if room <= 0 {
		return 0, OK
	}
	landing := vectra9.free_space(out)

	count := u32(min(room, max_payload(src.server)))
	request := vectra9.Msg(
		vectra9.Treaddir{fid = src.fid, offset = member_offset, count = count},
	)
	reply: vectra9.Msg
	if e := rpc(src.server, &request, &reply, landing); e != OK {
		return 0, e
	}
	answer, ok := reply.(vectra9.Rreaddir)
	if !ok {
		return 0, vectra9.EPROTO
	}
	if len(answer.data) > room {
		return 0, vectra9.EPROTO
	}
	n := take_payload(landing, answer.data)

	/*
	Every entry is walked before any of it is kept, and a malformed one fails
	the whole pass.

	The walk is what validates the payload, and the patch rides on it. `at` is
	where the entry starts, and a cookie sits `QID_WIRE_SIZE` bytes into it. That
	is the layout `put_dirent` writes and `next_dirent` reads, stated once in
	`codec.odin` and relied on here.
	*/
	scan := vectra9.cursor_from(landing[:n])
	for {
		at := scan.pos
		entry, more := vectra9.next_dirent(&scan)
		if !more {
			break
		}
		if entry.offset > UNION_OFFSET_MASK {
			return 0, vectra9.EPROTO
		}
		patch := vectra9.cursor_from(landing[at + vectra9.QID_WIRE_SIZE:])
		vectra9.put_u64(&patch, u64(member_id) << UNION_MEMBER_SHIFT | entry.offset)
		if patch.err != .None {
			return 0, vectra9.EPROTO
		}
		wrote += 1
	}

	if scan.err != .None {
		return 0, vectra9.EPROTO
	}
	if !vectra9.commit(out, n) {
		return 0, vectra9.EPROTO
	}
	return wrote, OK
}
