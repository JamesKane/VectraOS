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

holds :: proc "contextless" (text: string, want_text: string) -> bool {
	if len(want_text) > len(text) {
		return false
	}
	for i := 0; i + len(want_text) <= len(text); i += 1 {
		if text[i:i + len(want_text)] == want_text {
			return true
		}
	}
	return false
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

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	// A conversation that listens, and one that connects to it. The connect is
	// the whole handshake, because the loopback answers inside the write.
	server := clone()
	ctl(server, "announce 9", "a conversation announces a port")
	want(holds(text_of(server, "status"), "Listen"), "and its status says it is listening")

	client := clone()
	want(client != server, "a second clone is a second conversation")
	ctl(client, "connect 10.0.2.15!9", "a conversation connects to it")
	want(holds(text_of(client, "status"), "Established"), "and the handshake left it established")

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
	want(holds(text_of(accepted, "status"), "Established"), "and it is established too")
	want(holds(text_of(accepted, "local"), "!9"), "on the port that was announced")

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
	want(holds(text_of(accepted, "status"), "Close_Wait"), "which puts the far end in Close_Wait")
	want(stream_read(accepted) == "", "and ends its stream")

	libuser.exits("ok")
}
