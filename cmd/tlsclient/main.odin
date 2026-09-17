/*
tlsclient -- a TLS 1.3 connection to a host, as a command.

It dials `tcp!host!port` through `/net`, runs the `sys/libtls` client handshake
over that connection against the trust roots in `/lib/tls/roots`, and then relays
bytes: everything on standard input is sent encrypted, and everything the server
sends comes back in the clear on standard output. So

    echo -n 'GET / HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n' \
        | tlsclient example 443

is one HTTPS request and its response, the way `openssl s_client` is used, and
`servers/webfs` will drive the same `sys/libtls.Client` without the command in
between. `docs/WEB.md` section 3 builds this once, here, as the wire the web
stands on.

The relay is request-then-response: standard input is read to its end and sent,
then the response is read to the server's close. That is every HTTP/1.1 fetch and
every Gemini request; a duplex, interactive session wants a thread per direction
and is left for when a caller needs it.
*/
package tlsclient

import "core:crypto/x509"
import "core:time"
import "vsys:abi"
import "vsys:libnet"
import "vsys:libtls"
import "vsys:libuser"

// Sock boxes the connection's data-file descriptor for the IO callbacks.
Sock :: struct {
	fd: int,
}

sock_read :: proc(ctx: rawptr, buf: []u8) -> int {
	s := (^Sock)(ctx)
	return int(libuser.read(s.fd, buf))
}

sock_write :: proc(ctx: rawptr, buf: []u8) -> int {
	s := (^Sock)(ctx)
	return int(libuser.write(s.fd, buf))
}

fail :: proc "contextless" (what: string) -> ! {
	_ = libuser.write(2, transmute([]u8)string("tlsclient: "))
	_ = libuser.write(2, transmute([]u8)what)
	_ = libuser.write(2, transmute([]u8)string("\n"))
	libuser.exits(what)
}

// load_roots reads the trust store, a file of X.509 certificates in DER, one
// after another, and returns them parsed. Concatenated DER, not PEM: each
// certificate is a self-delimiting ASN.1 element, so its own length walks to the
// next. An empty or unreadable store is fatal -- a client with no roots trusts
// nothing and must not pretend otherwise.
load_roots :: proc(path: string) -> []^x509.Certificate {
	data, ok := libuser.read_file(path, context.allocator)
	if !ok {
		fail("cannot read the trust store /lib/tls/roots")
	}
	roots: [dynamic]^x509.Certificate
	off := 0
	for off < len(data) {
		cert, err := x509.parse(data[off:], context.allocator)
		if err != .None || len(cert.raw) == 0 {
			break
		}
		c := new(x509.Certificate)
		c^ = cert
		append(&roots, c)
		off += len(cert.raw)
	}
	if len(roots) == 0 {
		fail("the trust store holds no certificates")
	}
	return roots[:]
}

// now_time reads the wall clock from /dev/time for certificate validity. A clock
// that reads zero was never set, and validating a certificate against 1970 would
// accept an expired one, so this fails closed rather than guess.
now_time :: proc() -> time.Time {
	fd := libuser.open("/dev/time", abi.O_RDONLY)
	if fd < 0 {
		fail("cannot open /dev/time")
	}
	line: [96]u8
	n := libuser.read(int(fd), line[:])
	_ = libuser.close(int(fd))
	sec: i64
	for i in 0 ..< int(n) {
		c := line[i]
		if c < '0' || c > '9' {
			break
		}
		sec = sec * 10 + i64(c - '0')
	}
	if sec == 0 {
		fail("the clock is unset; cannot judge certificate validity")
	}
	return time.unix(sec, 0)
}

// fill_random draws `len(buf)` bytes from /dev/random, the ephemeral key and the
// ClientHello random the handshake needs to be fresh.
fill_random :: proc(buf: []u8) -> bool {
	fd := libuser.open("/dev/random", abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	n := libuser.read(int(fd), buf)
	_ = libuser.close(int(fd))
	return int(n) == len(buf)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	if len(args) < 2 {
		fail("usage: tlsclient host [port]")
	}
	host := args[1]
	port := len(args) >= 3 ? args[2] : "443"

	roots := load_roots("/lib/tls/roots")
	now := now_time()

	spec_buf: [256]u8
	spec := libuser.cat_into(spec_buf[:], "tcp!", host, "!", port)
	dir: [libnet.DIAL_MAX]u8
	fd, dirlen, dok := libnet.dial_dir(spec, dir[:])
	if !dok {
		fail("cannot dial the host")
	}

	sock := new(Sock)
	sock.fd = int(fd)
	cl := new(libtls.Client)
	io := libtls.IO {
		ctx   = sock,
		read  = sock_read,
		write = sock_write,
	}
	libtls.client_init(cl, io, roots, now, host)

	priv: [32]u8
	random: [32]u8
	if !fill_random(priv[:]) || !fill_random(random[:]) {
		fail("no entropy from /dev/random")
	}

	if !libtls.client_handshake(cl, priv, random) {
		fail("the TLS handshake failed")
	}

	// Send standard input, then read the response to standard output.
	buf: [4096]u8
	for {
		n := libuser.read(0, buf[:])
		if n <= 0 {
			break
		}
		if !libtls.client_write(cl, buf[:n]) {
			fail("could not send")
		}
	}
	for {
		n := libtls.client_read(cl, buf[:])
		if n < 0 {
			fail("could not read the response")
		}
		if n == 0 {
			break
		}
		_ = libuser.write(1, buf[:n])
	}

	_ = libtls.client_close(cl)
	libnet.hangup(string(dir[:dirlen]))
	_ = libuser.close(int(fd))
	libuser.exits("")
}
