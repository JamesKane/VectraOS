/*
libplumb -- a plumb message, packed and unpacked, sent and received.

`servers/plumber` routes a message from one program to another by rules,
`docs/GHOST.md` section 5. A message is Plan 9's: a source, a destination
port, a working directory, a type, attributes as `name=value` pairs, and the
data. On the wire it is text, one field per line and the data last after
its byte count. So `cat` shows one and `echo` could make one.

    src
    dst
    wdir
    type
    attr
    ndata
    data

A program sends by writing a packed message to `/mnt/plumb/send`. It receives
by reading a port, `/mnt/plumb/web` say, where each read that returns is one
whole message. A read parks until there is one.
*/
package libplumb

import "vsys:abi"
import "vsys:libuser"

// The most a message may pack to: a port's read takes one in one frame.
MAX :: 8192

PLUMB_DIR :: "/mnt/plumb"
PLUMB_SRV :: "/srv/plumb"

// reach opens a file under the plumber's directory. When the directory is
// empty in this namespace, the posted plumber is mounted there first. So a
// program the plumber itself started, whose namespace was made before the
// mount, still finds it.
reach :: proc "contextless" (name: string, flags: u64) -> int {
	path: [128]u8
	full := libuser.cat_into(path[:], PLUMB_DIR, "/", name)
	fd := libuser.open(full, flags)
	if fd < 0 {
		if libuser.mount(PLUMB_SRV, PLUMB_DIR, 0) < 0 {
			return -1
		}
		fd = libuser.open(full, flags)
	}
	return int(fd)
}

Msg :: struct {
	src:  string,
	dst:  string,
	wdir: string,
	type: string,
	attr: string,
	data: string,
}

// pack writes `m` in the wire form into `into` and answers the length, or
// -1 when it does not fit.
pack :: proc "contextless" (m: ^Msg, into: []u8) -> int {
	count: [24]u8
	n := put_uint(count[:], len(m.data))
	need := len(m.src) + len(m.dst) + len(m.wdir) + len(m.type) + len(m.attr) + n + 6 + len(m.data)
	if need > len(into) {
		return -1
	}
	at := 0
	at += copy(into[at:], m.src)
	into[at] = '\n'
	at += 1
	at += copy(into[at:], m.dst)
	into[at] = '\n'
	at += 1
	at += copy(into[at:], m.wdir)
	into[at] = '\n'
	at += 1
	at += copy(into[at:], m.type)
	into[at] = '\n'
	at += 1
	at += copy(into[at:], m.attr)
	into[at] = '\n'
	at += 1
	at += copy(into[at:], count[:n])
	into[at] = '\n'
	at += 1
	at += copy(into[at:], m.data)
	return at
}

// unpack reads a message in the wire form. Its strings point into `text`.
unpack :: proc "contextless" (text: string) -> (m: Msg, ok: bool) {
	rest := text
	m.src, rest, ok = take_line(rest)
	if !ok {
		return m, false
	}
	m.dst, rest, ok = take_line(rest)
	if !ok {
		return m, false
	}
	m.wdir, rest, ok = take_line(rest)
	if !ok {
		return m, false
	}
	m.type, rest, ok = take_line(rest)
	if !ok {
		return m, false
	}
	m.attr, rest, ok = take_line(rest)
	if !ok {
		return m, false
	}
	count: string
	count, rest, ok = take_line(rest)
	if !ok {
		return m, false
	}
	n := 0
	for i in 0 ..< len(count) {
		if count[i] < '0' || count[i] > '9' {
			return m, false
		}
		n = n * 10 + int(count[i] - '0')
	}
	if n > len(rest) {
		return m, false
	}
	m.data = rest[:n]
	return m, true
}

// take_line answers the text up to the next newline and what follows it.
take_line :: proc "contextless" (s: string) -> (line: string, rest: string, ok: bool) {
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			return s[:i], s[i + 1:], true
		}
	}
	return s, "", false
}

/*
attr_value answers the value of `name` among `attr`'s `name=value` pairs,
which spaces part. A value may be quoted with single quotes, `''` inside
standing for one. It is answered with the quotes still on, since a caller
that wants a quoted one strips it.
*/
attr_value :: proc "contextless" (attr: string, name: string) -> (string, bool) {
	at := 0
	for at < len(attr) {
		for at < len(attr) && attr[at] == ' ' {
			at += 1
		}
		start := at
		eq := -1
		for at < len(attr) && attr[at] != ' ' {
			if attr[at] == '=' && eq < 0 {
				eq = at
			}
			if attr[at] == '\'' {
				// Inside quotes, up to the closing one.
				at += 1
				for at < len(attr) {
					if attr[at] == '\'' {
						if at + 1 < len(attr) && attr[at + 1] == '\'' {
							at += 2
							continue
						}
						break
					}
					at += 1
				}
			}
			at += 1
		}
		if eq >= 0 && attr[start:eq] == name {
			return attr[eq + 1:min(at, len(attr))], true
		}
	}
	return "", false
}

// send writes `m` to the plumber. False when there is no plumber, or no rule
// took the message.
send :: proc "contextless" (m: ^Msg) -> bool {
	buf: [MAX]u8
	n := pack(m, buf[:])
	if n < 0 {
		return false
	}
	fd := reach("send", abi.O_WRONLY)
	if fd < 0 {
		return false
	}
	wrote := libuser.write(fd, buf[:n])
	_ = libuser.close(fd)
	return wrote == i64(n)
}

// send_text sends `data` as text from `src`, to whatever port the rules say.
send_text :: proc "contextless" (src: string, data: string) -> bool {
	m := Msg{src = src, type = "text", data = data}
	return send(&m)
}

// open_port opens a port for reading, or answers -1.
open_port :: proc "contextless" (name: string) -> int {
	return reach(name, abi.O_RDONLY)
}

// recv reads one message off an open port into `buf` and unpacks it. The
// read parks until a message is there. False at end of file, when the
// plumber is gone.
recv :: proc "contextless" (fd: int, buf: []u8) -> (m: Msg, ok: bool) {
	n := libuser.read(fd, buf)
	if n <= 0 {
		return m, false
	}
	return unpack(string(buf[:n]))
}

put_uint :: proc "contextless" (into: []u8, v: int) -> int {
	if v == 0 {
		into[0] = '0'
		return 1
	}
	tmp: [24]u8
	n := 0
	x := v
	for x > 0 {
		tmp[n] = u8('0' + x % 10)
		x /= 10
		n += 1
	}
	for i in 0 ..< n {
		into[i] = tmp[n - 1 - i]
	}
	return n
}
