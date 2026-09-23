/*
What a connection does besides one request and its response, `docs/WEB.md`
step 0's last three: it is kept for the next request, it becomes a
WebSocket, and a Gemini capsule's certificate is trusted on first use.

## The pool

A response framed by its length or chunked, from an HTTP/1.1 server that
did not say `Connection: close`, ends with the connection still good. The
fetch then leaves it here instead of hanging it up, keyed by scheme, host
and port, with the io proc and the TLS client that were reading it. The
next fetch to the same place takes it. A server may close a connection
that idles, and the taker learns so only when its request answers
nothing, so `fetch` dials once more then, and says nothing of it.

The pool is small and short. Every idle connection holds a conversation
in `netfs`, whose table is shared by every program on the machine, so
four are kept and none for longer than half a minute.

## The WebSocket

RFC 6455, over the conversation's own connection. `ctl upgrade` asks for
it, and the fetch sends the GET with `Upgrade`, `Connection` and a fresh
`Sec-WebSocket-Key`. The server answers `101` with the key's accept,
sha1 over the key and the RFC's GUID, and a mismatch fails the fetch.

Then `ws` is the socket. A read answers one frame, a piece at a time if
the read is shorter, and parks while none is waiting. A write sends one
text frame, masked as a client's must be. A ping is answered with its
pong, a message in fragments is joined before a read sees it, and a
close is answered with a close. `hangup` sends the close, and the reader
ends the conversation when the server's comes back.

Two threads write: whoever wrote to `ws`, and the reader with a pong. So
every write takes `Conv.wlock`, and goes through `Fetch.wio`, an io proc
of its own, because the reader's io proc is parked in a read for as long
as the socket lives. A write made before the handshake is done sleeps on
`Conv.up` under the same lock until it is.

## Trust on first use

A capsule's certificate is usually its own root. `libtls` is told to let
a leaf through that chains to nothing, still checking that the server
holds its key, and answers the leaf's sha256. `<store>/known` holds one
line per host and port: `host!port sha256`. The first connection writes
the line. Every later one must match it, and a capsule whose certificate
changed is refused until a person edits the line, which is the only
answer a first-use scheme has to a changed key.
*/
package webfs

import "core:crypto/hash"
import "vsys:lib9p"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libtls"
import "vsys:libuser"
import "vsys:vectra9"

// -- The pool -------------------------------------------------------------------

MAX_IDLE :: 4
IDLE_SECONDS :: 30

idle: [MAX_IDLE]^Fetch

// pool_take answers an idle connection to `key`, or nil. Stale ones it meets
// on the way are hung up.
pool_take :: proc(key: string) -> ^Fetch {
	now := now_seconds()
	for i in 0 ..< MAX_IDLE {
		p := idle[i]
		if p == nil {
			continue
		}
		if now - p.since > IDLE_SECONDS {
			idle[i] = nil
			conn_drop(p)
			continue
		}
		if string(p.key[:p.keylen]) == key {
			idle[i] = nil
			return p
		}
	}
	return nil
}

// pool_put keeps a finished fetch's connection for the next request there,
// pushing out the longest idle when the pool is full.
pool_put :: proc(f: ^Fetch) {
	f.c = nil
	f.keep = false
	f.reused = false
	f.since = now_seconds()
	oldest := 0
	for i in 0 ..< MAX_IDLE {
		if idle[i] == nil {
			idle[i] = f
			return
		}
		if idle[i].since < idle[oldest].since {
			oldest = i
		}
	}
	conn_drop(idle[oldest])
	idle[oldest] = f
}

// adopt moves a pooled connection into this fetch: the descriptor, the dial's
// directory, the io proc that reads it and the TLS client over it, whose
// reads and writes now name this fetch.
adopt :: proc(f: ^Fetch, p: ^Fetch) {
	if f.io != nil {
		libthread.ioclose(f.io)
	}
	f.io = p.io
	f.fd = p.fd
	f.dir = p.dir
	f.dirlen = p.dirlen
	f.tls = p.tls
	if f.tls != nil {
		f.tls.io.ctx = f
	}
	f.reused = true
	free(p)
}

// conn_close hangs a fetch's connection up and keeps its io proc, for a fetch
// that dials again.
conn_close :: proc(f: ^Fetch) {
	if f.tls != nil {
		free(f.tls)
		f.tls = nil
	}
	if f.fd >= 0 {
		libnet.hangup(string(f.dir[:f.dirlen]))
		_ = libuser.close(f.fd)
		f.fd = -1
	}
}

// conn_drop is the end of a fetch that is not kept: the connection, both io
// procs and the record.
conn_drop :: proc(f: ^Fetch) {
	conn_close(f)
	if f.wio != nil {
		libthread.ioclose(f.wio)
	}
	if f.io != nil {
		libthread.ioclose(f.io)
	}
	free(f)
}

// reusable says a response leaves its connection good for another request:
// HTTP/1.1, and no `Connection: close`.
reusable :: proc "contextless" (head: string) -> bool {
	if len(head) < 8 || head[:8] != "HTTP/1.1" {
		return false
	}
	if v, has := header_value(head, "connection"); has && libodin.contains(v, "close") {
		return false
	}
	return true
}

// -- Trust on first use -----------------------------------------------------------

/*
tofu_check holds a capsule's certificate to the one first seen for its host
and port. A leaf that chained to a root needs no line. One that did not is
written down the first time and must match every time after.
*/
tofu_check :: proc(f: ^Fetch, u: Url) -> bool {
	fp, chained := libtls.client_peer(f.tls)
	if chained {
		return true
	}
	hex: [64]u8
	hex_of(fp[:], hex[:])
	kb: [300]u8
	key := libuser.cat_into(kb[:], u.host, "!", u.port)
	pb: [300]u8
	path := libuser.cat_into(pb[:], store, "/known")
	if data, ok := libuser.read_file(path, context.allocator); ok {
		defer delete(data)
		text := string(data)
		at := 0
		for at < len(text) {
			e := at
			for e < len(text) && text[e] != '\n' {
				e += 1
			}
			line := text[at:e]
			at = e + 1
			name, rest := word(line)
			if name == key {
				seen, _ := word(rest)
				return seen == string(hex[:])
			}
		}
	}
	// The first sight: this line is what every later connection is held to.
	lb: [400]u8
	line := libuser.cat_into(lb[:], key, " ", string(hex[:]), "\n")
	fd := libuser.open_append(path, 0o644)
	if fd >= 0 {
		_ = libuser.write_full(int(fd), transmute([]u8)line)
		_ = libuser.close(int(fd))
	}
	return true
}

// -- The WebSocket ------------------------------------------------------------------

WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_MAX_FRAME :: 1 << 20

OP_CONT :: u8(0x0)
OP_TEXT :: u8(0x1)
OP_BINARY :: u8(0x2)
OP_CLOSE :: u8(0x8)
OP_PING :: u8(0x9)
OP_PONG :: u8(0xA)

// ws_request_headers writes the upgrade's headers and a fresh key, and answers
// the key's length in `key`, or zero with no entropy for it.
ws_request_headers :: proc(sink: ^libodin.Sink, key: []u8) -> int {
	nonce: [16]u8
	if !fill_random(nonce[:]) {
		return 0
	}
	n := b64_padded(nonce[:], key)
	libodin.put_str(sink, "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ")
	libodin.put_str(sink, string(key[:n]))
	libodin.put_str(sink, "\r\n")
	return n
}

// ws_accepted says the server took the upgrade: `101`, and the accept that
// only a server that read this key can have made.
ws_accepted :: proc(head: string, key: string) -> bool {
	if len(head) < 12 || head[9:12] != "101" {
		return false
	}
	got, has := header_value(head, "sec-websocket-accept")
	if !has {
		return false
	}
	want: [32]u8
	return trim(got) == ws_accept(key, want[:])
}

// ws_accept is the RFC's answer to a key: base64 of sha1 over the key and the
// GUID.
ws_accept :: proc(key: string, into: []u8) -> string {
	joined: [96]u8
	j := libuser.cat_into(joined[:], key, WS_GUID)
	digest: [20]u8
	hash.hash_bytes_to_buffer(.Insecure_SHA1, transmute([]u8)j, digest[:])
	n := b64_padded(digest[:], into)
	return string(into[:n])
}

// b64_padded is base64 in the standard alphabet with its `=` padding, which
// the WebSocket headers carry and `libodin`'s encoder leaves off.
b64_padded :: proc "contextless" (data: []u8, into: []u8) -> int {
	n := libodin.b64_encode(data, into)
	if n < 0 {
		return 0
	}
	for n % 4 != 0 && n < len(into) {
		into[n] = '='
		n += 1
	}
	return n
}

/*
ws_run is the socket's life, on the fetch thread: the conversation says so,
a write that waited for the handshake goes, and then frames are read until
the socket closes. What came after the `101`'s headers is the first of them.
*/
ws_run :: proc(f: ^Fetch, first: []u8) {
	c := f.c
	f.wio = libthread.ioproc(32 * 1024)
	if f.wio == nil {
		fail_fetch(c, "no io proc for the socket's writes")
		return
	}
	c.fetch = f
	c.state = .Socket
	answer_held(c)
	ws_wake(c)

	raw := make([dynamic]u8, libuser.allocator())
	defer delete(raw)
	append(&raw, ..first)
	msg := make([dynamic]u8, libuser.allocator())
	defer delete(msg)
	chunk: [4096]u8
	for {
		// A frame's header: two bytes, the length's extension, a mask key
		// when the server set one (it should not).
		op, fin, payload, used, whole := ws_parse(raw[:])
		if !whole {
			n := stream_read(f, chunk[:])
			if n <= 0 {
				break
			}
			append(&raw, ..chunk[:n])
			if len(raw) > WS_MAX_FRAME + 16 {
				break
			}
			continue
		}
		switch op {
		case OP_TEXT, OP_BINARY, OP_CONT:
			append(&msg, ..payload)
			if fin {
				frame := make([]u8, len(msg), libuser.allocator())
				copy(frame, msg[:])
				append(&c.frames, frame)
				clear(&msg)
				answer_held(c)
			}
		case OP_PING:
			libthread.qlock(&c.wlock)
			_ = ws_send_frame(f, OP_PONG, payload)
			libthread.qunlock(&c.wlock)
		case OP_CLOSE:
			// Answered with a close, whether or not this end sent one first.
			libthread.qlock(&c.wlock)
			_ = ws_send_frame(f, OP_CLOSE, payload[:min(len(payload), 2)])
			libthread.qunlock(&c.wlock)
			c.state = .Done
			return
		}
		copy(raw[:], raw[used:])
		resize(&raw, len(raw) - used)
	}
	c.state = .Done
}

// ws_parse reads one frame off the front of `raw`: its opcode, whether it is
// the last of its message, the payload unmasked in place, and the bytes it
// took. `whole` is false until the frame has all arrived.
ws_parse :: proc "contextless" (raw: []u8) -> (op: u8, fin: bool, payload: []u8, used: int, whole: bool) #no_bounds_check {
	if len(raw) < 2 {
		return
	}
	fin = raw[0] & 0x80 != 0
	op = raw[0] & 0x0F
	masked := raw[1] & 0x80 != 0
	length := int(raw[1] & 0x7F)
	at := 2
	switch length {
	case 126:
		if len(raw) < 4 {
			return
		}
		length = int(raw[2]) << 8 | int(raw[3])
		at = 4
	case 127:
		if len(raw) < 10 {
			return
		}
		length = 0
		for i in 2 ..< 10 {
			length = length << 8 | int(raw[i])
		}
		at = 10
	}
	mask: [4]u8
	if masked {
		if len(raw) < at + 4 {
			return
		}
		copy(mask[:], raw[at:at + 4])
		at += 4
	}
	if length < 0 || length > WS_MAX_FRAME || len(raw) < at + length {
		return
	}
	payload = raw[at:at + length]
	if masked {
		for i in 0 ..< length {
			payload[i] ~= mask[i & 3]
		}
	}
	return op, fin, payload, at + length, true
}

/*
ws_send_frame writes one frame, masked with a fresh key as a client's must
be. The caller holds `Conv.wlock`, so two writers never interleave.
*/
ws_send_frame :: proc(f: ^Fetch, op: u8, payload: []u8) -> bool {
	frame := make([]u8, len(payload) + 14, libuser.allocator())
	defer delete(frame)
	frame[0] = 0x80 | op
	at := 2
	switch {
	case len(payload) < 126:
		frame[1] = 0x80 | u8(len(payload))
	case len(payload) < 65536:
		frame[1] = 0x80 | 126
		frame[2] = u8(len(payload) >> 8)
		frame[3] = u8(len(payload))
		at = 4
	case:
		frame[1] = 0x80 | 127
		for i in 0 ..< 8 {
			frame[2 + i] = u8(u64(len(payload)) >> uint(56 - 8 * i))
		}
		at = 10
	}
	mask: [4]u8
	if !fill_random(mask[:]) {
		return false
	}
	copy(frame[at:], mask[:])
	at += 4
	for i in 0 ..< len(payload) {
		frame[at + i] = payload[i] ~ mask[i & 3]
	}
	return stream_write(f, frame[:at + len(payload)])
}

// ws_take_frame answers what a read of `ws` gets: the waiting frame, or as
// much of it as fits, the rest for the next read. Nothing waiting and the
// socket closed is the end.
ws_take_frame :: proc "contextless" (c: ^Conv, into: []u8) -> []u8 {
	context = libuser.heap_context()
	if len(c.frames) == 0 {
		return nil
	}
	head := c.frames[0]
	n := copy(into, head[c.fpos:])
	c.fpos += n
	if c.fpos >= len(head) {
		delete(head, libuser.allocator())
		ordered_remove(&c.frames, 0)
		c.fpos = 0
	}
	return into[:n]
}

// ws_wake readies every write that waits for the handshake: the socket is up,
// or it never will be.
ws_wake :: proc "contextless" (c: ^Conv) {
	c.up.l = &c.wlock
	libthread.qlock(&c.wlock)
	libthread.rwakeupall(&c.up)
	libthread.qunlock(&c.wlock)
}

Ws_Write :: struct {
	c:     ^Conv,
	tag:   vectra9.Tag,
	op:    u8,
	data:  []u8,
	count: u32,
}

// ws_write_start hands a write of `ws` to a thread of its own, which answers
// the held request when the frame is out.
ws_write_start :: proc(c: ^Conv, tag: vectra9.Tag, data: []u8) -> bool {
	w := new(Ws_Write)
	w.c = c
	w.tag = tag
	w.op = OP_TEXT
	w.count = u32(len(data))
	w.data = make([]u8, len(data))
	copy(w.data, data)
	c.refs += 1 // The write's own hold, so the record outlives the wait
	if libthread.threadcreate(ws_write_thread, w, 64 * 1024) < 0 {
		c.refs -= 1
		delete(w.data)
		free(w)
		return false
	}
	return true
}

// ws_close_start sends the close frame, on a thread, for `hangup`.
ws_close_start :: proc(c: ^Conv) -> bool {
	w := new(Ws_Write)
	w.c = c
	w.op = OP_CLOSE
	code := [2]u8{0x03, 0xE8} // 1000, a normal close
	w.data = make([]u8, 2)
	copy(w.data, code[:])
	c.refs += 1
	if libthread.threadcreate(ws_write_thread, w, 64 * 1024) < 0 {
		c.refs -= 1
		delete(w.data)
		free(w)
		return false
	}
	return true
}

ws_write_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	w := (^Ws_Write)(arg)
	c := w.c
	c.up.l = &c.wlock
	libthread.qlock(&c.wlock)
	for c.state == .Idle || c.state == .Fetching || c.state == .Streaming {
		libthread.rsleep(&c.up)
	}
	ok := c.state == .Socket && c.fetch != nil && ws_send_frame(c.fetch, w.op, w.data)
	libthread.qunlock(&c.wlock)
	if w.op != OP_CLOSE {
		if req := lib9p.find_held_tag(&srv, w.tag); req != nil {
			reply: vectra9.Msg = vectra9.Rwrite{count = w.count}
			if !ok {
				reply = vectra9.error_reply(vectra9.EPIPE)
			}
			_ = lib9p.respond(req, reply)
		}
	}
	i := int(uintptr(rawptr(c)) - uintptr(rawptr(&convs[0]))) / size_of(Conv)
	release(i)
	delete(w.data)
	free(w)
	libthread.threadexits("")
}

trim :: proc "contextless" (s: string) -> string {
	b := 0
	e := len(s)
	for b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n') {
		b += 1
	}
	for e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n') {
		e -= 1
	}
	return s[b:e]
}
