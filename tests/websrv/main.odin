/*
websrv -- a scripted HTTP/1.1 server on `/net/tcp`, so `servers/webfs` is
proven over a real connection.

It announces a port, takes one connection, and reads a request up to its
empty line. It answers `hello, web` as a chunked body in two chunks, which is
the framing a client must reassemble. Then it hangs up and exits `ok`, or the name
of the step that did not hold. The boot self-test runs it and has `webfs`
fetch from it, `docs/WEB.md` step 0.

    websrv [port]                 default 8080
*/
package websrv

import "vsys:abi"
import "vsys:libnet"
import "vsys:libuser"

RESPONSE :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n6\r\nhello,\r\n5\r\n web\n\r\n0\r\n\r\n"

fail :: proc "contextless" (what: string) -> ! {
	libuser.eprint("websrv: ", what, "\n")
	libuser.exits(what)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	port := len(args) >= 2 ? args[1] : "8080"

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
	line: [64]u8
	n := libuser.read(int(lfd), line[:])
	_ = libuser.close(int(lfd))
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
	if got < 4 || string(req[:4]) != "GET " {
		fail("not a GET")
	}
	if !libuser.write_full(int(dfd), transmute([]u8)string(RESPONSE)) {
		fail("send the response")
	}
	libnet.hangup(accepted)
	_ = libuser.close(int(dfd))
	libuser.exits("ok")
}

has_blank_line :: proc "contextless" (data: []u8) -> bool #no_bounds_check {
	for i in 0 ..< len(data) - 1 {
		if data[i] == '\n' && (data[i + 1] == '\n' || (i + 2 < len(data) && data[i + 1] == '\r' && data[i + 2] == '\n')) {
			return true
		}
	}
	return false
}
