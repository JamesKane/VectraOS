/*
tcptest -- `/net/tcp`'s conversations, driven from ring 3.

The kernel's self-test starts `netfs`, mounts what it serves at `/net`, and
spawns this. The word it exits with is `ok`, or the name of the first step that
did not hold.

One conversation announces a port. Another connects to it, which is a SYN, a SYN
and ACK, and an ACK across the loopback before the write returns. The listener
then hands over the conversation it answered with, through a read of `listen`.
Bytes go each way over the stream, and a hangup sends the FIN that puts the far
end into `Close_Wait` and ends the reader's stream.

Everything is done through the files `docs/FLEET.md` section 3 lays out. The
conversation shape is under test as much as the state machine.
*/
package tcptest

import "vsys:abi"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
}

path_buf: [64]u8
read_buf: [256]u8

// conv_path builds `/net/tcp/N/leaf`.
conv_path :: proc "contextless" (n: int, leaf: string) -> string {
	sink := libodin.sink_from(path_buf[:])
	libodin.put_str(&sink, "/net/tcp/")
	libodin.put_uint(&sink, u64(n))
	libodin.put_str(&sink, "/")
	libodin.put_str(&sink, leaf)
	return libodin.str(&sink)
}

// number reads the decimal at the start of `text`.
number :: proc "contextless" (text: string) -> (int, bool) {
	v := 0
	digits := 0
	for i in 0 ..< len(text) {
		if text[i] < '0' || text[i] > '9' {
			break
		}
		v = v * 10 + int(text[i] - '0')
		digits += 1
	}
	return v, digits > 0
}

clone :: proc "contextless" () -> int {
	fd := libuser.open("/net/tcp/clone", abi.O_RDONLY)
	want(fd >= 0, "the clone file opens")
	line: [16]u8
	n := libuser.read(int(fd), line[:])
	_ = libuser.close(int(fd))
	want(n > 0, "and answers a conversation's number")
	v, ok := number(string(line[:int(n)]))
	want(ok, "which is a number")
	return v
}

ctl :: proc "contextless" (n: int, line: string, what: string) {
	fd := libuser.open(conv_path(n, "ctl"), abi.O_WRONLY)
	want(fd >= 0, "a conversation's ctl opens")
	ok := libuser.write(int(fd), transmute([]u8)line) == i64(len(line))
	_ = libuser.close(int(fd))
	want(ok, what)
}

text_of :: proc "contextless" (n: int, leaf: string) -> string {
	fd := libuser.open(conv_path(n, leaf), abi.O_RDONLY)
	want(fd >= 0, "a conversation's file opens")
	got := libuser.read(int(fd), read_buf[:])
	_ = libuser.close(int(fd))
	return string(read_buf[:max(int(got), 0)])
}

// stream_write puts bytes into a conversation's data file.
stream_write :: proc "contextless" (n: int, text: string, what: string) {
	fd := libuser.open(conv_path(n, "data"), abi.O_WRONLY)
	want(fd >= 0, "a conversation's data opens for writing")
	ok := libuser.write(int(fd), transmute([]u8)text) == i64(len(text))
	_ = libuser.close(int(fd))
	want(ok, what)
}

// stream_read takes what a conversation's stream holds.
stream_read :: proc "contextless" (n: int) -> string {
	fd := libuser.open(conv_path(n, "data"), abi.O_RDONLY)
	want(fd >= 0, "a conversation's data opens for reading")
	got := libuser.read(int(fd), read_buf[:])
	_ = libuser.close(int(fd))
	return string(read_buf[:max(int(got), 0)])
}

// write_some puts as much of `data` as the stream takes now, and answers the
// count. A short answer is the window holding the sender back, not an error.
write_some :: proc "contextless" (n: int, data: []u8) -> int {
	fd := libuser.open(conv_path(n, "data"), abi.O_WRONLY)
	want(fd >= 0, "the bulk stream opens for writing")
	got := libuser.write(int(fd), data)
	_ = libuser.close(int(fd))
	return int(got)
}

// read_some takes what the stream holds now, up to `out`, and answers the count.
read_some :: proc "contextless" (n: int, out: []u8) -> int {
	fd := libuser.open(conv_path(n, "data"), abi.O_RDONLY)
	want(fd >= 0, "the bulk stream opens for reading")
	got := libuser.read(int(fd), out)
	_ = libuser.close(int(fd))
	return int(max(got, 0))
}

bulk: [6144]u8
sink: [2048]u8


// The address this machine answers to, read from `/net/local`, so the
// connects below are the loopback on any machine: the bench's two have
// addresses of their own, and a hardcoded one would cross the card there.
local_buf: [32]u8
local_len: int

my_address :: proc "contextless" () -> string {
	if local_len == 0 {
		fd := libuser.open("/net/local", abi.O_RDONLY)
		want(fd >= 0, "/net/local opens")
		n := libuser.read(int(fd), local_buf[:])
		_ = libuser.close(int(fd))
		want(n > 0, "and answers this machine's address")
		local_len = int(n)
		for local_len > 0 && (local_buf[local_len - 1] == '\n' || local_buf[local_len - 1] == '\r') {
			local_len -= 1
		}
	}
	return string(local_buf[:local_len])
}

// connect_line builds `connect a.b.c.d!port` for this machine's own address.
connect_buf: [64]u8

connect_line :: proc "contextless" (port: string) -> string {
	return libuser.cat_into(connect_buf[:], "connect ", my_address(), "!", port)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	// A conversation that listens, and one that connects to it. The connect is
	// the whole handshake, because the loopback answers inside the write.
	server := clone()
	ctl(server, "announce 9", "a conversation announces a port")
	want(libodin.contains(text_of(server, "status"), "Listen"), "and its status says it is listening")

	client := clone()
	want(client != server, "a second clone is a second conversation")
	ctl(client, connect_line("9"), "a conversation connects to it")
	want(libodin.contains(text_of(client, "status"), "Established"), "and the handshake left it established")

	// The listener hands over the conversation it answered with.
	accepted := 0
	{
		fd := libuser.open(conv_path(server, "listen"), abi.O_RDONLY)
		want(fd >= 0, "the listening conversation's listen file opens")
		got := libuser.read(int(fd), read_buf[:])
		_ = libuser.close(int(fd))
		want(got > 0, "and answers the conversation it accepted")
		v, ok := number(string(read_buf[:int(got)]))
		want(ok, "which is a number")
		accepted = v
	}
	want(accepted != server && accepted != client, "the accepted end is a conversation of its own")
	want(libodin.contains(text_of(accepted, "status"), "Established"), "and it is established too")
	want(libodin.contains(text_of(accepted, "local"), "!9"), "on the port that was announced")

	// Bytes each way over the stream.
	out_text := "hello tcp"
	stream_write(client, out_text, "the connected end takes a write")
	want(stream_read(accepted) == out_text, "and the bytes arrive whole at the other end")

	back_text := "and back again"
	stream_write(accepted, back_text, "the accepted end takes a write")
	want(stream_read(client) == back_text, "and those bytes come back the other way")

	// The close: a FIN one way puts the far end into Close_Wait, and its
	// stream ends rather than waiting for bytes that will not come.
	ctl(client, "hangup", "the connected end hangs up")
	want(libodin.contains(text_of(accepted, "status"), "Close_Wait"), "which puts the far end in Close_Wait")
	want(stream_read(accepted) == "", "and ends its stream")

	// -- The connection server turns two names into an address ---------------
	{
		fd := libuser.open("/net/cs", abi.O_RDWR)
		want(fd >= 0, "the connection server's file opens")
		q := "tcp!vectra!vtest"
		want(libuser.write(int(fd), transmute([]u8)q) == i64(len(q)), "and takes a dial string")
		n := libuser.read(int(fd), read_buf[:])
		_ = libuser.close(int(fd))
		want(n > 0, "and answers where to connect")
		answer := string(read_buf[:int(n)])
		want(libodin.contains(answer, "/net/tcp/clone"), "with the clone file to open")
		want(libodin.contains(answer, "10.0.2.15!1717"), "and the address the database names")
	}

	// -- Dialling by name, through `cs` and the database ----------------------
	//
	// Nothing here writes an address. `tcp!vectra!vtest` is two names, and
	// `/net/cs` turns them into one by reading `/lib/ndb/local`. What comes
	// back is a stream like any other.
	{
		dir: [128]u8
		dlen, aok := libnet.announce("tcp!vectra!vtest", dir[:])
		want(aok, "a conversation announces a service by name")
		server_dir := string(dir[:dlen])

		fd, dok := libnet.dial("tcp!vectra!vtest")
		want(dok, "and another dials that same name")

		// The listener hands over what it answered.
		lp: [160]u8
		lfd := libuser.open(libnet.join(lp[:], server_dir, "listen"), abi.O_RDONLY)
		want(lfd >= 0, "the announced conversation's listen opens")
		got := libuser.read(int(lfd), read_buf[:])
		_ = libuser.close(int(lfd))
		want(got > 0, "and answers the conversation it accepted")
		acc, nok := number(string(read_buf[:int(got)]))
		want(nok, "which is a number")

		// And the stream carries bytes, dialled end to accepted end.
		named := "by name"
		want(libuser.write(fd, transmute([]u8)named) == i64(len(named)), "the dialled stream takes a write")
		want(stream_read(acc) == named, "and the bytes arrive at the accepted end")
		_ = libuser.close(fd)
	}

	// -- A transfer larger than the receive buffer ---------------------------
	//
	// The receive buffer is smaller than this, so the window shuts partway and
	// a read is what reopens it. A small message never reaches that edge. Every
	// byte crosses once and in order across it. The sender is held to the
	// window, and the count it is told is the count that went. No byte the
	// buffer could not take is acknowledged as if it had.
	{
		srv := clone()
		ctl(srv, "announce 30", "a conversation announces for the bulk transfer")
		cli := clone()
		ctl(cli, connect_line("30"), "another connects for the bulk transfer")

		acc := 0
		{
			fd := libuser.open(conv_path(srv, "listen"), abi.O_RDONLY)
			want(fd >= 0, "the bulk listener's listen opens")
			got := libuser.read(int(fd), read_buf[:])
			_ = libuser.close(int(fd))
			want(got > 0, "and answers the accepted conversation")
			v, ok := number(string(read_buf[:int(got)]))
			want(ok, "which is a number")
			acc = v
		}

		for j in 0 ..< len(bulk) {
			bulk[j] = u8(j)
		}
		sent := 0
		recvd := 0
		ordered := true
		// Drain fully before each write. A write then always finds an open
		// window, and never parks on this one thread that must also do the read.
		for recvd < len(bulk) {
			if sent < len(bulk) {
				n := write_some(cli, bulk[sent:])
				want(n > 0, "the bulk write moves at least one byte")
				sent += n
			}
			for recvd < sent {
				room := min(len(sink), sent - recvd)
				m := read_some(acc, sink[:room])
				want(m > 0, "the bulk read returns what was sent")
				for k in 0 ..< m {
					if sink[k] != u8(recvd + k) {
						ordered = false
					}
				}
				recvd += m
			}
		}
		want(sent == len(bulk), "the whole blob was sent")
		want(recvd == len(bulk), "and the whole blob arrived")
		want(ordered, "every byte once and in order, across the window's edge")
	}

	libuser.exits("ok")
}
