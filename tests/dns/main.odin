/*
dnstest -- a resolver of one name, for the suite to ask through `dns` and `cs`.

The kernel's self-test points `dns` at this machine, starts this, and asks
`/net/dns` for `fs.test` and `/net/cs` for `tcp!fs.test!9fs`. This announces
port 53, takes each question off its conversation, and answers `fs.test` with
`10.0.0.2`, twice, the way a resolver at a router would. It exits with `ok`
when both questions were the one expected, or with the name it was asked
instead. Everything here goes through the files a program would use, so it is
the datagram server's shape under test as well: an announced conversation
answering whoever last spoke to it.
*/
package dnstest

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
query: [libnet.DNS_MAX]u8
answer: [libnet.DNS_MAX]u8

conv_path :: proc "contextless" (n: int, leaf: string) -> string {
	sink := libodin.sink_from(path_buf[:])
	libodin.put_str(&sink, "/net/udp/")
	libodin.put_uint(&sink, u64(n))
	libodin.put_str(&sink, "/")
	libodin.put_str(&sink, leaf)
	return libodin.str(&sink)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	cfd := libuser.open("/net/udp/clone", abi.O_RDONLY)
	want(cfd >= 0, "the clone file opens")
	line: [16]u8
	n := libuser.read(int(cfd), line[:])
	_ = libuser.close(int(cfd))
	want(n > 0, "and answers a conversation")
	conv := 0
	for i in 0 ..< int(n) {
		if line[i] < '0' || line[i] > '9' {
			break
		}
		conv = conv * 10 + int(line[i] - '0')
	}
	ctl := libuser.open(conv_path(conv, "ctl"), abi.O_WRONLY)
	want(ctl >= 0, "its ctl opens")
	text := "announce 53"
	want(libuser.write(int(ctl), transmute([]u8)text) == i64(len(text)), "and announces the resolver's port")
	_ = libuser.close(int(ctl))

	data := libuser.open(conv_path(conv, "data"), abi.O_RDWR)
	want(data >= 0, "its data opens")
	// One question: `cs` asks `dns`, which remembers the answer, so the
	// suite's three questions reach the resolver as one.
	{
		got := libuser.read(int(data), query[:])
		want(got > 0, "a question arrives")
		name: [128]u8
		nl := libnet.dns_question(query[:got], name[:])
		want(nl > 0, "and parses")
		if string(name[:nl]) != "fs.test" {
			fail(string(name[:nl]))
		}
		m := libnet.put_dns_answer(answer[:], query[:got], libnet.IP{10, 0, 0, 2})
		want(m > 0, "the answer encodes")
		want(libuser.write(int(data), answer[:m]) == i64(m), "and goes back to whoever asked")
	}
	_ = libuser.close(int(data))
	libuser.exits("ok")
}
