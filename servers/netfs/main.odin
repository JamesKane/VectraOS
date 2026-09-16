/*
netfs -- the IPv4 stack, in ring 3, serving `/net`.

`docs/FLEET.md` step 0 makes the network a file server. The card is the
kernel's, as `#E` at `/dev/ether`. Everything above it is here: ARP, IPv4 and
ICMP over `sys/libnet`'s wire formats, and the `/net` files a program reads.
This is `consrv`'s shape, the one `sys/libthread` gives a server that waits on
two things:

    the ether thread  reads /dev/ether0/data through an io proc, and every
                      frame that arrives is answered, cached or counted
    the serve loop    `lib9p.serve`: a frame through its own io proc, the
                      handler, the reply

**Nothing here is locked.** Threads of one proc touch the ARP table, the
counters and the fid table, and a thread runs until it blocks.

**What it does today.** It answers an ARP request for its own address, so the
network can find it. It resolves an address by ARP and remembers it, and it
answers an ICMP echo, so it can be pinged. At start it asks for the gateway's
address and pings it, which proves a stack in ring 3 reaches the world through a
file. TCP and UDP conversations, `cs` and the rest of the `/net` tree are the
steps after this one.

    /net/etherN/addr   a card's hardware address
    /net/etherN/stats  frames each way on it, and what became of them
    /net/ipifc/N/      an interface's ctl and status; /net/iproute; /net/ndb
    /net/arp           the addresses this machine has resolved
    /net/icmp/         conversations, as udp's, and `stats` for the probe

The address is static, QEMU's guest, until `cmd/ipconfig` asks for one.
*/
package netfs

import "base:runtime"

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

// The tree.
NODE_ROOT :: i32(0)
NODE_ARP :: i32(3)
NODE_ICMP :: i32(4)
NODE_UDP :: i32(5) // The udp directory
NODE_CLONE :: i32(6) // udp/clone

/*
A conversation's five files are numbered from `CONV_BASE`, a stride apart, so a
node says which conversation and which file in one number. `conv_of` reads it
back, and a node past the conversations this server has is not a node.
*/
CONV_BASE :: i32(16)
CONV_STRIDE :: i32(8)
CONV_DIR :: i32(0)
CONV_CTL :: i32(1)
CONV_DATA :: i32(2)
CONV_LOCAL :: i32(3)
CONV_REMOTE :: i32(4)
CONV_STATUS :: i32(5)

conv_node :: proc "contextless" (i: int, kind: i32) -> i32 {
	return CONV_BASE + i32(i) * CONV_STRIDE + kind
}

NODE_TCP :: i32(7) // The tcp directory
NODE_TCLONE :: i32(8) // tcp/clone
NODE_SYSNAME :: i32(9) // This machine's name, from the record its card matched
NODE_LOCAL :: i32(10) // This machine's own address, resolved from ndb
NODE_ICLONE :: i32(11) // icmp/clone
NODE_ISTATS :: i32(12) // icmp/stats
NODE_NDB :: i32(13) // What ipconfig learned
NODE_IPROUTE :: i32(14) // The route table
NODE_IPIFC :: i32(15) // The ipifc directory; 16 on is CONV_BASE, the conversations

/*
An interface has two directories: `/net/etherN`, the card with its address
and counts, and `/net/ipifc/N`, its control and status. Each is numbered from
its own base, a stride apart, the way the conversations are.
*/
ETHER_BASE :: i32(1024)
ETHER_DIR :: i32(0)
ETHER_ADDR :: i32(1)
ETHER_STATS :: i32(2)
IFC_BASE :: i32(2048)
IFC_DIR :: i32(0)
IFC_CTL :: i32(1)
IFC_STATUS :: i32(2)
IFC_STRIDE :: i32(4)

ether_node :: proc "contextless" (i: int, kind: i32) -> i32 {
	return ETHER_BASE + i32(i) * IFC_STRIDE + kind
}

ether_of :: proc "contextless" (node: i32) -> (i: int, kind: i32, ok: bool) {
	if node < ETHER_BASE || node >= IFC_BASE {
		return 0, 0, false
	}
	v := node - ETHER_BASE
	i = int(v / IFC_STRIDE)
	kind = v % IFC_STRIDE
	if i >= ifc_count || kind > ETHER_STATS {
		return 0, 0, false
	}
	return i, kind, true
}

ifc_node :: proc "contextless" (i: int, kind: i32) -> i32 {
	return IFC_BASE + i32(i) * IFC_STRIDE + kind
}

ifc_of :: proc "contextless" (node: i32) -> (i: int, kind: i32, ok: bool) {
	if node < IFC_BASE {
		return 0, 0, false
	}
	v := node - IFC_BASE
	i = int(v / IFC_STRIDE)
	kind = v % IFC_STRIDE
	if i >= ifc_count || kind > IFC_STATUS {
		return 0, 0, false
	}
	return i, kind, true
}

// TCP's conversations are numbered from their own base, far enough past UDP's
// that the two never decode as each other.
TCONV_BASE :: i32(128)
TCONV_STRIDE :: i32(8)
TCONV_DIR :: i32(0)
TCONV_CTL :: i32(1)
TCONV_DATA :: i32(2)
TCONV_LOCAL :: i32(3)
TCONV_REMOTE :: i32(4)
TCONV_STATUS :: i32(5)
TCONV_LISTEN :: i32(6)

tconv_node :: proc "contextless" (i: int, kind: i32) -> i32 {
	return TCONV_BASE + i32(i) * TCONV_STRIDE + kind
}

tconv_of :: proc "contextless" (node: i32) -> (i: int, kind: i32, ok: bool) {
	if node < TCONV_BASE {
		return 0, 0, false
	}
	v := node - TCONV_BASE
	i = int(v / TCONV_STRIDE)
	kind = v % TCONV_STRIDE
	if i >= MAX_TCP || kind > TCONV_LISTEN {
		return 0, 0, false
	}
	return i, kind, true
}

conv_of :: proc "contextless" (node: i32) -> (i: int, kind: i32, ok: bool) {
	if node < CONV_BASE {
		return 0, 0, false
	}
	v := node - CONV_BASE
	i = int(v / CONV_STRIDE)
	kind = v % CONV_STRIDE
	if i >= MAX_CONV || kind > CONV_STATUS {
		return 0, 0, false
	}
	return i, kind, true
}

FRAME :: 1200

fids: libuser.Fid_Table
srv: lib9p.Srv

// One frame out, built here and written to a card. A datagram's payload is
// the largest thing it carries.
out: [2048]u8


/*
_start opens every card's files and hands the process to the thread library.
The opens come first because the descriptor table is shared, and an io proc
holds the number. 0x74 is no card that would open, which is a machine with no
`#E` and so no network for this server to serve.
*/
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()

	if open_ifcs() == 0 {
		libuser.exit(0x74)
	}
	libthread.main(threadmain, nil)
}

/*
threadmain posts the service, starts an ether thread per interface, asks for
the gateway's address, and then serves until something stops it. The ARP goes
out after the ether threads are reading, so the reply has somewhere to land.
*/
threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	fd, perr := libuser.post("/srv/net")
	if perr < 0 {
		libthread.threadexitsall("post")
	}
	srv = lib9p.Srv {
		fd      = fd,
		handler = handler,
		msize   = FRAME,
	}
	// The names, before anything can ask for one, and then each interface's
	// own address out of them.
	ndb_load()
	resolve_addresses()

	for i in 0 ..< ifc_count {
		if libthread.threadcreate(ether_thread, rawptr(uintptr(i))) < 0 {
			libthread.threadexitsall("threadcreate")
		}
	}

	// Ask who has the gateway, when a link of ours reaches it. The reply
	// arrives at that interface's ether thread, which remembers it and sends
	// the echo that follows.
	probe_gateway()

	_, why := lib9p.serve(&srv)
	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

/*
ether_thread is one card's whole life: a read of its `data` through an io proc,
and what arrives handed to the stack. The read parks in the kernel until a
frame comes or its bound passes. An empty answer is a reason to ask again
rather than a failure. The first interface's thread is the one that winds the
clock, so two cards do not make the rounds twice as short.
*/
ether_thread :: proc "contextless" (arg: rawptr) {
	i := int(uintptr(arg))
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexitsall("ioproc")
	}
	frame: [2048]u8
	for {
		n := libthread.ioread(io, ifcs[i].fd, frame[:])
		drain_wakes()
		if n <= 0 {
			/*
			The read reached its bound with nothing on the card, which is one
			round of the stack's coarse clock. The clock is wound only here,
			never on a pass that carried a frame. A round is then a span the
			device sets. Winding it on every pass would shrink the round as
			traffic grew, and fire a retransmit soonest when the network was
			busiest.
			*/
			if i == 0 {
				tcp_tick()
			}
			drain_wakes()
			continue
		}
		take(i, frame[:int(n)])
		drain_wakes()
	}
}

/*
Held reads are answered from the ether thread, never from a handler.

A reply must not go out while the serve loop is part way through a request. The
loopback is where that would happen: a connect's own write drives the accept
that answers a listen read. The serve loop would then write one reply while
owing another, into a pipe a held read's note-poll is already filling. Both
directions can stall.

So a protocol never answers a held read itself. It raises a flag here, and the
ether thread lowers it between frames. The serve loop is parked in `ioread`
then, and the reply buffer is no one else's. This is the shape `consrv` and
`servers/intuition` keep: the thread that reads the device is the one that
answers what the device's arrivals unblock.
*/
wake_udp: [MAX_CONV]bool
wake_tcp: [MAX_TCP]bool
wake_listen: [MAX_TCP]bool
wake_connect: [MAX_TCP]bool
wake_write: [MAX_TCP]bool

// drain_wakes answers every held read a protocol raised a flag for. The ether
// thread calls it, and nothing else does.
drain_wakes :: proc "contextless" () #no_bounds_check {
	for i in 0 ..< MAX_CONV {
		if wake_udp[i] {
			wake_udp[i] = false
			answer_conv(i)
		}
	}
	for i in 0 ..< MAX_TCP {
		if wake_tcp[i] {
			wake_tcp[i] = false
			answer_tcp(i)
		}
		if wake_listen[i] {
			wake_listen[i] = false
			answer_listen(i)
		}
		if wake_connect[i] {
			wake_connect[i] = false
			answer_connect(i)
		}
		if wake_write[i] {
			wake_write[i] = false
			answer_write(i)
		}
	}
}

// -- The stack ----------------------------------------------------------------

/*
What became of a datagram handed to `ip_output`. `Sent` reached the wire or
was delivered here. `Held` waits on an ARP reply and goes out when it comes,
or not at all, which for a datagram is as good as sent. `Dropped` is a card
that would not take it, or a destination no route covers. TCP counts a
retransmit only on `Sent`; UDP and ICMP fail a write only on `Dropped`.
*/
Output :: enum {
	Sent,
	Held,
	Dropped,
}

/*
ip_output sends one datagram to `dst`, and is the only place that decides how.

A datagram for one of this machine's own addresses is delivered here and never
reaches a card, which is the loopback. One for the broadcast address goes to
every station on the interface it is bound to, `bound`, or the first one, with
no address to resolve. Anything else takes the route: an interface, and a next
hop that is the destination on its own link or a gateway otherwise. The ARP
table holds the hop's hardware address or it does not, and a miss asks for it
and holds this datagram for the reply, the way Plan 9's `Arpent` does. Every
protocol above hands over a body and a number, and none of them frames.

This owns `out`. The loopback path does not touch it, so a datagram delivered
inside this call cannot overwrite a frame being built further up.
*/
ip_output :: proc "contextless" (dst: libnet.IP, proto: u8, body: []u8, bound := -1) -> Output #no_bounds_check {
	if k := ifc_holding(dst); k >= 0 {
		ip_deliver(k, dst, dst, proto, body)
		return .Sent
	}
	if dst == BROADCAST {
		i := bound >= 0 && bound < ifc_count ? bound : 0
		return emit(i, BROADCAST_MAC, dst, proto, body)
	}
	i, hop, ok := route(dst)
	if !ok {
		return .Dropped
	}
	mac, known := libnet.arp_lookup(&ifcs[i].arp, hop)
	if !known {
		hold_pending(i, hop, dst, proto, body)
		send_arp_request(i, hop)
		return .Held
	}
	return emit(i, mac, dst, proto, body)
}

// emit frames one datagram from interface `i` to hardware address `mac` and
// writes it to the card.
emit :: proc "contextless" (i: int, mac: libnet.MAC, dst: libnet.IP, proto: u8, body: []u8) -> Output #no_bounds_check {
	f := &ifcs[i]
	at := libnet.put_eth(out[:], mac, f.mac, libnet.ETHERTYPE_IPV4)
	body_at := libnet.put_ipv4(out[:], at, f.ip, dst, proto, len(body), 0)
	copy(out[body_at:], body)
	end := body_at + len(body)
	f.frames_out += 1
	return libuser.write(f.fd, out[:end]) == i64(end) ? .Sent : .Dropped
}

/*
hold_pending keeps one datagram for a hop whose address is not yet known. A
datagram already waiting for that hop is replaced, so the newest is the one
that goes. When every slot is busy with a different hop, the oldest by
eviction turn gives way.
*/
hold_pending :: proc "contextless" (i: int, hop, dst: libnet.IP, proto: u8, body: []u8) #no_bounds_check {
	f := &ifcs[i]
	if len(body) > len(f.pending[0].body) {
		return
	}
	slot := -1
	for k in 0 ..< PENDING_SLOTS {
		if f.pending[k].have && f.pending[k].hop == hop {
			slot = k
			break
		}
	}
	if slot < 0 {
		for k in 0 ..< PENDING_SLOTS {
			if !f.pending[k].have {
				slot = k
				break
			}
		}
	}
	if slot < 0 {
		slot = f.pending_evict
		f.pending_evict = (f.pending_evict + 1) % PENDING_SLOTS
	}
	p := &f.pending[slot]
	p.have = true
	p.hop = hop
	p.dst = dst
	p.proto = proto
	p.blen = len(body)
	copy(p.body[:], body)
}

/*
flush_pending sends the datagrams whose hops a reply has now taught interface
`i`. It runs after each received frame, so a reply or a passively learned
address both release whatever was waiting on it. A slot whose hop is still
unknown keeps waiting.
*/
flush_pending :: proc "contextless" (i: int) #no_bounds_check {
	f := &ifcs[i]
	for k in 0 ..< PENDING_SLOTS {
		p := &f.pending[k]
		if !p.have {
			continue
		}
		mac, known := libnet.arp_lookup(&f.arp, p.hop)
		if !known {
			continue
		}
		p.have = false
		_ = emit(i, mac, p.dst, p.proto, p.body[:p.blen])
	}
}

/*
ip_deliver hands one datagram's body to the protocol it belongs to. It is the
demultiplexer both ways in: a datagram off a card arrives here, and so does one
this machine addressed to itself. `dst` is what the header named, which a
transport's checksum covers and a listener may care about.
*/
ip_deliver :: proc "contextless" (ifc: int, src, dst: libnet.IP, proto: u8, body: []u8) {
	switch proto {
	case libnet.IPPROTO_UDP:
		if u, ok := libnet.parse_udp(body, src, dst); ok {
			udp_deliver(src, dst, u.sport, u.dport, u.payload)
		}
	case libnet.IPPROTO_TCP:
		tcp_input(src, dst, body)
	case libnet.IPPROTO_ICMP:
		icmp_in(src, body)
	}
	_ = ifc
}

// take is one received frame on interface `i`, and what this stack makes of it.
take :: proc "contextless" (i: int, frame: []u8) #no_bounds_check {
	ifcs[i].frames_in += 1
	switch libnet.eth_type(frame) {
	case libnet.ETHERTYPE_ARP:
		take_arp(i, frame)
	case libnet.ETHERTYPE_IPV4:
		take_ipv4(i, frame)
	}
	// A reply, or an address learned from any frame, may release a waiter.
	flush_pending(i)
}

/*
take_arp answers a request for this interface's address and remembers what a
reply tells it. A reply for the gateway is also the cue to send the echo. There
is an address to send it to now.
*/
take_arp :: proc "contextless" (i: int, frame: []u8) #no_bounds_check {
	if len(frame) < libnet.ETH_HDR + libnet.ARP_LEN {
		return
	}
	a, ok := libnet.parse_arp(frame[libnet.ETH_HDR:])
	if !ok {
		return
	}
	f := &ifcs[i]
	// Whoever spoke, we now know their address.
	libnet.arp_insert(&f.arp, a.spa, a.sha)

	switch a.op {
	case libnet.ARP_REQUEST:
		if f.ip != ANY && a.tpa == f.ip {
			at := libnet.put_eth(out[:], a.sha, f.mac, libnet.ETHERTYPE_ARP)
			at = libnet.put_arp(out[:], at, libnet.Arp{
				op  = libnet.ARP_REPLY,
				sha = f.mac,
				spa = f.ip,
				tha = a.sha,
				tpa = a.spa,
			})
			f.frames_out += 1
			_ = libuser.write(f.fd, out[:at])
		}
	case libnet.ARP_REPLY:
		if gw, has := default_gateway(); has && a.spa == gw && echo_sent == 0 {
			send_echo(gw)
		}
	}
}

/*
take_ipv4 takes one datagram off interface `i`'s card. A datagram for another
address is not this machine's business, and there is no forwarding here to
pass it on. An interface with no address yet takes everything the card gives
it: the answer to its own request for one names an address it does not have.

Whoever sent it, this interface now knows where they are. An address seen on a
frame goes into the ARP table, so a reply needs no request first. That is how a
ping from a machine this one has never spoken to is answered.
*/
take_ipv4 :: proc "contextless" (i: int, frame: []u8) #no_bounds_check {
	if len(frame) < libnet.ETH_HDR + libnet.IPV4_HDR {
		return
	}
	f := &ifcs[i]
	pkt := frame[libnet.ETH_HDR:]
	h, ok := libnet.parse_ipv4(pkt)
	if !ok {
		f.ip_bad += 1
		return
	}
	if f.ip != ANY && h.dst != f.ip && h.dst != BROADCAST {
		f.ip_not_mine += 1
		return
	}
	if h.total > len(pkt) || h.total < h.hdr_len {
		f.ip_bad += 1
		return
	}
	f.ip_in += 1
	libnet.arp_insert(&f.arp, h.src, libnet.eth_src(frame))
	ip_deliver(i, h.src, h.dst, h.proto, pkt[h.hdr_len:h.total])
}

/*
probe_gateway asks for the default gateway's hardware address, once, when a
link of this machine's reaches it. At start, when the database gave an
interface an address on the gateway's link; otherwise when `ipconfig` or a
route written by hand makes one. The reply is the cue for the echo that proves
a datagram crosses.
*/
probe_gateway :: proc "contextless" () {
	if echo_sent != 0 {
		return
	}
	if gw, has := default_gateway(); has {
		if i := on_link(gw); i >= 0 {
			send_arp_request(i, gw)
		}
	}
}

// send_arp_request asks interface `i`'s link who has `who`, as a broadcast.
send_arp_request :: proc "contextless" (i: int, who: libnet.IP) #no_bounds_check {
	f := &ifcs[i]
	n := libnet.build_arp_request(out[:], f.mac, f.ip, who)
	f.arp_asked += 1
	f.frames_out += 1
	_ = libuser.write(f.fd, out[:n])
}

// -- The files ----------------------------------------------------------------

// render writes a file's whole contents into `into` and answers its length.
render :: proc "contextless" (node: i32, into: []u8) -> int #no_bounds_check {
	sink := libodin.sink_from(into)
	switch node {
	case NODE_ARP:
		render_arp(&sink)
	case NODE_SYSNAME:
		libodin.put_str(&sink, string(sysname[:sysname_len]))
	case NODE_LOCAL:
		put_ip(&sink, primary_ip())
		libodin.put_str(&sink, "\n")
	case NODE_IPROUTE:
		render_routes(&sink)
	case NODE_NDB:
		libodin.put_str(&sink, string(ndb_note[:ndb_note_len]))
	case NODE_ISTATS:
		libodin.put_str(&sink, "sent ")
		libodin.put_uint(&sink, u64(echo_sent))
		libodin.put_str(&sink, " received ")
		libodin.put_uint(&sink, u64(echo_recv))
		libodin.put_str(&sink, " answered ")
		libodin.put_uint(&sink, u64(echo_answered))
		libodin.put_str(&sink, " delivered ")
		libodin.put_uint(&sink, u64(icmp_delivered))
		libodin.put_str(&sink, " unclaimed ")
		libodin.put_uint(&sink, u64(icmp_unclaimed))
		libodin.put_str(&sink, " bad ")
		libodin.put_uint(&sink, u64(icmp_bad))
		libodin.put_str(&sink, "\n")
	case:
		if i, kind, ok := tconv_of(node); ok {
			render_tconv(&sink, i, kind)
		} else if j, k2, ok2 := conv_of(node); ok2 {
			render_conv(&sink, j, k2)
		} else if e, ek, eok := ether_of(node); eok {
			if ek == ETHER_ADDR {
				put_mac(&sink, ifcs[e].mac)
				libodin.put_str(&sink, "\n")
			} else if ek == ETHER_STATS {
				render_ether_stats(&sink, e)
			}
		} else if f, fk, fok := ifc_of(node); fok && fk == IFC_STATUS {
			render_ifc_status(&sink, f)
		}
	}
	return len(libodin.str(&sink))
}

put_ip :: proc "contextless" (sink: ^libodin.Sink, ip: libnet.IP) {
	for i in 0 ..< 4 {
		if i > 0 {
			libodin.put_str(sink, ".")
		}
		libodin.put_uint(sink, u64(ip[i]))
	}
}

put_mac :: proc "contextless" (sink: ^libodin.Sink, mac: libnet.MAC) {
	m := mac
	libodin.put_mac(sink, m[:])
}

// -- The tree -----------------------------------------------------------------

is_dir :: proc "contextless" (node: i32) -> bool {
	if node == NODE_ROOT || node == NODE_UDP || node == NODE_TCP || node == NODE_ICMP || node == NODE_IPIFC {
		return true
	}
	if _, kind, ok := tconv_of(node); ok {
		return kind == TCONV_DIR
	}
	if _, kind, ok := ether_of(node); ok {
		return kind == ETHER_DIR
	}
	if _, kind, ok := ifc_of(node); ok {
		return kind == IFC_DIR
	}
	_, kind, ok := conv_of(node)
	return ok && kind == CONV_DIR
}

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if is_dir(node) {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	if name == "." {
		return from
	}
	if name == ".." {
		return parent_of(from)
	}
	switch from {
	case NODE_ROOT:
		if i, ok := ether_name(name); ok {
			return ether_node(i, ETHER_DIR)
		}
		switch name {
		case "ipifc":
			return NODE_IPIFC
		case "iproute":
			return NODE_IPROUTE
		case "sysname":
			return NODE_SYSNAME
		case "ndb":
			return NODE_NDB
		case "arp":
			return NODE_ARP
		case "icmp":
			return NODE_ICMP
		case "udp":
			return NODE_UDP
		case "tcp":
			return NODE_TCP
		case "local":
			return NODE_LOCAL
		}
	case NODE_IPIFC:
		if v, _, ok := scan_uint(name); ok && int(v) < ifc_count {
			return ifc_node(int(v), IFC_DIR)
		}
	case NODE_UDP, NODE_ICMP:
		proto := from == NODE_UDP ? Proto.UDP : Proto.ICMP
		if name == "clone" {
			return from == NODE_UDP ? NODE_CLONE : NODE_ICLONE
		}
		if name == "stats" && from == NODE_ICMP {
			return NODE_ISTATS
		}
		// A number names a conversation that exists, of this protocol.
		if v, _, ok := scan_uint(name); ok {
			i := int(v)
			if i < MAX_CONV && convs[i].used && convs[i].proto == proto {
				return conv_node(i, CONV_DIR)
			}
		}
	}
	if from == NODE_TCP {
		if name == "clone" {
			return NODE_TCLONE
		}
		if v, _, ok := scan_uint(name); ok {
			i := int(v)
			if i < MAX_TCP && tcps[i].used {
				return tconv_node(i, TCONV_DIR)
			}
		}
		return -1
	}
	// Inside an interface's two directories.
	if i, kind, ok := ether_of(from); ok && kind == ETHER_DIR {
		switch name {
		case "addr":
			return ether_node(i, ETHER_ADDR)
		case "stats":
			return ether_node(i, ETHER_STATS)
		}
		return -1
	}
	if i, kind, ok := ifc_of(from); ok && kind == IFC_DIR {
		switch name {
		case "ctl":
			return ifc_node(i, IFC_CTL)
		case "status":
			return ifc_node(i, IFC_STATUS)
		}
		return -1
	}
	// Inside a TCP conversation's directory.
	if i, kind, ok := tconv_of(from); ok && kind == TCONV_DIR {
		switch name {
		case "ctl":
			return tconv_node(i, TCONV_CTL)
		case "data":
			return tconv_node(i, TCONV_DATA)
		case "listen":
			return tconv_node(i, TCONV_LISTEN)
		case "local":
			return tconv_node(i, TCONV_LOCAL)
		case "remote":
			return tconv_node(i, TCONV_REMOTE)
		case "status":
			return tconv_node(i, TCONV_STATUS)
		}
		return -1
	}
	// Inside a UDP conversation's directory.
	if i, kind, ok := conv_of(from); ok && kind == CONV_DIR {
		switch name {
		case "ctl":
			return conv_node(i, CONV_CTL)
		case "data":
			return conv_node(i, CONV_DATA)
		case "local":
			return conv_node(i, CONV_LOCAL)
		case "remote":
			return conv_node(i, CONV_REMOTE)
		case "status":
			return conv_node(i, CONV_STATUS)
		}
	}
	return -1
}

// ether_name reads `etherN` for an interface this stack has.
ether_name :: proc "contextless" (name: string) -> (int, bool) {
	if len(name) != 6 || name[:5] != "ether" || name[5] < '0' || name[5] > '9' {
		return 0, false
	}
	i := int(name[5] - '0')
	return i, i < ifc_count
}

// proto_dir is the directory a conversation of `proto` lives under.
proto_dir :: proc "contextless" (proto: Proto) -> i32 {
	return proto == .UDP ? NODE_UDP : NODE_ICMP
}

// parent_of is where `..` goes from any node in the tree.
parent_of :: proc "contextless" (node: i32) -> i32 {
	if i, kind, ok := ether_of(node); ok {
		return kind == ETHER_DIR ? NODE_ROOT : ether_node(i, ETHER_DIR)
	}
	if i, kind, ok := ifc_of(node); ok {
		return kind == IFC_DIR ? NODE_IPIFC : ifc_node(i, IFC_DIR)
	}
	if node == NODE_CLONE {
		return NODE_UDP
	}
	if node == NODE_TCLONE {
		return NODE_TCP
	}
	if node == NODE_ICLONE || node == NODE_ISTATS {
		return NODE_ICMP
	}
	if i, kind, ok := tconv_of(node); ok {
		return kind == TCONV_DIR ? NODE_TCP : tconv_node(i, TCONV_DIR)
	}
	if i, kind, ok := conv_of(node); ok {
		return kind == CONV_DIR ? proto_dir(convs[i].proto) : conv_node(i, CONV_DIR)
	}
	return NODE_ROOT
}

// -- The handler --------------------------------------------------------------

handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state
	_ = s
	_ = tag

	if !libuser.default_reply(request, reply) {
		return
	}

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)

	case vectra9.Tattach:
		libuser.attach(&fids, m, reply, NODE_ROOT, qid_of)

	case vectra9.Twalk:
		libuser.walk(&fids, m, reply, step, qid_of)

	case vectra9.Tlopen:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		libuser.fid_open(&fids, m.fid)
		// A descriptor on a conversation's file counts against its life, so the
		// conversation is not reclaimed while a program still holds one.
		if i, _, is_tcp := tconv_of(node); is_tcp && tcps[i].used {
			tcps[i].refs += 1
		}
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Tread:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		if is_dir(node) {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}

		/*
		A read of any protocol's `clone` takes a conversation and answers
		its number. It is the only read here with a side effect, and the whole
		of how a caller gets a conversation. The protocols answer it the same
		way, so they answer it in one place.
		*/
		if node == NODE_CLONE || node == NODE_TCLONE || node == NODE_ICLONE {
			if m.offset > 0 {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			i := -1
			switch node {
			case NODE_TCLONE:
				i = tcp_alloc()
			case NODE_CLONE:
				i = conv_alloc(.UDP)
			case NODE_ICLONE:
				i = conv_alloc(.ICMP)
			}
			if i < 0 {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			line: [16]u8
			csink := libodin.sink_from(line[:])
			libodin.put_uint(&csink, u64(i))
			libodin.put_str(&csink, "\n")
			text := libodin.str(&csink)
			room := min(min(len(buf), int(m.count)), len(text))
			copy(buf[:room], text[:room])
			reply^ = vectra9.Rread{data = buf[:room]}
			return
		}

		/*
		A TCP conversation's `data` takes what the stream holds, or is held
		until some arrives. A stream whose far end closed, with nothing left,
		answers empty, which is the end of file a reader waits for. `listen` is
		the same shape over the backlog.
		*/
		if i, kind, is_tcp := tconv_of(node); is_tcp {
			room := min(len(buf), int(m.count))
			if room <= 0 {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			if kind == TCONV_DATA {
				got := drain_tcp(rawptr(uintptr(i)), buf[:room])
				if got > 0 {
					reply^ = vectra9.Rread{data = buf[:got]}
					return
				}
				if got < 0 {
					// The far end has closed with nothing left: end of file.
					reply^ = vectra9.Rread{data = nil}
					return
				}
				lib9p.hold(&srv)
				return
			}
			if kind == TCONV_LISTEN {
				got := drain_listen(rawptr(uintptr(i)), buf[:room])
				if got > 0 {
					reply^ = vectra9.Rread{data = buf[:got]}
					return
				}
				lib9p.hold(&srv)
				return
			}
		}

		// A read of a conversation's `data` takes the oldest datagram, or is
		// held until one arrives for it.
		if i, kind, is_conv := conv_of(node); is_conv && kind == CONV_DATA {
			room := min(len(buf), int(m.count))
			if room <= 0 {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			got := conv_pop(i, buf[:room])
			if got > 0 {
				reply^ = vectra9.Rread{data = buf[:got]}
				return
			}
			lib9p.hold(&srv)
			return
		}

		// Every other file here is small and made on demand, so a read renders
		// it whole and answers the window the offset names.
		whole: [1024]u8 = ---
		size := render(node, whole[:])
		off := int(m.offset)
		if off >= size {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		room := min(min(len(buf), int(m.count)), size - off)
		copy(buf[:room], whole[off:off + room])
		reply^ = vectra9.Rread{data = buf[:room]}

	case vectra9.Twrite:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		if i, kind, is_tcp := tconv_of(node); is_tcp {
			switch kind {
			case TCONV_CTL:
				// A `connect` is held until the handshake settles. The write
				// is then synchronous: it returns when the conversation is
				// established, and `answer_connect` is what answers it.
				switch run_tcp_ctl(i, string(m.data)) {
				case .Connecting:
					lib9p.hold(&srv)
				case .Done:
					reply^ = vectra9.Rwrite{count = u32(len(m.data))}
				case .Bad:
					reply^ = vectra9.error_reply(vectra9.EINVAL)
				}
			case TCONV_DATA:
				// The write returns the bytes the window and the retransmit
				// queue let through. A write that got none is held until an
				// acknowledgement makes room. A stream blocks a writer there,
				// rather than lose what it could not take or spin it on a
				// zero-length write.
				sent := tcp_write(i, m.data)
				if sent < 0 {
					reply^ = vectra9.error_reply(vectra9.EIO)
					return
				}
				if sent == 0 && len(m.data) > 0 {
					lib9p.hold(&srv)
					return
				}
				reply^ = vectra9.Rwrite{count = u32(sent)}
			case:
				reply^ = vectra9.error_reply(vectra9.EPERM)
			}
			return
		}
		// The interface and route controls, and the note ipconfig leaves.
		if node == NODE_IPROUTE || node == NODE_NDB {
			ok2 := node == NODE_IPROUTE ? route_ctl(string(m.data)) : ndb_set(m.data)
			if !ok2 {
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
			return
		}
		if f, fk, fok := ifc_of(node); fok {
			if fk != IFC_CTL || !ifc_ctl(f, string(m.data)) {
				reply^ = vectra9.error_reply(fk == IFC_CTL ? vectra9.EINVAL : vectra9.EPERM)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
			return
		}
		i, kind, is_conv := conv_of(node)
		if !is_conv {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		switch kind {
		case CONV_CTL:
			if !run_ctl(i, string(m.data)) {
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case CONV_DATA:
			if !conv_send(i, m.data) {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case:
			reply^ = vectra9.error_reply(vectra9.EPERM)
		}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := is_dir(node)
		size := u64(0)
		if !dir {
			whole: [1024]u8 = ---
			size = u64(render(node, whole[:]))
		}
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100444,
			nlink   = dir ? 2 : 1,
			size    = size,
			blksize = 512,
		}

	case vectra9.Tclunk:
		// A descriptor on a conversation's file is going away. It stops counting
		// against the conversation's life, so a finished one can be reclaimed.
		// A listener is freed the moment its `listen` file is clunked, on
		// purpose or by exiting. A program holds that file open to keep the
		// accepting role, the way Plan 9 holds a conversation open through a
		// file. Letting it go ends the role, so no conversation is left
		// answering SYNs that nothing will accept.
		node := libuser.fid_lookup(&fids, m.fid)
		held_open := libuser.fid_is_open(&fids, m.fid)
		libuser.fid_release(&fids, m.fid)
		if held_open {
			if i, kind, ok := tconv_of(node); ok && tcps[i].used {
				if tcps[i].refs > 0 {
					tcps[i].refs -= 1
				}
				if kind == TCONV_LISTEN && tcps[i].state == .Listen {
					tcp_release(i)
				}
			}
		}
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	if !is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])

	// A protocol's directory is a listing that changes: `clone`, and then a
	// numbered entry per conversation that exists.
	if node == NODE_UDP || node == NODE_TCP || node == NODE_ICMP {
		readdir_conv_dir(m, reply, &c, node)
		return
	}

	names: []string
	nodes: []i32
	switch {
	case node == NODE_ROOT:
		root_names := [?]string{"ether0", "ether1", "arp", "icmp", "udp", "tcp", "local", "sysname", "ipifc", "iproute", "ndb"}
		root_nodes := [?]i32{ether_node(0, ETHER_DIR), ether_node(1, ETHER_DIR), NODE_ARP, NODE_ICMP, NODE_UDP, NODE_TCP, NODE_LOCAL, NODE_SYSNAME, NODE_IPIFC, NODE_IPROUTE, NODE_NDB}
		// A second card that is not there is not listed.
		skip := ifc_count < 2 ? 1 : 0
		names = ifc_count < 2 ? root_names[1:] : root_names[:]
		nodes = ifc_count < 2 ? root_nodes[1:] : root_nodes[:]
		if skip == 1 {
			names[0] = "ether0"
			nodes[0] = ether_node(0, ETHER_DIR)
		}
	case node == NODE_IPIFC:
		ifc_names := [?]string{"0", "1"}
		ifc_nodes := [?]i32{ifc_node(0, IFC_DIR), ifc_node(1, IFC_DIR)}
		names = ifc_names[:ifc_count]
		nodes = ifc_nodes[:ifc_count]
	case:
		if e, _, is_ether := ether_of(node); is_ether {
			names = []string{"addr", "stats"}
			nodes = []i32{ether_node(e, ETHER_ADDR), ether_node(e, ETHER_STATS)}
		} else if f, _, is_ifc := ifc_of(node); is_ifc {
			names = []string{"ctl", "status"}
			nodes = []i32{ifc_node(f, IFC_CTL), ifc_node(f, IFC_STATUS)}
		} else if tconv, _, is_tcp := tconv_of(node); is_tcp {
			names = []string{"ctl", "data", "listen", "local", "remote", "status"}
			nodes = []i32{
				tconv_node(tconv, TCONV_CTL),
				tconv_node(tconv, TCONV_DATA),
				tconv_node(tconv, TCONV_LISTEN),
				tconv_node(tconv, TCONV_LOCAL),
				tconv_node(tconv, TCONV_REMOTE),
				tconv_node(tconv, TCONV_STATUS),
			}
		} else {
			conv, _, _ := conv_of(node)
			names = []string{"ctl", "data", "local", "remote", "status"}
			nodes = []i32{
				conv_node(conv, CONV_CTL),
				conv_node(conv, CONV_DATA),
				conv_node(conv, CONV_LOCAL),
				conv_node(conv, CONV_REMOTE),
				conv_node(conv, CONV_STATUS),
			}
		}
	}
	for i := int(m.offset); i < len(names); i += 1 {
		if vectra9.remaining(&c) < vectra9.dirent_size(names[i]) {
			break
		}
		t := is_dir(nodes[i]) ? vectra9.DT_DIR : vectra9.DT_REG
		vectra9.put_dirent(
			&c,
			vectra9.Dirent{qid = qid_of(nodes[i]), offset = u64(i + 1), type = t, name = names[i]},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}

/*
readdir_conv_dir lists a protocol's directory: `clone` first, `stats` after it
for icmp, and then one entry per conversation that exists, named by its number.
The offset counts entries, so the fixed files come first and conversation `n`
is entry `n` past them. Every protocol has the same directory, so all are
listed here.
*/
readdir_conv_dir :: proc "contextless" (
	m: vectra9.Treaddir,
	reply: ^vectra9.Msg,
	c: ^vectra9.Cursor,
	dir: i32,
) #no_bounds_check {
	fixed_names: []string
	fixed_nodes: []i32
	switch dir {
	case NODE_TCP:
		fixed_names = []string{"clone"}
		fixed_nodes = []i32{NODE_TCLONE}
	case NODE_UDP:
		fixed_names = []string{"clone"}
		fixed_nodes = []i32{NODE_CLONE}
	case:
		fixed_names = []string{"clone", "stats"}
		fixed_nodes = []i32{NODE_ICLONE, NODE_ISTATS}
	}
	fixed := len(fixed_names)
	for i := int(m.offset); i < fixed; i += 1 {
		if vectra9.remaining(c) < vectra9.dirent_size(fixed_names[i]) {
			break
		}
		vectra9.put_dirent(
			c,
			vectra9.Dirent{qid = qid_of(fixed_nodes[i]), offset = u64(i + 1), type = vectra9.DT_REG, name = fixed_names[i]},
		)
	}
	is_tcp := dir == NODE_TCP
	last := is_tcp ? MAX_TCP : MAX_CONV
	name: [16]u8
	for i := max(int(m.offset) - fixed, 0); i < last; i += 1 {
		used := is_tcp ? tcps[i].used : (convs[i].used && proto_dir(convs[i].proto) == dir)
		if !used {
			continue
		}
		sink := libodin.sink_from(name[:])
		libodin.put_uint(&sink, u64(i))
		entry := libodin.str(&sink)
		if vectra9.remaining(c) < vectra9.dirent_size(entry) {
			break
		}
		dir_node := is_tcp ? tconv_node(i, TCONV_DIR) : conv_node(i, CONV_DIR)
		vectra9.put_dirent(
			c,
			vectra9.Dirent{qid = qid_of(dir_node), offset = u64(i + fixed + 1), type = vectra9.DT_DIR, name = entry},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(c)}
}
