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

	// -- A live frame across the card, from ring 3 through `#E` ---------------
	//
	// The kernel serves the virtio-net card as `/dev/ether`. This opens it,
	// reads the card's own address, sends a broadcast ARP for the gateway, and
	// polls for the reply. It proves the whole ring 3 path the stack will use.
	// A frame this program built left on the card, and a frame the card received
	// came back, all through files.
	{
		afd := libuser.open("/dev/ether/addr", abi.O_RDONLY)
		want(afd >= 0, "the ether address file opens")
		{
			card: [6]u8
			libuser.read(int(afd), card[:])
			_ = libuser.close(int(afd))
			card_mac := libnet.MAC{card[0], card[1], card[2], card[3], card[4], card[5]}

			dfd := libuser.open("/dev/ether/data", abi.O_RDWR)
			want(dfd >= 0, "the ether data file opens")

			out: [64]u8
			n := libnet.build_arp_request(out[:], card_mac, mine, gw)
			want(libuser.write(int(dfd), out[:n]) == i64(n), "the ARP request is written to the card")

			in_buf: [2048]u8
			got := false
			for _ in 0 ..< 3000 {
				rn := libuser.read(int(dfd), in_buf[:])
				if rn > 0 {
					frame := in_buf[:int(rn)]
					if libnet.eth_type(frame) == libnet.ETHERTYPE_ARP && int(rn) >= libnet.ETH_HDR + libnet.ARP_LEN {
						a, ok := libnet.parse_arp(frame[libnet.ETH_HDR:])
						if ok && a.op == libnet.ARP_REPLY && a.spa == gw {
							got = true
							break
						}
					}
				} else {
					_ = libuser.sleep(1)
				}
			}
			want(got, "the gateway answered our ARP across the card, from ring 3")
			_ = libuser.close(int(dfd))
		}
	}

	// -- The retransmit queue remembers until it is acknowledged --------------
	{
		q: libnet.Retx
		a := "one"
		b := "two"
		c := "three"
		want(libnet.retx_push(&q, 100, libnet.TCP_PSH, transmute([]u8)a, 1), "a segment is remembered")
		want(libnet.retx_push(&q, 103, libnet.TCP_PSH, transmute([]u8)b, 2), "and a second")
		want(libnet.retx_push(&q, 106, libnet.TCP_PSH, transmute([]u8)c, 3), "and a third")
		want(libnet.retx_count(&q) == 3, "all three are waiting")

		// A bare ACK takes no sequence space, so nothing remembers it.
		want(libnet.retx_push(&q, 111, libnet.TCP_ACK, nil, 4), "a bare ACK is taken")
		want(libnet.retx_count(&q) == 3, "and is not remembered, having nothing to acknowledge")

		// A SYN takes a sequence number of its own.
		want(libnet.retx_span(libnet.TCP_SYN, 0) == 1, "a SYN takes one sequence number")
		want(libnet.retx_span(libnet.TCP_FIN, 4) == 5, "a FIN takes one past its bytes")

		// Acknowledging past the first two drops exactly those.
		libnet.retx_ack(&q, 106)
		want(libnet.retx_count(&q) == 1, "an acknowledgement drops what it covers")

		// Nothing is due before its timeout, and the oldest is due after it.
		_, due := libnet.retx_due(&q, 4, 10)
		want(!due, "nothing is due before its timeout")
		i, due2 := libnet.retx_due(&q, 20, 10)
		want(due2, "and the segment is due after it")
		libnet.retx_sent(&q, i, 20)
		_, due3 := libnet.retx_due(&q, 21, 10)
		want(!due3, "sending it again restarts its timer")

		libnet.retx_ack(&q, 200)
		want(libnet.retx_count(&q) == 0, "an acknowledgement past everything empties the queue")
	}

	// -- The resequencer holds what arrived early ----------------------------
	{
		r: libnet.Resequencer
		later := "world"
		want(libnet.reseq_insert(&r, 110, transmute([]u8)later), "a segment that came early is held")
		want(libnet.reseq_held(&r) == 1, "and is waiting")

		// Nothing is contiguous at 100, because 100 is what has not arrived.
		out: [64]u8
		want(libnet.reseq_take(&r, 100, out[:]) == 0, "nothing is contiguous before the gap is filled")

		// Once the stream reaches 110, the held segment is the next run.
		n := libnet.reseq_take(&r, 110, out[:])
		want(n == len(later), "the held segment comes out when its turn arrives")
		want(string(out[:n]) == later, "with its bytes intact")
		want(libnet.reseq_held(&r) == 0, "and is no longer held")

		// The same sequence twice is held once.
		want(libnet.reseq_insert(&r, 200, transmute([]u8)later), "a segment is held")
		want(libnet.reseq_insert(&r, 200, transmute([]u8)later), "and the same one again is taken")
		want(libnet.reseq_held(&r) == 1, "but held only once")
		libnet.reseq_drop(&r)
		want(libnet.reseq_held(&r) == 0, "a close forgets what was held")
	}

	// -- The window says how much more may be sent ---------------------------
	{
		want(libnet.send_room(0, 0, 1000) == 1000, "an idle conversation may send the whole window")
		want(libnet.send_room(0, 400, 1000) == 600, "what is in flight comes off the window")
		want(libnet.send_room(0, 1000, 1000) == 0, "a full window stops the sender")
		want(libnet.send_room(0, 1200, 1000) == 0, "and a window smaller than what is in flight is not negative")
	}

	libuser.exits("ok")
}
