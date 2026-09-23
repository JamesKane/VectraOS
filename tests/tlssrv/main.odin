/*
tlssrv -- a scripted TLS 1.3 server on `/net/tcp`, so `tlsclient` is proven
over a real connection.

`tests/crypto` proves the client engine against a server on an in-memory pipe.
What that cannot reach is the command's own glue. The dial through `/net/cs`,
the trust store read off `/lib/tls/roots`, the clock off `/dev/time`, and the
relay of standard input and output. This is the far end for that. It announces
a port and takes one connection. It answers the ClientHello with the
certificate the trust store holds (the leaf is its own root). It checks the
client's Finished, reads one line of application data, and answers it prefixed
`you said: `. Then it says close_notify, hangs up, and exits `ok`, or the name
of the step that did not hold. A GET gets a small page, and a Gemini request
a small capsule.

`tests/web.rc` runs it against `tlsclient` from the boot self-test,
`docs/WEB.md` step 0.

    tlssrv [port] [-u]            default 4433

`-u` serves `/lib/tests/capsule.der` instead: a self-signed certificate no
trust root names, the capsule `webfs` trusts on first use.

The server side of the handshake is `sys/libtls/server.odin`. This file frames
records and moves them, one message per record, the way a plain peer would.
*/
package tlssrv

import "vsys:abi"
import "vsys:libnet"
import "vsys:libtls"
import "vsys:libuser"

// The private scalar of the certificate in `/lib/tls/roots` -- the same key
// `tests/crypto` embeds, so both fixtures sign for the one test identity.
CERT_PRIV :: [32]u8{
	0x92, 0xf2, 0x9e, 0x14, 0x1a, 0x76, 0xb7, 0xa3, 0x24, 0x15, 0x22, 0x91, 0x8e, 0x97, 0x45, 0x9f,
	0xce, 0xcf, 0xb3, 0xa8, 0x8d, 0x01, 0xb7, 0x43, 0xda, 0x72, 0x23, 0x9b, 0xa3, 0x6b, 0xaa, 0x3c,
}

// The private scalar of `tests/capsule.der`, the certificate no root names.
CAPSULE_PRIV :: [32]u8{
	0x4e, 0x03, 0x09, 0x95, 0x70, 0x03, 0x65, 0x00, 0xd1, 0x81, 0x45, 0x4e, 0x6e, 0x44, 0x35, 0x9b,
	0xc7, 0x24, 0xa2, 0x1b, 0x42, 0x11, 0xe7, 0x32, 0x38, 0x95, 0x80, 0x70, 0xf4, 0x17, 0xf1, 0x6b,
}

// What an HTTP request is answered with: a body by Content-Length.
HTTP_RESPONSE :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 18\r\nConnection: close\r\n\r\nhello, secure web\n"

// What a Gemini request is answered with: a status, a media type, a body.
GEMINI_RESPONSE :: "20 text/gemini\r\n# hello, gemini\n"

// request_whole says whether the client's request has all arrived: a line for
// the echo, or an HTTP request through its empty line.
request_whole :: proc "contextless" (req: []u8) -> bool #no_bounds_check {
	if len(req) == 0 {
		return false
	}
	if len(req) >= 4 && string(req[:4]) == "GET " {
		for i in 0 ..< len(req) - 1 {
			if req[i] == '\n' && (req[i + 1] == '\n' || (i + 2 < len(req) && req[i + 1] == '\r' && req[i + 2] == '\n')) {
				return true
			}
		}
		return false
	}
	return req[len(req) - 1] == '\n'
}

// One connection's state and buffers: large, so it lives on the heap.
Fixture :: struct {
	srv:         libtls.Server,
	fd:          int,
	rx:          [libtls.REC_CAP]u8,
	plain:       [libtls.MAX_CIPHERTEXT]u8,
	tx:          [libtls.REC_CAP]u8,
	msg:         [2048]u8,
	request:     [2048]u8,
	request_len: int,
}

fail :: proc "contextless" (what: string) -> ! {
	libuser.eprint("tlssrv: ", what, "\n")
	libuser.exits(what)
}

read_full :: proc(fd: int, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		n := libuser.read(fd, buf[got:])
		if n <= 0 {
			return false
		}
		got += int(n)
	}
	return true
}

write_all :: proc(fd: int, buf: []u8) -> bool {
	sent := 0
	for sent < len(buf) {
		n := libuser.write(fd, buf[sent:])
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

// recv_record reads one whole record off the connection: its wire type and the
// record with its header, which is the AEAD's associated data.
recv_record :: proc(f: ^Fixture) -> (wire: u8, full: []u8, ok: bool) {
	if !read_full(f.fd, f.rx[:libtls.RECORD_HEADER]) {
		return 0, nil, false
	}
	length := int(f.rx[3]) << 8 | int(f.rx[4])
	if length > libtls.MAX_CIPHERTEXT {
		return 0, nil, false
	}
	if !read_full(f.fd, f.rx[libtls.RECORD_HEADER:][:length]) {
		return 0, nil, false
	}
	return f.rx[0], f.rx[:libtls.RECORD_HEADER + length], true
}

// send_sealed frames one handshake message or application payload as a
// record sealed under the server's current write key, and sends it.
send_sealed :: proc(f: ^Fixture, inner: u8, payload: []u8, what: string) {
	n := libtls.seal_record(&f.srv.conn.write, inner, payload, f.tx[:])
	if n < 0 || !write_all(f.fd, f.tx[:n]) {
		fail(what)
	}
}

// send_message runs one flight step, which writes a handshake message into
// `f.msg`, and sends it sealed.
send_message :: proc(f: ^Fixture, step: proc(s: ^libtls.Server, out: []u8) -> int, what: string) {
	n := step(&f.srv, f.msg[:])
	if n < 0 {
		fail(what)
	}
	send_sealed(f, libtls.CONTENT_HANDSHAKE, f.msg[:n], what)
}

// accept announces `port`, waits for one connection, and opens its stream.
// `listen` answers the number of the conversation it accepted, which sits
// beside the one that announced.
accept :: proc(port: string) -> (fd: int, accepted: string) {
	addr: [64]u8
	spec := libuser.cat_into(addr[:], "tcp!*!", port)
	dir := new([libnet.DIAL_MAX]u8)
	dirlen, ok := libnet.announce(spec, dir[:])
	if !ok {
		fail("announce")
	}
	served := string(dir[:dirlen])

	path := new([160]u8)
	lfd := libuser.open(libnet.join(path[:], served, "listen"), abi.O_RDONLY)
	if lfd < 0 {
		fail("listen")
	}
	libuser.eprint("tlssrv: listening at ", served, "\n")
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
	base := new([160]u8)
	accepted = libuser.cat_into(base[:], served[:cut + 1], string(line[:at]))
	dfd := libuser.open(libnet.join(path[:], accepted, "data"), abi.O_RDWR)
	if dfd < 0 {
		fail("open the stream")
	}
	return int(dfd), accepted
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	port := len(args) >= 2 && args[1] != "-u" ? args[1] : "4433"
	untrusted := len(args) >= 2 && args[len(args) - 1] == "-u"

	// The identity: the trust store's first certificate, the test one the
	// build stages ahead of the host's roots, and its key.
	store, cok := libuser.read_file(untrusted ? "/lib/tests/capsule.der" : "/lib/tls/roots", context.allocator)
	first := libtls.der_len(store)
	if !cok || first <= 0 {
		fail("read the certificate")
	}
	cert := store[:first]
	f := new(Fixture)
	priv := untrusted ? CAPSULE_PRIV : CERT_PRIV
	if !libtls.server_init(&f.srv, cert, priv[:]) {
		fail("set the key")
	}

	accepted: string
	f.fd, accepted = accept(port)

	// The ClientHello, one plaintext handshake record.
	wire, full, rok := recv_record(f)
	if !rok || wire != libtls.CONTENT_HANDSHAKE {
		fail("read the ClientHello")
	}
	epriv: [32]u8
	erand: [32]u8
	for i in 0 ..< 32 {
		epriv[i] = u8(0x80 + i)
		erand[i] = u8(0xaa)
	}
	shn := libtls.answer_client_hello(&f.srv, full[libtls.RECORD_HEADER:], epriv, erand, f.msg[:])
	if shn < 0 {
		fail("answer the ClientHello")
	}
	rn := libtls.write_plaintext_record(libtls.CONTENT_HANDSHAKE, f.msg[:shn], f.tx[:])
	if rn < 0 || !write_all(f.fd, f.tx[:rn]) {
		fail("send the ServerHello")
	}
	ccs := [1]u8{0x01}
	rn = libtls.write_plaintext_record(libtls.CONTENT_CHANGE_CIPHER_SPEC, ccs[:], f.tx[:])
	if rn < 0 || !write_all(f.fd, f.tx[:rn]) {
		fail("send change_cipher_spec")
	}

	// The sealed flight, one message per record.
	send_message(f, libtls.server_encrypted_extensions, "send EncryptedExtensions")
	send_message(f, libtls.server_certificate, "send the Certificate")
	send_message(f, libtls.server_certificate_verify, "sign the CertificateVerify")
	send_message(f, libtls.server_finished, "send the Finished")

	// The client's Finished, then its request: sealed records, routed by the
	// inner type once opened. A change_cipher_spec on the wire is dropped.
	for f.srv.state != .Connected || !request_whole(f.request[:f.request_len]) {
		wire, full, rok = recv_record(f)
		if !rok {
			fail("the stream ended early")
		}
		if wire == libtls.CONTENT_CHANGE_CIPHER_SPEC {
			continue
		}
		if wire != libtls.CONTENT_APPLICATION_DATA {
			fail("an unsealed record after the keys")
		}
		n, inner, ok := libtls.open_record(&f.srv.conn.read, full, f.plain[:])
		if !ok {
			fail("open a record from the client")
		}
		switch inner {
		case libtls.CONTENT_HANDSHAKE:
			if !libtls.server_client_finished(&f.srv, f.plain[:n]) {
				fail("the client's Finished")
			}
		case libtls.CONTENT_APPLICATION_DATA:
			if f.srv.state != .Connected || f.request_len + n > len(f.request) {
				fail("application data out of turn")
			}
			copy(f.request[f.request_len:], f.plain[:n])
			f.request_len += n
		case:
			fail("an alert from the client")
		}
	}

	// The answer, and a clean end. A line is echoed. An HTTP request gets a
	// small page and a Gemini request a small capsule, so `webfs` can fetch
	// over https and gemini from this same fixture.
	reply: [600]u8
	text: string
	if f.request_len >= 4 && string(f.request[:4]) == "GET " {
		text = HTTP_RESPONSE
	} else if f.request_len >= 9 && string(f.request[:9]) == "gemini://" {
		text = GEMINI_RESPONSE
	} else {
		text = libuser.cat_into(reply[:], "you said: ", string(f.request[:f.request_len]))
	}
	send_sealed(f, libtls.CONTENT_APPLICATION_DATA, transmute([]u8)text, "send the reply")
	alert := [2]u8{1, 0} // warning, close_notify
	send_sealed(f, libtls.CONTENT_ALERT, alert[:], "send close_notify")

	libnet.hangup(accepted)
	_ = libuser.close(f.fd)
	libuser.exits("ok")
}
