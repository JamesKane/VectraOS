/*
Where the characters come from.

A string for `-c` and for `eval`, a file read whole for a script, or a
descriptor read as the parser needs more, which is the interactive case and
the one that prompts. The lexer asks one character at a time and never
knows which.
*/
package rc

import "vsys:libuser"

Input :: struct {
	buf:         [dynamic]u8,
	pos:         int,
	fd:          int, // -1 when everything is in `buf` already
	eof:         bool,
	interactive: bool,
	prompt:      int, // which $prompt the next fill prints: 1 or 2
	line:        int,
}

input_from_string :: proc(in_: ^Input, text: string) {
	in_.buf = make([dynamic]u8, 0, len(text))
	append(&in_.buf, ..transmute([]u8)text)
	in_.pos = 0
	in_.fd = -1
	in_.eof = false
	in_.line = 1
}

input_from_fd :: proc(in_: ^Input, fd: int, interactive: bool) {
	in_.buf = make([dynamic]u8, 0, 256)
	in_.pos = 0
	in_.fd = fd
	in_.eof = false
	in_.interactive = interactive
	in_.prompt = 1
	in_.line = 1
}

input_free :: proc(in_: ^Input) {
	delete(in_.buf)
}

// fill reads more, and says whether it got any. The bytes already consumed
// go first, so a long session does not keep every line it ever read.
@(private = "file")
fill :: proc(in_: ^Input) -> bool {
	if in_.eof || in_.fd < 0 {
		in_.eof = true
		return false
	}
	if in_.pos > 0 {
		remaining := len(in_.buf) - in_.pos
		copy(in_.buf[:remaining], in_.buf[in_.pos:])
		resize(&in_.buf, remaining)
		in_.pos = 0
	}
	if in_.interactive {
		show_prompt(in_.prompt)
		in_.prompt = 2
	}
	tmp: [1024]u8
	n := libuser.read(in_.fd, tmp[:])
	if n <= 0 {
		in_.eof = true
		return false
	}
	append(&in_.buf, ..tmp[:n])
	return true
}

peekc :: proc(in_: ^Input) -> (c: u8, ok: bool) {
	if in_.pos >= len(in_.buf) && !fill(in_) {
		return 0, false
	}
	return in_.buf[in_.pos], true
}

getc :: proc(in_: ^Input) -> (c: u8, ok: bool) {
	c, ok = peekc(in_)
	if ok {
		in_.pos += 1
		if c == '\n' {
			in_.line += 1
		}
	}
	return
}

// discard_line throws away the rest of the current line, after a syntax
// error, so the next prompt starts clean.
discard_line :: proc(in_: ^Input) {
	for {
		c, ok := getc(in_)
		if !ok || c == '\n' {
			return
		}
	}
}

// read_file reads a whole file into a fresh buffer, or answers false.
read_file :: proc(path: string) -> (data: []u8, ok: bool) {
	fd := libuser.open(path, 0)
	if fd < 0 {
		return nil, false
	}
	defer libuser.close(int(fd))
	buf := make([dynamic]u8, 0, 4096)
	tmp: [4096]u8
	for {
		n := libuser.read(int(fd), tmp[:])
		if n < 0 {
			delete(buf)
			return nil, false
		}
		if n == 0 {
			break
		}
		append(&buf, ..tmp[:n])
	}
	return buf[:], true
}
