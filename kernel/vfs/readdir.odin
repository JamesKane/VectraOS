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

import "vsys:vectra9"

/*
    cookie = member_index << 56 | member_offset

Eight bits of member index, fifty-six of the member's own cookie. A union of
more than 256 trees would break this, and a server whose own cookies exceed
2^56 would too. Neither is a real number. Both are checked rather than assumed,
because an offset that silently wraps reads the wrong directory rather than
fails.
*/
UNION_MEMBER_SHIFT :: 56
UNION_OFFSET_MASK :: (u64(1) << UNION_MEMBER_SHIFT) - 1
MAX_UNION_MEMBERS :: 1 << (64 - UNION_MEMBER_SHIFT)

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
	if member_count(mp) < 2 {
		return readdir_one(c, offset, buf)
	}
	return readdir_union(c, mp, offset, buf)
}

// readdir_one is the ordinary case: one server, its own cookies, no rewriting.
@(private)
readdir_one :: proc(c: ^Chan, offset: u64, buf: []u8) -> (n: int, err: Errno) {
	count := u32(min(len(buf), int(c.server.session.msize) - vectra9.HEADER_SIZE - 4))
	request := vectra9.Msg(vectra9.Treaddir{fid = c.fid, offset = offset, count = count})
	reply: vectra9.Msg

	// Held to the end of the procedure: `answer.data` is the server's own
	// directory buffer, and it stays this thread's only while the session does.
	e, g := rpc(c.server, &request, &reply)
	defer rpc_end(g)
	if e != OK {
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
	n = copy(buf, answer.data)
	return n, OK
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
	idx := int(offset >> UNION_MEMBER_SHIFT)
	member_offset := offset & UNION_OFFSET_MASK

	out := vectra9.cursor_from(buf)

	for ; idx < MAX_UNION_MEMBERS; idx += 1 {
		member, _, present := member_ref_at(mp, idx)
		if !present {
			break // Past the last member: the union is exhausted.
		}
		defer chan_close(member)

		/*
		The caller's chan is already open on whichever member `cross_mounts`
		substituted, so that member is read through it rather than opened a second
		time. Matched by (server, qid.path), rather than assumed to be member zero.
		The assumption is true today, and is exactly the kind that stops being true
		quietly. A listing would then read one member's entries under another
		member's index.
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
		wrote, err = union_pass(src, idx, member_offset, &out)
		if !borrowed {
			chan_close(src)
		}
		if err != OK {
			return 0, err
		}
		if wrote > 0 {
			return out.pos, OK
		}

		// This member is spent. Move to the next one *within this call*, so a
		// caller never sees a zero-length read that is not the end.
		member_offset = 0
	}

	return out.pos, OK
}

/*
union_pass copies one member's entries into `out`, restamping the cookies.

Entries are re-encoded rather than memcpy'd, because the offset field has to
change. The re-encode is exact. Only `offset` differs, so the payload is the
same length it arrived as. That is what lets the request ask for exactly the
room left in `out` and be sure the answer fits.
*/
@(private)
union_pass :: proc(
	src: ^Chan,
	idx: int,
	member_offset: u64,
	out: ^vectra9.Cursor,
) -> (wrote: int, err: Errno) {
	room := vectra9.remaining(out)
	if room <= 0 {
		return 0, OK
	}

	count := u32(min(room, int(src.server.session.msize) - vectra9.HEADER_SIZE - 4))
	request := vectra9.Msg(
		vectra9.Treaddir{fid = src.fid, offset = member_offset, count = count},
	)
	reply: vectra9.Msg

	// The re-encode below reads `answer.data` all the way through, so the
	// session is held for the whole of it -- that buffer is the server's.
	e, g := rpc(src.server, &request, &reply)
	defer rpc_end(g)
	if e != OK {
		return 0, e
	}
	answer, ok := reply.(vectra9.Rreaddir)
	if !ok {
		return 0, vectra9.EPROTO
	}

	in_cursor := vectra9.cursor_from(answer.data)
	for {
		entry, more := vectra9.next_dirent(&in_cursor)
		if !more {
			break
		}
		if entry.offset > UNION_OFFSET_MASK {
			return 0, vectra9.EPROTO
		}
		entry.offset = u64(idx) << UNION_MEMBER_SHIFT | entry.offset
		vectra9.put_dirent(out, entry)
		if out.err != .None {
			return 0, vectra9.EPROTO
		}
		wrote += 1
	}

	if in_cursor.err != .None {
		return 0, vectra9.EPROTO
	}
	return wrote, OK
}
