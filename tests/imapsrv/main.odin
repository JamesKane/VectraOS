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

    imapsrv [port]   default 1143
*/
package imapsrv

import "vsys:abi"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"

USER :: "glenda"
PASSWORD :: "hunter2"

REPLY :: "From: Bob Jones <bob@example.net>\r\nTo: glenda@example.org\r\nSubject: Re: A message with two parts\r\nDate: Fri, 18 Sep 2026 09:00:00 +0000\r\nMessage-ID: <two@example.net>\r\nIn-Reply-To: <one@example.org>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nGot it, thanks.\r\n"

fail :: proc "contextless" (what: string) -> ! {
	libuser.eprint("imapsrv: ", what, "\n")
	libuser.exits(what)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	port := len(args) >= 2 ? args[1] : "1143"

	first, fok := libuser.read_file("/lib/tests/mail.eml", context.allocator)
	if !fok {
		fail("read the saved mail")
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
	libuser.eprint("imapsrv: listening at ", served, "\n")

	// Two sessions: one that logs in and fetches, and one that is refused.
	// Either may come first, and the count stands at two.
	logged := 0
	refused := 0
	for logged + refused < 2 {
		how := serve_one(lfd, served, first)
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

// serve_one takes the next connection and runs the session. True when the
// client logged in and fetched, false when it was refused.
serve_one :: proc(lfd: i64, served: string, first: []u8) -> bool {
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
			say(dfd, "* 2 EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY 1] UIDs valid\r\n* OK [UIDNEXT 103] Predicted next UID\r\n* FLAGS (\\Seen \\Answered)\r\n")
			say(dfd, libuser.cat_into(out[64:], tag, " OK [READ-WRITE] SELECT completed\r\n"))
		case "UID":
			sub, _ := word(args)
			if !selected || upper(sub, out[:64]) != "FETCH" {
				say(dfd, libuser.cat_into(out[64:], tag, " BAD not that\r\n"))
				continue
			}
			literal(dfd, 1, 101, first)
			literal(dfd, 2, 102, transmute([]u8)string(REPLY))
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
