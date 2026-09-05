/*
ipconfig -- ask the network for an address, and tell the stack.

    ipconfig [etherN]

With no argument, every interface that has no address asks for one. With one,
that interface asks, whether or not it has one. The asking is DHCP over a
conversation of `/net/udp`, bound to the interface and connected to the
broadcast address, since a machine with no address can only shout. An answer
goes into `/net/ipifc/N/ctl` as the interface's address and mask, into
`/net/iproute` as the default route through the router named, and into
`/net/ndb` as a line of what was learned, for `dns` and anyone else who asks.

A machine whose router hands out addresses then needs no line in
`/lib/ndb/local`. `docs/FLEET.md` section 3 has the shape.
*/
package ipconfig

import "vsys:abi"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"

// How long one answer is waited for, in the kernel's millisecond ticks, and
// how many times the whole exchange is tried before giving up.
WAIT :: 2000
TRIES :: 3

dir: [64]u8
msg: [libnet.DHCP_MAX]u8
reply: [libnet.DHCP_MAX]u8
line: [256]u8

say :: proc "contextless" (text: string) {
	_ = libuser.write(1, transmute([]u8)text)
}

fail :: proc "contextless" (what: string) -> ! {
	say(what)
	say("\n")
	libuser.exits(what)
}

on_note :: proc "c" (ureg: rawptr, note: cstring) {
	_ = ureg
	_ = note
	libuser.noted(abi.NCONT)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	if libuser.notify(uintptr(rawptr(on_note))) != 0 {
		fail("ipconfig: cannot catch a note")
	}
	if len(args) >= 2 {
		if !configure(args[1], true) {
			libuser.exits("no answer")
		}
		libuser.exits("")
	}
	names := [?]string{"ether0", "ether1"}
	for name in names {
		_ = configure(name, false)
	}
	libuser.exits("")
}

// -- One interface --------------------------------------------------------------

/*
configure asks for an address on `name`. `force` asks even when the interface
has one. Answers whether an address was set. An interface that is not there
is simply skipped.
*/
configure :: proc "contextless" (name: string, force: bool) -> bool {
	path: [64]u8
	ifc := ifc_number(name)
	if ifc < 0 {
		return false
	}
	status: [128]u8
	n := read_file(libuser.cat_into(path[:], "/net/ipifc/", name[5:6], "/status"), status[:])
	if n <= 0 {
		return false
	}
	if !force && !libodin.contains(string(status[:n]), " 0.0.0.0 ") {
		return false
	}
	mac, mok := card_address(name)
	if !mok {
		return false
	}

	// A conversation bound to the card, shouting.
	fd, dirlen, ok := udp_conv(name)
	if !ok {
		fail("ipconfig: cannot take a udp conversation")
	}
	defer {
		_ = libuser.close(fd)
		libnet.hangup(string(dir[:dirlen]))
	}

	xid := u32(mac[2]) << 24 | u32(mac[3]) << 16 | u32(mac[4]) << 8 | u32(mac[5])
	for try in 0 ..< TRIES {
		xid += u32(try)
		offer, got := exchange(fd, libnet.Dhcp_Ask{kind = libnet.DHCP_DISCOVER, xid = xid, mac = mac}, libnet.DHCP_OFFER)
		if !got {
			continue
		}
		ack, acked := exchange(fd, libnet.Dhcp_Ask{kind = libnet.DHCP_REQUEST, xid = xid, mac = mac, requested = offer.yiaddr, server = offer.server}, libnet.DHCP_ACK)
		if !acked {
			continue
		}
		if ack.mask == (libnet.IP{}) {
			ack.mask = libnet.IP{255, 255, 255, 0}
		}
		apply(name, ack)
		return true
	}
	return false
}

// exchange sends one message and waits for the answer of `kind` that carries
// its transaction, passing over any other.
exchange :: proc "contextless" (fd: int, ask: libnet.Dhcp_Ask, kind: u8) -> (libnet.Dhcp_Answer, bool) {
	n := libnet.put_dhcp(msg[:], ask)
	if libuser.write(fd, msg[:n]) != i64(n) {
		return {}, false
	}
	_ = libuser.alarm(WAIT)
	defer libuser.alarm(0)
	for {
		got := libuser.read(fd, reply[:])
		if got <= 0 {
			return {}, false
		}
		a, ok := libnet.parse_dhcp(reply[:got])
		if ok && a.xid == ask.xid && a.kind == kind {
			return a, true
		}
	}
}

// apply tells the stack what the server said, and says so on the console.
apply :: proc "contextless" (name: string, a: libnet.Dhcp_Answer) {
	path: [64]u8
	sink := libodin.sink_from(line[:])
	libodin.put_str(&sink, "add ")
	put_ip(&sink, a.yiaddr)
	libodin.put_str(&sink, " ")
	put_ip(&sink, a.mask)
	write_file(libuser.cat_into(path[:], "/net/ipifc/", name[5:6], "/ctl"), libodin.str(&sink))

	if a.router != (libnet.IP{}) {
		sink = libodin.sink_from(line[:])
		libodin.put_str(&sink, "add 0.0.0.0 0.0.0.0 ")
		put_ip(&sink, a.router)
		write_file("/net/iproute", libodin.str(&sink))
	}

	sink = libodin.sink_from(line[:])
	libodin.put_str(&sink, "ip=")
	put_ip(&sink, a.yiaddr)
	libodin.put_str(&sink, " ipmask=")
	put_ip(&sink, a.mask)
	libodin.put_str(&sink, " ipgw=")
	put_ip(&sink, a.router)
	libodin.put_str(&sink, " dns=")
	put_ip(&sink, a.dns)
	libodin.put_str(&sink, " ifc=")
	libodin.put_str(&sink, name)
	libodin.put_str(&sink, "\n")
	write_file("/net/ndb", libodin.str(&sink))

	say(name)
	say(": ")
	say(libodin.str(&sink))
}

// -- The files ----------------------------------------------------------------

// udp_conv takes a conversation, binds it to the card and connects it to the
// broadcast address on the server's port, at the client's.
udp_conv :: proc "contextless" (name: string) -> (int, int, bool) {
	cfd := libuser.open("/net/udp/clone", abi.O_RDONLY)
	if cfd < 0 {
		return -1, 0, false
	}
	num: [16]u8
	n := libuser.read(int(cfd), num[:])
	_ = libuser.close(int(cfd))
	if n <= 0 {
		return -1, 0, false
	}
	digits := 0
	for digits < int(n) && num[digits] >= '0' && num[digits] <= '9' {
		digits += 1
	}
	dirlen := len(libuser.cat_into(dir[:], "/net/udp/", string(num[:digits])))

	path: [64]u8
	ctl := libuser.open(libnet.join(path[:], string(dir[:dirlen]), "ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return -1, 0, false
	}
	defer libuser.close(int(ctl))
	bind: [32]u8
	if !write_fd(int(ctl), libuser.cat_into(bind[:], "bind ", name)) {
		return -1, 0, false
	}
	if !write_fd(int(ctl), "announce 68") || !write_fd(int(ctl), "connect 255.255.255.255!67") {
		return -1, 0, false
	}
	data := libuser.open(libnet.join(path[:], string(dir[:dirlen]), "data"), abi.O_RDWR)
	if data < 0 {
		return -1, 0, false
	}
	return int(data), dirlen, true
}

// card_address reads the card's hardware address from the stack.
card_address :: proc "contextless" (name: string) -> (libnet.MAC, bool) {
	path: [64]u8
	text: [32]u8
	n := read_file(libuser.cat_into(path[:], "/net/", name, "/addr"), text[:])
	if n < 17 {
		return {}, false
	}
	mac: libnet.MAC
	for i in 0 ..< 6 {
		hi, ok1 := hex(text[i * 3])
		lo, ok2 := hex(text[i * 3 + 1])
		if !ok1 || !ok2 {
			return {}, false
		}
		mac[i] = hi << 4 | lo
	}
	return mac, true
}

hex :: proc "contextless" (c: u8) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// ifc_number answers N for `etherN`, or -1 for a name that is not one.
ifc_number :: proc "contextless" (name: string) -> int {
	if len(name) != 6 || name[:5] != "ether" || name[5] < '0' || name[5] > '9' {
		return -1
	}
	return int(name[5] - '0')
}

read_file :: proc "contextless" (path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	n := libuser.read(int(fd), into)
	_ = libuser.close(int(fd))
	return int(n)
}

write_file :: proc "contextless" (path: string, text: string) -> bool {
	fd := libuser.open(path, abi.O_WRONLY)
	if fd < 0 {
		return false
	}
	ok := write_fd(int(fd), text)
	_ = libuser.close(int(fd))
	return ok
}

write_fd :: proc "contextless" (fd: int, text: string) -> bool {
	return libuser.write(fd, transmute([]u8)text) == i64(len(text))
}

put_ip :: proc "contextless" (sink: ^libodin.Sink, ip: libnet.IP) {
	for i in 0 ..< 4 {
		if i > 0 {
			libodin.put_str(sink, ".")
		}
		libodin.put_uint(sink, u64(ip[i]))
	}
}
