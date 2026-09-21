/*
gemd -- a directory served as Gemini: `docs/WEB.md` section 9's other
half of "a page served both ways". It serves the same tree `httpd`
does, over one TLS 1.3 connection a request, so a `.md` written once is
read on the web and here. A `.md` is served as it is, since Gemini's
gemtext is close enough that a person reads it raw; other files go by
their type. A request is one line, `gemini://host/path`, and the
answer is a status, a media type, and the body.

    gemd -r ROOT [port] [count]

It announces `tcp!*!port`, default 1965, and serves `count`
connections, or forever when `count` is zero. The identity is the
certificate in `/lib/tls/roots`, the one the fleet's test root names
this machine with, so a client that dials by this machine's name
verifies it. `docs/FLEET.md` section 4 keeps the real key in `factotum`;
this uses the test key, as `tlssrv` does, until a Gemini identity is a
`factotum` proto.
*/
package gemd

import "vsys:abi"
import "vsys:libnet"
import "vsys:libtls"
import "vsys:libuser"

// The test identity's private scalar, the same `tlssrv` signs with, so a
// client that trusts `/lib/tls/roots` trusts this server.
CERT_PRIV :: [32]u8{
	0x92, 0xf2, 0x9e, 0x14, 0x1a, 0x76, 0xb7, 0xa3, 0x24, 0x15, 0x22, 0x91, 0x8e, 0x97, 0x45, 0x9f,
	0xce, 0xcf, 0xb3, 0xa8, 0x8d, 0x01, 0xb7, 0x43, 0xda, 0x72, 0x23, 0x9b, 0xa3, 0x6b, 0xaa, 0x3c,
}

root: string
root_buf: [256]u8
cert: []u8
priv: [32]u8

Conn :: struct {
	srv:         libtls.Server,
	fd:          int,
	rx:          [libtls.REC_CAP]u8,
	plain:       [libtls.MAX_CIPHERTEXT]u8,
	tx:          [libtls.REC_CAP]u8,
	msg:         [2048]u8,
	request:     [2048]u8,
	request_len: int,
}

fail :: proc "contextless" (what: string) {
	libuser.eprint("gemd: ", what, "\n")
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	port := "1965"
	count := 1
	seen_port := false
	seen_count := false
	for i := 1; i < len(args); i += 1 {
		if args[i] == "-r" && i + 1 < len(args) {
			root = string(root_buf[:copy(root_buf[:], args[i + 1])])
			i += 1
		} else if !seen_port {
			port = args[i]
			seen_port = true
		} else if !seen_count {
			if v, ok := libuser.atoi(args[i]); ok {
				count = int(v)
				seen_count = true
			}
		}
	}
	if root == "" {
		root = "/usr/glenda/www"
	}
	store, cok := libuser.read_file("/lib/tls/roots", context.allocator)
	first := libtls.der_len(store)
	if !cok || first <= 0 {
		fail("read the certificate")
		libuser.exits("no cert")
	}
	cert = store[:first]
	priv = CERT_PRIV

	addr: [64]u8
	spec := libuser.cat_into(addr[:], "tcp!*!", port)
	dir: [libnet.DIAL_MAX]u8
	dirlen, ok := libnet.announce(spec, dir[:])
	if !ok {
		fail("announce")
		libuser.exits("announce")
	}
	served := string(dir[:dirlen])
	path: [160]u8
	lfd := libuser.open(libnet.join(path[:], served, "listen"), abi.O_RDONLY)
	if lfd < 0 {
		fail("listen")
		libuser.exits("listen")
	}
	libuser.eprint("gemd: serving ", root, " at ", served, "\n")
	for i := 0; count == 0 || i < count; i += 1 {
		accept_one(int(lfd), served)
	}
	_ = libuser.close(int(lfd))
	libuser.exits("")
}

// accept_one takes the next connection off `listen`, runs the handshake,
// answers the request, and hangs up.
accept_one :: proc(lfd: int, served: string) {
	line: [64]u8
	n := libuser.read(lfd, line[:])
	if n <= 0 {
		return
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
	path: [200]u8
	dfd := libuser.open(libnet.join(path[:], accepted, "data"), abi.O_RDWR)
	if dfd < 0 {
		return
	}
	c := new(Conn)
	c.fd = int(dfd)
	if handshake(c) && read_request(c) {
		answer(c)
	}
	free(c)
	_ = libuser.close(int(dfd))
	libnet.hangup(accepted)
}

// handshake runs the server side of TLS 1.3 to Connected, false on any
// failure, so one bad connection does not end the server.
handshake :: proc(c: ^Conn) -> bool {
	if !libtls.server_init(&c.srv, cert, priv[:]) {
		return false
	}
	wire, full, rok := recv_record(c)
	if !rok || wire != libtls.CONTENT_HANDSHAKE {
		return false
	}
	epriv: [32]u8
	erand: [32]u8
	if !libuser.read_random(epriv[:]) || !libuser.read_random(erand[:]) {
		return false
	}
	shn := libtls.answer_client_hello(&c.srv, full[libtls.RECORD_HEADER:], epriv, erand, c.msg[:])
	if shn < 0 {
		return false
	}
	rn := libtls.write_plaintext_record(libtls.CONTENT_HANDSHAKE, c.msg[:shn], c.tx[:])
	if rn < 0 || !write_all(c.fd, c.tx[:rn]) {
		return false
	}
	ccs := [1]u8{0x01}
	rn = libtls.write_plaintext_record(libtls.CONTENT_CHANGE_CIPHER_SPEC, ccs[:], c.tx[:])
	if rn < 0 || !write_all(c.fd, c.tx[:rn]) {
		return false
	}
	if !send_message(c, libtls.server_encrypted_extensions) ||
	   !send_message(c, libtls.server_certificate) ||
	   !send_message(c, libtls.server_certificate_verify) ||
	   !send_message(c, libtls.server_finished) {
		return false
	}
	return true
}

// read_request reads the client's Finished and its one request line.
read_request :: proc(c: ^Conn) -> bool {
	for c.srv.state != .Connected || !line_done(c.request[:c.request_len]) {
		wire, full, rok := recv_record(c)
		if !rok {
			return false
		}
		if wire == libtls.CONTENT_CHANGE_CIPHER_SPEC {
			continue
		}
		if wire != libtls.CONTENT_APPLICATION_DATA {
			return false
		}
		n, inner, ok := libtls.open_record(&c.srv.conn.read, full, c.plain[:])
		if !ok {
			return false
		}
		switch inner {
		case libtls.CONTENT_HANDSHAKE:
			if !libtls.server_client_finished(&c.srv, c.plain[:n]) {
				return false
			}
		case libtls.CONTENT_APPLICATION_DATA:
			if c.srv.state != .Connected || c.request_len + n > len(c.request) {
				return false
			}
			copy(c.request[c.request_len:], c.plain[:n])
			c.request_len += n
		case:
			return false
		}
	}
	return true
}

// answer serves the request's path out of the root, sealed, then ends.
answer :: proc(c: ^Conn) {
	req := string(c.request[:c.request_len])
	for len(req) > 0 && (req[len(req) - 1] == '\n' || req[len(req) - 1] == '\r') {
		req = req[:len(req) - 1]
	}
	// The path after the host: gemini://host/path.
	p := "/"
	if i := index_of(req, "://"); i >= 0 {
		rest := req[i + 3:]
		slash := index_of(rest, "/")
		if slash >= 0 {
			p = rest[slash:]
		}
	}
	body, ctype, ok := read_page(p)
	if !ok {
		_ = send_sealed(c, libtls.CONTENT_APPLICATION_DATA, transmute([]u8)string("51 not found\r\n"))
		close_down(c)
		return
	}
	defer delete(body)
	head: [128]u8
	_ = send_sealed(c, libtls.CONTENT_APPLICATION_DATA, transmute([]u8)libuser.cat_into(head[:], "20 ", ctype, "\r\n"))
	// The body, in pieces the record layer can seal.
	at := 0
	for at < len(body) {
		end := min(at + 8192, len(body))
		_ = send_sealed(c, libtls.CONTENT_APPLICATION_DATA, body[at:end])
		at = end
	}
	close_down(c)
}

close_down :: proc(c: ^Conn) {
	alert := [2]u8{1, 0}
	_ = send_sealed(c, libtls.CONTENT_ALERT, alert[:])
}

// read_page reads the file at `p` out of the root, its body owned by the
// caller and its Gemini media type. A `/` asks for index.gmi or index.md.
read_page :: proc(p: string) -> ([]u8, string, bool) {
	if p == "" || p[0] != '/' || has_dotdot(p) {
		return nil, "", false
	}
	rel := p[1:]
	full: [512]u8
	if len(rel) == 0 || rel[len(rel) - 1] == '/' {
		if data, ok := libuser.read_file(libuser.cat_into(full[:], root, "/", rel, "index.gmi"), context.allocator); ok {
			return data, "text/gemini", true
		}
		if data, ok := libuser.read_file(libuser.cat_into(full[:], root, "/", rel, "index.md"), context.allocator); ok {
			return data, "text/gemini", true
		}
		return nil, "", false
	}
	data, ok := libuser.read_file(libuser.cat_into(full[:], root, "/", rel), context.allocator)
	if !ok {
		return nil, "", false
	}
	return data, media_type(rel), true
}

// media_type answers a file's Gemini media type. A `.md` and a `.gmi` are
// gemtext, served as they are.
media_type :: proc "contextless" (name: string) -> string {
	if has_suffix(name, ".md") || has_suffix(name, ".gmi") {
		return "text/gemini"
	}
	if has_suffix(name, ".txt") {
		return "text/plain"
	}
	if has_suffix(name, ".png") {
		return "image/png"
	}
	if has_suffix(name, ".jpg") || has_suffix(name, ".jpeg") {
		return "image/jpeg"
	}
	return "application/octet-stream"
}

// -- The TLS record plumbing, as tlssrv frames it ---------------------------------

recv_record :: proc(c: ^Conn) -> (wire: u8, full: []u8, ok: bool) {
	if !read_full(c.fd, c.rx[:libtls.RECORD_HEADER]) {
		return 0, nil, false
	}
	length := int(c.rx[3]) << 8 | int(c.rx[4])
	if length > libtls.MAX_CIPHERTEXT {
		return 0, nil, false
	}
	if !read_full(c.fd, c.rx[libtls.RECORD_HEADER:][:length]) {
		return 0, nil, false
	}
	return c.rx[0], c.rx[:libtls.RECORD_HEADER + length], true
}

send_sealed :: proc(c: ^Conn, inner: u8, payload: []u8) -> bool {
	n := libtls.seal_record(&c.srv.conn.write, inner, payload, c.tx[:])
	return n >= 0 && write_all(c.fd, c.tx[:n])
}

send_message :: proc(c: ^Conn, step: proc(s: ^libtls.Server, out: []u8) -> int) -> bool {
	n := step(&c.srv, c.msg[:])
	if n < 0 {
		return false
	}
	return send_sealed(c, libtls.CONTENT_HANDSHAKE, c.msg[:n])
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

// -- Small things -----------------------------------------------------------------

line_done :: proc "contextless" (req: []u8) -> bool {
	return len(req) > 0 && req[len(req) - 1] == '\n'
}

has_suffix :: proc "contextless" (s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

has_dotdot :: proc "contextless" (p: string) -> bool {
	for i in 0 ..< len(p) {
		if p[i] == '.' && i + 1 < len(p) && p[i + 1] == '.' {
			return true
		}
	}
	return false
}

index_of :: proc "contextless" (haystack: string, needle: string) -> int {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return -1
	}
	for i := 0; i + len(needle) <= len(haystack); i += 1 {
		if haystack[i:i + len(needle)] == needle {
			return i
		}
	}
	return -1
}
