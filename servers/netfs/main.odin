/*
netfs -- the IPv4 stack, in ring 3, serving `/net`.

`docs/FLEET.md` step 0 makes the network a file server. The card is the
kernel's, as `#E` at `/dev/ether`. Everything above it is here: ARP, IPv4 and
ICMP over `sys/libnet`'s wire formats, and the `/net` files a program reads.
This is `consrv`'s shape, the one `sys/libthread` gives a server that waits on
two things:

    the ether thread  reads /dev/ether/data through an io proc, and every
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

    /net/ether0/addr   the card's hardware address
    /net/arp           the addresses this machine has resolved
    /net/icmp          echoes sent and echoes answered

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
NODE_ETHER :: i32(1) // The ether0 directory
NODE_ADDR :: i32(2) // ether0/addr
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

// This machine's address and the gateway it probes, QEMU's user network until
// a `cmd/ipconfig` asks for one.
MY_IP :: libnet.IP{10, 0, 2, 15}
GW_IP :: libnet.IP{10, 0, 2, 2}

// The identifier this stack puts in the echoes it sends.
ECHO_ID :: u16(0x5643)

fids: libuser.Fid_Table
srv: lib9p.Srv

ether_fd: int
my_mac: libnet.MAC
arp_table: libnet.Arp_Table

// What the probe did, which `/net/icmp` reports and the self-test reads.
echo_sent: int
echo_recv: int
probed: bool // Whether the gateway's address has been asked for once

// One frame out, built here and written to the card. A datagram's payload is
// the largest thing it carries.
out: [2048]u8

/*
_start opens the card's files and hands the process to the thread library. The
opens come first because the descriptor table is shared, and an io proc holds
the number. 0x74 is a card that would not open, which is a machine with no
`#E` and so no network for this server to serve.
*/
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()

	afd := libuser.open("/dev/ether/addr", abi.O_RDONLY)
	if afd < 0 {
		libuser.exit(0x74)
	}
	raw: [6]u8
	n := libuser.read(int(afd), raw[:])
	_ = libuser.close(int(afd))
	if n != 6 {
		libuser.exit(0x74)
	}
	my_mac = libnet.MAC{raw[0], raw[1], raw[2], raw[3], raw[4], raw[5]}

	dfd := libuser.open("/dev/ether/data", abi.O_RDWR)
	if dfd < 0 {
		libuser.exit(0x74)
	}
	ether_fd = int(dfd)

	libthread.main(threadmain, nil)
}

/*
threadmain posts the service, starts the ether thread, asks for the gateway's
address, and then serves until something stops it. The ARP goes out after the
ether thread is reading, so the reply has somewhere to land.
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
	if libthread.threadcreate(ether_thread, nil) < 0 {
		libthread.threadexitsall("threadcreate")
	}

	// Ask who has the gateway. The reply arrives at the ether thread, which
	// remembers it and sends the echo that follows.
	send_arp_request(GW_IP)
	probed = true

	_, why := lib9p.serve(&srv)
	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

/*
ether_thread is the card's whole life: a read of `data` through an io proc, and
what arrives handed to the stack. The read parks in the kernel until a frame
comes or its bound passes. An empty answer is a reason to ask again rather than
a failure.
*/
ether_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexitsall("ioproc")
	}
	frame: [2048]u8
	for {
		n := libthread.ioread(io, ether_fd, frame[:])
		if n <= 0 {
			continue
		}
		take(frame[:int(n)])
	}
}

// -- The stack ----------------------------------------------------------------

// take is one received frame, and what this stack makes of it.
take :: proc "contextless" (frame: []u8) #no_bounds_check {
	switch libnet.eth_type(frame) {
	case libnet.ETHERTYPE_ARP:
		take_arp(frame)
	case libnet.ETHERTYPE_IPV4:
		take_ipv4(frame)
	}
}

/*
take_arp answers a request for this machine's address and remembers what a
reply tells it. A reply for the gateway is also the cue to send the echo. There is an address
to send it to now.
*/
take_arp :: proc "contextless" (frame: []u8) #no_bounds_check {
	if len(frame) < libnet.ETH_HDR + libnet.ARP_LEN {
		return
	}
	a, ok := libnet.parse_arp(frame[libnet.ETH_HDR:])
	if !ok {
		return
	}
	// Whoever spoke, we now know their address.
	libnet.arp_insert(&arp_table, a.spa, a.sha)

	switch a.op {
	case libnet.ARP_REQUEST:
		if a.tpa == MY_IP {
			at := libnet.put_eth(out[:], a.sha, my_mac, libnet.ETHERTYPE_ARP)
			at = libnet.put_arp(out[:], at, libnet.Arp{
				op  = libnet.ARP_REPLY,
				sha = my_mac,
				spa = MY_IP,
				tha = a.sha,
				tpa = a.spa,
			})
			_ = libuser.write(ether_fd, out[:at])
		}
	case libnet.ARP_REPLY:
		if a.spa == GW_IP && echo_sent == 0 {
			send_echo(GW_IP, a.sha)
		}
	}
}

/*
take_ipv4 answers an ICMP echo addressed to this machine and counts the echo
replies its own probe asked for. A datagram for another address is not this
machine's business, and there is no routing here to pass it on.
*/
take_ipv4 :: proc "contextless" (frame: []u8) #no_bounds_check {
	if len(frame) < libnet.ETH_HDR + libnet.IPV4_HDR {
		return
	}
	pkt := frame[libnet.ETH_HDR:]
	h, ok := libnet.parse_ipv4(pkt)
	if !ok || h.dst != MY_IP {
		return
	}
	if h.total > len(pkt) || h.total < h.hdr_len {
		return
	}
	body := pkt[h.hdr_len:h.total]

	if h.proto == libnet.IPPROTO_UDP {
		if u, uok := libnet.parse_udp(body, h.src, h.dst); uok {
			udp_deliver(h.src, u.sport, u.dport, u.payload)
		}
		return
	}
	if h.proto == libnet.IPPROTO_TCP {
		tcp_input(h.src, body)
		return
	}
	if h.proto != libnet.IPPROTO_ICMP {
		return
	}
	m, mok := libnet.parse_icmp(body)
	if !mok {
		return
	}
	switch m.kind {
	case libnet.ICMP_ECHOREPLY:
		if m.id == ECHO_ID {
			echo_recv += 1
		}
	case libnet.ICMP_ECHO:
		// Answer it, to whoever sent it, with the payload it carried.
		src := libnet.eth_src(frame)
		payload := body[libnet.ICMP_HDR:]
		at := libnet.put_eth(out[:], src, my_mac, libnet.ETHERTYPE_IPV4)
		icmp_len := libnet.ICMP_HDR + len(payload)
		body_at := libnet.put_ipv4(out[:], at, MY_IP, h.src, libnet.IPPROTO_ICMP, icmp_len, 0)
		end := libnet.put_icmp_echo(out[:], body_at, libnet.ICMP_ECHOREPLY, m.id, m.seq, payload)
		_ = libuser.write(ether_fd, out[:end])
	}
}

// send_arp_request asks who has `who`, as a broadcast.
send_arp_request :: proc "contextless" (who: libnet.IP) {
	n := libnet.build_arp_request(out[:], my_mac, MY_IP, who)
	_ = libuser.write(ether_fd, out[:n])
}

// send_echo sends one ICMP echo request to `ip` at `mac`, and counts it.
send_echo :: proc "contextless" (ip: libnet.IP, mac: libnet.MAC) #no_bounds_check {
	payload := "vectra"
	at := libnet.put_eth(out[:], mac, my_mac, libnet.ETHERTYPE_IPV4)
	icmp_len := libnet.ICMP_HDR + len(payload)
	body_at := libnet.put_ipv4(out[:], at, MY_IP, ip, libnet.IPPROTO_ICMP, icmp_len, 1)
	end := libnet.put_icmp_echo(
		out[:],
		body_at,
		libnet.ICMP_ECHO,
		ECHO_ID,
		u16(echo_sent + 1),
		transmute([]u8)payload,
	)
	if libuser.write(ether_fd, out[:end]) == i64(end) {
		echo_sent += 1
	}
}

// -- The files ----------------------------------------------------------------

// render writes a file's whole contents into `into` and answers its length.
render :: proc "contextless" (node: i32, into: []u8) -> int #no_bounds_check {
	sink := libodin.sink_from(into)
	switch node {
	case NODE_ADDR:
		put_mac(&sink, my_mac)
		libodin.put_str(&sink, "\n")
	case NODE_ARP:
		for i in 0 ..< libnet.ARP_ENTRIES {
			e := &arp_table.entries[i]
			if !e.valid {
				continue
			}
			put_ip(&sink, e.ip)
			libodin.put_str(&sink, " ")
			put_mac(&sink, e.mac)
			libodin.put_str(&sink, "\n")
		}
	case NODE_ICMP:
		libodin.put_str(&sink, "sent ")
		libodin.put_uint(&sink, u64(echo_sent))
		libodin.put_str(&sink, " received ")
		libodin.put_uint(&sink, u64(echo_recv))
		libodin.put_str(&sink, "\n")
	case:
		if i, kind, ok := tconv_of(node); ok {
			render_tconv(&sink, i, kind)
		} else if j, k2, ok2 := conv_of(node); ok2 {
			render_conv(&sink, j, k2)
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

put_mac :: proc "contextless" (sink: ^libodin.Sink, mac: libnet.MAC) #no_bounds_check {
	hexd := "0123456789abcdef"
	pair: [2]u8
	for i in 0 ..< 6 {
		if i > 0 {
			libodin.put_str(sink, ":")
		}
		pair[0] = hexd[mac[i] >> 4]
		pair[1] = hexd[mac[i] & 0xF]
		libodin.put_str(sink, string(pair[:]))
	}
}

// -- The tree -----------------------------------------------------------------

is_dir :: proc "contextless" (node: i32) -> bool {
	if node == NODE_ROOT || node == NODE_ETHER || node == NODE_UDP || node == NODE_TCP {
		return true
	}
	if _, kind, ok := tconv_of(node); ok {
		return kind == TCONV_DIR
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
		switch name {
		case "ether0":
			return NODE_ETHER
		case "arp":
			return NODE_ARP
		case "icmp":
			return NODE_ICMP
		case "udp":
			return NODE_UDP
		case "tcp":
			return NODE_TCP
		}
	case NODE_ETHER:
		if name == "addr" {
			return NODE_ADDR
		}
	case NODE_UDP:
		if name == "clone" {
			return NODE_CLONE
		}
		// A number names a conversation that exists.
		if v, _, ok := scan_uint(name); ok {
			i := int(v)
			if i < MAX_CONV && convs[i].used {
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

// parent_of is where `..` goes from any node in the tree.
parent_of :: proc "contextless" (node: i32) -> i32 {
	if node == NODE_ADDR {
		return NODE_ETHER
	}
	if node == NODE_CLONE {
		return NODE_UDP
	}
	if node == NODE_TCLONE {
		return NODE_TCP
	}
	if i, kind, ok := tconv_of(node); ok {
		return kind == TCONV_DIR ? NODE_TCP : tconv_node(i, TCONV_DIR)
	}
	if i, kind, ok := conv_of(node); ok {
		return kind == CONV_DIR ? NODE_UDP : conv_node(i, CONV_DIR)
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

		// A read of TCP's `clone` takes a conversation the same way UDP's does.
		if node == NODE_TCLONE {
			if m.offset > 0 {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			i := tcp_alloc()
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
			for k in 0 ..< room {
				buf[k] = text[k]
			}
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
				got := tcp_pop(i, buf[:room])
				if got > 0 {
					reply^ = vectra9.Rread{data = buf[:got]}
					return
				}
				if tcps[i].fin_seen {
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

		// A read of `clone` takes a conversation and answers its number. It is
		// the only read here with a side effect, and the whole of how a caller
		// gets a conversation.
		if node == NODE_CLONE {
			if m.offset > 0 {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			i := conv_alloc()
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
			for k in 0 ..< room {
				buf[k] = text[k]
			}
			reply^ = vectra9.Rread{data = buf[:room]}
			return
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
		whole: [1024]u8
		size := render(node, whole[:])
		off := int(m.offset)
		if off >= size {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		room := min(min(len(buf), int(m.count)), size - off)
		for i in 0 ..< room {
			buf[i] = whole[off + i]
		}
		reply^ = vectra9.Rread{data = buf[:room]}

	case vectra9.Twrite:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		if i, kind, is_tcp := tconv_of(node); is_tcp {
			switch kind {
			case TCONV_CTL:
				if !run_tcp_ctl(i, string(m.data)) {
					reply^ = vectra9.error_reply(vectra9.EINVAL)
					return
				}
				reply^ = vectra9.Rwrite{count = u32(len(m.data))}
			case TCONV_DATA:
				if !tcp_write(i, m.data) {
					reply^ = vectra9.error_reply(vectra9.EIO)
					return
				}
				reply^ = vectra9.Rwrite{count = u32(len(m.data))}
			case:
				reply^ = vectra9.error_reply(vectra9.EPERM)
			}
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
			if !udp_send(i, m.data) {
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
			whole: [1024]u8
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
		libuser.fid_release(&fids, m.fid)
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

	// The udp directory is the one listing that changes: `clone`, and then a
	// numbered entry per conversation that exists.
	if node == NODE_UDP || node == NODE_TCP {
		readdir_conv_dir(m, reply, &c, node == NODE_TCP)
		return
	}

	names: []string
	nodes: []i32
	switch {
	case node == NODE_ROOT:
		names = []string{"ether0", "arp", "icmp", "udp", "tcp"}
		nodes = []i32{NODE_ETHER, NODE_ARP, NODE_ICMP, NODE_UDP, NODE_TCP}
	case node == NODE_ETHER:
		names = []string{"addr"}
		nodes = []i32{NODE_ADDR}
	case:
		if tconv, _, is_tcp := tconv_of(node); is_tcp {
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
readdir_conv_dir lists a protocol's directory: `clone` first, and then one entry
per conversation that exists, named by its number. The offset counts entries, so
`clone` is entry zero and conversation `n` is entry `n + 1`. Both protocols have
the same directory, so both are listed here.
*/
readdir_conv_dir :: proc "contextless" (
	m: vectra9.Treaddir,
	reply: ^vectra9.Msg,
	c: ^vectra9.Cursor,
	is_tcp: bool,
) #no_bounds_check {
	clone_node := is_tcp ? NODE_TCLONE : NODE_CLONE
	last := is_tcp ? MAX_TCP : MAX_CONV
	if m.offset < 1 && vectra9.remaining(c) >= vectra9.dirent_size("clone") {
		vectra9.put_dirent(
			c,
			vectra9.Dirent{qid = qid_of(clone_node), offset = 1, type = vectra9.DT_REG, name = "clone"},
		)
	}
	name: [16]u8
	for i := max(int(m.offset) - 1, 0); i < last; i += 1 {
		used := is_tcp ? tcps[i].used : convs[i].used
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
			vectra9.Dirent{qid = qid_of(dir_node), offset = u64(i + 2), type = vectra9.DT_DIR, name = entry},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(c)}
}
