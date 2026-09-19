/*
smtpsrv -- a scripted SMTP submission server on `/net/tcp`, so
`servers/mailfs` sending is proven over a real connection: `docs/WEB.md`
section 6's "a message written to new ... comes out of a scripted SMTP".

It announces a port and serves two sessions: EHLO, AUTH PLAIN for one
user and password, MAIL FROM, RCPT TO, DATA and QUIT. A message that is
taken is written to the file named, its dot-stuffing undone, so the
test reads what arrived. A recipient at `nowhere` is refused with 550,
which is the session that must fail. Then it exits `ok`, or the name of
the step that did not hold.

    smtpsrv [port] [file] [taken]   default 1587, /usr/glenda/sent.eml, 1

`taken` is how many messages to take before the exit; each overwrites
the file. One refused session is always waited for.
*/
package smtpsrv

import "vsys:abi"
import "vsys:libnet"
import "vsys:libuser"

USER :: "glenda"
PASSWORD :: "hunter2"
// AUTH PLAIN's line for the two above: NUL glenda NUL hunter2, in base64.
AUTH_OK :: "AGdsZW5kYQBodW50ZXIy"

fail :: proc "contextless" (what: string) -> ! {
	libuser.eprint("smtpsrv: ", what, "\n")
	libuser.exits(what)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	port := len(args) >= 2 ? args[1] : "1587"
	out := len(args) >= 3 ? args[2] : "/usr/glenda/sent.eml"
	want := 1
	if len(args) >= 4 {
		if v, ok := libuser.atoi(args[3]); ok && v > 0 {
			want = int(v)
		}
	}

	addr: [64]u8
	spec := libuser.cat_into(addr[:], "tcp!*!", port)
	dir: [libnet.DIAL_MAX]u8
	dirlen, ok := libnet.announce(spec, dir[:])
	if !ok {
		fail("announce")
	}
	served := string(dir[:dirlen])
	path: [160]u8
	lfd := libuser.open(libnet.join(path[:], served, "listen"), abi.O_RDONLY)
	if lfd < 0 {
		fail("listen")
	}
	libuser.eprint("smtpsrv: listening at ", served, "\n")

	taken := 0
	refused := 0
	for taken < want || refused < 1 {
		if serve_one(lfd, served, out) {
			taken += 1
		} else {
			refused += 1
		}
	}
	_ = libuser.close(int(lfd))
	if taken != want || refused != 1 {
		fail("the messages taken and one refused wanted")
	}
	libuser.exits("ok")
}

// serve_one runs one session. True when a message was taken.
serve_one :: proc(lfd: i64, served: string, out: string) -> bool {
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
	base: [160]u8
	accepted := libuser.cat_into(base[:], served[:cut + 1], string(line[:at]))
	dfd := libuser.open(libnet.join(path[:], accepted, "data"), abi.O_RDWR)
	if dfd < 0 {
		fail("open the stream")
	}
	defer {
		_ = libuser.close(int(dfd))
		libnet.hangup(accepted)
	}
	say(dfd, "220 smtpsrv ready\r\n")

	rd: libuser.Reader
	libuser.reader_init(&rd, int(dfd))
	authed := false
	taken := false
	for {
		req, got := libuser.read_line(&rd)
		if !got {
			return taken
		}
		verb, args := word(req)
		up: [16]u8
		switch upper(verb, up[:]) {
		case "EHLO", "HELO":
			say(dfd, "250-smtpsrv greets you\r\n250 AUTH PLAIN\r\n")
		case "AUTH":
			_, cred := word(args)
			cred, _ = word(cred)
			if cred == AUTH_OK {
				authed = true
				say(dfd, "235 Authentication successful\r\n")
			} else {
				say(dfd, "535 Authentication failed\r\n")
			}
		case "MAIL":
			say(dfd, authed ? "250 OK\r\n" : "530 Authentication required\r\n")
		case "RCPT":
			if has_suffix(args, "nowhere>") || has_suffix(args, "nowhere>\r") {
				say(dfd, "550 No such user here\r\n")
			} else {
				say(dfd, "250 OK\r\n")
			}
		case "DATA":
			say(dfd, "354 End data with <CR><LF>.<CR><LF>\r\n")
			if take_message(&rd, out) {
				taken = true
				say(dfd, "250 OK: queued\r\n")
			} else {
				say(dfd, "554 Transaction failed\r\n")
			}
		case "QUIT":
			say(dfd, "221 Bye\r\n")
			return taken
		case "RSET", "NOOP":
			say(dfd, "250 OK\r\n")
		case:
			say(dfd, "500 Command unrecognized\r\n")
		}
	}
}

// take_message reads lines up to the lone dot into `out`, a leading
// doubled dot made single, each line ended with CRLF as it came.
take_message :: proc(rd: ^libuser.Reader, out: string) -> bool {
	// The disk keeps a file across boots, and a create will not overwrite.
	_ = libuser.remove(out)
	fd := libuser.create(out, abi.O_WRONLY, 0o644)
	if fd < 0 {
		fail("create the output file")
	}
	defer _ = libuser.close(int(fd))
	for {
		l, got := libuser.read_line(rd)
		if !got {
			return false
		}
		if len(l) > 0 && l[len(l) - 1] == '\r' {
			l = l[:len(l) - 1]
		}
		if l == "." {
			return true
		}
		if len(l) > 1 && l[0] == '.' && l[1] == '.' {
			l = l[1:]
		}
		if !libuser.write_full(int(fd), transmute([]u8)l) || !libuser.write_full(int(fd), transmute([]u8)string("\r\n")) {
			fail("write the message")
		}
	}
}

say :: proc(dfd: i64, text: string) {
	if !libuser.write_full(int(dfd), transmute([]u8)text) {
		fail("write the reply")
	}
}

word :: proc "contextless" (s: string) -> (first: string, rest: string) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\r') {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' && s[i] != '\r' {
		i += 1
	}
	first = s[start:i]
	for i < len(s) && s[i] == ' ' {
		i += 1
	}
	return first, s[i:]
}

upper :: proc "contextless" (s: string, into: []u8) -> string {
	n := min(len(s), len(into))
	for i in 0 ..< n {
		c := s[i]
		into[i] = c >= 'a' && c <= 'z' ? c - 32 : c
	}
	return string(into[:n])
}

has_suffix :: proc "contextless" (s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}
