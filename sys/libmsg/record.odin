/*
The record half of libmsg: a message, a conversation, and their ids. It
needs nothing of ring 3, so a host harness can build it beside `libfeed`
and check a parse without a machine. `msg.odin` is the tree.
*/
package libmsg

import "core:crypto/hash"

// One message. Its strings belong to whoever made it, until `msg_free`.
Msg :: struct {
	id:        string,
	from:      string,
	date:      i64, // Seconds since the epoch
	date_text: string, // As the network wrote it
	subject:   string,
	body:      string,
	type:      string, // The body's media type
	raw:       string, // What the network sent
	replyto:   string,
	links:     string, // One per line
	hash:      [64]u8, // sha256 of `raw`, as hex
}

Conv :: struct {
	name: string,
	msgs: [dynamic]Msg, // In id order
}

// find answers the index of the message called `id` in `c`, or -1.
find :: proc "contextless" (c: ^Conv, id: string) -> int {
	for m, i in c.msgs {
		if m.id == id {
			return i
		}
	}
	return -1
}

msg_free :: proc(m: ^Msg) {
	delete(m.id)
	delete(m.from)
	delete(m.date_text)
	delete(m.subject)
	delete(m.body)
	delete(m.type)
	delete(m.raw)
	delete(m.replyto)
	delete(m.links)
	m^ = Msg{}
}

// conv_clear takes every message out of a conversation.
conv_clear :: proc(c: ^Conv) {
	for &m in c.msgs {
		msg_free(&m)
	}
	clear(&c.msgs)
}

/*
make_id writes the id of a message dated `date` with the network's own id
`netid` into `into`: sixteen hex digits of the date, a dot, and the
network's id when it is a name, else sixteen hex digits of its sha256. A
name is one to sixty-four of the letters, digits, `.`, `_` and `-`, and not
`.` or `..`.
*/
make_id :: proc(date: i64, netid: string, into: []u8) -> string {
	if len(into) < 16 + 1 + 64 {
		return ""
	}
	hex_of_u64(u64(max(date, 0)), into[:16])
	into[16] = '.'
	n := 17
	if is_name(netid) {
		n += copy(into[17:], netid)
	} else {
		digest: [32]u8
		hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)netid, digest[:])
		hex_of(digest[:8], into[17:33])
		n = 33
	}
	return string(into[:n])
}

is_name :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 || len(s) > 64 || s == "." || s == ".." {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

HEX := "0123456789abcdef"

hex_of :: proc "contextless" (bytes: []u8, into: []u8) #no_bounds_check {
	for b, i in bytes {
		if 2 * i + 1 >= len(into) {
			return
		}
		into[2 * i] = HEX[b >> 4]
		into[2 * i + 1] = HEX[b & 15]
	}
}

hex_of_u64 :: proc "contextless" (v: u64, into: []u8) #no_bounds_check {
	x := v
	for i := len(into) - 1; i >= 0; i -= 1 {
		into[i] = HEX[x & 15]
		x >>= 4
	}
}

put_int :: proc "contextless" (into: []u8, v: i64) -> int #no_bounds_check {
	if v == 0 {
		into[0] = '0'
		return 1
	}
	n := 0
	x := v
	if x < 0 {
		into[0] = '-'
		n = 1
		x = -x
	}
	tmp: [24]u8
	k := 0
	for x > 0 {
		tmp[k] = u8('0' + x % 10)
		x /= 10
		k += 1
	}
	for i in 0 ..< k {
		into[n + i] = tmp[k - 1 - i]
	}
	return n + k
}

// calendar answers the civil date and time of seconds since the epoch, in
// UTC: the inverse of libfeed's `civil`, Howard Hinnant's civil-from-days.
calendar :: proc "contextless" (secs: i64) -> (y, mo, d, h, mi, s: int) {
	days := secs / 86400
	rem := secs % 86400
	if rem < 0 {
		rem += 86400
		days -= 1
	}
	h = int(rem / 3600)
	mi = int(rem % 3600 / 60)
	s = int(rem % 60)
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	yy := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = int(doy - (153 * mp + 2) / 5 + 1)
	mo = int(mp < 10 ? mp + 3 : mp - 9)
	if mo <= 2 {
		yy += 1
	}
	y = int(yy)
	return
}

// format_time writes `secs` as `YYYY-MM-DD HH:MM` into `into`, sixteen
// bytes, the way a timeline row shows a message's time.
format_time :: proc "contextless" (secs: i64, into: []u8) -> string #no_bounds_check {
	if len(into) < 16 {
		return ""
	}
	y, mo, d, h, mi, _ := calendar(secs)
	put_pad(into[0:4], y)
	into[4] = '-'
	put_pad(into[5:7], mo)
	into[7] = '-'
	put_pad(into[8:10], d)
	into[10] = ' '
	put_pad(into[11:13], h)
	into[13] = ':'
	put_pad(into[14:16], mi)
	return string(into[:16])
}

@(private = "file")
put_pad :: proc "contextless" (into: []u8, v: int) #no_bounds_check {
	x := v
	for i := len(into) - 1; i >= 0; i -= 1 {
		into[i] = u8('0' + x % 10)
		x /= 10
	}
}
