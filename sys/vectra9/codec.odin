/*
The wire codec: decoded messages to 9P2000.L bytes, and back.

Only a transport that crosses an address space ever calls this. An in-process
call passes the `Msg` by pointer, and this file takes no part. That is the
whole point of the layer, and it is why the codec can afford to be strict and
simple rather than fast.

Framing is `size[4] type[1] tag[2]` then a body, with `size` counting itself.
Strings are a 16-bit length and then bytes, never NUL-terminated. Qids are
thirteen bytes on the wire and sixteen in memory. Everything is little-endian,
and assembled a byte at a time rather than cast through a pointer. A message
buffer has no alignment guarantee, and an unaligned `u64` load is a fault on
some of the architectures Vectra intends to run on.

Bounds are checked once per field, in `advance`, and the first failure latches
into `Cursor.err`. Every accessor after that is a no-op that returns zero. A
long decode therefore needs no check after every line, because the error is
still there at the end.
*/
package vectra9

/*
A bounds-checked position in a buffer, for reading or for writing.

Errors latch rather than saturating, which is the opposite of `libodin.Sink`. A
truncated log line is better than no log line. A truncated 9P message is a
protocol violation. A codec that quietly produced one would put a malformed
message on the wire, and blame the far end.
*/
Cursor :: struct {
	buf: []u8,
	pos: int,
	err: Error,
}

cursor_from :: proc "contextless" (buf: []u8) -> Cursor {
	return Cursor{buf = buf}
}

// bytes returns what the cursor wrote so far.
written :: proc "contextless" (c: ^Cursor) -> []u8 {
	return c.buf[:c.pos]
}

// remaining reports how much room or data is left. Servers use it to size an
// Rread against what the client asked for.
remaining :: proc "contextless" (c: ^Cursor) -> int {
	if c.err != .None {
		return 0
	}
	return len(c.buf) - c.pos
}

/*
free_space hands back the room left, for a caller that fills it some other way
than field by field.

The one that does is a payload which arrives already encoded and needs a field
changed. `kernel/vfs`'s union directory read is that: a member's entries land
here and only the cookie is rewritten. Copying them through this cursor would
mean holding the same bytes twice to change eight of them.

`commit` is how the caller says how much it used.
*/
free_space :: proc "contextless" (c: ^Cursor) -> []u8 {
	if c.err != .None {
		return nil
	}
	return c.buf[c.pos:]
}

// commit advances past bytes a caller wrote into `free_space` itself. Latches
// `Short_Buffer` rather than moves past the end, like every other write here.
commit :: proc "contextless" (c: ^Cursor, n: int) -> bool {
	if c.err != .None {
		return false
	}
	if n < 0 || c.pos + n > len(c.buf) {
		c.err = .Short_Buffer
		return false
	}
	c.pos += n
	return true
}

@(private = "file")
advance :: proc "contextless" (c: ^Cursor, n: int) -> (start: int, ok: bool) {
	if c.err != .None {
		return 0, false
	}
	if n < 0 || c.pos + n > len(c.buf) {
		c.err = .Short_Buffer
		return 0, false
	}
	start = c.pos
	c.pos += n
	return start, true
}

// -- Primitives --------------------------------------------------------------

put_u8 :: proc "contextless" (c: ^Cursor, v: u8) #no_bounds_check {
	if i, ok := advance(c, 1); ok {
		c.buf[i] = v
	}
}

put_u16 :: proc "contextless" (c: ^Cursor, v: u16) #no_bounds_check {
	if i, ok := advance(c, 2); ok {
		c.buf[i + 0] = u8(v)
		c.buf[i + 1] = u8(v >> 8)
	}
}

put_u32 :: proc "contextless" (c: ^Cursor, v: u32) #no_bounds_check {
	if i, ok := advance(c, 4); ok {
		c.buf[i + 0] = u8(v)
		c.buf[i + 1] = u8(v >> 8)
		c.buf[i + 2] = u8(v >> 16)
		c.buf[i + 3] = u8(v >> 24)
	}
}

put_u64 :: proc "contextless" (c: ^Cursor, v: u64) #no_bounds_check {
	if i, ok := advance(c, 8); ok {
		for b in 0 ..< 8 {
			c.buf[i + b] = u8(v >> uint(8 * b))
		}
	}
}

put_string :: proc "contextless" (c: ^Cursor, s: string) #no_bounds_check {
	if len(s) > 0xFFFF {
		c.err = .String_Too_Long
		return
	}
	put_u16(c, u16(len(s)))
	if i, ok := advance(c, len(s)); ok {
		for b in 0 ..< len(s) {
			c.buf[i + b] = s[b]
		}
	}
}

put_qid :: proc "contextless" (c: ^Cursor, q: Qid) {
	put_u8(c, transmute(u8)q.kind)
	put_u32(c, q.version)
	put_u64(c, q.path)
}

// put_data writes a count-prefixed payload: `count[4]` then the bytes. The
// shape Tread, Rread, Twrite and Rreaddir all share.
put_data :: proc "contextless" (c: ^Cursor, data: []u8) #no_bounds_check {
	put_u32(c, u32(len(data)))
	if i, ok := advance(c, len(data)); ok {
		for b in 0 ..< len(data) {
			c.buf[i + b] = data[b]
		}
	}
}

get_u8 :: proc "contextless" (c: ^Cursor) -> u8 #no_bounds_check {
	if i, ok := advance(c, 1); ok {
		return c.buf[i]
	}
	return 0
}

get_u16 :: proc "contextless" (c: ^Cursor) -> u16 #no_bounds_check {
	if i, ok := advance(c, 2); ok {
		return u16(c.buf[i]) | u16(c.buf[i + 1]) << 8
	}
	return 0
}

get_u32 :: proc "contextless" (c: ^Cursor) -> u32 #no_bounds_check {
	if i, ok := advance(c, 4); ok {
		return(
			u32(c.buf[i]) |
			u32(c.buf[i + 1]) << 8 |
			u32(c.buf[i + 2]) << 16 |
			u32(c.buf[i + 3]) << 24 \
		)
	}
	return 0
}

get_u64 :: proc "contextless" (c: ^Cursor) -> u64 #no_bounds_check {
	if i, ok := advance(c, 8); ok {
		v: u64
		for b in 0 ..< 8 {
			v |= u64(c.buf[i + b]) << uint(8 * b)
		}
		return v
	}
	return 0
}

/*
get_string returns a string aliasing the cursor's buffer.

Borrowed, not copied -- see the ownership rule at the top of `proto.odin`. The
returned string is valid exactly as long as the buffer is.
*/
get_string :: proc "contextless" (c: ^Cursor) -> string #no_bounds_check {
	n := int(get_u16(c))
	if i, ok := advance(c, n); ok {
		return string(c.buf[i:i + n])
	}
	return ""
}

get_qid :: proc "contextless" (c: ^Cursor) -> Qid {
	q: Qid
	q.kind = transmute(Qid_Flags)get_u8(c)
	q.version = get_u32(c)
	q.path = get_u64(c)
	return q
}

// get_data returns a count-prefixed payload, aliasing the buffer.
get_data :: proc "contextless" (c: ^Cursor) -> []u8 #no_bounds_check {
	n := int(get_u32(c))
	if i, ok := advance(c, n); ok {
		return c.buf[i:i + n]
	}
	return nil
}

// -- Directory entries -------------------------------------------------------

/*
One entry inside an Rreaddir payload: `qid[13] offset[8] type[1] name[s]`.

`offset` is the cookie a client passes back to continue the listing. It is what
the next Treaddir's offset field must be, to read the entry *after* this one.
It is deliberately opaque. A union directory hides its member index in the high
bits of exactly this field.
*/
Dirent :: struct {
	qid:    Qid,
	offset: u64,
	type:   u8, // DT_DIR, DT_REG, DT_LNK ... as Linux numbers them
	name:   string,
}

DT_UNKNOWN :: u8(0)
DT_DIR :: u8(4)
DT_REG :: u8(8)
DT_LNK :: u8(10)

// dirent_size is what one entry will occupy, so a server can stop filling a
// buffer before it overruns the count the client asked for.
dirent_size :: proc "contextless" (name: string) -> int {
	return QID_WIRE_SIZE + 8 + 1 + 2 + len(name)
}

put_dirent :: proc "contextless" (c: ^Cursor, e: Dirent) {
	put_qid(c, e.qid)
	put_u64(c, e.offset)
	put_u8(c, e.type)
	put_string(c, e.name)
}

// next_dirent reads one entry, reporting false at the end of the payload or on
// a malformed one.
next_dirent :: proc "contextless" (c: ^Cursor) -> (e: Dirent, ok: bool) {
	if c.err != .None || remaining(c) == 0 {
		return {}, false
	}
	e.qid = get_qid(c)
	e.offset = get_u64(c)
	e.type = get_u8(c)
	e.name = get_string(c)
	return e, c.err == .None
}

// -- Whole messages ----------------------------------------------------------

/*
encode writes one complete message into `buf` and returns its length.

The size field goes in as a placeholder, and gets patched once the body is
known. That is cheaper than two measurements of the message, and it is why
`buf` has to be writable rather than a stream.
*/
encode :: proc "contextless" (buf: []u8, tag: Tag, msg: Msg) -> (n: int, err: Error) #no_bounds_check {
	c := cursor_from(buf)

	put_u32(&c, 0) // Patched below
	put_u8(&c, u8(kind(msg)))
	put_u16(&c, u16(tag))
	encode_body(&c, msg)

	if c.err != .None {
		return 0, c.err
	}

	size := u32(c.pos)
	c.buf[0] = u8(size)
	c.buf[1] = u8(size >> 8)
	c.buf[2] = u8(size >> 16)
	c.buf[3] = u8(size >> 24)
	return c.pos, .None
}

/*
message_size peeks at a message's declared length without decoding it.

What a stream transport needs to know how many bytes to wait for. Reports false
until at least the four bytes of the size field arrive.
*/
message_size :: proc "contextless" (data: []u8) -> (size: u32, ok: bool) #no_bounds_check {
	if len(data) < 4 {
		return 0, false
	}
	size = u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
	return size, size >= HEADER_SIZE
}

/*
decode parses one message out of `data`.

Trailing bytes are permitted and ignored, so a caller that holds a stream
buffer can pass what it has. The message's own declared size bounds it.
Anything that claims to be longer than the buffer is refused rather than read.

The result borrows `data`.
*/
decode :: proc "contextless" (data: []u8) -> (tag: Tag, msg: Msg, err: Error) {
	size, ok := message_size(data)
	if !ok {
		return 0, nil, .Short_Buffer
	}
	if int(size) > len(data) {
		return 0, nil, .Size_Mismatch
	}

	// Bound the cursor by the declared size, not by the buffer. A body that tries
	// to read past its own message is a malformed message, not a short buffer.
	// The bound is here, so every accessor below gets that for free.
	c := cursor_from(data[:size])
	c.pos = 4

	raw := get_u8(&c)
	tag = Tag(get_u16(&c))
	if c.err != .None {
		return 0, nil, c.err
	}
	if raw == 6 {
		return tag, nil, .Illegal_Kind
	}

	msg, err = decode_body(&c, Kind(raw))
	if err != .None {
		return tag, nil, err
	}
	return tag, msg, .None
}

// -- Bodies ------------------------------------------------------------------

@(private = "file")
encode_body :: proc "contextless" (c: ^Cursor, msg: Msg) {
	switch m in msg {
	case Rlerror:
		put_u32(c, m.ecode)

	case Tstatfs:
		put_u32(c, u32(m.fid))
	case Rstatfs:
		put_u32(c, m.type)
		put_u32(c, m.bsize)
		put_u64(c, m.blocks)
		put_u64(c, m.bfree)
		put_u64(c, m.bavail)
		put_u64(c, m.files)
		put_u64(c, m.ffree)
		put_u64(c, m.fsid)
		put_u32(c, m.namelen)

	case Tlopen:
		put_u32(c, u32(m.fid))
		put_u32(c, m.flags)
	case Rlopen:
		put_qid(c, m.qid)
		put_u32(c, m.iounit)

	case Tlcreate:
		put_u32(c, u32(m.fid))
		put_string(c, m.name)
		put_u32(c, m.flags)
		put_u32(c, m.mode)
		put_u32(c, m.gid)
	case Rlcreate:
		put_qid(c, m.qid)
		put_u32(c, m.iounit)

	case Tsymlink:
		put_u32(c, u32(m.fid))
		put_string(c, m.name)
		put_string(c, m.target)
		put_u32(c, m.gid)
	case Rsymlink:
		put_qid(c, m.qid)

	case Tmknod:
		put_u32(c, u32(m.dfid))
		put_string(c, m.name)
		put_u32(c, m.mode)
		put_u32(c, m.major)
		put_u32(c, m.minor)
		put_u32(c, m.gid)
	case Rmknod:
		put_qid(c, m.qid)

	case Trename:
		put_u32(c, u32(m.fid))
		put_u32(c, u32(m.dfid))
		put_string(c, m.name)
	case Rrename:

	case Treadlink:
		put_u32(c, u32(m.fid))
	case Rreadlink:
		put_string(c, m.target)

	case Tgetattr:
		put_u32(c, u32(m.fid))
		put_u64(c, m.request_mask)
	case Rgetattr:
		put_u64(c, m.valid)
		put_qid(c, m.qid)
		put_u32(c, m.mode)
		put_u32(c, m.uid)
		put_u32(c, m.gid)
		put_u64(c, m.nlink)
		put_u64(c, m.rdev)
		put_u64(c, m.size)
		put_u64(c, m.blksize)
		put_u64(c, m.blocks)
		put_u64(c, m.atime_sec)
		put_u64(c, m.atime_nsec)
		put_u64(c, m.mtime_sec)
		put_u64(c, m.mtime_nsec)
		put_u64(c, m.ctime_sec)
		put_u64(c, m.ctime_nsec)
		put_u64(c, m.btime_sec)
		put_u64(c, m.btime_nsec)
		put_u64(c, m.gen)
		put_u64(c, m.data_version)

	case Tsetattr:
		put_u32(c, u32(m.fid))
		put_u32(c, m.valid)
		put_u32(c, m.mode)
		put_u32(c, m.uid)
		put_u32(c, m.gid)
		put_u64(c, m.size)
		put_u64(c, m.atime_sec)
		put_u64(c, m.atime_nsec)
		put_u64(c, m.mtime_sec)
		put_u64(c, m.mtime_nsec)
	case Rsetattr:

	case Txattrwalk:
		put_u32(c, u32(m.fid))
		put_u32(c, u32(m.newfid))
		put_string(c, m.name)
	case Rxattrwalk:
		put_u64(c, m.size)

	case Txattrcreate:
		put_u32(c, u32(m.fid))
		put_string(c, m.name)
		put_u64(c, m.attr_size)
		put_u32(c, m.flags)
	case Rxattrcreate:

	case Treaddir:
		put_u32(c, u32(m.fid))
		put_u64(c, m.offset)
		put_u32(c, m.count)
	case Rreaddir:
		put_data(c, m.data)

	case Tfsync:
		put_u32(c, u32(m.fid))
		put_u32(c, m.datasync)
	case Rfsync:

	case Tlock:
		put_u32(c, u32(m.fid))
		put_u8(c, m.type)
		put_u32(c, m.flags)
		put_u64(c, m.start)
		put_u64(c, m.length)
		put_u32(c, m.proc_id)
		put_string(c, m.client_id)
	case Rlock:
		put_u8(c, m.status)

	case Tgetlock:
		put_u32(c, u32(m.fid))
		put_u8(c, m.type)
		put_u64(c, m.start)
		put_u64(c, m.length)
		put_u32(c, m.proc_id)
		put_string(c, m.client_id)
	case Rgetlock:
		put_u8(c, m.type)
		put_u64(c, m.start)
		put_u64(c, m.length)
		put_u32(c, m.proc_id)
		put_string(c, m.client_id)

	case Tlink:
		put_u32(c, u32(m.dfid))
		put_u32(c, u32(m.fid))
		put_string(c, m.name)
	case Rlink:

	case Tmkdir:
		put_u32(c, u32(m.dfid))
		put_string(c, m.name)
		put_u32(c, m.mode)
		put_u32(c, m.gid)
	case Rmkdir:
		put_qid(c, m.qid)

	case Trenameat:
		put_u32(c, u32(m.olddirfid))
		put_string(c, m.oldname)
		put_u32(c, u32(m.newdirfid))
		put_string(c, m.newname)
	case Rrenameat:

	case Tunlinkat:
		put_u32(c, u32(m.dirfid))
		put_string(c, m.name)
		put_u32(c, m.flags)
	case Runlinkat:

	case Tversion:
		put_u32(c, m.msize)
		put_string(c, m.version)
	case Rversion:
		put_u32(c, m.msize)
		put_string(c, m.version)

	case Tauth:
		put_u32(c, u32(m.afid))
		put_string(c, m.uname)
		put_string(c, m.aname)
		put_u32(c, m.n_uname)
	case Rauth:
		put_qid(c, m.aqid)

	case Tattach:
		put_u32(c, u32(m.fid))
		put_u32(c, u32(m.afid))
		put_string(c, m.uname)
		put_string(c, m.aname)
		put_u32(c, m.n_uname)
	case Rattach:
		put_qid(c, m.qid)

	case Tflush:
		put_u16(c, u16(m.oldtag))
	case Rflush:

	case Twalk:
		if m.count > MAX_WALK_ELEMENTS || m.count < 0 {
			c.err = .Too_Many_Walk_Elements
			return
		}
		put_u32(c, u32(m.fid))
		put_u32(c, u32(m.newfid))
		put_u16(c, u16(m.count))
		for i in 0 ..< m.count {
			put_string(c, m.names[i])
		}
	case Rwalk:
		if m.count > MAX_WALK_ELEMENTS || m.count < 0 {
			c.err = .Too_Many_Walk_Elements
			return
		}
		put_u16(c, u16(m.count))
		for i in 0 ..< m.count {
			put_qid(c, m.qids[i])
		}

	case Tread:
		put_u32(c, u32(m.fid))
		put_u64(c, m.offset)
		put_u32(c, m.count)
	case Rread:
		put_data(c, m.data)

	case Twrite:
		put_u32(c, u32(m.fid))
		put_u64(c, m.offset)
		put_data(c, m.data)
	case Rwrite:
		put_u32(c, m.count)

	case Tclunk:
		put_u32(c, u32(m.fid))
	case Rclunk:

	case Tremove:
		put_u32(c, u32(m.fid))
	case Rremove:
	}
}

@(private = "file")
decode_body :: proc "contextless" (c: ^Cursor, k: Kind) -> (Msg, Error) {
	msg: Msg

	switch k {
	case .Rlerror:
		msg = Rlerror{ecode = get_u32(c)}

	case .Tstatfs:
		msg = Tstatfs{fid = Fid(get_u32(c))}
	case .Rstatfs:
		m: Rstatfs
		m.type = get_u32(c)
		m.bsize = get_u32(c)
		m.blocks = get_u64(c)
		m.bfree = get_u64(c)
		m.bavail = get_u64(c)
		m.files = get_u64(c)
		m.ffree = get_u64(c)
		m.fsid = get_u64(c)
		m.namelen = get_u32(c)
		msg = m

	case .Tlopen:
		m: Tlopen
		m.fid = Fid(get_u32(c))
		m.flags = get_u32(c)
		msg = m
	case .Rlopen:
		m: Rlopen
		m.qid = get_qid(c)
		m.iounit = get_u32(c)
		msg = m

	case .Tlcreate:
		m: Tlcreate
		m.fid = Fid(get_u32(c))
		m.name = get_string(c)
		m.flags = get_u32(c)
		m.mode = get_u32(c)
		m.gid = get_u32(c)
		msg = m
	case .Rlcreate:
		m: Rlcreate
		m.qid = get_qid(c)
		m.iounit = get_u32(c)
		msg = m

	case .Tsymlink:
		m: Tsymlink
		m.fid = Fid(get_u32(c))
		m.name = get_string(c)
		m.target = get_string(c)
		m.gid = get_u32(c)
		msg = m
	case .Rsymlink:
		msg = Rsymlink{qid = get_qid(c)}

	case .Tmknod:
		m: Tmknod
		m.dfid = Fid(get_u32(c))
		m.name = get_string(c)
		m.mode = get_u32(c)
		m.major = get_u32(c)
		m.minor = get_u32(c)
		m.gid = get_u32(c)
		msg = m
	case .Rmknod:
		msg = Rmknod{qid = get_qid(c)}

	case .Trename:
		m: Trename
		m.fid = Fid(get_u32(c))
		m.dfid = Fid(get_u32(c))
		m.name = get_string(c)
		msg = m
	case .Rrename:
		msg = Rrename{}

	case .Treadlink:
		msg = Treadlink{fid = Fid(get_u32(c))}
	case .Rreadlink:
		msg = Rreadlink{target = get_string(c)}

	case .Tgetattr:
		m: Tgetattr
		m.fid = Fid(get_u32(c))
		m.request_mask = get_u64(c)
		msg = m
	case .Rgetattr:
		m: Rgetattr
		m.valid = get_u64(c)
		m.qid = get_qid(c)
		m.mode = get_u32(c)
		m.uid = get_u32(c)
		m.gid = get_u32(c)
		m.nlink = get_u64(c)
		m.rdev = get_u64(c)
		m.size = get_u64(c)
		m.blksize = get_u64(c)
		m.blocks = get_u64(c)
		m.atime_sec = get_u64(c)
		m.atime_nsec = get_u64(c)
		m.mtime_sec = get_u64(c)
		m.mtime_nsec = get_u64(c)
		m.ctime_sec = get_u64(c)
		m.ctime_nsec = get_u64(c)
		m.btime_sec = get_u64(c)
		m.btime_nsec = get_u64(c)
		m.gen = get_u64(c)
		m.data_version = get_u64(c)
		msg = m

	case .Tsetattr:
		m: Tsetattr
		m.fid = Fid(get_u32(c))
		m.valid = get_u32(c)
		m.mode = get_u32(c)
		m.uid = get_u32(c)
		m.gid = get_u32(c)
		m.size = get_u64(c)
		m.atime_sec = get_u64(c)
		m.atime_nsec = get_u64(c)
		m.mtime_sec = get_u64(c)
		m.mtime_nsec = get_u64(c)
		msg = m
	case .Rsetattr:
		msg = Rsetattr{}

	case .Txattrwalk:
		m: Txattrwalk
		m.fid = Fid(get_u32(c))
		m.newfid = Fid(get_u32(c))
		m.name = get_string(c)
		msg = m
	case .Rxattrwalk:
		msg = Rxattrwalk{size = get_u64(c)}

	case .Txattrcreate:
		m: Txattrcreate
		m.fid = Fid(get_u32(c))
		m.name = get_string(c)
		m.attr_size = get_u64(c)
		m.flags = get_u32(c)
		msg = m
	case .Rxattrcreate:
		msg = Rxattrcreate{}

	case .Treaddir:
		m: Treaddir
		m.fid = Fid(get_u32(c))
		m.offset = get_u64(c)
		m.count = get_u32(c)
		msg = m
	case .Rreaddir:
		msg = Rreaddir{data = get_data(c)}

	case .Tfsync:
		m: Tfsync
		m.fid = Fid(get_u32(c))
		m.datasync = get_u32(c)
		msg = m
	case .Rfsync:
		msg = Rfsync{}

	case .Tlock:
		m: Tlock
		m.fid = Fid(get_u32(c))
		m.type = get_u8(c)
		m.flags = get_u32(c)
		m.start = get_u64(c)
		m.length = get_u64(c)
		m.proc_id = get_u32(c)
		m.client_id = get_string(c)
		msg = m
	case .Rlock:
		msg = Rlock{status = get_u8(c)}

	case .Tgetlock:
		m: Tgetlock
		m.fid = Fid(get_u32(c))
		m.type = get_u8(c)
		m.start = get_u64(c)
		m.length = get_u64(c)
		m.proc_id = get_u32(c)
		m.client_id = get_string(c)
		msg = m
	case .Rgetlock:
		m: Rgetlock
		m.type = get_u8(c)
		m.start = get_u64(c)
		m.length = get_u64(c)
		m.proc_id = get_u32(c)
		m.client_id = get_string(c)
		msg = m

	case .Tlink:
		m: Tlink
		m.dfid = Fid(get_u32(c))
		m.fid = Fid(get_u32(c))
		m.name = get_string(c)
		msg = m
	case .Rlink:
		msg = Rlink{}

	case .Tmkdir:
		m: Tmkdir
		m.dfid = Fid(get_u32(c))
		m.name = get_string(c)
		m.mode = get_u32(c)
		m.gid = get_u32(c)
		msg = m
	case .Rmkdir:
		msg = Rmkdir{qid = get_qid(c)}

	case .Trenameat:
		m: Trenameat
		m.olddirfid = Fid(get_u32(c))
		m.oldname = get_string(c)
		m.newdirfid = Fid(get_u32(c))
		m.newname = get_string(c)
		msg = m
	case .Rrenameat:
		msg = Rrenameat{}

	case .Tunlinkat:
		m: Tunlinkat
		m.dirfid = Fid(get_u32(c))
		m.name = get_string(c)
		m.flags = get_u32(c)
		msg = m
	case .Runlinkat:
		msg = Runlinkat{}

	case .Tversion:
		m: Tversion
		m.msize = get_u32(c)
		m.version = get_string(c)
		msg = m
	case .Rversion:
		m: Rversion
		m.msize = get_u32(c)
		m.version = get_string(c)
		msg = m

	case .Tauth:
		m: Tauth
		m.afid = Fid(get_u32(c))
		m.uname = get_string(c)
		m.aname = get_string(c)
		m.n_uname = get_u32(c)
		msg = m
	case .Rauth:
		msg = Rauth{aqid = get_qid(c)}

	case .Tattach:
		m: Tattach
		m.fid = Fid(get_u32(c))
		m.afid = Fid(get_u32(c))
		m.uname = get_string(c)
		m.aname = get_string(c)
		m.n_uname = get_u32(c)
		msg = m
	case .Rattach:
		msg = Rattach{qid = get_qid(c)}

	case .Tflush:
		msg = Tflush{oldtag = Tag(get_u16(c))}
	case .Rflush:
		msg = Rflush{}

	case .Twalk:
		m: Twalk
		m.fid = Fid(get_u32(c))
		m.newfid = Fid(get_u32(c))
		n := int(get_u16(c))
		if n > MAX_WALK_ELEMENTS {
			return nil, .Too_Many_Walk_Elements
		}
		for i in 0 ..< n {
			m.names[i] = get_string(c)
		}
		m.count = n
		msg = m
	case .Rwalk:
		m: Rwalk
		n := int(get_u16(c))
		if n > MAX_WALK_ELEMENTS {
			return nil, .Too_Many_Walk_Elements
		}
		for i in 0 ..< n {
			m.qids[i] = get_qid(c)
		}
		m.count = n
		msg = m

	case .Tread:
		m: Tread
		m.fid = Fid(get_u32(c))
		m.offset = get_u64(c)
		m.count = get_u32(c)
		msg = m
	case .Rread:
		msg = Rread{data = get_data(c)}

	case .Twrite:
		m: Twrite
		m.fid = Fid(get_u32(c))
		m.offset = get_u64(c)
		m.data = get_data(c)
		msg = m
	case .Rwrite:
		msg = Rwrite{count = get_u32(c)}

	case .Tclunk:
		msg = Tclunk{fid = Fid(get_u32(c))}
	case .Rclunk:
		msg = Rclunk{}

	case .Tremove:
		msg = Tremove{fid = Fid(get_u32(c))}
	case .Rremove:
		msg = Rremove{}

	case:
		return nil, .Unknown_Kind
	}

	if c.err != .None {
		return nil, c.err
	}
	return msg, .None
}
