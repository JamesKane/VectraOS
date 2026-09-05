/*
Hexadecimal, for keys that cross a text file: `/mnt/factotum/rpc`'s lines,
`/adm/keys`, and the `key=` on a host's `ndb` record. Lower case out; either
case in.
*/
package libcrypto

@(private = "file")
DIGITS :: "0123456789abcdef"

// hex_encode writes `src` as hex into `dst`, which is twice as long, and
// answers the text. A `dst` too short answers an empty string.
hex_encode :: proc "contextless" (dst: []u8, src: []u8) -> string #no_bounds_check {
	if len(dst) < 2 * len(src) {
		return ""
	}
	digits := DIGITS // A constant cannot be indexed by a variable; a copy can.
	for b, i in src {
		dst[2 * i] = digits[b >> 4]
		dst[2 * i + 1] = digits[b & 0xF]
	}
	return string(dst[:2 * len(src)])
}

// hex_decode reads hex text into `dst` and answers how many bytes it wrote,
// or -1 for text that is not hex or does not fit.
hex_decode :: proc "contextless" (dst: []u8, text: string) -> int #no_bounds_check {
	if len(text) % 2 != 0 || len(dst) < len(text) / 2 {
		return -1
	}
	for i := 0; i < len(text); i += 2 {
		hi, ok1 := nibble(text[i])
		lo, ok2 := nibble(text[i + 1])
		if !ok1 || !ok2 {
			return -1
		}
		dst[i / 2] = hi << 4 | lo
	}
	return len(text) / 2
}

@(private = "file")
nibble :: proc "contextless" (c: u8) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}
