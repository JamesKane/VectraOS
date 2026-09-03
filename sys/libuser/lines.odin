/*
Reading input the way tools do: a line at a time, or all of it.

`Reader` buffers a descriptor and hands out lines without their newline,
each valid until the next call. A tool that reads lines from a pipe gets
whole lines whatever the writer's write sizes were. `read_all` is for the
tools that need the whole file first -- `sort`, `tail`, `cmp` -- and takes
an allocator, because a program with a heap has one to give.
*/
package libuser

import "base:runtime"

READER_SIZE :: 8192

Reader :: struct {
	fd:    int,
	buf:   [READER_SIZE]u8,
	start: int,
	end:   int,
	eof:   bool,
	// A line longer than the buffer is handed out in pieces, and the
	// caller cannot tell; this says so, for the tool that cares.
	split: bool,
}

reader_init :: proc "contextless" (r: ^Reader, fd: int) {
	r.fd = fd
	r.start = 0
	r.end = 0
	r.eof = false
	r.split = false
}

/*
read_line is the next line without its newline. The last line of a file
that does not end in one is a line too. Answers false at the end.
*/
read_line :: proc "contextless" (r: ^Reader) -> (line: string, ok: bool) #no_bounds_check {
	for {
		for i in r.start ..< r.end {
			if r.buf[i] == '\n' {
				line = string(r.buf[r.start:i])
				r.start = i + 1
				return line, true
			}
		}
		if r.eof {
			if r.start < r.end {
				line = string(r.buf[r.start:r.end])
				r.start = r.end
				return line, true
			}
			return "", false
		}
		// Slide what is left to the front and read more after it.
		if r.start > 0 {
			n := r.end - r.start
			copy(r.buf[:n], r.buf[r.start:r.end])
			r.start = 0
			r.end = n
		}
		if r.end == READER_SIZE {
			// A line longer than the buffer: hand out what there is.
			r.split = true
			line = string(r.buf[:r.end])
			r.start = r.end
			return line, true
		}
		n := read(r.fd, r.buf[r.end:])
		if n <= 0 {
			r.eof = true
			continue
		}
		r.end += int(n)
	}
}

// read_all reads a descriptor to its end into memory from `allocator`.
read_all :: proc(fd: int, allocator: runtime.Allocator) -> (data: []u8, ok: bool) {
	out := make([dynamic]u8, 0, 4096, allocator)
	tmp: [4096]u8
	for {
		n := read(fd, tmp[:])
		if n < 0 {
			delete(out)
			return nil, false
		}
		if n == 0 {
			break
		}
		append(&out, ..tmp[:n])
	}
	return out[:], true
}

// read_file is `read_all` of a named file.
read_file :: proc(path: string, allocator: runtime.Allocator) -> (data: []u8, ok: bool) {
	fd := open(path, 0)
	if fd < 0 {
		return nil, false
	}
	defer close(int(fd))
	return read_all(int(fd), allocator)
}

// eprint writes its pieces to descriptor 2, in order, as one message. No
// formatting and no allocation: a tool's error line is a few strings.
eprint :: proc "contextless" (parts: ..string) {
	for p in parts {
		write_full(2, transmute([]u8)p)
	}
}

// itoa writes a number into `buf` and answers the digits.
itoa :: proc "contextless" (buf: []u8, v: i64) -> string #no_bounds_check {
	if v == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	neg := v < 0
	x := neg ? -v : v
	tmp: [24]u8
	i := 0
	for x > 0 {
		tmp[i] = u8('0' + x % 10)
		x /= 10
		i += 1
	}
	n := 0
	if neg {
		buf[0] = '-'
		n = 1
	}
	for i > 0 {
		i -= 1
		buf[n] = tmp[i]
		n += 1
	}
	return string(buf[:n])
}

// atoi parses a decimal, with an optional sign. False for anything else.
atoi :: proc "contextless" (s: string) -> (v: i64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	i := 0
	neg := false
	if s[0] == '-' || s[0] == '+' {
		neg = s[0] == '-'
		i = 1
	}
	if i >= len(s) {
		return 0, false
	}
	for ; i < len(s); i += 1 {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		v = v * 10 + i64(s[i] - '0')
	}
	return neg ? -v : v, true
}
