/*
Base64, RFC 4648: the standard alphabet, unpadded, is how Matrix carries
every key and every sealed message; the URL alphabet, unpadded, is how a
JWS carries its parts. One codec serves both, so a decoder reads either
alphabet, with or without padding.
*/
package libodin

B64_STD :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
B64_URL :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

// b64_encode writes `data` into `into` without padding, in the URL
// alphabet when `url`, and answers how many characters, or -1 when
// `into` is too small.
b64_encode :: proc "contextless" (data: []u8, into: []u8, url := false) -> int #no_bounds_check {
	need := (len(data) * 8 + 5) / 6
	if len(into) < need {
		return -1
	}
	table := url ? B64_URL : B64_STD
	n := 0
	i := 0
	for i + 3 <= len(data) {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
		into[n] = table[v >> 18 & 63]
		into[n + 1] = table[v >> 12 & 63]
		into[n + 2] = table[v >> 6 & 63]
		into[n + 3] = table[v & 63]
		n += 4
		i += 3
	}
	switch len(data) - i {
	case 1:
		v := u32(data[i]) << 16
		into[n] = table[v >> 18 & 63]
		into[n + 1] = table[v >> 12 & 63]
		n += 2
	case 2:
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8
		into[n] = table[v >> 18 & 63]
		into[n + 1] = table[v >> 12 & 63]
		into[n + 2] = table[v >> 6 & 63]
		n += 3
	}
	return n
}

// b64_decode reads base64 in either alphabet, padded or not, into `into`
// and answers how many bytes, or -1 for a character outside both
// alphabets or too small a buffer.
b64_decode :: proc "contextless" (text: string, into: []u8) -> int #no_bounds_check {
	n := 0
	bits: u32 = 0
	have: u32 = 0
	for c in transmute([]u8)text {
		v: u32
		switch {
		case c >= 'A' && c <= 'Z':
			v = u32(c - 'A')
		case c >= 'a' && c <= 'z':
			v = u32(c - 'a') + 26
		case c >= '0' && c <= '9':
			v = u32(c - '0') + 52
		case c == '+' || c == '-':
			v = 62
		case c == '/' || c == '_':
			v = 63
		case c == '=':
			continue
		case:
			return -1
		}
		bits = bits << 6 | v
		have += 6
		if have >= 8 {
			have -= 8
			if n >= len(into) {
				return -1
			}
			into[n] = u8(bits >> have)
			n += 1
		}
	}
	return n
}
