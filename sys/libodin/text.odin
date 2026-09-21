/*
Small text and byte operations both privilege levels want.

Several places wrote each of these by hand. The kernel's `/proc` and its
debugger each had a prefix test. Two ctl files each had a trim. A dozen files
had a decimal parse. Every file that reads a header had a little-endian word
fold. They live here so that the next file does not write a thirteenth.
*/
package libodin

has_prefix :: proc "contextless" (s, prefix: string) -> bool #no_bounds_check {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

has_suffix :: proc "contextless" (s, suffix: string) -> bool #no_bounds_check {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

// has_dotdot says whether a path holds a `..`, the guard a file server
// wants so a request cannot climb out of the root it serves.
has_dotdot :: proc "contextless" (p: string) -> bool #no_bounds_check {
	for i := 0; i + 1 < len(p); i += 1 {
		if p[i] == '.' && p[i + 1] == '.' {
			return true
		}
	}
	return false
}

is_space :: proc "contextless" (b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// trim_space drops blanks and line ends from both ends of a string. A ctl
// write arrives with the newline the shell typed, and the command is the
// rest.
trim_space :: proc "contextless" (s: string) -> string #no_bounds_check {
	start, end := 0, len(s)
	for start < end && is_space(s[start]) {
		start += 1
	}
	for end > start && is_space(s[end - 1]) {
		end -= 1
	}
	return s[start:end]
}

// parse_uint reads an unsigned decimal. The whole string has to be digits,
// and there has to be at least one. Overflow is a failure, not a wrap.
parse_uint :: proc "contextless" (s: string) -> (value: u64, ok: bool) #no_bounds_check {
	if len(s) == 0 {
		return 0, false
	}
	for b in transmute([]u8)s {
		if b < '0' || b > '9' {
			return 0, false
		}
		d := u64(b - '0')
		if value > (max(u64) - d) / 10 {
			return 0, false
		}
		value = value * 10 + d
	}
	return value, true
}

// Little-endian words in a byte slice, for headers and tables that are laid
// out by a spec rather than by this compiler. `vectra9` has the same over a
// cursor, for a 9P message.
get_u32le :: proc "contextless" (b: []u8) -> u32 #no_bounds_check {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

get_u64le :: proc "contextless" (b: []u8) -> u64 #no_bounds_check {
	v: u64
	for i in 0 ..< 8 {
		v |= u64(b[i]) << uint(8 * i)
	}
	return v
}

put_u32le :: proc "contextless" (b: []u8, v: u32) #no_bounds_check {
	for i in 0 ..< 4 {
		b[i] = u8(v >> uint(8 * i))
	}
}

put_u64le :: proc "contextless" (b: []u8, v: u64) #no_bounds_check {
	for i in 0 ..< 8 {
		b[i] = u8(v >> uint(8 * i))
	}
}
