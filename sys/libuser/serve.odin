/*
A 9P server, as a loop a program calls.

`/bin/niner` proved a program can answer 9P and built every reply by hand.
This file is what that proof buys the next server. It carries the posting,
the frame loop and the codec, so a program brings a `vectra9.Handler` and
nothing else. That signature is the load-bearing choice, because it is the
one every kernel server implements. A handler cannot tell whether it answers
from ring 0 behind a transport or from ring 3 behind a pipe. That is the
claim `sys/vectra9` opens with, now true across the privilege boundary.

The loop is the wire's mirror. The wire encodes requests and matches
replies. This side decodes requests and answers in order, one at a time,
which is the shape the borrow rule was born under. The handler may answer
out of its own storage, because nothing else is inside it.

## How a server stops

Two ways, both the caller's to see in the result:

  - **A `Tremove` is answered and then obeyed.** Removal of a file a server
    serves is the client saying stop, which is `/bin/niner`'s rule kept.
    The reply goes out first, so the remover hears yes.
  - **The pipe ends.** EOF means every client is gone, and a frame that lies
    about its size means the stream cannot be re-synchronised. Both end the
    loop, and the reason says which.
*/
package libuser

import "vsys:abi"
import "vsys:vectra9"

// Why `serve` returned. `Removed` is the orderly stop. `Hangup` is a pipe
// that ended. `Broken` is a frame no loop can read past: a size beyond the
// buffer, or bytes that will not decode.
Serve_End :: enum {
	Removed,
	Hangup,
	Broken,
}

/*
post publishes one end of a fresh pipe under a name in `/srv`.

Plan 9's arc, made one call: pipe, create, write the digits, and give back
both spent descriptors. What returns is the serve end, ready for `serve`. On
any refusal along the way, everything opened is closed again. The answer is
then the kernel's errno, so a caller learns which step said no.
*/
post :: proc "contextless" (path: string) -> (serve_fd: int, err: i64) {
	packed := pipe()
	if packed < 0 {
		return -1, packed
	}
	end0, end1 := abi.pipe_ends(packed)

	cfd := create(path, abi.O_WRONLY, 0o600)
	if cfd < 0 {
		_ = close(end0)
		_ = close(end1)
		return -1, cfd
	}

	digits: [4]u8
	n := put_dec(digits[:], u64(end1))
	wrote := write(int(cfd), digits[:n])
	_ = close(int(cfd))
	if wrote != i64(n) {
		_ = close(end0)
		_ = close(end1)
		return -1, wrote < 0 ? wrote : -1
	}

	// The posting holds its own reference now, so the program's handle on
	// the posted end is spent the moment the write lands.
	_ = close(end1)
	return end0, 0
}

/*
serve answers requests from a descriptor until something ends the loop.

`frame` receives each request and `out` each reply, so both must hold a
whole message. Their size is the msize this server can honour, and the
handler's `Tversion` answer should say no more. `payload` is handed to the
handler for replies that carry bytes, which is the same contract every
kernel transport keeps with its handlers.

The handler runs with a session whose fields mean nothing here. It exists
because the signature carries one, and the signature is shared with servers
that need it.
*/
serve :: proc "contextless" (
	fd: int,
	handler: vectra9.Handler,
	state: rawptr,
	frame: []u8,
	out: []u8,
	payload: []u8,
) -> (served: u64, why: Serve_End) {
	session: vectra9.Session

	for {
		header := frame[:vectra9.HEADER_SIZE]
		if !read_full(fd, header) {
			return served, .Hangup
		}
		size := int(header[0]) | int(header[1]) << 8 | int(header[2]) << 16 | int(header[3]) << 24
		if size < vectra9.HEADER_SIZE || size > len(frame) {
			return served, .Broken
		}
		if !read_full(fd, frame[vectra9.HEADER_SIZE:size]) {
			return served, .Hangup
		}

		tag, request, derr := vectra9.decode(frame[:size])
		if derr != .None {
			return served, .Broken
		}
		_, is_remove := request.(vectra9.Tremove)

		reply: vectra9.Msg
		handler(state, &session, tag, &request, &reply, payload)

		n, eerr := vectra9.encode(out, tag, reply)
		if eerr != .None {
			return served, .Broken
		}
		if !write_full(fd, out[:n]) {
			return served, .Hangup
		}
		served += 1

		if is_remove {
			return served, .Removed
		}
	}
}

// put_dec writes a number as decimal digits and reports how many. For the
// descriptor a posting writes, so the bound is small.
put_dec :: proc "contextless" (buf: []u8, v: u64) -> int #no_bounds_check {
	digits: [20]u8
	d := 0
	v := v
	for {
		digits[d] = '0' + u8(v % 10)
		d += 1
		v /= 10
		if v == 0 {
			break
		}
	}
	if d > len(buf) {
		return 0
	}
	n := 0
	for d > 0 {
		d -= 1
		buf[n] = digits[d]
		n += 1
	}
	return n
}
