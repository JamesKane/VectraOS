/*
udptest -- `/net/udp`'s conversations, driven from ring 3.

The kernel's self-test starts `netfs`, mounts what it serves at `/net`, and
spawns this. The word it exits with is `ok`, or the name of the first step that
did not hold. Everything here is done the way a program does it, through the files
`docs/FLEET.md` section 3 lays out. So this is the conversation shape itself
under test.

Two conversations are taken from `clone`. One announces a port, the other
connects to it and writes a datagram. The bytes come back out of the first one's
`data`, which is the loopback path. The stack delivers a datagram for this
machine's own address rather than putting it on the card. `local`, `remote` and
`status` are read back to say the conversation is what the control lines made
it.
*/
package udptest

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

// conv_path builds `/net/udp/N/leaf`, the path a conversation's file has.
conv_path :: proc "contextless" (n: int, leaf: string) -> string {
	sink := libodin.sink_from(path_buf[:])
	libodin.put_str(&sink, "/net/udp/")
	libodin.put_uint(&sink, u64(n))
	libodin.put_str(&sink, "/")
	libodin.put_str(&sink, leaf)
	return libodin.str(&sink)
}

// clone takes a new conversation and answers its number.
clone :: proc "contextless" () -> int {
	fd := libuser.open("/net/udp/clone", abi.O_RDONLY)
	want(fd >= 0, "the clone file opens")
	line: [16]u8
	n := libuser.read(int(fd), line[:])
	_ = libuser.close(int(fd))
	want(n > 0, "and answers a conversation's number")
	v := 0
	digits := 0
	for i in 0 ..< int(n) {
		if line[i] < '0' || line[i] > '9' {
			break
		}
		v = v * 10 + int(line[i] - '0')
		digits += 1
	}
	want(digits > 0, "which is a number")
	return v
}

// ctl writes one control line to a conversation, and says it took.
ctl :: proc "contextless" (n: int, line: string, what: string) {
	fd := libuser.open(conv_path(n, "ctl"), abi.O_WRONLY)
	want(fd >= 0, "a conversation's ctl opens")
	ok := libuser.write(int(fd), transmute([]u8)line) == i64(len(line))
	_ = libuser.close(int(fd))
	want(ok, what)
}

// text_of reads one of a conversation's small text files.
read_buf: [128]u8

text_of :: proc "contextless" (n: int, leaf: string) -> string {
	fd := libuser.open(conv_path(n, leaf), abi.O_RDONLY)
	want(fd >= 0, "a conversation's file opens")
	got := libuser.read(int(fd), read_buf[:])
	_ = libuser.close(int(fd))
	want(got > 0, "and answers its text")
	return string(read_buf[:int(got)])
}

// holds reports whether `text` carries `want_text` anywhere in it.
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	// One conversation announces a port, so a datagram for it has somewhere to
	// land.
	server := clone()
	ctl(server, "announce 7", "a conversation announces a port")

	// Another connects to that port on this machine's own address, and writes.
	client := clone()
	want(client != server, "a second clone is a second conversation")
	ctl(client, "connect 10.0.2.15!7", "a conversation connects to it")

	message := "vectra udp"
	{
		fd := libuser.open(conv_path(client, "data"), abi.O_WRONLY)
		want(fd >= 0, "the connected conversation's data opens")
		sent := libuser.write(int(fd), transmute([]u8)message) == i64(len(message))
		_ = libuser.close(int(fd))
		want(sent, "and takes a datagram")
	}

	// The bytes come out of the announced conversation, whole.
	{
		fd := libuser.open(conv_path(server, "data"), abi.O_RDONLY)
		want(fd >= 0, "the announced conversation's data opens")
		got := libuser.read(int(fd), read_buf[:])
		_ = libuser.close(int(fd))
		want(int(got) == len(message), "and answers the datagram whole")
		want(string(read_buf[:int(got)]) == message, "with the bytes that were written")
	}

	// And the conversation says what it is.
	want(libodin.contains(text_of(server, "local"), "!7"), "the announced end is the port it announced")
	want(libodin.contains(text_of(server, "status"), "Announced"), "and its status says so")
	want(libodin.contains(text_of(client, "remote"), "10.0.2.15!7"), "the connected end names the far side")
	want(libodin.contains(text_of(client, "status"), "Connected"), "and its status says so")

	// A hangup ends one, and the number stops being a conversation.
	ctl(client, "hangup", "a conversation hangs up")
	want(libuser.open(conv_path(client, "ctl"), abi.O_WRONLY) < 0, "and its files are gone")

	libuser.exits("ok")
}
