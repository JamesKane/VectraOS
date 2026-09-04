/*
udp -- conversations, `/net/udp`'s half of the stack.

`docs/FLEET.md` section 3 gives every protocol the same shape, and this is the
first one built to it:

    /net/udp/clone     a read answers a new conversation's number
    /net/udp/N/ctl     `announce port`, `connect addr!port`, `hangup`
    /net/udp/N/data    a datagram per read, a datagram per write
    /net/udp/N/local   this end
    /net/udp/N/remote  the far end
    /net/udp/N/status  what the conversation is

A read of `data` with nothing waiting is held rather than answered empty. The
ether thread answers it when a datagram for that conversation arrives. That
is `lib9p`'s held-read pair per conversation, the shape `servers/intuition`
already uses for a window's mouse.

**A datagram for this machine's own address never reaches the card.** The stack
delivers it to the conversation that announced the port. That is what a loopback
is, and it lets two conversations here talk to each other. A datagram
for anywhere else is a frame, and needs the far side's hardware address in the
ARP table before it can be one.
*/
package netfs

import "vsys:lib9p"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"
import "vsys:vectra9"

MAX_CONV :: 8
DG_MAX :: 512
DG_SLOTS :: 4

// The first port an unannounced conversation is given, well above the ones a
// service would announce.
EPHEMERAL :: u16(30000)

Dgram :: struct {
	len:   int,
	raddr: libnet.IP,
	rport: u16,
	data:  [DG_MAX]u8,
}

Conv :: struct {
	used:      bool,
	announced: bool,
	connected: bool,
	lport:     u16,
	raddr:     libnet.IP,
	rport:     u16,
	// The datagrams that arrived and have not been read, oldest at `head`.
	q:         [DG_SLOTS]Dgram,
	head:      int,
	tail:      int,
}

convs: [MAX_CONV]Conv
next_port: u16 = EPHEMERAL

// conv_alloc takes the first free conversation, or answers -1.
conv_alloc :: proc "contextless" () -> int #no_bounds_check {
	for i in 0 ..< MAX_CONV {
		if !convs[i].used {
			convs[i] = Conv {
				used  = true,
				lport = next_port,
			}
			next_port += 1
			return i
		}
	}
	return -1
}

conv_free :: proc "contextless" (i: int) #no_bounds_check {
	if i >= 0 && i < MAX_CONV {
		convs[i] = Conv{}
	}
}

// conv_queued reports how many datagrams a conversation is holding.
conv_queued :: proc "contextless" (i: int) -> int #no_bounds_check {
	return convs[i].tail - convs[i].head
}

/*
conv_push puts one datagram on a conversation's queue and answers any read that
was held for it. A queue that is full drops the oldest. A datagram may be lost,
and a reader behind the sender wants the newest.
*/
conv_push :: proc "contextless" (i: int, raddr: libnet.IP, rport: u16, payload: []u8) #no_bounds_check {
	c := &convs[i]
	if conv_queued(i) >= DG_SLOTS {
		c.head += 1
	}
	d := &c.q[c.tail % DG_SLOTS]
	d.len = min(len(payload), DG_MAX)
	d.raddr = raddr
	d.rport = rport
	copy(d.data[:d.len], payload[:d.len])
	c.tail += 1
	answer_conv(i)
}

// conv_pop takes the oldest datagram into `out` and answers its length.
conv_pop :: proc "contextless" (i: int, out: []u8) -> int #no_bounds_check {
	c := &convs[i]
	if conv_queued(i) == 0 {
		return 0
	}
	d := &c.q[c.head % DG_SLOTS]
	n := min(d.len, len(out))
	copy(out[:n], d.data[:n])
	c.head += 1
	return n
}

/*
udp_deliver hands one received datagram to the conversation it belongs to. That
is the one holding its destination port, whose far end matches when it has one.
A datagram nothing announced is dropped, which is what a port with no listener
means.
*/
udp_deliver :: proc "contextless" (src: libnet.IP, sport: u16, dport: u16, payload: []u8) #no_bounds_check {
	for i in 0 ..< MAX_CONV {
		c := &convs[i]
		if !c.used || c.lport != dport {
			continue
		}
		if c.connected && (c.raddr != src || c.rport != sport) {
			continue
		}
		conv_push(i, src, sport, payload)
		return
	}
}

/*
udp_send sends one datagram from conversation `i` to the far end it is connected
to. It builds the datagram and hands it to `ip_output`. That is the one place
deciding whether a datagram goes on the card or is delivered here.
*/
udp_send :: proc "contextless" (i: int, payload: []u8) -> bool #no_bounds_check {
	c := &convs[i]
	if !c.connected {
		return false
	}
	dgram: [libnet.UDP_HDR + DG_MAX]u8 = ---
	end := libnet.put_udp(dgram[:], 0, my_ip, c.raddr, c.lport, c.rport, payload)
	return ip_output(c.raddr, libnet.IPPROTO_UDP, dgram[:end])
}

// -- The control file ---------------------------------------------------------

/*
run_ctl takes one of the three lines a conversation understands. `announce`
gives it a port to be found at, `connect` gives it a far end to send to, and
`hangup` ends it.
*/
run_ctl :: proc "contextless" (i: int, text: string) -> bool #no_bounds_check {
	verb, rest := word(text)
	switch verb {
	case "announce":
		port, ok := scan_port(rest)
		if !ok {
			return false
		}
		convs[i].lport = port
		convs[i].announced = true
		return true
	case "connect":
		addr, _ := word(rest)
		ip, port, ok := scan_addr(addr)
		if !ok {
			return false
		}
		convs[i].raddr = ip
		convs[i].rport = port
		convs[i].connected = true
		return true
	case "hangup":
		conv_free(i)
		return true
	}
	return false
}

// word answers the first run of non-space characters and the rest after it.
word :: proc "contextless" (s: string) -> (first: string, rest: string) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' && s[i] != '\t' && s[i] != '\n' && s[i] != '\r' {
		i += 1
	}
	return s[start:i], s[i:]
}

// scan_uint reads a decimal number, and answers it with what follows.
scan_uint :: proc "contextless" (s: string) -> (v: u32, rest: string, ok: bool) #no_bounds_check {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + u32(s[i] - '0')
		i += 1
	}
	return v, s[i:], i > 0
}

scan_port :: proc "contextless" (s: string) -> (u16, bool) {
	w, _ := word(s)
	v, _, ok := scan_uint(w)
	if !ok || v > 65535 {
		return 0, false
	}
	return u16(v), true
}

// scan_ip reads `a.b.c.d` and answers what follows it, so a caller can go on
// to read a port or check the text ended.
scan_ip :: proc "contextless" (s: string) -> (ip: libnet.IP, rest: string, ok: bool) #no_bounds_check {
	rest = s
	for i in 0 ..< 4 {
		v, after, got := scan_uint(rest)
		if !got || v > 255 {
			return {}, s, false
		}
		ip[i] = u8(v)
		rest = after
		if i < 3 {
			if len(rest) == 0 || rest[0] != '.' {
				return {}, s, false
			}
			rest = rest[1:]
		}
	}
	return ip, rest, true
}

// address reads a whole `a.b.c.d`, which is what a database record holds.
address :: proc "contextless" (s: string) -> (libnet.IP, bool) {
	ip, _, ok := scan_ip(s)
	return ip, ok
}

// scan_addr reads `a.b.c.d!port`, the way a dial string names one end.
scan_addr :: proc "contextless" (s: string) -> (ip: libnet.IP, port: u16, ok: bool) #no_bounds_check {
	addr, rest, got_ip := scan_ip(s)
	if !got_ip {
		return {}, 0, false
	}
	if len(rest) == 0 || rest[0] != '!' {
		return {}, 0, false
	}
	v, _, got := scan_uint(rest[1:])
	if !got || v > 65535 {
		return {}, 0, false
	}
	return addr, u16(v), true
}

// -- The held read, one conversation at a time --------------------------------

// answer_conv answers a read held on conversation `i`'s data file, now that a
// datagram for it is queued.
answer_conv :: proc "contextless" (i: int) {
	lib9p.answer_reads(&srv, rawptr(uintptr(i)), wants_conv, drain_conv)
}

wants_conv :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	i := int(uintptr(arg))
	#partial switch m in request^ {
	case vectra9.Tread:
		node := libuser.fid_lookup(&fids, m.fid)
		conv, kind, ok := conv_of(node)
		return ok && conv == i && kind == CONV_DATA
	}
	return false
}

drain_conv :: proc "contextless" (arg: rawptr, buf: []u8) -> int {
	return conv_pop(int(uintptr(arg)), buf)
}

// -- What the files say -------------------------------------------------------

// render_conv writes one of a conversation's text files.
render_conv :: proc "contextless" (sink: ^libodin.Sink, i: int, kind: i32) #no_bounds_check {
	c := &convs[i]
	switch kind {
	case CONV_LOCAL:
		put_ip(sink, my_ip)
		libodin.put_str(sink, "!")
		libodin.put_uint(sink, u64(c.lport))
		libodin.put_str(sink, "\n")
	case CONV_REMOTE:
		if c.connected {
			put_ip(sink, c.raddr)
			libodin.put_str(sink, "!")
			libodin.put_uint(sink, u64(c.rport))
		}
		libodin.put_str(sink, "\n")
	case CONV_STATUS:
		libodin.put_str(sink, c.connected ? "Connected" : (c.announced ? "Announced" : "Open"))
		libodin.put_str(sink, " queued ")
		libodin.put_uint(sink, u64(conv_queued(i)))
		libodin.put_str(sink, "\n")
	}
}
