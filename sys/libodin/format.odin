/*
libodin -- the minimal freestanding core shared by the kernel and by userland
servers before libposix is available.

Everything in here writes into caller-supplied storage. There is no allocator
in a `-default-to-nil-allocator` build. Code that runs during early boot, or
inside a fault handler, must not be the code that discovers that.
*/
package libodin

DIGITS_LOWER :: "0123456789abcdef"
DIGITS_UPPER :: "0123456789ABCDEF"

/*
A Sink is a fixed byte buffer plus a write cursor.

Overflow saturates rather than kills. `overflowed` records that output went
missing, so a caller can flag it. A panic message that is too long still prints
what fits, rather than faults inside the panic path.
*/
Sink :: struct {
	buf:        []u8,
	len:        int,
	overflowed: bool,
}

sink_from :: proc "contextless" (buf: []u8) -> Sink {
	return Sink{buf = buf}
}

// bytes returns the portion of the sink's buffer that something wrote.
bytes :: proc "contextless" (s: ^Sink) -> []u8 {
	return s.buf[:s.len]
}

// str returns the written portion as a string aliasing the sink's buffer.
str :: proc "contextless" (s: ^Sink) -> string {
	return string(s.buf[:s.len])
}

reset :: proc "contextless" (s: ^Sink) {
	s.len = 0
	s.overflowed = false
}

put_byte :: proc "contextless" (s: ^Sink, b: u8) {
	if s.len >= len(s.buf) {
		s.overflowed = true
		return
	}
	s.buf[s.len] = b
	s.len += 1
}

put_str :: proc "contextless" (s: ^Sink, text: string) {
	for i in 0 ..< len(text) {
		put_byte(s, text[i])
	}
}

// put_pad writes `count` copies of `b`, ignoring non-positive counts.
put_pad :: proc "contextless" (s: ^Sink, b: u8, count: int) {
	for _ in 0 ..< count {
		put_byte(s, b)
	}
}

/*
put_uint formats `value` in `base` (2..16), zero-padded to at least `width`
digits.

The scratch array is sized for the worst case, base 2 of a u64, so the digit
loop can never run off the end.
*/
put_uint :: proc "contextless" (s: ^Sink, value: u64, base: u64 = 10, width: int = 0, upper := false) {
	digits := upper ? DIGITS_UPPER : DIGITS_LOWER
	scratch: [64]u8
	n := 0

	v := value
	for {
		scratch[n] = digits[v % base]
		n += 1
		v /= base
		if v == 0 {
			break
		}
	}

	put_pad(s, '0', width - n)
	for i := n - 1; i >= 0; i -= 1 {
		put_byte(s, scratch[i])
	}
}

put_int :: proc "contextless" (s: ^Sink, value: i64, base: u64 = 10) {
	if value < 0 {
		put_byte(s, '-')
		// Negating i64 min overflows, so widen through u64 instead.
		put_uint(s, u64(-(value + 1)) + 1, base)
		return
	}
	put_uint(s, u64(value), base)
}

// put_hex writes an 0x-prefixed value padded to `width` hex digits.
put_hex :: proc "contextless" (s: ^Sink, value: u64, width: int = 0) {
	put_str(s, "0x")
	put_uint(s, value, 16, width)
}

// put_ptr writes a pointer in the canonical 16-digit form so that columns of
// addresses line up in a log.
put_ptr :: proc "contextless" (s: ^Sink, p: rawptr) {
	put_hex(s, u64(uintptr(p)), 16)
}

/*
put_size writes a byte count in the largest binary unit that keeps the integer
part non-zero, with one fractional digit.

A reader takes a boot log at a glance, and `3.9 GiB` carries more than
4293918720 does.
*/
put_size :: proc "contextless" (s: ^Sink, bytes_count: u64) {
	units := [?]string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}

	unit := 0
	whole := bytes_count
	rem := u64(0)
	for whole >= 1024 && unit < len(units) - 1 {
		rem = whole % 1024
		whole /= 1024
		unit += 1
	}

	put_uint(s, whole)
	if unit > 0 {
		// One decimal place, rounded down: rem/1024 scaled to tenths.
		put_byte(s, '.')
		put_uint(s, rem * 10 / 1024)
	}
	put_byte(s, ' ')
	put_str(s, units[unit])
}
