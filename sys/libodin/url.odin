/*
The URL percent-encoding both directions, RFC 3986: a form value goes out
encoded and comes in decoded, and several web programs wrote it by hand.
It lives here so the next one does not write another.
*/
package libodin

// url_encode writes `s` into `out` percent-encoded, the unreserved bytes
// as they are, and answers how many bytes.
url_encode :: proc "contextless" (out: []u8, s: string) -> int #no_bounds_check {
	hex := "0123456789ABCDEF"
	n := 0
	for c in transmute([]u8)s {
		unreserved := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~'
		if unreserved && n < len(out) {
			out[n] = c
			n += 1
		} else if n + 3 <= len(out) {
			out[n] = '%'
			out[n + 1] = hex[c >> 4]
			out[n + 2] = hex[c & 15]
			n += 3
		}
	}
	return n
}

// url_decode writes `s` into `out` with its percent-escapes and pluses
// decoded, and answers how many bytes.
url_decode :: proc "contextless" (s: string, out: []u8) -> int #no_bounds_check {
	n := 0
	i := 0
	for i < len(s) && n < len(out) {
		c := s[i]
		if c == '+' {
			out[n] = ' '
			n += 1
			i += 1
		} else if c == '%' && i + 2 < len(s) {
			hi := url_hex(s[i + 1])
			lo := url_hex(s[i + 2])
			if hi >= 0 && lo >= 0 {
				out[n] = u8(hi << 4 | lo)
				n += 1
				i += 3
			} else {
				out[n] = c
				n += 1
				i += 1
			}
		} else {
			out[n] = c
			n += 1
			i += 1
		}
	}
	return n
}

// url_hex answers a hex digit's value, or -1.
url_hex :: proc "contextless" (c: u8) -> int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c - 'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c - 'A') + 10
	}
	return -1
}
