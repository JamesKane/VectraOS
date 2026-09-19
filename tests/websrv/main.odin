/*
websrv -- a scripted HTTP/1.1 server on `/net/tcp`, so `servers/webfs` is
proven over a real connection.

It announces a port and serves a number of connections, one after another,
each a GET answered by its path. `/` is `hello, web` as a chunked body in two
chunks, the framing a client must reassemble. `/gz` is a body gzipped, with
the header that says so. `/cookie` sets a cookie. `/whoami` answers with the
`Cookie` header it was sent, or `none`.

Then it exits `ok`, or the name of the step that did not hold. The boot
self-test runs it and has `webfs` fetch from it, `docs/WEB.md` step 0.

    websrv [port] [connections]   default 8080 and 1
*/
package websrv

import "vsys:abi"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"

CHUNKED :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n6\r\nhello,\r\n5\r\n web\n\r\n0\r\n\r\n"
GZ_HEAD :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: 42\r\nConnection: close\r\n\r\n"
// `hello, compressed web\n`, as `gzip -9 -n` framed it.
GZ_BODY := [?]u8{
	0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0xcb, 0x48,
	0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x48, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d,
	0x2e, 0x4e, 0x4d, 0x51, 0x28, 0x4f, 0x4d, 0xe2, 0x02, 0x00, 0x80, 0xd1,
	0xd8, 0x6d, 0x16, 0x00, 0x00, 0x00,
}
COOKIE :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nSet-Cookie: session=abc; Path=/\r\nContent-Length: 11\r\nConnection: close\r\n\r\ncookie set\n"
NOT_FOUND :: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
// A login page, the form a reader fills: a name, a password, a button. The
// POST it sends is answered with the name, so the reader's typing is proven
// by what comes back.
LOGIN_HEAD :: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 314\r\nConnection: close\r\n\r\n"
LOGIN_BODY :: "<html><head><title>Sign in</title></head><body><h1>Sign in</h1><form method=\"post\" action=\"/login\"><p>Name <input type=\"text\" name=\"user\" placeholder=\"name\"></p><p>Password <input type=\"password\" name=\"pass\"></p><input type=\"hidden\" name=\"next\" value=\"/\"><input type=\"submit\" value=\"Sign in\"></form></body></html>\n"

fail :: proc "contextless" (what: string) -> ! {
	libuser.eprint("websrv: ", what, "\n")
	libuser.exits(what)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	port := len(args) >= 2 ? args[1] : "8080"
	count := 1
	if len(args) >= 3 {
		if v, ok := libuser.atoi(args[2]); ok && v > 0 {
			count = int(v)
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
	libuser.eprint("websrv: listening at ", served, "\n")
	for _ in 0 ..< count {
		serve_one(lfd, served)
	}
	_ = libuser.close(int(lfd))
	libuser.exits("ok")
}

// serve_one takes the next connection off `listen` and answers its GET by path.
serve_one :: proc(lfd: i64, served: string) {
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

	// The request, up to its empty line.
	req: [4096]u8
	got := 0
	for {
		m := libuser.read(int(dfd), req[got:])
		if m <= 0 {
			fail("the request ended early")
		}
		got += int(m)
		if has_blank_line(req[:got]) || got == len(req) {
			break
		}
	}
	post := got >= 5 && string(req[:5]) == "POST "
	if !post && (got < 4 || string(req[:4]) != "GET ") {
		fail("not a GET or a POST")
	}
	// The path is the second word of the request line.
	text := string(req[post ? 5 : 4:got])
	sp := 0
	for sp < len(text) && text[sp] != ' ' {
		sp += 1
	}
	rpath := text[:sp]
	// A POST's body follows the blank line, Content-Length bytes of it,
	// which may still be on the wire.
	body := ""
	if post {
		want := header_int(text, "content-length")
		head_end := blank_line_end(req[:got])
		for got < head_end + want && got < len(req) {
			m := libuser.read(int(dfd), req[got:])
			if m <= 0 {
				break
			}
			got += int(m)
		}
		body = string(req[head_end:min(head_end + want, got)])
	}
	ok := true
	switch rpath {
	case "/new":
		// A chatmail relay's answer: an account made on this machine's own
		// address, for docs/WEB.md section 6's account in one request.
		local: [64]u8
		ln := read_small("/net/local", local[:])
		out: [256]u8
		json := libuser.cat_into(out[:], "{\"email\": \"ac1@", string(local[:max(ln, 0)]), "\", \"password\": \"relay-made\"}\n")
		head: [160]u8
		num: [16]u8
		ok = libuser.write_full(int(dfd), transmute([]u8)libuser.cat_into(head[:], "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ", libuser.itoa(num[:], i64(len(json))), "\r\nConnection: close\r\n\r\n")) && libuser.write_full(int(dfd), transmute([]u8)json)
	case "/login":
		if !post {
			ok = libuser.write_full(int(dfd), transmute([]u8)string(LOGIN_HEAD)) && libuser.write_full(int(dfd), transmute([]u8)string(LOGIN_BODY))
			break
		}
		// The name the form sent, `user=` in the body.
		user := "nobody"
		pos := 0
		for pos < len(body) {
			amp := pos
			for amp < len(body) && body[amp] != '&' {
				amp += 1
			}
			pair := body[pos:amp]
			pos = amp + 1
			if len(pair) > 5 && pair[:5] == "user=" {
				user = pair[5:]
			}
		}
		line: [300]u8
		b := libuser.cat_into(line[:], "welcome ", user, "\n")
		head: [200]u8
		hs := libodin.sink_from(head[:])
		libodin.put_str(&hs, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ")
		libodin.put_uint(&hs, u64(len(b)))
		libodin.put_str(&hs, "\r\nConnection: close\r\n\r\n")
		ok = libuser.write_full(int(dfd), transmute([]u8)libodin.str(&hs)) && libuser.write_full(int(dfd), transmute([]u8)b)
	case "/":
		ok = libuser.write_full(int(dfd), transmute([]u8)string(CHUNKED))
	case "/gz":
		gz := GZ_BODY
		ok = libuser.write_full(int(dfd), transmute([]u8)string(GZ_HEAD)) && libuser.write_full(int(dfd), gz[:])
	case "/cookie":
		ok = libuser.write_full(int(dfd), transmute([]u8)string(COOKIE))
	case "/whoami":
		// The Cookie header the client sent, or none.
		sent := "none"
		pos := 0
		for pos < len(text) {
			eol := pos
			for eol < len(text) && text[eol] != '\n' {
				eol += 1
			}
			hl := text[pos:eol]
			pos = eol + 1
			if len(hl) > 8 && (hl[:8] == "Cookie: " || hl[:8] == "cookie: ") {
				sent = hl[8:]
				for len(sent) > 0 && sent[len(sent) - 1] == '\r' {
					sent = sent[:len(sent) - 1]
				}
			}
		}
		body: [600]u8
		b := libuser.cat_into(body[:], "cookie: ", sent, "\n")
		head: [200]u8
		hs := libodin.sink_from(head[:])
		libodin.put_str(&hs, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ")
		libodin.put_uint(&hs, u64(len(b)))
		libodin.put_str(&hs, "\r\nConnection: close\r\n\r\n")
		ok = libuser.write_full(int(dfd), transmute([]u8)libodin.str(&hs)) && libuser.write_full(int(dfd), transmute([]u8)b)
	case:
		ok = libuser.write_full(int(dfd), transmute([]u8)string(NOT_FOUND))
	}
	if !ok {
		fail("send the response")
	}
	libnet.hangup(accepted)
	_ = libuser.close(int(dfd))
}

// header_int answers a header's number, or zero.
read_small :: proc "contextless" (path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	n := libuser.read(int(fd), into)
	_ = libuser.close(int(fd))
	// The address, its newline off.
	for n > 0 && (into[n - 1] == '\n' || into[n - 1] == '\r') {
		n -= 1
	}
	return int(n)
}

header_int :: proc "contextless" (text: string, name: string) -> int {
	pos := 0
	for pos < len(text) {
		eol := pos
		for eol < len(text) && text[eol] != '\n' {
			eol += 1
		}
		hl := text[pos:eol]
		pos = eol + 1
		if len(hl) <= len(name) + 1 || hl[len(name)] != ':' {
			continue
		}
		same := true
		for i in 0 ..< len(name) {
			c := hl[i]
			if c >= 'A' && c <= 'Z' {
				c += 32
			}
			if c != name[i] {
				same = false
				break
			}
		}
		if !same {
			continue
		}
		v := 0
		for i in len(name) + 1 ..< len(hl) {
			if hl[i] >= '0' && hl[i] <= '9' {
				v = v * 10 + int(hl[i] - '0')
			}
		}
		return v
	}
	return 0
}

// blank_line_end is the offset just past the first blank line.
blank_line_end :: proc "contextless" (req: []u8) -> int {
	for i in 0 ..< len(req) {
		if req[i] == '\n' && i + 2 < len(req) && req[i + 1] == '\r' && req[i + 2] == '\n' {
			return i + 3
		}
		if req[i] == '\n' && i + 1 < len(req) && req[i + 1] == '\n' {
			return i + 2
		}
	}
	return len(req)
}

has_blank_line :: proc "contextless" (data: []u8) -> bool #no_bounds_check {
	for i in 0 ..< len(data) - 1 {
		if data[i] == '\n' && (data[i + 1] == '\n' || (i + 2 < len(data) && data[i + 1] == '\r' && data[i + 2] == '\n')) {
			return true
		}
	}
	return false
}
