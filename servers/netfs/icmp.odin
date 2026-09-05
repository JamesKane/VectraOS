/*
icmp -- the echo answered, the probe at start, and `/net/icmp`'s conversations.

An ICMP conversation is a UDP one with no ports: `connect a.b.c.d!1` names the
far end, a write of `data` is one whole ICMP message, and a read is one whole
message that came back from that far end. The port in the address is carried
and ignored, so a dial string keeps its three parts. That is 9front's shape
for the protocol, and `cmd/ping` is its caller.

    /net/icmp/clone    a read answers a new conversation's number
    /net/icmp/N/...    ctl, data, local, remote, status, as udp's
    /net/icmp/stats    echoes sent and echoes answered by the stack's own probe

**A message a program writes is its own.** The stack fills in the checksum and
nothing else, so a program builds the type, the identifier and the sequence
it wants to see come back. A reply is matched to a conversation by the address
it came from, not by the identifier, which is the program's to check.
*/
package netfs

import "vsys:libnet"

// The identifier this stack puts in the echoes it sends itself.
ECHO_ID :: u16(0x5643)

// The most one ICMP message this stack builds carries.
ICMP_MAX :: 576

// What the probe did, which `/net/icmp/stats` reports and the self-test reads,
// and what the stack did for others: echoes it answered, messages it handed
// to a conversation, and messages nothing was connected to hear.
echo_sent: int
echo_recv: int
echo_answered: int
icmp_delivered: int
icmp_unclaimed: int
icmp_bad: int // Messages that were short or did not sum

/*
icmp_in answers an echo so this machine can be pinged, counts the replies this
stack's own probe asked for, and hands every other message to the conversation
connected to the address it came from.
*/
icmp_in :: proc "contextless" (src: libnet.IP, body: []u8) #no_bounds_check {
	m, ok := libnet.parse_icmp(body)
	if !ok {
		icmp_bad += 1
		return
	}
	switch m.kind {
	case libnet.ICMP_ECHO:
		msg: [ICMP_MAX]u8 = ---
		payload := body[libnet.ICMP_HDR:]
		if len(payload) > ICMP_MAX - libnet.ICMP_HDR {
			payload = payload[:ICMP_MAX - libnet.ICMP_HDR]
		}
		end := libnet.put_icmp_echo(msg[:], 0, libnet.ICMP_ECHOREPLY, m.id, m.seq, payload)
		if ip_output(src, libnet.IPPROTO_ICMP, msg[:end]) != .Dropped {
			echo_answered += 1
		}
	case libnet.ICMP_ECHOREPLY:
		if m.id == ECHO_ID {
			echo_recv += 1
			return
		}
		icmp_deliver(src, body)
	case:
		icmp_deliver(src, body)
	}
}

/*
icmp_deliver queues one message on the conversation connected to the address it
came from. The first such conversation takes it, and a message nothing is
connected to is dropped, which is what an unasked-for reply means.
*/
icmp_deliver :: proc "contextless" (src: libnet.IP, body: []u8) #no_bounds_check {
	for i in 0 ..< MAX_CONV {
		c := &convs[i]
		if !c.used || c.proto != .ICMP || !c.connected || c.raddr != src {
			continue
		}
		conv_push(i, src, 0, body)
		icmp_delivered += 1
		return
	}
	icmp_unclaimed += 1
}

/*
icmp_send sends one message from conversation `i` to the far end it is
connected to. The message is the caller's, header and all. Only the checksum
is filled in here, so it is right whatever the caller wrote there.
*/
icmp_send :: proc "contextless" (i: int, message: []u8) -> bool #no_bounds_check {
	c := &convs[i]
	if !c.connected || len(message) < libnet.ICMP_HDR || len(message) > DG_MAX {
		return false
	}
	msg: [DG_MAX]u8 = ---
	copy(msg[:len(message)], message)
	libnet.put_be16(msg[:], 2, 0)
	libnet.put_be16(msg[:], 2, libnet.checksum(msg[:len(message)]))
	return ip_output(c.raddr, libnet.IPPROTO_ICMP, msg[:len(message)]) != .Dropped
}

/*
send_echo sends one ICMP echo request to `ip` and counts it. The hardware
address is `ip_output`'s business, not this one's.
*/
send_echo :: proc "contextless" (ip: libnet.IP) #no_bounds_check {
	payload := "vectra"
	msg: [ICMP_MAX]u8 = ---
	end := libnet.put_icmp_echo(
		msg[:],
		0,
		libnet.ICMP_ECHO,
		ECHO_ID,
		u16(echo_sent + 1),
		transmute([]u8)payload,
	)
	if ip_output(ip, libnet.IPPROTO_ICMP, msg[:end]) != .Dropped {
		echo_sent += 1
	}
}
