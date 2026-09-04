/*
nettest -- `sys/libnet`'s wire formats, exercised from ring 3.

The kernel's self-test spawns this program and reads the word it exits with.
The word is `ok` when every step held, or the name of the first that did not.
Each step builds a packet and reads it back, or checks a checksum a corruption
must break. No card is touched, so this is a pure test of the arithmetic
`docs/FLEET.md` step 0's stack is built on. A live frame across the card is a
later step, once `#E` and `netfs` exist.

An ARP request round-trips. An IPv4 header carries a checksum that catches a
flipped bit. An ICMP echo does the same. The ARP table remembers an address and
forgets a miss.
*/
package nettest

import "vsys:abi"
import "vsys:libnet"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	me := libnet.MAC{0x52, 0x54, 0x00, 0x12, 0x34, 0x56}
	mine := libnet.IP{10, 0, 2, 15}
	gw := libnet.IP{10, 0, 2, 2}

	buf: [128]u8

	// -- An ARP request round-trips -------------------------------------------
	{
		n := libnet.build_arp_request(buf[:], me, mine, gw)
		want(n == libnet.ETH_HDR + libnet.ARP_LEN, "the ARP request is a frame's worth")
		want(libnet.eth_type(buf[:n]) == libnet.ETHERTYPE_ARP, "its ethertype is ARP")
		want(libnet.eth_src(buf[:n]) == me, "its source is our address")

		a, ok := libnet.parse_arp(buf[libnet.ETH_HDR:n])
		want(ok, "the ARP body parses")
		want(a.op == libnet.ARP_REQUEST, "it is a request")
		want(a.spa == mine && a.tpa == gw, "it asks who has the gateway")
		want(a.sha == me, "and gives our hardware address")
	}

	// -- An ARP reply parses, and the table remembers it ----------------------
	{
		gw_mac := libnet.MAC{0x52, 0x55, 0x0A, 0x00, 0x02, 0x02}
		reply: [64]u8
		at := libnet.put_eth(reply[:], me, gw_mac, libnet.ETHERTYPE_ARP)
		at = libnet.put_arp(reply[:], at, libnet.Arp{
			op  = libnet.ARP_REPLY,
			sha = gw_mac,
			spa = gw,
			tha = me,
			tpa = mine,
		})
		a, ok := libnet.parse_arp(reply[libnet.ETH_HDR:at])
		want(ok && a.op == libnet.ARP_REPLY, "the ARP reply parses")
		want(a.sha == gw_mac && a.spa == gw, "it is the gateway's address")

		table: libnet.Arp_Table
		libnet.arp_insert(&table, a.spa, a.sha)
		got, hit := libnet.arp_lookup(&table, gw)
		want(hit && got == gw_mac, "the table remembers the gateway")
		_, miss := libnet.arp_lookup(&table, libnet.IP{10, 0, 2, 99})
		want(!miss, "and does not invent an address it never saw")
	}

	// -- An IPv4 header checks its own checksum -------------------------------
	{
		pkt: [64]u8
		payload := "hello"
		body := libnet.put_ipv4(pkt[:], 0, mine, gw, libnet.IPPROTO_ICMP, len(payload), 0x1234)
		want(body == libnet.IPV4_HDR, "the IPv4 header is twenty bytes")
		copy(pkt[body:], transmute([]u8)payload)

		h, ok := libnet.parse_ipv4(pkt[:body + len(payload)])
		want(ok, "a correct IPv4 header passes its checksum")
		want(h.src == mine && h.dst == gw, "its addresses read back")
		want(h.proto == libnet.IPPROTO_ICMP, "its protocol reads back")
		want(h.total == libnet.IPV4_HDR + len(payload), "its length reads back")

		// A flipped bit in the header must fail the checksum.
		pkt[8] ~= 0x01
		_, ok2 := libnet.parse_ipv4(pkt[:body + len(payload)])
		want(!ok2, "a flipped bit fails the IPv4 checksum")
	}

	// -- An ICMP echo checks its own checksum --------------------------------
	{
		msg: [64]u8
		payload := "vectra"
		end := libnet.put_icmp_echo(msg[:], 0, libnet.ICMP_ECHO, 0xABCD, 7, transmute([]u8)payload)
		want(end == libnet.ICMP_HDR + len(payload), "the ICMP message is header plus payload")

		m, ok := libnet.parse_icmp(msg[:end])
		want(ok, "a correct ICMP echo passes its checksum")
		want(m.kind == libnet.ICMP_ECHO && m.id == 0xABCD && m.seq == 7, "its fields read back")

		msg[9] ~= 0x80
		_, ok2 := libnet.parse_icmp(msg[:end])
		want(!ok2, "a flipped bit fails the ICMP checksum")
	}

	libuser.exits("ok")
}
