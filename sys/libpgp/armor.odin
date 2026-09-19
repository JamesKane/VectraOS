/*
ASCII armor, RFC 9580 section 6: base64 of the packets between two
dashed lines, with a CRC-24 after an `=` on the last line. Mail carries
a sealed message this way, as the second part of `multipart/encrypted`.
An Autocrypt header carries a key as bare base64, with no armor, and
`armor_decode` reads both: lines of base64 with or without the dashes.
*/
package libpgp

// armor writes `data` as `kind` ("PGP MESSAGE", "PGP PUBLIC KEY BLOCK")
// into `out`, and answers the length or -1.
armor :: proc(kind: string, data: []u8, out: []u8) -> int #no_bounds_check {
	need := 2 * (11 + len(kind) + 6) + 2 + len(data) * 4 / 3 + len(data) / 48 * 2 + 16
	if need > len(out) {
		return -1
	}
	n := 0
	n += copy(out[n:], "-----BEGIN ")
	n += copy(out[n:], kind)
	n += copy(out[n:], "-----\r\n\r\n")
	n += base64_lines(data, out[n:], 64)
	out[n] = '='
	n += 1
	crc := crc24(data)
	crc_bytes := [3]u8{u8(crc >> 16), u8(crc >> 8), u8(crc)}
	n += base64_lines(crc_bytes[:], out[n:], 0)
	n += copy(out[n:], "-----END ")
	n += copy(out[n:], kind)
	n += copy(out[n:], "-----\r\n")
	return n
}

/*
armor_decode reads armored text, or bare base64, into `out`, and answers
the length or -1. A CRC line is checked when there is one. Headers
between the first dashed line and the empty line are skipped.
*/
armor_decode :: proc(text: string, out: []u8) -> int #no_bounds_check {
	at := 0
	in_body := !has_dashes(text)
	if !in_body {
		// Past the BEGIN line and any headers, to the empty line.
		for at < len(text) {
			e := at
			for e < len(text) && text[e] != '\n' {
				e += 1
			}
			line := trim_line(text[at:e])
			at = e + 1
			if len(line) == 0 {
				break
			}
		}
	}
	n := 0
	acc := u32(0)
	bits := 0
	crc_given := -1
	for at < len(text) {
		e := at
		for e < len(text) && text[e] != '\n' {
			e += 1
		}
		line := trim_line(text[at:e])
		at = e + 1
		if len(line) == 0 {
			continue
		}
		if line[0] == '-' {
			break
		}
		if line[0] == '=' {
			crc_bytes: [3]u8
			if decode_b64(line[1:], crc_bytes[:]) == 3 {
				crc_given = int(crc_bytes[0]) << 16 | int(crc_bytes[1]) << 8 | int(crc_bytes[2])
			}
			continue
		}
		for i in 0 ..< len(line) {
			v := b64_value(line[i])
			if v < 0 {
				continue
			}
			acc = acc << 6 | u32(v)
			bits += 6
			if bits >= 8 {
				bits -= 8
				if n >= len(out) {
					return -1
				}
				out[n] = u8(acc >> uint(bits))
				n += 1
				acc &= (1 << uint(bits)) - 1
			}
		}
	}
	if crc_given >= 0 && crc24(out[:n]) != crc_given {
		return -1
	}
	return n
}

@(private = "file")
has_dashes :: proc "contextless" (s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] == '-' {
			return true
		}
		if s[i] != ' ' && s[i] != '\r' && s[i] != '\n' && s[i] != '\t' {
			return false
		}
	}
	return false
}

@(private = "file")
trim_line :: proc "contextless" (s: string) -> string #no_bounds_check {
	a, b := 0, len(s)
	for a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r') {
		a += 1
	}
	for b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r') {
		b -= 1
	}
	return s[a:b]
}

@(private = "file")
decode_b64 :: proc "contextless" (s: string, out: []u8) -> int #no_bounds_check {
	n := 0
	acc := u32(0)
	bits := 0
	for i in 0 ..< len(s) {
		v := b64_value(s[i])
		if v < 0 {
			continue
		}
		acc = acc << 6 | u32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			if n >= len(out) {
				return n
			}
			out[n] = u8(acc >> uint(bits))
			n += 1
			acc &= (1 << uint(bits)) - 1
		}
	}
	return n
}

@(private = "file")
b64_value :: proc "contextless" (c: u8) -> int {
	switch {
	case c >= 'A' && c <= 'Z':
		return int(c - 'A')
	case c >= 'a' && c <= 'z':
		return int(c - 'a') + 26
	case c >= '0' && c <= '9':
		return int(c - '0') + 52
	case c == '+':
		return 62
	case c == '/':
		return 63
	}
	return -1
}

// base64_lines writes base64 with CRLF every `width` characters, or on one
// line for a width of zero, ending with CRLF.
@(private = "file")
base64_lines :: proc(data: []u8, out: []u8, width: int) -> int #no_bounds_check {
	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	n := 0
	col := 0
	i := 0
	for i < len(data) {
		b0 := u32(data[i])
		b1 := i + 1 < len(data) ? u32(data[i + 1]) : 0
		b2 := i + 2 < len(data) ? u32(data[i + 2]) : 0
		v := b0 << 16 | b1 << 8 | b2
		out[n] = alphabet[v >> 18 & 63]
		out[n + 1] = alphabet[v >> 12 & 63]
		out[n + 2] = i + 1 < len(data) ? alphabet[v >> 6 & 63] : '='
		out[n + 3] = i + 2 < len(data) ? alphabet[v & 63] : '='
		n += 4
		col += 4
		i += 3
		if width > 0 && col >= width && i < len(data) {
			out[n], out[n + 1] = '\r', '\n'
			n += 2
			col = 0
		}
	}
	out[n], out[n + 1] = '\r', '\n'
	return n + 2
}

// crc24 is the armor's checksum, the OpenPGP polynomial.
crc24 :: proc "contextless" (data: []u8) -> int {
	crc := u32(0xB704CE)
	for b in data {
		crc ~= u32(b) << 16
		for _ in 0 ..< 8 {
			crc <<= 1
			if crc & 0x1000000 != 0 {
				crc ~= 0x1864CFB
			}
		}
	}
	return int(crc & 0xFFFFFF)
}
