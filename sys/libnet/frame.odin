/*
frame -- the wire formats the network is made of, and the checksum they share.

`docs/FLEET.md` step 0's `netfs` is the IPv4 stack that will serve `/net`, and
`sys/libnet` is the library beside it. This file is the foundation both stand
on. It encodes and decodes an ethernet frame, an ARP packet, an IPv4 datagram
and an ICMP message. The internet checksum two of them carry lives here too.
Nothing here touches a card or a file, so `tests/net` proves it all against
known packets with no network. The `dial` and `announce` calls `docs/FLEET.md`
gives this library come later, over `/net` once `netfs` serves it.

The byte order on the wire is big-endian, which the host is not. So every
multi-byte field goes through `put_be16` and its kin rather than a cast. The
checksum is the one's-complement sum RFC 1071 defines, the same arithmetic an
IPv4 header and an ICMP message both fold their words into.
*/
package libnet

// An IPv4 address and an ethernet address, the two this stack carries.
IP :: [4]u8
MAC :: [6]u8

// The ethertypes, protocol numbers and message kinds this stack knows.
ETHERTYPE_ARP :: u16(0x0806)
ETHERTYPE_IPV4 :: u16(0x0800)
ARP_REQUEST :: u16(1)
ARP_REPLY :: u16(2)
IPPROTO_ICMP :: u8(1)
IPPROTO_UDP :: u8(17)
IPPROTO_TCP :: u8(6)
ICMP_ECHO :: u8(8)
ICMP_ECHOREPLY :: u8(0)

// The fixed header sizes, in bytes.
ETH_HDR :: 14
ARP_LEN :: 28
IPV4_HDR :: 20
ICMP_HDR :: 8

BROADCAST :: MAC{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}

// -- Big-endian access, the wire's byte order ---------------------------------

put_be16 :: proc "contextless" (b: []u8, at: int, v: u16) #no_bounds_check {
	b[at] = u8(v >> 8)
	b[at + 1] = u8(v)
}
get_be16 :: proc "contextless" (b: []u8, at: int) -> u16 #no_bounds_check {
	return u16(b[at]) << 8 | u16(b[at + 1])
}
put_be32 :: proc "contextless" (b: []u8, at: int, v: u32) #no_bounds_check {
	b[at] = u8(v >> 24)
	b[at + 1] = u8(v >> 16)
	b[at + 2] = u8(v >> 8)
	b[at + 3] = u8(v)
}
get_be32 :: proc "contextless" (b: []u8, at: int) -> u32 #no_bounds_check {
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

/*
checksum is the internet checksum of `data`, folded onto `seed`. It sums the
bytes as big-endian 16-bit words, adds the carries back in, and complements the
result. A header carrying its own correct checksum sums with a seed of zero to
zero, which is how a receiver checks one. `seed` lets a caller carry a
pseudo-header's partial sum into the sum of what follows.
*/
checksum :: proc "contextless" (data: []u8, seed: u32 = 0) -> u16 #no_bounds_check {
	sum := seed
	i := 0
	for i + 1 < len(data) {
		sum += u32(data[i]) << 8 | u32(data[i + 1])
		i += 2
	}
	if i < len(data) {
		sum += u32(data[i]) << 8
	}
	for sum >> 16 != 0 {
		sum = (sum & 0xFFFF) + (sum >> 16)
	}
	return u16(~sum)
}

// -- Ethernet -----------------------------------------------------------------

// put_eth writes an ethernet header and answers where the payload begins.
put_eth :: proc "contextless" (b: []u8, dst: MAC, src: MAC, ethertype: u16) -> int #no_bounds_check {
	for i in 0 ..< 6 {
		b[i] = dst[i]
		b[6 + i] = src[i]
	}
	put_be16(b, 12, ethertype)
	return ETH_HDR
}

eth_type :: proc "contextless" (frame: []u8) -> u16 {
	if len(frame) < ETH_HDR {
		return 0
	}
	return get_be16(frame, 12)
}

eth_src :: proc "contextless" (frame: []u8) -> MAC #no_bounds_check {
	m: MAC
	if len(frame) >= ETH_HDR {
		for i in 0 ..< 6 {
			m[i] = frame[6 + i]
		}
	}
	return m
}

// -- ARP ----------------------------------------------------------------------

Arp :: struct {
	op:  u16,
	sha: MAC,
	spa: IP,
	tha: MAC,
	tpa: IP,
}

// put_arp writes an ARP packet body (28 bytes) at `at`, ethernet over IPv4.
put_arp :: proc "contextless" (b: []u8, at: int, a: Arp) -> int #no_bounds_check {
	put_be16(b, at + 0, 1) // htype: ethernet
	put_be16(b, at + 2, ETHERTYPE_IPV4) // ptype: IPv4
	b[at + 4] = 6 // hlen
	b[at + 5] = 4 // plen
	put_be16(b, at + 6, a.op)
	for i in 0 ..< 6 {b[at + 8 + i] = a.sha[i]}
	for i in 0 ..< 4 {b[at + 14 + i] = a.spa[i]}
	for i in 0 ..< 6 {b[at + 18 + i] = a.tha[i]}
	for i in 0 ..< 4 {b[at + 24 + i] = a.tpa[i]}
	return at + ARP_LEN
}

parse_arp :: proc "contextless" (p: []u8) -> (a: Arp, ok: bool) #no_bounds_check {
	if len(p) < ARP_LEN {
		return {}, false
	}
	// Only ethernet-over-IPv4 with the right lengths is a packet this parses.
	if get_be16(p, 0) != 1 || get_be16(p, 2) != ETHERTYPE_IPV4 || p[4] != 6 || p[5] != 4 {
		return {}, false
	}
	a.op = get_be16(p, 6)
	for i in 0 ..< 6 {a.sha[i] = p[8 + i]}
	for i in 0 ..< 4 {a.spa[i] = p[14 + i]}
	for i in 0 ..< 6 {a.tha[i] = p[18 + i]}
	for i in 0 ..< 4 {a.tpa[i] = p[24 + i]}
	return a, true
}

// build_arp_request writes a broadcast ARP request into `b` asking who has
// `tpa`, and answers the frame length.
build_arp_request :: proc "contextless" (b: []u8, src: MAC, spa: IP, tpa: IP) -> int {
	at := put_eth(b, BROADCAST, src, ETHERTYPE_ARP)
	return put_arp(b, at, Arp{op = ARP_REQUEST, sha = src, spa = spa, tpa = tpa})
}

// -- IPv4 ---------------------------------------------------------------------

/*
put_ipv4 writes a 20-byte IPv4 header at `at` for a datagram whose payload is
`payload_len` bytes of protocol `proto`, and computes its checksum. `ident` is
the identification field a caller varies per datagram. Returns the offset past
the header, where the payload goes.
*/
put_ipv4 :: proc "contextless" (
	b: []u8,
	at: int,
	src: IP,
	dst: IP,
	proto: u8,
	payload_len: int,
	ident: u16 = 0,
) -> int #no_bounds_check {
	b[at + 0] = 0x45 // version 4, header length 5 words
	b[at + 1] = 0 // DSCP/ECN
	put_be16(b, at + 2, u16(IPV4_HDR + payload_len)) // total length
	put_be16(b, at + 4, ident)
	put_be16(b, at + 6, 0) // flags, fragment offset
	b[at + 8] = 64 // TTL
	b[at + 9] = proto
	put_be16(b, at + 10, 0) // checksum, zero while summed
	for i in 0 ..< 4 {b[at + 12 + i] = src[i]}
	for i in 0 ..< 4 {b[at + 16 + i] = dst[i]}
	put_be16(b, at + 10, checksum(b[at:at + IPV4_HDR]))
	return at + IPV4_HDR
}

Ipv4 :: struct {
	src:      IP,
	dst:      IP,
	proto:    u8,
	hdr_len:  int, // Bytes of header, so the payload begins here
	total:    int, // Total datagram length the header claims
}

/*
parse_ipv4 reads an IPv4 header, checks its checksum, and answers where the
payload begins and how long the datagram is. A header that is not version 4, is
shorter than it claims, or whose checksum is wrong is refused.
*/
parse_ipv4 :: proc "contextless" (p: []u8) -> (h: Ipv4, ok: bool) #no_bounds_check {
	if len(p) < IPV4_HDR {
		return {}, false
	}
	if p[0] >> 4 != 4 {
		return {}, false
	}
	h.hdr_len = int(p[0] & 0x0F) * 4
	if h.hdr_len < IPV4_HDR || h.hdr_len > len(p) {
		return {}, false
	}
	if checksum(p[:h.hdr_len]) != 0 {
		return {}, false
	}
	h.total = int(get_be16(p, 2))
	h.proto = p[9]
	for i in 0 ..< 4 {h.src[i] = p[12 + i]}
	for i in 0 ..< 4 {h.dst[i] = p[16 + i]}
	return h, true
}

// -- ICMP ---------------------------------------------------------------------

/*
put_icmp_echo writes an ICMP echo or echo-reply at `at`, with `payload` after
its eight-byte header, and computes the checksum over the whole message. Returns
the offset past the message.
*/
put_icmp_echo :: proc "contextless" (
	b: []u8,
	at: int,
	kind: u8,
	id: u16,
	seq: u16,
	payload: []u8,
) -> int #no_bounds_check {
	b[at + 0] = kind
	b[at + 1] = 0 // code
	put_be16(b, at + 2, 0) // checksum, zero while summed
	put_be16(b, at + 4, id)
	put_be16(b, at + 6, seq)
	for i in 0 ..< len(payload) {
		b[at + ICMP_HDR + i] = payload[i]
	}
	end := at + ICMP_HDR + len(payload)
	put_be16(b, at + 2, checksum(b[at:end]))
	return end
}

Icmp :: struct {
	kind: u8,
	code: u8,
	id:   u16,
	seq:  u16,
}

parse_icmp :: proc "contextless" (p: []u8) -> (m: Icmp, ok: bool) #no_bounds_check {
	if len(p) < ICMP_HDR {
		return {}, false
	}
	if checksum(p) != 0 {
		return {}, false
	}
	m.kind = p[0]
	m.code = p[1]
	m.id = get_be16(p, 4)
	m.seq = get_be16(p, 6)
	return m, true
}

// -- The ARP table ------------------------------------------------------------

ARP_ENTRIES :: 16

Arp_Entry :: struct {
	ip:    IP,
	mac:   MAC,
	valid: bool,
}

Arp_Table :: struct {
	entries: [ARP_ENTRIES]Arp_Entry,
	next:    int, // The slot a new entry replaces, oldest first
}

// arp_insert records `ip`'s hardware address, replacing an existing entry for
// the same address or the oldest slot.
arp_insert :: proc "contextless" (t: ^Arp_Table, ip: IP, mac: MAC) #no_bounds_check {
	for i in 0 ..< ARP_ENTRIES {
		if t.entries[i].valid && t.entries[i].ip == ip {
			t.entries[i].mac = mac
			return
		}
	}
	t.entries[t.next] = Arp_Entry{ip = ip, mac = mac, valid = true}
	t.next = (t.next + 1) % ARP_ENTRIES
}

// arp_lookup answers `ip`'s hardware address, and whether it is known.
arp_lookup :: proc "contextless" (t: ^Arp_Table, ip: IP) -> (MAC, bool) #no_bounds_check {
	for i in 0 ..< ARP_ENTRIES {
		if t.entries[i].valid && t.entries[i].ip == ip {
			return t.entries[i].mac, true
		}
	}
	return {}, false
}

// -- UDP ----------------------------------------------------------------------

UDP_HDR :: 8

/*
sum16 is the running one's-complement sum `checksum` folds. It is exposed
because a UDP checksum sums two things that are not next to each other. One is
a pseudo-header built from the IPv4 addresses, and the other the datagram. A
caller sums each in turn and folds once at the end.
*/
sum16 :: proc "contextless" (data: []u8, seed: u32 = 0) -> u32 #no_bounds_check {
	sum := seed
	i := 0
	for i + 1 < len(data) {
		sum += u32(data[i]) << 8 | u32(data[i + 1])
		i += 2
	}
	if i < len(data) {
		sum += u32(data[i]) << 8
	}
	return sum
}

// fold carries a running sum down to sixteen bits and complements it, which is
// the checksum a header carries.
fold :: proc "contextless" (seed: u32) -> u16 {
	sum := seed
	for sum >> 16 != 0 {
		sum = (sum & 0xFFFF) + (sum >> 16)
	}
	return u16(~sum)
}

/*
pseudo sums the twelve bytes IPv4 puts in front of a UDP datagram or a TCP
segment for the checksum's sake. They are the two addresses, a zero, the
protocol number, and the length of what follows. They are summed but never sent.
*/
pseudo :: proc "contextless" (src: IP, dst: IP, proto: u8, length: int) -> u32 #no_bounds_check {
	head: [12]u8
	for i in 0 ..< 4 {
		head[i] = src[i]
		head[4 + i] = dst[i]
	}
	head[8] = 0
	head[9] = proto
	put_be16(head[:], 10, u16(length))
	return sum16(head[:])
}

udp_pseudo :: proc "contextless" (src: IP, dst: IP, udp_len: int) -> u32 {
	return pseudo(src, dst, IPPROTO_UDP, udp_len)
}

/*
put_udp writes a UDP header and its payload at `at`, and computes the checksum
over the pseudo-header and the datagram together. A checksum that comes out zero
is sent as all ones, because zero means "no checksum" on the wire. Returns the
offset past the datagram.
*/
put_udp :: proc "contextless" (
	b: []u8,
	at: int,
	src: IP,
	dst: IP,
	sport: u16,
	dport: u16,
	payload: []u8,
) -> int #no_bounds_check {
	udp_len := UDP_HDR + len(payload)
	put_be16(b, at + 0, sport)
	put_be16(b, at + 2, dport)
	put_be16(b, at + 4, u16(udp_len))
	put_be16(b, at + 6, 0) // checksum, zero while summed
	for i in 0 ..< len(payload) {
		b[at + UDP_HDR + i] = payload[i]
	}
	end := at + udp_len
	ck := fold(sum16(b[at:end], udp_pseudo(src, dst, udp_len)))
	if ck == 0 {
		ck = 0xFFFF
	}
	put_be16(b, at + 6, ck)
	return end
}

Udp :: struct {
	sport:   u16,
	dport:   u16,
	payload: []u8,
}

/*
parse_udp reads a UDP header and answers the ports and the payload inside it. A
datagram carrying a checksum is checked against the pseudo-header the addresses
make. One carrying zero is not, because zero means the sender computed none.
*/
parse_udp :: proc "contextless" (p: []u8, src: IP, dst: IP) -> (u: Udp, ok: bool) #no_bounds_check {
	if len(p) < UDP_HDR {
		return {}, false
	}
	udp_len := int(get_be16(p, 4))
	if udp_len < UDP_HDR || udp_len > len(p) {
		return {}, false
	}
	if get_be16(p, 6) != 0 {
		if fold(sum16(p[:udp_len], udp_pseudo(src, dst, udp_len))) != 0 {
			return {}, false
		}
	}
	u.sport = get_be16(p, 0)
	u.dport = get_be16(p, 2)
	u.payload = p[UDP_HDR:udp_len]
	return u, true
}

// -- TCP ----------------------------------------------------------------------

TCP_HDR :: 20

// The flag bits a segment carries, in the byte after the data offset.
TCP_FIN :: u8(0x01)
TCP_SYN :: u8(0x02)
TCP_RST :: u8(0x04)
TCP_PSH :: u8(0x08)
TCP_ACK :: u8(0x10)

Tcp :: struct {
	sport:   u16,
	dport:   u16,
	seq:     u32,
	ack:     u32,
	flags:   u8,
	window:  u16,
	payload: []u8,
}

/*
put_tcp writes a TCP header and its payload at `at`, with no options, so the
data offset is always five words. The checksum covers the pseudo-header the
IPv4 addresses make and the segment together, the way UDP's does. Returns the
offset past the segment.
*/
put_tcp :: proc "contextless" (
	b: []u8,
	at: int,
	src: IP,
	dst: IP,
	t: Tcp,
) -> int #no_bounds_check {
	put_be16(b, at + 0, t.sport)
	put_be16(b, at + 2, t.dport)
	put_be32(b, at + 4, t.seq)
	put_be32(b, at + 8, t.ack)
	b[at + 12] = 5 << 4 // Data offset: five words, no options
	b[at + 13] = t.flags
	put_be16(b, at + 14, t.window)
	put_be16(b, at + 16, 0) // checksum, zero while summed
	put_be16(b, at + 18, 0) // urgent pointer
	for i in 0 ..< len(t.payload) {
		b[at + TCP_HDR + i] = t.payload[i]
	}
	end := at + TCP_HDR + len(t.payload)
	seg_len := end - at
	ck := fold(sum16(b[at:end], pseudo(src, dst, IPPROTO_TCP, seg_len)))
	put_be16(b, at + 16, ck)
	return end
}

/*
parse_tcp reads a segment, checks its checksum against the pseudo-header, and
answers the fields and the payload past the header. A data offset smaller than
the header, or larger than the segment, is refused. The options a longer offset
names are skipped rather than read.
*/
parse_tcp :: proc "contextless" (p: []u8, src: IP, dst: IP) -> (t: Tcp, ok: bool) #no_bounds_check {
	if len(p) < TCP_HDR {
		return {}, false
	}
	if fold(sum16(p, pseudo(src, dst, IPPROTO_TCP, len(p)))) != 0 {
		return {}, false
	}
	off := int(p[12] >> 4) * 4
	if off < TCP_HDR || off > len(p) {
		return {}, false
	}
	t.sport = get_be16(p, 0)
	t.dport = get_be16(p, 2)
	t.seq = get_be32(p, 4)
	t.ack = get_be32(p, 8)
	t.flags = p[13]
	t.window = get_be16(p, 14)
	t.payload = p[off:]
	return t, true
}
