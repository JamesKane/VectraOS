/*
The codec's self-test, run at boot.

There is nowhere to run a unit test in a kernel. A wire codec is exactly the
kind of code whose bugs stay invisible until something at the other end of a
cable disagrees. So it checks itself on the machine, once, and says so in the
boot log.

The oracle is a re-encode. For every message kind, a fully-populated sample is
encoded, decoded, and encoded again. The two byte strings must be identical.

That catches a field written in the wrong order, a field read at the wrong
width, and a field the decoder forgot. All three produce a byte string that
differs somewhere. It is worth far more than a comparison of the decoded
structs. That would need fifty more comparison cases. It would also miss a
codec that is self-consistently wrong about the *order* of two same-width
fields.

Every field in every sample is non-zero and distinct, which is what makes the
oracle sound. A decoder that silently dropped a field would re-encode it as
zero, and the comparison would fail. Samples with zeroes in them would let that
pass.
*/
package vectra9

Verify_Result :: struct {
	kinds_tested:  int,
	failures:      int,
	first_failure: Kind,
	first_error:   Error,
}

// A scratch payload for the messages that carry bytes. Deliberately not all the
// same value: a codec that mixed up two lengths would still produce matching
// bytes if the payload were uniform.
@(private = "file")
PAYLOAD := [?]u8{0xA5, 0x01, 0x02, 0xFE, 0x7F, 0x80, 0x33, 0xCC}

/*
verify round-trips every message kind and exercises both transports.

`scratch` is split four ways, and must be at least 2 KiB. The largest sample is
Rgetattr, at a little over 200 bytes. The loopback needs a request buffer and a
reply buffer of its own.
*/
verify :: proc "contextless" (scratch: []u8) -> Verify_Result {
	result: Verify_Result

	if len(scratch) < 2048 {
		result.failures = 1
		result.first_error = .Short_Buffer
		return result
	}

	quarter := len(scratch) / 4
	first := scratch[0:quarter]
	second := scratch[quarter:2 * quarter]

	for index := 0; ; index += 1 {
		msg, more := sample(index)
		if !more {
			break
		}
		result.kinds_tested += 1

		if err := round_trip(first, second, msg); err != .None {
			result.failures += 1
			if result.first_error == .None {
				result.first_failure = kind(msg)
				result.first_error = err
			}
		}
	}

	// The malformed-input cases. Valid input only half-tests a codec. These are
	// the paths that stop anything from acting on a corrupt message.
	if !rejects_bad_input() {
		result.failures += 1
		if result.first_error == .None {
			result.first_error = .Unknown_Kind
		}
	}

	// And the claim the whole layer rests on: a handler cannot tell which
	// transport it is behind.
	if !transports_agree(scratch[2 * quarter:3 * quarter], scratch[3 * quarter:]) {
		result.failures += 1
		if result.first_error == .None {
			result.first_error = .Transport_Failed
		}
	}

	return result
}

/*
round_trip encodes, decodes, re-encodes, and compares the two byte strings.

The decoded message borrows `a`, so `b` has to be a different buffer.

An encode back into `a` would overwrite the very bytes the decoded message's
strings and slices point at. The comparison would then run against whatever the
encoder happened to leave behind. That is a bug this test would otherwise be
uniquely bad at noticing.
*/
@(private = "file")
round_trip :: proc "contextless" (a, b: []u8, msg: Msg) -> Error #no_bounds_check {
	TAG :: Tag(0x4A5B)

	n, err := encode(a, TAG, msg)
	if err != .None {
		return err
	}

	tag, decoded, derr := decode(a[:n])
	if derr != .None {
		return derr
	}
	if tag != TAG {
		return .Size_Mismatch
	}
	if kind(decoded) != kind(msg) {
		return .Unknown_Kind
	}

	m, merr := encode(b, TAG, decoded)
	if merr != .None {
		return merr
	}
	if m != n {
		return .Size_Mismatch
	}
	for i in 0 ..< n {
		if a[i] != b[i] {
			return .Size_Mismatch
		}
	}
	return .None
}

/*
rejects_bad_input checks that malformed messages are refused rather than parsed.

Each of these is a shape an attacker or a broken peer can put on a wire. Each
has to fail as an error, rather than as a plausible-looking message.
*/
@(private = "file")
rejects_bad_input :: proc "contextless" () -> bool #no_bounds_check {
	buf: [64]u8

	// A message shorter than its own header.
	if _, _, err := decode(buf[:3]); err != .Short_Buffer {
		return false
	}

	// A well-formed header claiming to be longer than the buffer it arrived in.
	// Refused, not read: this is the classic way a codec is talked into reading
	// past the end of a packet.
	n, _ := encode(buf[:], 1, Tclunk{fid = 7})
	buf[0] = 0xFF
	if _, _, err := decode(buf[:n]); err != .Size_Mismatch {
		return false
	}

	// Type 6 is reserved and must never be accepted.
	n2, _ := encode(buf[:], 1, Tclunk{fid = 7})
	buf[4] = 6
	if _, _, err := decode(buf[:n2]); err != .Illegal_Kind {
		return false
	}

	// A type byte that is not a 9P2000.L message at all.
	n3, _ := encode(buf[:], 1, Tclunk{fid = 7})
	buf[4] = 200
	if _, _, err := decode(buf[:n3]); err != .Unknown_Kind {
		return false
	}

	// Encoding into a buffer too small for the message. Must be an error, not a
	// truncated message: a short 9P message is a protocol violation that the
	// far end would blame on itself.
	tiny: [8]u8
	if _, err := encode(tiny[:], 1, Tattach{uname = "verylongusername"}); err != .Short_Buffer {
		return false
	}

	// More walk elements than the protocol allows.
	over: Twalk
	over.count = MAX_WALK_ELEMENTS + 1
	if _, err := encode(buf[:], 1, over); err != .Too_Many_Walk_Elements {
		return false
	}

	return true
}

// -- Transport equivalence ---------------------------------------------------

/*
A handler that answers Tread with something derived from what it was asked.

Deliberately not a constant. A transport that dropped the request and invented
a reply would pass a test whose expected answer did not depend on the request.
*/
@(private = "file")
echo_handler :: proc "contextless" (
	server: rawptr,
	s: ^Session,
	tag: Tag,
	request: ^Msg,
	reply: ^Msg,
) {
	_ = tag
	_ = server
	_ = s

	#partial switch m in request^ {
	case Tread:
		reply^ = Rwrite{count = u32(m.fid) + u32(m.offset) + m.count}
	case Tversion:
		reply^ = Rversion{msize = m.msize, version = m.version}
	case:
		reply^ = error_reply(EOPNOTSUPP)
	}
}

/*
transports_agree runs the same handler behind both transports.

This is the design's central claim, made testable. `In_Process` hands the
message over by pointer. `Encoded_Loopback` serialises it and parses it back.
The handler must not be able to tell. If these two ever disagree, something
leaked across the transport boundary that was supposed to stay behind it.
*/
@(private = "file")
transports_agree :: proc "contextless" (request_buf, reply_buf: []u8) -> bool {
	request := Msg(Tread{fid = 0x1234, offset = 0x5678, count = 0x9ABC})

	direct := In_Process {
		handler = echo_handler,
	}
	direct_session := session_from(in_process_transport(&direct))
	direct_reply: Msg
	if err := call(&direct_session, &request, &direct_reply); err != .None {
		return false
	}

	encoded := Encoded_Loopback {
		handler     = echo_handler,
		request_buf = request_buf,
		reply_buf   = reply_buf,
	}
	encoded_session := session_from(encoded_loopback_transport(&encoded))
	encoded_reply: Msg
	if err := call(&encoded_session, &request, &encoded_reply); err != .None {
		return false
	}

	a, a_ok := direct_reply.(Rwrite)
	b, b_ok := encoded_reply.(Rwrite)
	if !a_ok || !b_ok || a.count != b.count {
		return false
	}

	// And the version handshake, which is the one exchange with a rule of its
	// own: msize is clamped to the smaller of the two sides.
	if err := negotiate(&encoded_session, 4096); err != .None {
		return false
	}
	return encoded_session.msize == 4096 && encoded_session.version == VERSION
}

// -- The samples -------------------------------------------------------------

/*
sample returns message number `index`, or false once they run out.

One per kind, every field distinct and non-zero, for the reason given at the
top of this file. A switch rather than a table, because the messages are
different types and a table would need the union anyway. And the compiler will
not let this drift out of step with `Kind` without somebody noticing the count.
*/
@(private = "file")
sample :: proc "contextless" (index: int) -> (Msg, bool) {
	switch index {
	case 0:
		return Rlerror{ecode = 0x1111_1111}, true
	case 1:
		return Tstatfs{fid = 0x2222_2222}, true
	case 2:
		return Rstatfs {
				type = 0x0101_0101,
				bsize = 0x0202_0202,
				blocks = 0x0303_0303_0303_0303,
				bfree = 0x0404_0404_0404_0404,
				bavail = 0x0505_0505_0505_0505,
				files = 0x0606_0606_0606_0606,
				ffree = 0x0707_0707_0707_0707,
				fsid = 0x0808_0808_0808_0808,
				namelen = 0x0909_0909,
			}, true
	case 3:
		return Tlopen{fid = 0x1234_5678, flags = 0x9ABC_DEF0}, true
	case 4:
		return Rlopen{qid = qid_sample(), iounit = 0x1357_9BDF}, true
	case 5:
		return Tlcreate{fid = 0x11, name = "created", flags = 0x22, mode = 0x33, gid = 0x44}, true
	case 6:
		return Rlcreate{qid = qid_sample(), iounit = 0x2468_ACE0}, true
	case 7:
		return Tsymlink{fid = 0x55, name = "link", target = "/some/target", gid = 0x66}, true
	case 8:
		return Rsymlink{qid = qid_sample()}, true
	case 9:
		return Tmknod {
				dfid = 0x77,
				name = "node",
				mode = 0x88,
				major = 0x99,
				minor = 0xAA,
				gid = 0xBB,
			}, true
	case 10:
		return Rmknod{qid = qid_sample()}, true
	case 11:
		return Trename{fid = 0xCC, dfid = 0xDD, name = "renamed"}, true
	case 12:
		return Rrename{}, true
	case 13:
		return Treadlink{fid = 0xEE}, true
	case 14:
		return Rreadlink{target = "/read/link/target"}, true
	case 15:
		return Tgetattr{fid = 0xFF, request_mask = 0x0FED_CBA9_8765_4321}, true
	case 16:
		return Rgetattr {
				valid = 0x1000_0000_0000_0001,
				qid = qid_sample(),
				mode = 0x0000_81A4,
				uid = 0x0000_03E8,
				gid = 0x0000_03E9,
				nlink = 0x11,
				rdev = 0x12,
				size = 0x13,
				blksize = 0x14,
				blocks = 0x15,
				atime_sec = 0x16,
				atime_nsec = 0x17,
				mtime_sec = 0x18,
				mtime_nsec = 0x19,
				ctime_sec = 0x1A,
				ctime_nsec = 0x1B,
				btime_sec = 0x1C,
				btime_nsec = 0x1D,
				gen = 0x1E,
				data_version = 0x1F,
			}, true
	case 17:
		return Tsetattr {
				fid = 0x21,
				valid = 0x22,
				mode = 0x23,
				uid = 0x24,
				gid = 0x25,
				size = 0x26,
				atime_sec = 0x27,
				atime_nsec = 0x28,
				mtime_sec = 0x29,
				mtime_nsec = 0x2A,
			}, true
	case 18:
		return Rsetattr{}, true
	case 19:
		return Txattrwalk{fid = 0x2B, newfid = 0x2C, name = "user.attr"}, true
	case 20:
		return Rxattrwalk{size = 0x2D2D_2D2D_2D2D_2D2D}, true
	case 21:
		return Txattrcreate{fid = 0x2E, name = "user.new", attr_size = 0x2F, flags = 0x30}, true
	case 22:
		return Rxattrcreate{}, true
	case 23:
		return Treaddir{fid = 0x31, offset = 0x3232_3232_3232_3232, count = 0x33}, true
	case 24:
		return Rreaddir{data = PAYLOAD[:]}, true
	case 25:
		return Tfsync{fid = 0x34, datasync = 0x35}, true
	case 26:
		return Rfsync{}, true
	case 27:
		return Tlock {
				fid = 0x36,
				type = 0x37,
				flags = 0x38,
				start = 0x39,
				length = 0x3A,
				proc_id = 0x3B,
				client_id = "locker",
			}, true
	case 28:
		return Rlock{status = 0x3C}, true
	case 29:
		return Tgetlock {
				fid = 0x3D,
				type = 0x3E,
				start = 0x3F,
				length = 0x40,
				proc_id = 0x41,
				client_id = "getlocker",
			}, true
	case 30:
		return Rgetlock {
				type = 0x42,
				start = 0x43,
				length = 0x44,
				proc_id = 0x45,
				client_id = "heldby",
			}, true
	case 31:
		return Tlink{dfid = 0x46, fid = 0x47, name = "hardlink"}, true
	case 32:
		return Rlink{}, true
	case 33:
		return Tmkdir{dfid = 0x48, name = "newdir", mode = 0x49, gid = 0x4A}, true
	case 34:
		return Rmkdir{qid = qid_sample()}, true
	case 35:
		return Trenameat {
				olddirfid = 0x4B,
				oldname = "before",
				newdirfid = 0x4C,
				newname = "after",
			}, true
	case 36:
		return Rrenameat{}, true
	case 37:
		return Tunlinkat{dirfid = 0x4D, name = "doomed", flags = 0x4E}, true
	case 38:
		return Runlinkat{}, true
	case 39:
		return Tversion{msize = MSIZE_DEFAULT, version = VERSION}, true
	case 40:
		return Rversion{msize = MSIZE_DEFAULT, version = VERSION}, true
	case 41:
		return Tauth{afid = 0x4F, uname = "glenda", aname = "main", n_uname = 0x50}, true
	case 42:
		return Rauth{aqid = qid_sample()}, true
	case 43:
		return Tattach {
				fid = 0x51,
				afid = NOFID,
				uname = "glenda",
				aname = "main",
				n_uname = 0x52,
			}, true
	case 44:
		return Rattach{qid = qid_sample()}, true
	case 45:
		return Tflush{oldtag = 0x5354}, true
	case 46:
		return Rflush{}, true
	case 47:
		m: Twalk
		m.fid = 0x55
		m.newfid = 0x56
		m.names[0] = "usr"
		m.names[1] = "glenda"
		m.names[2] = "lib"
		m.count = 3
		return m, true
	case 48:
		m: Rwalk
		m.qids[0] = qid_sample()
		m.qids[1] = Qid{kind = {.Dir}, version = 0x5758_595A, path = 0x5B5C_5D5E_5F60_6162}
		m.count = 2
		return m, true
	case 49:
		return Tread{fid = 0x63, offset = 0x6465_6667_6869_6A6B, count = 0x6C}, true
	case 50:
		return Rread{data = PAYLOAD[:]}, true
	case 51:
		return Twrite{fid = 0x6D, offset = 0x6E6F_7071_7273_7475, data = PAYLOAD[:]}, true
	case 52:
		return Rwrite{count = 0x7677_7879}, true
	case 53:
		return Tclunk{fid = 0x7A}, true
	case 54:
		return Rclunk{}, true
	case 55:
		return Tremove{fid = 0x7B}, true
	case 56:
		return Rremove{}, true
	}
	return nil, false
}

@(private = "file")
qid_sample :: proc "contextless" () -> Qid {
	// Several flags at once, so a codec that masked the byte down to a single
	// bit would be caught.
	return Qid{kind = {.Dir, .Append, .Tmp}, version = 0xDEAD_BEEF, path = 0x0123_4567_89AB_CDEF}
}
