/*
dhcp -- the messages a machine asks for an address with, RFC 2131's.

Four messages cross for an address. The client broadcasts DISCOVER from no
address at all, a server answers OFFER with one, the client broadcasts
REQUEST naming the offer and the server, and the server answers ACK. Every
message is one BOOTP frame: the fixed fields, the magic cookie, and options.
The options this reads are the ones `cmd/ipconfig` needs, the mask, the
router, the name servers and the lease, and the message type that says which
of the four it is.

Like the rest of `sys/libnet`, this only reads and writes byte slices, so
`tests/net` proves it against a message built here and an answer written by
hand.
*/
package libnet

DHCP_CLIENT_PORT :: u16(68)
DHCP_SERVER_PORT :: u16(67)

DHCP_DISCOVER :: u8(1)
DHCP_OFFER :: u8(2)
DHCP_REQUEST :: u8(3)
DHCP_ACK :: u8(5)
DHCP_NAK :: u8(6)

// The fixed part, then the four-byte cookie, then options. A message is
// padded to `DHCP_MIN` bytes, the smallest a BOOTP server is sure to take.
DHCP_FIXED :: 236
DHCP_MIN :: 300
DHCP_MAX :: 576

@(private = "file")
DHCP_COOKIE :: [4]u8{0x63, 0x82, 0x53, 0x63}

@(private = "file")
OPT_MASK :: u8(1)
@(private = "file")
OPT_ROUTER :: u8(3)
@(private = "file")
OPT_DNS :: u8(6)
@(private = "file")
OPT_REQUESTED :: u8(50)
@(private = "file")
OPT_LEASE :: u8(51)
@(private = "file")
OPT_KIND :: u8(53)
@(private = "file")
OPT_SERVER :: u8(54)
@(private = "file")
OPT_PARAMS :: u8(55)
@(private = "file")
OPT_END :: u8(255)

// What a client says: which of the four, from which card, and for a REQUEST,
// which offer from which server.
Dhcp_Ask :: struct {
	kind:      u8,
	xid:       u32,
	mac:       MAC,
	requested: IP, // REQUEST only: the address offered
	server:    IP, // REQUEST only: the server that offered it
}

// What a server answered, as far as a client cares.
Dhcp_Answer :: struct {
	kind:   u8,
	xid:    u32,
	yiaddr: IP, // The address offered or acknowledged
	server: IP,
	mask:   IP,
	router: IP,
	dns:    IP,
	lease:  u32, // Seconds
}

/*
put_dhcp writes one client message into `b` and answers its length. The
broadcast flag is set, so a server answers to every station rather than to an
address this client does not have yet. The parameter list asks for the mask,
the router and the name servers, which is what `ipconfig` writes into
`/net/ndb`.
*/
put_dhcp :: proc "contextless" (b: []u8, a: Dhcp_Ask) -> int #no_bounds_check {
	for i in 0 ..< DHCP_MIN {
		b[i] = 0
	}
	b[0] = 1 // BOOTREQUEST
	b[1] = 1 // Ethernet
	b[2] = 6 // Hardware address length
	put_be32(b, 4, a.xid)
	put_be16(b, 10, 0x8000) // Broadcast
	for i in 0 ..< 6 {
		b[28 + i] = a.mac[i]
	}
	at := DHCP_FIXED
	cookie := DHCP_COOKIE
	for i in 0 ..< 4 {
		b[at + i] = cookie[i]
	}
	at += 4
	b[at] = OPT_KIND
	b[at + 1] = 1
	b[at + 2] = a.kind
	at += 3
	if a.kind == DHCP_REQUEST {
		b[at] = OPT_REQUESTED
		b[at + 1] = 4
		for i in 0 ..< 4 {
			b[at + 2 + i] = a.requested[i]
		}
		at += 6
		b[at] = OPT_SERVER
		b[at + 1] = 4
		for i in 0 ..< 4 {
			b[at + 2 + i] = a.server[i]
		}
		at += 6
	}
	b[at] = OPT_PARAMS
	b[at + 1] = 3
	b[at + 2] = OPT_MASK
	b[at + 3] = OPT_ROUTER
	b[at + 4] = OPT_DNS
	at += 5
	b[at] = OPT_END
	at += 1
	return max(at, DHCP_MIN)
}

/*
parse_dhcp reads a server's message. A message that is not a reply, has no
cookie, or names no message type is refused. Options not asked for are
stepped over by their length.
*/
parse_dhcp :: proc "contextless" (p: []u8) -> (a: Dhcp_Answer, ok: bool) #no_bounds_check {
	if len(p) < DHCP_FIXED + 4 || p[0] != 2 {
		return {}, false
	}
	cookie := DHCP_COOKIE
	for i in 0 ..< 4 {
		if p[DHCP_FIXED + i] != cookie[i] {
			return {}, false
		}
	}
	a.xid = get_be32(p, 4)
	for i in 0 ..< 4 {
		a.yiaddr[i] = p[16 + i]
		a.server[i] = p[20 + i]
	}
	at := DHCP_FIXED + 4
	for at < len(p) {
		code := p[at]
		if code == OPT_END {
			break
		}
		if code == 0 {
			at += 1
			continue
		}
		if at + 1 >= len(p) {
			return {}, false
		}
		n := int(p[at + 1])
		body := at + 2
		if body + n > len(p) {
			return {}, false
		}
		switch code {
		case OPT_KIND:
			if n >= 1 {
				a.kind = p[body]
			}
		case OPT_MASK:
			if n >= 4 {
				for i in 0 ..< 4 {a.mask[i] = p[body + i]}
			}
		case OPT_ROUTER:
			if n >= 4 {
				for i in 0 ..< 4 {a.router[i] = p[body + i]}
			}
		case OPT_DNS:
			if n >= 4 {
				for i in 0 ..< 4 {a.dns[i] = p[body + i]}
			}
		case OPT_SERVER:
			if n >= 4 {
				for i in 0 ..< 4 {a.server[i] = p[body + i]}
			}
		case OPT_LEASE:
			if n >= 4 {
				a.lease = get_be32(p, body)
			}
		}
		at = body + n
	}
	if a.kind == 0 {
		return {}, false
	}
	return a, true
}
