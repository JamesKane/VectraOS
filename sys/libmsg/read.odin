/*
The reading half of libmsg: a message directory back into a record, and a
conversation directory into its rows. This is what a program that shows
messages uses, `apps/mothra` first, and it reads any network's tree, since
they all serve one shape. `is_message` says whether a directory is one,
by its `from` file.
*/
package libmsg

import "vsys:abi"
import "vsys:libuser"

// How much of a body a row of a timeline needs: its first line.
FIRST_LINE_MAX :: 256

// is_message says whether `dir` is a message directory: it has a `from`.
is_message :: proc "contextless" (dir: string) -> bool {
	path: [512]u8
	st: abi.Stat
	return libuser.stat(libuser.cat_into(path[:], dir, "/from"), &st) >= 0
}

// path_is_dir says whether a path is a directory.
path_is_dir :: proc "contextless" (path: string) -> bool {
	st: abi.Stat
	return libuser.stat(path, &st) >= 0 && st.mode & abi.DMDIR != 0
}

/*
read_msg reads a message directory into a record: every file but `raw`,
whose bytes a reader does not show, and `replies`, which is walked with
`read_conv`. The record's strings are its own, on `allocator`, and `id`
is the directory's last name.
*/
read_msg :: proc(dir: string, allocator := context.allocator) -> (m: Msg, ok: bool) {
	context.allocator = allocator
	if !is_message(dir) {
		return m, false
	}
	m.id = clone(libuser.basename(dir))
	m.from = read_line(dir, "from")
	m.subject = read_line(dir, "subject")
	m.type = read_line(dir, "type")
	m.replyto = read_line(dir, "replyto")
	date := read_line(dir, "date")
	defer delete(date)
	m.date, m.date_text = split_date(date)
	m.body = read_whole(dir, "body")
	m.links = read_whole(dir, "links")
	h := read_line(dir, "hash")
	defer delete(h)
	m.hash_len = copy(m.hash[:], h)
	return m, true
}

/*
read_conv reads a conversation directory into rows: each message's id,
from, date, subject and the first line of its body, in the directory's
order, which is time order. The rows are records with the rest empty.
*/
read_conv :: proc(dir: string, allocator := context.allocator) -> (rows: []Msg, ok: bool) {
	context.allocator = allocator
	names, found := libuser.read_dir(dir)
	if !found {
		return nil, false
	}
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	list := make([dynamic]Msg, 0, len(names))
	path: [512]u8
	for name in names {
		sub := libuser.cat_into(path[:], dir, "/", name)
		if !is_message(sub) {
			continue
		}
		m: Msg
		m.id = clone(name)
		m.from = read_line(sub, "from")
		m.subject = read_line(sub, "subject")
		date := read_line(sub, "date")
		m.date, m.date_text = split_date(date)
		delete(date)
		m.body = read_first_line(sub, "body")
		append(&list, m)
	}
	return list[:], true
}

rows_free :: proc(rows: []Msg, allocator := context.allocator) {
	context.allocator = allocator
	for &m in rows {
		msg_free(&m)
	}
	delete(rows)
}

// first_line answers what a timeline row shows of a message: its subject,
// or the first line of its body when it has none.
first_line :: proc "contextless" (m: ^Msg) -> string {
	if len(m.subject) > 0 {
		return m.subject
	}
	for i in 0 ..< len(m.body) {
		if m.body[i] == '\n' {
			return m.body[:i]
		}
	}
	return m.body
}

// split_date parts a `date` file's line into the seconds and the text.
@(private = "file")
split_date :: proc(line: string) -> (secs: i64, text: string) {
	i := 0
	for i < len(line) && line[i] != ' ' {
		i += 1
	}
	secs, _ = libuser.atoi(line[:i])
	if i < len(line) {
		return secs, clone(line[i + 1:])
	}
	return secs, ""
}

@(private = "file")
read_line :: proc(dir: string, name: string) -> string {
	text := read_whole(dir, name)
	n := len(text)
	for n > 0 && (text[n - 1] == '\n' || text[n - 1] == '\r') {
		n -= 1
	}
	return text[:n]
}

@(private = "file")
read_whole :: proc(dir: string, name: string) -> string {
	path: [512]u8
	data, ok := libuser.read_file(libuser.cat_into(path[:], dir, "/", name), context.allocator)
	if !ok {
		return ""
	}
	return string(data)
}

@(private = "file")
read_first_line :: proc(dir: string, name: string) -> string {
	path: [512]u8
	fd := libuser.open(libuser.cat_into(path[:], dir, "/", name), abi.O_RDONLY)
	if fd < 0 {
		return ""
	}
	buf: [FIRST_LINE_MAX]u8
	n := libuser.read(int(fd), buf[:])
	_ = libuser.close(int(fd))
	if n <= 0 {
		return ""
	}
	end := 0
	for end < int(n) && buf[end] != '\n' {
		end += 1
	}
	return clone(string(buf[:end]))
}
