/*
The TLS 1.3 client over a byte stream, RFC 8446 section 5.1 -- the driver that
turns the engine into a connection.

`handshake.odin` and `flight.odin` are pure: they take one whole handshake
message and hand back keys or a verdict, and never touch a socket. Something has
to read records off the wire, strip and reassemble them, feed the messages in,
and seal what goes back. That is here. A `Client` wraps a `Conn` and an `IO` --
a pair of read/write callbacks over whatever carries the bytes, a `/net/tcp`
connection for `tlsclient`, an in-memory pipe for a test -- and offers the four
things a caller wants: `client_handshake`, `client_write`, `client_read`,
`client_close`.

The record demultiplexer is the subtle part. Before the keys, the ServerHello
arrives as a plaintext handshake record; after them, the whole flight arrives as
application_data records that decrypt to handshake messages. A change_cipher_spec
record may appear anywhere and means nothing (RFC 8446 appendix D.4's middlebox
compatibility). A handshake message may be split across records or several packed
into one, so records are reassembled into a fragment buffer and whole messages
drawn from it. The wire content type says which path a record takes; the inner
type, after decryption, says what a sealed record really held.

This holds no lock and does no allocation of its own on the data path; the
certificate parse under `client_handshake` allocates from `context.allocator`,
as `certificate` documents. A `Client` is large (record and reassembly buffers),
so a caller heap-allocates it rather than standing one on the stack.
*/
package libtls

import "core:crypto/x509"
import "core:time"

// A change_cipher_spec record, RFC 8446 appendix D.4: sent for middlebox
// compatibility, carries a single 0x01, and is dropped on receipt.
CONTENT_CHANGE_CIPHER_SPEC :: u8(20)

// The largest TLSCiphertext.length RFC 8446 section 5.2 allows: a 2^14 fragment,
// its type byte and up to 255 padding, and the AEAD tag.
MAX_CIPHERTEXT :: (1 << 14) + 256
REC_CAP :: RECORD_HEADER + MAX_CIPHERTEXT

// The reassembly buffer bounds one handshake message. A server's Certificate is
// the large one; 64 KiB holds a normal chain with room to spare, and a message
// past it is refused rather than grown.
HS_REASSEMBLY :: 1 << 16

/*
IO is the byte stream under the records. `read` fills `buf` and returns the
count, 0 at end of stream, or negative on error; `write` sends `buf` and returns
the count written or negative. `ctx` is the caller's -- a file descriptor boxed
in a pointer, a pipe -- passed back to each call.
*/
IO :: struct {
	ctx:   rawptr,
	read:  proc(ctx: rawptr, buf: []u8) -> int,
	write: proc(ctx: rawptr, buf: []u8) -> int,
}

Client :: struct {
	conn:   Conn,
	io:     IO,

	// What `certificate` needs to verify the chain: the trust roots, the time to
	// judge validity at, and the host to match (empty to skip the name check).
	roots:       []^x509.Certificate,
	now:         time.Time,
	server_name: string,

	// The record just read (header included, so `open_record` can bind it) and
	// the plaintext a sealed one decrypts to.
	rx:    [REC_CAP]u8,
	plain: [MAX_CIPHERTEXT]u8,

	// The record about to be written, and a scratch for a handshake message
	// (ClientHello, the client's Finished) before it is framed.
	tx:      [REC_CAP]u8,
	hs_out:  [2048]u8,

	// Reassembly: handshake bytes drawn from records, not yet whole messages.
	hs_buf: [HS_REASSEMBLY]u8,
	hs_len: int,

	// Decrypted application data read ahead of the caller, and a flag for a
	// close_notify seen from the peer.
	app:     [MAX_CIPHERTEXT]u8,
	app_len: int,
	closed:  bool,
}

/*
client_init wires a freshly zeroed `Client` to its stream and its trust inputs.
`roots` are the parsed trust anchors, `now` is the time to judge certificate
validity at, and `server_name` is the host for SNI and the certificate's name
check (empty omits both). The caller has zeroed `cl` (heap-allocated) before this.
*/
client_init :: proc(cl: ^Client, io: IO, roots: []^x509.Certificate, now: time.Time, server_name: string) {
	cl.io = io
	cl.roots = roots
	cl.now = now
	cl.server_name = server_name
}

/*
client_tofu asks for trust on first use: a leaf that chains to no root is
accepted, and the caller checks `client_peer`'s fingerprint against the one it
kept for the host. Set before the handshake. Gemini's convention, and nothing
else's: an https fetch never asks for it.
*/
client_tofu :: proc(cl: ^Client) {
	cl.conn.tofu = true
}

// client_peer answers the server leaf's sha256, and whether it chained to a
// root. Good once the handshake is done.
client_peer :: proc(cl: ^Client) -> (fingerprint: [32]u8, chained: bool) {
	return cl.conn.leaf_sha256, cl.conn.chained
}

// -- The stream helpers ------------------------------------------------------

// io_read_full fills `buf` completely, or returns false at end of stream or on
// error -- a record is read whole or not at all.
io_read_full :: proc(cl: ^Client, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		n := cl.io.read(cl.io.ctx, buf[got:])
		if n <= 0 {
			return false
		}
		got += n
	}
	return true
}

io_write_all :: proc(cl: ^Client, buf: []u8) -> bool {
	sent := 0
	for sent < len(buf) {
		n := cl.io.write(cl.io.ctx, buf[sent:])
		if n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

// recv_record reads one whole record into `cl.rx` and returns its wire content
// type and the full record (header included). `ok` is false at end of stream or
// on a length past the maximum a record may carry.
recv_record :: proc(cl: ^Client) -> (wire_type: u8, full: []u8, ok: bool) {
	if !io_read_full(cl, cl.rx[:RECORD_HEADER]) {
		return 0, nil, false
	}
	length := int(cl.rx[3]) << 8 | int(cl.rx[4])
	if length < 0 || length > MAX_CIPHERTEXT {
		return 0, nil, false
	}
	if !io_read_full(cl, cl.rx[RECORD_HEADER:][:length]) {
		return 0, nil, false
	}
	return cl.rx[0], cl.rx[:RECORD_HEADER + length], true
}

// write_plaintext_record frames `payload` as one unencrypted record of type
// `wire_type` in `dst` and returns its length. Used only for the ClientHello,
// the one message a client sends before it has keys.
write_plaintext_record :: proc(wire_type: u8, payload: []u8, dst: []u8) -> int #no_bounds_check {
	if len(dst) < RECORD_HEADER + len(payload) {
		return -1
	}
	dst[0] = wire_type
	dst[1] = 0x03
	dst[2] = 0x03
	dst[3] = u8(len(payload) >> 8)
	dst[4] = u8(len(payload))
	copy(dst[RECORD_HEADER:], payload)
	return RECORD_HEADER + len(payload)
}

// -- The record demultiplexer ------------------------------------------------

// process_record routes one whole record: a change_cipher_spec is dropped, a
// plaintext handshake record (the ServerHello) feeds the reassembler, and an
// application_data record is opened and routed by its inner type. Returns false
// on any framing, decryption or protocol failure.
process_record :: proc(cl: ^Client, wire_type: u8, full: []u8) -> bool {
	switch wire_type {
	case CONTENT_CHANGE_CIPHER_SPEC:
		return true
	case CONTENT_HANDSHAKE:
		return feed_handshake(cl, full[RECORD_HEADER:])
	case CONTENT_APPLICATION_DATA:
		n, inner, ok := open_record(&cl.conn.read, full, cl.plain[:])
		if !ok {
			return false
		}
		switch inner {
		case CONTENT_HANDSHAKE:
			return feed_handshake(cl, cl.plain[:n])
		case CONTENT_APPLICATION_DATA:
			return app_append(cl, cl.plain[:n])
		case CONTENT_ALERT:
			return handle_alert(cl, cl.plain[:n])
		case:
			return false
		}
	case CONTENT_ALERT:
		return handle_alert(cl, full[RECORD_HEADER:])
	case:
		return false
	}
}

// app_append buffers decrypted application data for the caller's next read.
app_append :: proc(cl: ^Client, data: []u8) -> bool #no_bounds_check {
	if cl.app_len + len(data) > len(cl.app) {
		return false
	}
	copy(cl.app[cl.app_len:], data)
	cl.app_len += len(data)
	return true
}

// handle_alert reads a two-byte alert. A close_notify (description 0) ends the
// stream cleanly; any other alert is a failure.
handle_alert :: proc(cl: ^Client, data: []u8) -> bool {
	if len(data) >= 2 && data[1] == 0 {
		cl.closed = true
		return true
	}
	return false
}

// feed_handshake appends a handshake fragment to the reassembly buffer and
// dispatches every whole message it completes. A message longer than the buffer,
// or one the state machine rejects, fails.
feed_handshake :: proc(cl: ^Client, fragment: []u8) -> bool #no_bounds_check {
	if cl.hs_len + len(fragment) > len(cl.hs_buf) {
		return false
	}
	copy(cl.hs_buf[cl.hs_len:], fragment)
	cl.hs_len += len(fragment)

	pos := 0
	for cl.hs_len - pos >= 4 {
		mlen := int(cl.hs_buf[pos + 1]) << 16 | int(cl.hs_buf[pos + 2]) << 8 | int(cl.hs_buf[pos + 3])
		if cl.hs_len - pos < 4 + mlen {
			break
		}
		mtype := cl.hs_buf[pos]
		if !dispatch_handshake(cl, mtype, cl.hs_buf[pos:pos + 4 + mlen]) {
			return false
		}
		pos += 4 + mlen
	}
	// Keep the incomplete tail for the next fragment.
	copy(cl.hs_buf[:], cl.hs_buf[pos:cl.hs_len])
	cl.hs_len -= pos
	return true
}

// dispatch_handshake feeds one whole handshake message to the engine by where
// the connection is. The ServerHello opens the keys; the flight is dispatched by
// message type; once connected, a NewSessionTicket and other post-handshake
// messages are accepted and ignored (no resumption, no key update yet).
dispatch_handshake :: proc(cl: ^Client, mtype: u8, msg: []u8) -> bool {
	switch cl.conn.state {
	case .Wait_Server_Hello:
		if mtype != HS_SERVER_HELLO {
			return false
		}
		return server_hello(&cl.conn, msg)
	case .Wait_Flight:
		switch mtype {
		case HS_ENCRYPTED_EXTENSIONS:
			return encrypted_extensions(&cl.conn, msg)
		case HS_CERTIFICATE:
			return certificate(&cl.conn, msg, cl.roots, cl.now, cl.server_name)
		case HS_CERTIFICATE_VERIFY:
			return certificate_verify(&cl.conn, msg)
		case HS_FINISHED:
			if !finished(&cl.conn, msg) {
				return false
			}
			return send_client_finished(cl)
		case:
			return false
		}
	case .Connected:
		// NewSessionTicket and friends: accepted, nothing kept.
		return true
	case .Start, .Send_Finished, .Failed:
		return false
	}
	return false
}

// send_client_finished writes the client's Finished, seals it under the still-
// current handshake key, sends it, and switches both directions to the
// application keys.
send_client_finished :: proc(cl: ^Client) -> bool {
	cfn := client_finished(&cl.conn, cl.hs_out[:])
	if cfn < 0 {
		return false
	}
	rn := seal_record(&cl.conn.write, CONTENT_HANDSHAKE, cl.hs_out[:cfn], cl.tx[:])
	if rn < 0 || !io_write_all(cl, cl.tx[:rn]) {
		return false
	}
	enter_application(&cl.conn)
	return cl.conn.state == .Connected
}

// -- The four the caller uses ------------------------------------------------

/*
client_handshake runs the whole handshake: it sends the ClientHello, then reads
records and feeds their messages until the connection is connected or fails. The
client draws its ephemeral key and the ClientHello random from `priv` and
`random` -- a caller fills both from `/dev/random`. Returns false on any failure
along the way, with the connection left `.Failed`.
*/
client_handshake :: proc(cl: ^Client, priv: [32]u8, random: [32]u8) -> bool {
	chn := client_hello(&cl.conn, priv, random, cl.server_name, cl.hs_out[:])
	if chn < 0 {
		return false
	}
	rn := write_plaintext_record(CONTENT_HANDSHAKE, cl.hs_out[:chn], cl.tx[:])
	if rn < 0 || !io_write_all(cl, cl.tx[:rn]) {
		return false
	}

	for cl.conn.state != .Connected {
		wire, full, ok := recv_record(cl)
		if !ok {
			cl.conn.state = .Failed
			return false
		}
		if !process_record(cl, wire, full) {
			cl.conn.state = .Failed
			return false
		}
	}
	return true
}

/*
client_write sends `data` as one or more application_data records, each at most a
full fragment, sealed under the client's application key. Returns false if the
connection is not connected or the stream fails.
*/
client_write :: proc(cl: ^Client, data: []u8) -> bool {
	if cl.conn.state != .Connected {
		return false
	}
	off := 0
	for off < len(data) {
		chunk := len(data) - off
		if chunk > MAX_FRAGMENT {
			chunk = MAX_FRAGMENT
		}
		rn := seal_record(&cl.conn.write, CONTENT_APPLICATION_DATA, data[off:off + chunk], cl.tx[:])
		if rn < 0 || !io_write_all(cl, cl.tx[:rn]) {
			return false
		}
		off += chunk
	}
	return true
}

/*
client_read returns the next application data into `buf`: it drains what was read
ahead, and otherwise reads records until application data arrives. It returns the
byte count, 0 at a clean close (the peer's close_notify or end of stream), or -1
on a protocol or decryption error.
*/
client_read :: proc(cl: ^Client, buf: []u8) -> int #no_bounds_check {
	for cl.app_len == 0 {
		if cl.closed {
			return 0
		}
		wire, full, ok := recv_record(cl)
		if !ok {
			return cl.closed ? 0 : -1
		}
		if !process_record(cl, wire, full) {
			return -1
		}
	}
	n := copy(buf, cl.app[:cl.app_len])
	copy(cl.app[:], cl.app[n:cl.app_len])
	cl.app_len -= n
	return n
}

/*
client_close sends a close_notify alert, sealed under the client's application
key, so the peer sees a clean end. It does not close the underlying stream; the
caller owns that.
*/
client_close :: proc(cl: ^Client) -> bool {
	if cl.conn.state != .Connected {
		return false
	}
	alert := [2]u8{1, 0} // warning, close_notify
	rn := seal_record(&cl.conn.write, CONTENT_ALERT, alert[:], cl.tx[:])
	if rn < 0 {
		return false
	}
	return io_write_all(cl, cl.tx[:rn])
}
