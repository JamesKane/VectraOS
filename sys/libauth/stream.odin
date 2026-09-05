/*
libauth/stream -- the handshake on a connection, and the sealed stream after.

`docs/FLEET.md` section 4: the conversation happens before 9P, on the raw
stream. `auth_client` and `auth_server` each run the Noise IK handshake
through `factotum`, so neither holds a static key, and answer the far side's
name and a new descriptor. The new descriptor is one end of a pipe. Behind it
two processes forked here carry frames between the pipe's other end and the
connection: one seals what the program writes and sends it, the other opens
what arrives and hands it over. A frame on the wire is a two-byte
little-endian length and the ciphertext with its tag. The handshake messages
cross framed the same way.

The far side's name: a client already knows the host it dialled, and the
pattern proves it, since a stranger cannot complete `es` with a key it does
not hold. A server names its client by the static key the handshake handed
it, looked up in a keys file -- `user  hex  groups...`, one per line -- and a
key not in the file is `none`. What `none` may have is the service's decision,
as it is for Plan 9's file servers.
*/
package libauth

import "vsys:abi"
import "vsys:libcrypto"
import "vsys:libuser"

FRAME_MAX :: 1024 // Plaintext bytes one frame carries at most
KEYS_FILE :: "/adm/keys"
NONE :: "none"

// A sealed stream's two ends, as `auth_client` and `auth_server` answer it.
Session :: struct {
	fd:   int, // The program's end: read and write plaintext here
	name: [64]u8,
	nlen: int,
}

session_name :: proc "contextless" (s: ^Session) -> string {
	return string(s.name[:s.nlen])
}

// -- factotum's rpc, a line at a time ------------------------------------------

@(private = "file")
rpc_ask :: proc "contextless" (rpc: int, line: string, into: []u8) -> string {
	_ = libuser.write(rpc, transmute([]u8)line)
	n := libuser.read(rpc, into)
	if n <= 0 {
		return ""
	}
	return string(into[:n])
}

@(private = "file")
word :: proc "contextless" (line: string, n: int) -> string #no_bounds_check {
	at := 0
	i := 0
	for at < len(line) {
		for at < len(line) && line[at] == ' ' {at += 1}
		end := at
		for end < len(line) && line[end] != ' ' && line[end] != '\n' {end += 1}
		if i == n {
			return line[at:end]
		}
		i += 1
		at = end
	}
	return ""
}

// -- Frames on the wire ------------------------------------------------------------

@(private = "file")
write_frame :: proc "contextless" (fd: int, body: []u8) -> bool {
	hdr := [2]u8{u8(len(body)), u8(len(body) >> 8)}
	if !libuser.write_full(fd, hdr[:]) {
		return false
	}
	return libuser.write_full(fd, body)
}

@(private = "file")
read_frame :: proc "contextless" (fd: int, into: []u8) -> int {
	hdr: [2]u8
	if !libuser.read_full(fd, hdr[:]) {
		return -1
	}
	n := int(hdr[0]) | int(hdr[1]) << 8
	if n > len(into) {
		return -1
	}
	if n > 0 && !libuser.read_full(fd, into[:n]) {
		return -1
	}
	return n
}

// -- The two ends of the handshake -------------------------------------------------

/*
auth_client proves this session to the host at the far end of `conn`, as
`user` in `dom`, and answers a sealed stream. `host_key` is the host's static
public key in hex, the `key=` on its database record; the caller looks it up.
False is a handshake that did not complete: no key in factotum, the far side
not the host named, or the stream ending.
*/
auth_client :: proc "contextless" (conn: int, user, dom, host_key: string) -> (Session, bool) {
	s: Session
	rpc := libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	if rpc < 0 {
		return s, false
	}
	defer libuser.close(int(rpc))
	line: [256]u8
	reply: [1024]u8
	start := libuser.cat_into(line[:], "start initiator user=", user, " dom=", dom, " remote=", host_key)
	r := rpc_ask(int(rpc), start, reply[:])
	if len(r) < 4 || r[:4] != "msg " {
		return s, false
	}
	msg: [MSG1_MAX]u8
	n := libcrypto.hex_decode(msg[:], r[4:])
	if n <= 0 || !write_frame(conn, msg[:n]) {
		return s, false
	}
	in_: [MSG1_MAX]u8
	m := read_frame(conn, in_[:])
	if m <= 0 {
		return s, false
	}
	hex: [2 * MSG1_MAX + 4]u8
	ask := libuser.cat_into(hex[:], "msg ", libcrypto.hex_encode(hex[4:], in_[:m]))
	r = rpc_ask(int(rpc), ask, reply[:])
	if len(r) < 5 || r[:5] != "done " {
		return s, false
	}
	// The host is who it said: the pattern could not have completed otherwise.
	s.nlen = copy(s.name[:], host_key[:min(len(host_key), 8)])
	return seal_stream(&s, conn, word(r, 2), word(r, 3))
}

/*
auth_server proves the session at the far end of `conn` to this host, as
`host` in `dom`, and answers a sealed stream and the client's name: the user
whose key `keys_file` lists, or `none`. False is a handshake that did not
complete, which is what a stranger's dial comes to: refused before 9P.
*/
auth_server :: proc "contextless" (conn: int, host, dom: string, keys_file := KEYS_FILE) -> (Session, bool) {
	s: Session
	rpc := libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	if rpc < 0 {
		return s, false
	}
	defer libuser.close(int(rpc))
	line: [256]u8
	reply: [1024]u8
	start := libuser.cat_into(line[:], "start responder user=", host, " dom=", dom)
	if rpc_ask(int(rpc), start, reply[:]) != "ok" {
		return s, false
	}
	in_: [MSG1_MAX]u8
	m := read_frame(conn, in_[:])
	if m <= 0 {
		return s, false
	}
	hex: [2 * MSG1_MAX + 4]u8
	ask := libuser.cat_into(hex[:], "msg ", libcrypto.hex_encode(hex[4:], in_[:m]))
	r := rpc_ask(int(rpc), ask, reply[:])
	if len(r) < 4 || r[:4] != "msg " {
		return s, false
	}
	out: [MSG2_MAX]u8
	n := libcrypto.hex_decode(out[:], r[4:])
	if n <= 0 || !write_frame(conn, out[:n]) {
		return s, false
	}
	r = rpc_ask(int(rpc), "finish", reply[:])
	if len(r) < 5 || r[:5] != "done " {
		return s, false
	}
	s.nlen = copy(s.name[:], name_of_key(word(r, 1), keys_file))
	return seal_stream(&s, conn, word(r, 2), word(r, 3))
}

/*
name_of_key finds the user whose line in the keys file carries `key`, or
`none`. The file is `user  hex  groups...`, one per line, and a line that
begins with `#` is a comment.
*/
name_of_key :: proc "contextless" (key: string, keys_file: string) -> string #no_bounds_check {
	@(static) text: [8192]u8
	fd := libuser.open(keys_file, abi.O_RDONLY)
	if fd < 0 {
		return NONE
	}
	at := 0
	for at < len(text) {
		n := libuser.read(int(fd), text[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	_ = libuser.close(int(fd))
	all := string(text[:at])
	pos := 0
	for pos < len(all) {
		end := pos
		for end < len(all) && all[end] != '\n' {end += 1}
		ln := all[pos:end]
		if len(ln) > 0 && ln[0] != '#' && word(ln, 1) == key {
			return word(ln, 0)
		}
		pos = end + 1
	}
	return NONE
}

// -- The sealed stream ------------------------------------------------------------

/*
seal_stream makes the pipe and forks the two carriers, then answers the
program's end. `send_hex` and `recv_hex` are the transport keys factotum
handed over, this side's sending key first.

The carriers are a note group of their own, apart from the program: the
outbound one is forked with `RFNOTEG` and forks the inbound one inside it.
Either end of the stream may end first -- the program closing its descriptor,
or the far side hanging up -- and the carrier that sees it posts a note to
the group, which ends the other. Without that the two inbound carriers, one
each side, would each wait for the other side to close, for ever. Both are
`RFNOWAIT`: nothing waits for them, and they leave no record.
*/
@(private = "file")
seal_stream :: proc "contextless" (s: ^Session, conn: int, send_hex, recv_hex: string) -> (Session, bool) {
	send: Cipher
	recv: Cipher
	if libcrypto.hex_decode(send.k[:], send_hex) != 32 || libcrypto.hex_decode(recv.k[:], recv_hex) != 32 {
		return s^, false
	}
	send.has_key = true
	recv.has_key = true
	packed := libuser.pipe()
	if packed < 0 {
		return s^, false
	}
	near, far := abi.pipe_ends(packed)

	pid := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOTEG | abi.RFNOWAIT)
	if pid < 0 {
		_ = libuser.close(near)
		_ = libuser.close(far)
		return s^, false
	}
	if pid == 0 {
		// The group's leader carries outbound, after forking inbound into
		// the same group.
		_ = libuser.close(near)
		if libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOWAIT) == 0 {
			carry_in(conn, far, &recv)
		}
		carry_out(far, conn, &send)
	}
	_ = libuser.close(far)
	_ = libuser.close(conn)
	s.fd = near
	return s^, true
}

// leave ends this carrier and its sibling: a note to the group, then exit.
@(private = "file")
leave :: proc "contextless" () -> ! {
	_ = libuser.notepg(u64(libuser.getpid()), "hangup")
	libuser.exits("")
}

@(private = "file")
carry_out :: proc "contextless" (from: int, conn: int, c: ^Cipher) -> ! {
	context = libuser.heap_context()
	plain: [FRAME_MAX]u8
	frame: [FRAME_MAX + TAG_SIZE]u8
	for {
		n := libuser.read(from, plain[:])
		if n <= 0 {
			break
		}
		transport_seal(c, frame[:int(n) + TAG_SIZE], plain[:n])
		if !write_frame(conn, frame[:int(n) + TAG_SIZE]) {
			break
		}
	}
	leave()
}

@(private = "file")
carry_in :: proc "contextless" (conn: int, to: int, c: ^Cipher) -> ! {
	context = libuser.heap_context()
	frame: [FRAME_MAX + TAG_SIZE]u8
	plain: [FRAME_MAX]u8
	for {
		n := read_frame(conn, frame[:])
		if n < TAG_SIZE {
			break
		}
		if !transport_open(c, plain[:n - TAG_SIZE], frame[:n]) {
			break // A frame that does not open ends the stream, on purpose.
		}
		if !libuser.write_full(to, plain[:n - TAG_SIZE]) {
			break
		}
	}
	leave()
}
