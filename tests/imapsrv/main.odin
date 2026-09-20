/*
imapsrv -- a scripted IMAP4rev1 server on `/net/tcp`, so `servers/mailfs`
is proven over a real connection: `docs/WEB.md` section 6's "a saved IMAP
session through a pipe becomes an inbox of the right shape".

It announces a port and serves one session: a greeting, LOGIN for one
user and password, SELECT of INBOX with two messages, a UID FETCH that
answers each message as a literal, and LOGOUT. The first message is
`/lib/tests/mail.eml`, the two-part mail the document parser is proven
on. The second is a short reply to it. A wrong password is refused, and
the session then ends. Then it exits `ok`, or the name of the step that
did not hold.

With `-m` it is a mailbox instead: the files of one directory, in name
order, each a message whose UID is its place, for one user and
password. IDLE is answered, RFC 2177: `+ idling`, then `* N EXISTS`
when a file lands in the directory, until DONE. `tests/smtpsrv -d`
delivers into such directories, so two of these and one of it are the
servers between two mailfs. The directory begins empty, since the disk
keeps files across boots, and the sessions go on until the program is
ended. A session's lines come off a reader thread, so the idle can
watch the directory and the wire at once.

    imapsrv [port]                        the scripted session, default 1143
    imapsrv PORT -m DIR USER PASSWORD     a mailbox on DIR
*/
package imapsrv

import "vsys:abi"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"

USER :: "glenda"
PASSWORD :: "hunter2"

// The reply carries Bob's key the Autocrypt way: RFC 9580's sample
// certificate, whose secret key the seal's test holds.
REPLY :: "From: Bob Jones <bob@example.net>\r\nTo: glenda@example.org\r\nSubject: Re: A message with two parts\r\nDate: Fri, 18 Sep 2026 09:00:00 +0000\r\nMessage-ID: <two@example.net>\r\nIn-Reply-To: <one@example.org>\r\nAutocrypt: addr=bob@example.net; prefer-encrypt=mutual;\r\n keydata=xioGY4d/4xsAAAAg+U2nu0jWCmHlZ3BqZYfQMxmZu52JGggkLq2EVD34laPCsQYfGwoAAABCBYJj\r\n h3/jAwsJBwUVCg4IDAIWAAKbAwIeCSIhBssYbE8GCaaX5NUt+mxyKwwfHifBilZwj2Ul7Ce62azJ\r\n BScJAgcCAAAAAK0oIBA+LX0ifsDm185Ecds2v8lwgyU2kCcUmKfvBXbAf6rhRYWzuQOwEn7E/aLw\r\n IwRaLsdry0+VcallHhSu4RN6HWaEQsiPlR4zxP/TP7mhfVEe7XWPxtnMUMtf15OyA51YBM4qBmOH\r\n f+MZAAAAIIaTJINn+eUBXbki+PSAld2nhJh/LVmFsS+60WyvXkQ1wpsGGBsKAAAALAWCY4d/4wKb\r\n DCIhBssYbE8GCaaX5NUt+mxyKwwfHifBilZwj2Ul7Ce62azJAAAAAAQBIKbpGG2dWTX8j+VjFM21\r\n J0hqWlEg+bdiojWnKfA5AQpWUWtnNwDEM0g12vYxoWM8Y81W+bHBw805I8kWVkXU6vFOi+HWvv/i\r\n ra7ofJu16NnoUkhclkUrk0mXubZvyl4GBg==\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nGot it, thanks.\r\n"

// A third message, when the seal's test left one: sealed to the key
// factotum holds, so the inbox opens it.
SEALED_PATH :: "/usr/glenda/sealed.eml"
// And a fourth, sealed the same but with its signature bent, for the
// inbox to refuse.
BAD_PATH :: "/usr/glenda/sealed-bad.eml"

fail :: proc "contextless" (what: string) -> ! {
	libuser.eprint("imapsrv: ", what, "\n")
	libuser.exits(what)
}

// The mailbox, when `-m` was said.
Box :: struct {
	dir:   string,
	user:  string,
	pass:  string,
	names: [dynamic]string, // names[i] is the message with UID i + 1
}

box: Box

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	port := len(args) >= 2 ? args[1] : "1143"
	if len(args) >= 6 && args[2] == "-m" {
		box.dir = args[3]
		box.user = args[4]
		box.pass = args[5]
		box_port = port
		libthread.main(box_main, rawptr(&box), 64 * 1024)
	}

	first, fok := libuser.read_file("/lib/tests/mail.eml", context.allocator)
	if !fok {
		fail("read the saved mail")
	}
	sealed, _ := libuser.read_file(SEALED_PATH, context.allocator)
	bad, _ := libuser.read_file(BAD_PATH, context.allocator)

	lfd, served := listen_on(port)

	// Two sessions: one that logs in and fetches, and one that is refused.
	// Either may come first, and the count stands at two.
	logged := 0
	refused := 0
	for logged + refused < 2 {
		how := serve_one(lfd, served, first, sealed, bad)
		if how {
			logged += 1
		} else {
			refused += 1
		}
	}
	_ = libuser.close(int(lfd))
	if logged != 1 || refused != 1 {
		fail("one session in and one refused wanted")
	}
	libuser.exits("ok")
}

// listen_on announces the port and opens its listen file.
listen_on :: proc(port: string) -> (lfd: i64, served: string) {
	addr: [64]u8
	spec := libuser.cat_into(addr[:], "tcp!*!", port)
	@(static) dir: [libnet.DIAL_MAX]u8
	dirlen, ok := libnet.announce(spec, dir[:])
	if !ok {
		fail("announce")
	}
	served = string(dir[:dirlen])
	path: [160]u8
	lfd = libuser.open(libnet.join(path[:], served, "listen"), abi.O_RDONLY)
	if lfd < 0 {
		fail("listen")
	}
	libuser.eprint("imapsrv: listening at ", served, "\n")
	return lfd, served
}

// accept takes the next connection: its data file open, and its directory
// for the hangup.
accept :: proc(lfd: i64, served: string, accepted_buf: []u8) -> (dfd: i64, accepted: string) {
	path: [160]u8
	line: [64]u8
	n := libuser.read(int(lfd), line[:])
	if n <= 0 {
		fail("nothing connected")
	}
	at := 0
	for at < int(n) && line[at] >= '0' && line[at] <= '9' {
		at += 1
	}
	cut := 0
	for i in 0 ..< len(served) {
		if served[i] == '/' {
			cut = i
		}
	}
	accepted = libuser.cat_into(accepted_buf, served[:cut + 1], string(line[:at]))
	dfd = libuser.open(libnet.join(path[:], accepted, "data"), abi.O_RDWR)
	if dfd < 0 {
		fail("open the stream")
	}
	return dfd, accepted
}

// serve_one takes the next connection and runs the scripted session. True
// when the client logged in and fetched, false when it was refused.
serve_one :: proc(lfd: i64, served: string, first: []u8, sealed: []u8, bad: []u8) -> bool {
	base: [160]u8
	dfd, accepted := accept(lfd, served, base[:])
	defer {
		_ = libuser.close(int(dfd))
		libnet.hangup(accepted)
	}
	say(dfd, "* OK imapsrv ready\r\n")

	rd: libuser.Reader
	libuser.reader_init(&rd, int(dfd))
	logged := false
	selected := false
	for {
		req, got := libuser.read_line(&rd)
		if !got {
			return logged
		}
		tag, rest := word(req)
		verb, args := word(rest)
		out: [256]u8
		switch upper(verb, out[:64]) {
		case "CAPABILITY":
			say(dfd, "* CAPABILITY IMAP4rev1\r\n")
			say(dfd, libuser.cat_into(out[64:], tag, " OK CAPABILITY completed\r\n"))
		case "LOGIN":
			user, pass := word(args)
			pass, _ = word(pass)
			if unquote(user) == USER && unquote(pass) == PASSWORD {
				logged = true
				say(dfd, libuser.cat_into(out[64:], tag, " OK LOGIN completed\r\n"))
			} else {
				say(dfd, libuser.cat_into(out[64:], tag, " NO LOGIN failed\r\n"))
			}
		case "SELECT", "EXAMINE":
			if !logged {
				say(dfd, libuser.cat_into(out[64:], tag, " NO not logged in\r\n"))
				continue
			}
			selected = true
			count := 2 + (len(sealed) > 0 ? 1 : 0) + (len(bad) > 0 ? 1 : 0)
			say_selected(dfd, tag, count)
		case "UID":
			sub, _ := word(args)
			if !selected || upper(sub, out[:64]) != "FETCH" {
				say(dfd, libuser.cat_into(out[64:], tag, " BAD not that\r\n"))
				continue
			}
			literal(dfd, 1, 101, first)
			literal(dfd, 2, 102, transmute([]u8)string(REPLY))
			if len(sealed) > 0 {
				literal(dfd, 3, 103, sealed)
			}
			if len(bad) > 0 {
				literal(dfd, 4, 104, bad)
			}
			say(dfd, libuser.cat_into(out[64:], tag, " OK FETCH completed\r\n"))
		case "LOGOUT":
			say(dfd, "* BYE imapsrv logging out\r\n")
			say(dfd, libuser.cat_into(out[64:], tag, " OK LOGOUT completed\r\n"))
			return logged
		case "NOOP":
			say(dfd, libuser.cat_into(out[64:], tag, " OK NOOP completed\r\n"))
		case:
			say(dfd, libuser.cat_into(out[64:], tag, " BAD unknown command\r\n"))
		}
	}
}

// say_selected answers a SELECT: the count, and what a client expects beside it.
say_selected :: proc(dfd: i64, tag: string, count: int) {
	num: [8]u8
	line: [32]u8
	out: [128]u8
	say(dfd, libuser.cat_into(line[:], "* ", libuser.itoa(num[:], i64(count)), " EXISTS\r\n"))
	say(dfd, "* 0 RECENT\r\n* OK [UIDVALIDITY 1] UIDs valid\r\n* FLAGS (\\Seen \\Answered)\r\n")
	say(dfd, libuser.cat_into(out[:], tag, " OK [READ-WRITE] SELECT completed\r\n"))
}

// -- The mailbox --------------------------------------------------------------------

// One line off the wire, the reader thread's to make and the session's
// to free. A nil in the channel is the end of the stream.
Line :: struct {
	buf: [2048]u8,
	n:   int,
}

Reader :: struct {
	fd:    int,
	lines: ^libthread.Chan, // ^Line
}

box_main :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	b := (^Box)(arg)
	// The mailbox begins empty: the disk keeps files across boots.
	cut := 0
	for i in 0 ..< len(b.dir) {
		if b.dir[i] == '/' {
			cut = i
		}
	}
	if cut > 0 {
		_ = libuser.mkdir(b.dir[:cut])
	}
	_ = libuser.mkdir(b.dir)
	if names, ok := libuser.read_dir(b.dir); ok {
		path: [512]u8
		for name in names {
			_ = libuser.remove(libuser.cat_into(path[:], b.dir, "/", name))
			delete(name)
		}
		delete(names)
	}
	lfd, served := listen_on(box_port)
	for {
		serve_box(lfd, served)
	}
}

box_port: string // The mailbox's port, from the arguments

// serve_box runs one session on the mailbox, its lines from a reader
// thread so IDLE can watch the directory between them.
serve_box :: proc(lfd: i64, served: string) {
	base: [160]u8
	dfd, accepted := accept(lfd, served, base[:])
	rd := new(Reader)
	rd.fd = int(dfd)
	rd.lines = libthread.chancreate(size_of(rawptr), 16)
	// The idle's wait between looks at the directory goes through an io
	// proc: a sleep made as a system call would park this proc whole, and
	// the reader thread with it, so DONE would never arrive.
	io := libthread.ioproc()
	if rd.lines == nil || io == nil || libthread.threadcreate(reader_thread, rd, 32 * 1024) < 0 {
		fail("a reader for the session")
	}
	say(dfd, "* OK imapsrv ready\r\n")
	logged := false
	selected := false
	gone := false
	for !gone {
		l := (^Line)(libthread.recvp(rd.lines))
		if l == nil {
			break
		}
		req := string(l.buf[:l.n])
		tag, rest := word(req)
		verb, args := word(rest)
		out: [256]u8
		switch upper(verb, out[:64]) {
		case "CAPABILITY":
			say(dfd, "* CAPABILITY IMAP4rev1 IDLE\r\n")
			say(dfd, libuser.cat_into(out[64:], tag, " OK CAPABILITY completed\r\n"))
		case "LOGIN":
			user, pass := word(args)
			pass, _ = word(pass)
			if unquote(user) == box.user && unquote(pass) == box.pass {
				logged = true
				say(dfd, libuser.cat_into(out[64:], tag, " OK LOGIN completed\r\n"))
			} else {
				say(dfd, libuser.cat_into(out[64:], tag, " NO LOGIN failed\r\n"))
			}
		case "SELECT", "EXAMINE":
			if !logged {
				say(dfd, libuser.cat_into(out[64:], tag, " NO not logged in\r\n"))
				break
			}
			selected = true
			_ = scan_box()
			say_selected(dfd, tag, len(box.names))
		case "UID":
			sub, range := word(args)
			if !selected || upper(sub, out[:64]) != "FETCH" {
				say(dfd, libuser.cat_into(out[64:], tag, " BAD not that\r\n"))
				break
			}
			range, _ = word(range)
			from := 0
			for i in 0 ..< len(range) {
				if range[i] < '0' || range[i] > '9' {
					break
				}
				from = from * 10 + int(range[i] - '0')
			}
			if from < 1 {
				from = 1
			}
			if from > len(box.names) && len(box.names) > 0 {
				// `N:*` past the last: the last one, as the RFC has it.
				from = len(box.names)
			}
			path: [512]u8
			for i := from - 1; i < len(box.names); i += 1 {
				body, ok := libuser.read_file(libuser.cat_into(path[:], box.dir, "/", box.names[i]), context.allocator)
				if !ok {
					continue
				}
				literal(dfd, i + 1, i + 1, body)
				delete(body)
			}
			say(dfd, libuser.cat_into(out[64:], tag, " OK FETCH completed\r\n"))
		case "IDLE":
			if !selected {
				say(dfd, libuser.cat_into(out[64:], tag, " BAD not selected\r\n"))
				break
			}
			say(dfd, "+ idling\r\n")
			// The wire and the directory, in turn, until DONE.
			for {
				if p, ok := libthread.nbrecvp(rd.lines); ok {
					if p == nil {
						gone = true
						break
					}
					l2 := (^Line)(p)
					word1, _ := word(string(l2.buf[:l2.n]))
					done := upper(word1, out[:64]) == "DONE"
					free(l2)
					if done {
						say(dfd, libuser.cat_into(out[64:], tag, " OK IDLE terminated\r\n"))
						break
					}
					continue
				}
				if scan_box() {
					num: [8]u8
					line: [32]u8
					say(dfd, libuser.cat_into(line[:], "* ", libuser.itoa(num[:], i64(len(box.names))), " EXISTS\r\n"))
				}
				_ = libthread.iosleep(io, 10)
			}
		case "LOGOUT":
			say(dfd, "* BYE imapsrv logging out\r\n")
			say(dfd, libuser.cat_into(out[64:], tag, " OK LOGOUT completed\r\n"))
			// The client closes, and the reader says so.
		case "NOOP":
			say(dfd, libuser.cat_into(out[64:], tag, " OK NOOP completed\r\n"))
		case:
			say(dfd, libuser.cat_into(out[64:], tag, " BAD unknown command\r\n"))
		}
		free(l)
	}
	// The reader ended with the stream, and its channel is empty.
	libthread.ioclose(io)
	libthread.chanfree(rd.lines)
	free(rd)
	_ = libuser.close(int(dfd))
	libnet.hangup(accepted)
}

// scan_box takes any file new to the directory into the mailbox, in name
// order among themselves, and says whether there was one.
scan_box :: proc() -> bool {
	names, ok := libuser.read_dir(box.dir)
	if !ok {
		return false
	}
	defer delete(names)
	fresh: [dynamic]string
	defer delete(fresh)
	for name in names {
		known := false
		for have in box.names {
			if have == name {
				known = true
				break
			}
		}
		if known {
			delete(name)
			continue
		}
		// In order by name, so the relay's numbers stand.
		at := len(fresh)
		for i in 0 ..< len(fresh) {
			if fresh[i] > name {
				at = i
				break
			}
		}
		inject_at(&fresh, at, name)
	}
	for name in fresh {
		append(&box.names, name)
	}
	return len(fresh) > 0
}

inject_at :: proc(list: ^[dynamic]string, at: int, s: string) {
	append(list, "")
	for i := len(list) - 1; i > at; i -= 1 {
		list[i] = list[i - 1]
	}
	list[at] = s
}

// reader_thread reads the stream on an io proc of its own and hands each
// line to the session, then a nil when the stream ends.
reader_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	rd := (^Reader)(arg)
	io := libthread.ioproc()
	buf := make([]u8, 8192)
	start := 0
	end := 0
	if io != nil {
		for {
			found := false
			for i in start ..< end {
				if buf[i] == '\n' {
					e := i
					if e > start && buf[e - 1] == '\r' {
						e -= 1
					}
					l := new(Line)
					l.n = copy(l.buf[:], buf[start:e])
					start = i + 1
					libthread.sendp(rd.lines, l)
					found = true
					break
				}
			}
			if found {
				continue
			}
			if start > 0 {
				copy(buf, buf[start:end])
				end -= start
				start = 0
			}
			if end == len(buf) {
				break
			}
			n := libthread.ioread(io, rd.fd, buf[end:])
			if n <= 0 {
				break
			}
			end += int(n)
		}
		libthread.ioclose(io)
	}
	delete(buf)
	libthread.sendp(rd.lines, nil)
	libthread.threadexits("")
}

// -- Shared -------------------------------------------------------------------------

// literal answers one message of a UID FETCH: the header line with the
// byte count, the bytes, and the closing parenthesis.
literal :: proc(dfd: i64, seq: int, uid: int, body: []u8) {
	head: [128]u8
	sink := libodin.sink_from(head[:])
	libodin.put_str(&sink, "* ")
	libodin.put_uint(&sink, u64(seq))
	libodin.put_str(&sink, " FETCH (UID ")
	libodin.put_uint(&sink, u64(uid))
	libodin.put_str(&sink, " BODY[] {")
	libodin.put_uint(&sink, u64(len(body)))
	libodin.put_str(&sink, "}\r\n")
	say(dfd, libodin.str(&sink))
	if !libuser.write_full(int(dfd), body) {
		fail("write the message")
	}
	say(dfd, ")\r\n")
}

say :: proc(dfd: i64, text: string) {
	if !libuser.write_full(int(dfd), transmute([]u8)text) {
		fail("write the reply")
	}
}

word :: proc "contextless" (s: string) -> (first: string, rest: string) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\r' || s[i] == '\n') {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' && s[i] != '\r' && s[i] != '\n' {
		i += 1
	}
	first = s[start:i]
	for i < len(s) && s[i] == ' ' {
		i += 1
	}
	return first, s[i:]
}

unquote :: proc "contextless" (s: string) -> string {
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' {
		return s[1:len(s) - 1]
	}
	return s
}

upper :: proc "contextless" (s: string, into: []u8) -> string {
	n := min(len(s), len(into))
	for i in 0 ..< n {
		c := s[i]
		into[i] = c >= 'a' && c <= 'z' ? c - 32 : c
	}
	return string(into[:n])
}
