/*
Unpadded base64, the standard alphabet: how Matrix carries every key and
every sealed message.
*/
package libolm

B64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// b64_encode writes `data` into `into` without padding and answers how
// many characters, or -1 when `into` is too small.
b64_encode :: proc(data: []u8, into: []u8) -> int {
	need := (len(data) * 8 + 5) / 6
	if len(into) < need {
		return -1
	}
	n := 0
	i := 0
	for i + 3 <= len(data) {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
		into[n] = B64[v >> 18 & 63]
		into[n + 1] = B64[v >> 12 & 63]
		into[n + 2] = B64[v >> 6 & 63]
		into[n + 3] = B64[v & 63]
		n += 4
		i += 3
	}
	switch len(data) - i {
	case 1:
		v := u32(data[i]) << 16
		into[n] = B64[v >> 18 & 63]
		into[n + 1] = B64[v >> 12 & 63]
		n += 2
	case 2:
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8
		into[n] = B64[v >> 18 & 63]
		into[n + 1] = B64[v >> 12 & 63]
		into[n + 2] = B64[v >> 6 & 63]
		n += 3
	}
	return n
}

// b64_decode reads standard base64, padded or not, into `into` and
// answers how many bytes, or -1.
b64_decode :: proc(text: string, into: []u8) -> int {
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
