/*
tcp -- the reliable conversation, `/net/tcp`.

The same shape UDP has, with a state machine under it:

    /net/tcp/clone     a read answers a new conversation's number
    /net/tcp/N/ctl     `announce port`, `connect addr!port`, `hangup`
    /net/tcp/N/data    the byte stream
    /net/tcp/N/listen  a read answers a new conversation, when one arrives
    /net/tcp/N/local   this end
    /net/tcp/N/remote  the far end
    /net/tcp/N/status  the state it is in

**The handshake and the close are real.** A connect sends a SYN and waits for
the SYN and ACK to come back before it says the conversation is established. A
listening conversation makes a new one for each SYN it answers, and hands its
number to whoever reads `listen`. A hangup sends a FIN and follows the states
down to closed.

**What is not here yet.** A segment is sent once and never again, because
nothing here keeps a retransmit queue or a timer. A segment that arrives out of
order is dropped rather than held for the one before it. The window is a number
this end advertises and does not yet use to hold a sender back. Those three are
what a real network needs and a loopback does not, and they are the next
increment. What is here is the sequencing, the states and the stream, which is
what everything above TCP reads.

`docs/FLEET.md` step 0 wants congestion control among them. This is the state
machine it stands on.
*/
package netfs

import "vsys:lib9p"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"
import "vsys:vectra9"

MAX_TCP :: 8
TCP_RQ :: 2048 // The received stream a conversation holds
MSS :: 512 // The most payload one segment carries
BACKLOG :: 4

// The first sequence number a conversation sends, spread per conversation so
// two of them are never confused with each other.
ISS_BASE :: u32(1000)
ISS_STEP :: u32(100000)

Tcp_State :: enum u8 {
	Closed,
	Listen,
	Syn_Sent,
	Syn_Received,
	Established,
	Fin_Wait_1,
	Fin_Wait_2,
	Close_Wait,
	Last_Ack,
	Time_Wait,
}

Tcp_Conv :: struct {
	used:     bool,
	state:    Tcp_State,
	lport:    u16,
	raddr:    libnet.IP,
	rport:    u16,
	snd_nxt:  u32,
	snd_una:  u32,
	rcv_nxt:  u32,
	// The stream that arrived and has not been read.
	rq:       [TCP_RQ]u8,
	head:     int,
	tail:     int,
	fin_seen: bool,
	// A listening conversation's answered connections, waiting to be taken.
	backlog:  [BACKLOG]int,
	bhead:    int,
	btail:    int,
}

tcps: [MAX_TCP]Tcp_Conv
next_tcp_port: u16 = EPHEMERAL

tcp_alloc :: proc "contextless" () -> int #no_bounds_check {
	for i in 0 ..< MAX_TCP {
		if !tcps[i].used {
			tcps[i] = Tcp_Conv {
				used    = true,
				state   = .Closed,
				lport   = next_tcp_port,
				snd_nxt = ISS_BASE + u32(i) * ISS_STEP,
				snd_una = ISS_BASE + u32(i) * ISS_STEP,
			}
			next_tcp_port += 1
			return i
		}
	}
	return -1
}

tcp_free :: proc "contextless" (i: int) #no_bounds_check {
	if i >= 0 && i < MAX_TCP {
		tcps[i] = Tcp_Conv{}
	}
}

// -- The received stream -------------------------------------------------------

tcp_queued :: proc "contextless" (i: int) -> int #no_bounds_check {
	return tcps[i].tail - tcps[i].head
}

// tcp_push appends payload to a conversation's stream, as much as there is room
// for. What does not fit is dropped, which a window would have prevented.
tcp_push :: proc "contextless" (i: int, data: []u8) #no_bounds_check {
	c := &tcps[i]
	for k in 0 ..< len(data) {
		if c.tail - c.head >= TCP_RQ {
			break
		}
		c.rq[c.tail % TCP_RQ] = data[k]
		c.tail += 1
	}
}

tcp_pop :: proc "contextless" (i: int, out: []u8) -> int #no_bounds_check {
	c := &tcps[i]
	n := min(len(out), c.tail - c.head)
	for k in 0 ..< n {
		out[k] = c.rq[(c.head + k) % TCP_RQ]
	}
	c.head += n
	return n
}

// -- Sending -------------------------------------------------------------------

/*
tcp_output builds one segment and sends it. A segment for this machine's own
address goes straight back into `tcp_input`, which is the loopback, and one for
anywhere else becomes a frame. The segment is built on the stack rather than in
the shared frame buffer. A loopback segment is handled inside this call, and
would otherwise overwrite the buffer it came from.
*/
tcp_output :: proc "contextless" (i: int, flags: u8, payload: []u8) #no_bounds_check {
	c := &tcps[i]
	seg: [TCP_HDR_MAX]u8
	t := libnet.Tcp {
		sport   = c.lport,
		dport   = c.rport,
		seq     = c.snd_nxt,
		ack     = c.rcv_nxt,
		flags   = flags,
		window  = u16(TCP_RQ - (c.tail - c.head)),
		payload = payload,
	}
	end := libnet.put_tcp(seg[:], 0, MY_IP, c.raddr, t)

	// SYN and FIN each take a sequence number, and so does every byte sent.
	if flags & libnet.TCP_SYN != 0 || flags & libnet.TCP_FIN != 0 {
		c.snd_nxt += 1
	}
	c.snd_nxt += u32(len(payload))

	if c.raddr == MY_IP {
		tcp_input(MY_IP, seg[:end])
		return
	}
	mac, known := libnet.arp_lookup(&arp_table, c.raddr)
	if !known {
		send_arp_request(c.raddr)
		return
	}
	at := libnet.put_eth(out[:], mac, my_mac, libnet.ETHERTYPE_IPV4)
	body := libnet.put_ipv4(out[:], at, MY_IP, c.raddr, libnet.IPPROTO_TCP, end, 0)
	for k in 0 ..< end {
		out[body + k] = seg[k]
	}
	_ = libuser.write(ether_fd, out[:body + end])
}

// The most a segment this stack builds can be: a header and one MSS.
TCP_HDR_MAX :: libnet.TCP_HDR + MSS

// -- Receiving -----------------------------------------------------------------

/*
tcp_input takes one segment and drives the conversation it belongs to. A segment
for a conversation that exists goes to it. A SYN for a port something is
listening on makes a new conversation and answers it. Anything else is dropped,
because a reset is a segment this stack does not send yet.
*/
tcp_input :: proc "contextless" (src: libnet.IP, seg: []u8) #no_bounds_check {
	t, ok := libnet.parse_tcp(seg, src, MY_IP)
	if !ok {
		return
	}
	// An existing conversation: the four addresses match.
	for i in 0 ..< MAX_TCP {
		c := &tcps[i]
		if !c.used || c.state == .Listen || c.state == .Closed {
			continue
		}
		if c.lport == t.dport && c.rport == t.sport && c.raddr == src {
			tcp_step(i, t)
			return
		}
	}
	// A listener, and a SYN that asks it for a conversation.
	if t.flags & libnet.TCP_SYN == 0 || t.flags & libnet.TCP_ACK != 0 {
		return
	}
	for i in 0 ..< MAX_TCP {
		c := &tcps[i]
		if c.used && c.state == .Listen && c.lport == t.dport {
			tcp_accept(i, src, t)
			return
		}
	}
}

/*
tcp_accept makes the conversation a listening one answers a SYN with. The new
conversation goes on the listener's backlog before the SYN and ACK go out.
Whoever reads `listen` then finds it there, whatever the far side does next.
*/
tcp_accept :: proc "contextless" (listener: int, src: libnet.IP, t: libnet.Tcp) #no_bounds_check {
	n := tcp_alloc()
	if n < 0 {
		return
	}
	c := &tcps[n]
	c.state = .Syn_Received
	c.lport = t.dport
	c.raddr = src
	c.rport = t.sport
	c.rcv_nxt = t.seq + 1
	c.snd_nxt = ISS_BASE + u32(n) * ISS_STEP
	c.snd_una = c.snd_nxt

	l := &tcps[listener]
	if l.btail - l.bhead < BACKLOG {
		l.backlog[l.btail % BACKLOG] = n
		l.btail += 1
	}
	answer_listen(listener)

	tcp_output(n, libnet.TCP_SYN | libnet.TCP_ACK, nil)
}

/*
tcp_step is the state machine. Every transition sets this end's state before it
sends anything. A segment for the loopback is handled inside the call that sends
it, and would otherwise find a conversation that had not moved yet.
*/
tcp_step :: proc "contextless" (i: int, t: libnet.Tcp) #no_bounds_check {
	c := &tcps[i]

	if t.flags & libnet.TCP_ACK != 0 && seq_le(c.snd_una, t.ack) {
		c.snd_una = t.ack
	}

	#partial switch c.state {
	case .Syn_Sent:
		if t.flags & libnet.TCP_SYN != 0 && t.flags & libnet.TCP_ACK != 0 {
			c.rcv_nxt = t.seq + 1
			c.state = .Established
			tcp_output(i, libnet.TCP_ACK, nil)
		}
		return

	case .Syn_Received:
		if t.flags & libnet.TCP_ACK != 0 {
			c.state = .Established
		}
		// A SYN and ACK that also carried data falls through to the stream.

	case .Last_Ack:
		if t.flags & libnet.TCP_ACK != 0 {
			c.state = .Closed
		}
		return

	case .Fin_Wait_1:
		if t.flags & libnet.TCP_ACK != 0 && c.snd_una == c.snd_nxt {
			c.state = .Fin_Wait_2
		}

	case .Closed, .Listen:
		return
	}

	// The stream, in every state that has one.
	if len(t.payload) > 0 && t.seq == c.rcv_nxt {
		tcp_push(i, t.payload)
		c.rcv_nxt += u32(len(t.payload))
		tcp_output(i, libnet.TCP_ACK, nil)
		answer_tcp(i)
	}

	// The far side's own close.
	if t.flags & libnet.TCP_FIN != 0 && t.seq + u32(len(t.payload)) == c.rcv_nxt {
		c.rcv_nxt += 1
		c.fin_seen = true
		#partial switch c.state {
		case .Established, .Syn_Received:
			c.state = .Close_Wait
		case .Fin_Wait_1:
			c.state = .Time_Wait
		case .Fin_Wait_2:
			c.state = .Time_Wait
		}
		tcp_output(i, libnet.TCP_ACK, nil)
		answer_tcp(i)
	}
}

// seq_le compares two sequence numbers the way TCP does, on the circle rather
// than the line. A wrap then does not read as a jump backwards.
seq_le :: proc "contextless" (a: u32, b: u32) -> bool {
	return i32(b - a) >= 0
}

// -- What a conversation is told to do ----------------------------------------

tcp_connect :: proc "contextless" (i: int, ip: libnet.IP, port: u16) #no_bounds_check {
	c := &tcps[i]
	c.raddr = ip
	c.rport = port
	c.state = .Syn_Sent
	tcp_output(i, libnet.TCP_SYN, nil)
}

tcp_announce :: proc "contextless" (i: int, port: u16) #no_bounds_check {
	c := &tcps[i]
	c.lport = port
	c.state = .Listen
}

// tcp_hangup starts the close from whichever side this end is on.
tcp_hangup :: proc "contextless" (i: int) #no_bounds_check {
	c := &tcps[i]
	#partial switch c.state {
	case .Established, .Syn_Received:
		c.state = .Fin_Wait_1
		tcp_output(i, libnet.TCP_FIN | libnet.TCP_ACK, nil)
	case .Close_Wait:
		c.state = .Last_Ack
		tcp_output(i, libnet.TCP_FIN | libnet.TCP_ACK, nil)
	case:
		tcp_free(i)
	}
}

// tcp_write sends a run of bytes, a segment at a time.
tcp_write :: proc "contextless" (i: int, data: []u8) -> bool #no_bounds_check {
	c := &tcps[i]
	if c.state != .Established && c.state != .Close_Wait {
		return false
	}
	at := 0
	for at < len(data) {
		n := min(MSS, len(data) - at)
		tcp_output(i, libnet.TCP_PSH | libnet.TCP_ACK, data[at:at + n])
		at += n
	}
	return true
}

// -- The held reads ------------------------------------------------------------

answer_tcp :: proc "contextless" (i: int) {
	lib9p.answer_reads(&srv, rawptr(uintptr(i)), wants_tcp, drain_tcp)
}

wants_tcp :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	i := int(uintptr(arg))
	#partial switch m in request^ {
	case vectra9.Tread:
		node := libuser.fid_lookup(&fids, m.fid)
		conv, kind, ok := tconv_of(node)
		return ok && conv == i && kind == TCONV_DATA
	}
	return false
}

drain_tcp :: proc "contextless" (arg: rawptr, buf: []u8) -> int {
	return tcp_pop(int(uintptr(arg)), buf)
}

answer_listen :: proc "contextless" (i: int) {
	lib9p.answer_reads(&srv, rawptr(uintptr(i)), wants_listen, drain_listen)
}

wants_listen :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	i := int(uintptr(arg))
	#partial switch m in request^ {
	case vectra9.Tread:
		node := libuser.fid_lookup(&fids, m.fid)
		conv, kind, ok := tconv_of(node)
		return ok && conv == i && kind == TCONV_LISTEN
	}
	return false
}

// drain_listen takes the oldest answered connection off the backlog and writes
// its number, which is what a read of `listen` answers.
drain_listen :: proc "contextless" (arg: rawptr, buf: []u8) -> int #no_bounds_check {
	i := int(uintptr(arg))
	c := &tcps[i]
	if c.btail == c.bhead {
		return 0
	}
	n := c.backlog[c.bhead % BACKLOG]
	c.bhead += 1
	sink := libodin.sink_from(buf)
	libodin.put_uint(&sink, u64(n))
	libodin.put_str(&sink, "\n")
	return len(libodin.str(&sink))
}

// -- The control file and the text files --------------------------------------

run_tcp_ctl :: proc "contextless" (i: int, text: string) -> bool #no_bounds_check {
	verb, rest := word(text)
	switch verb {
	case "announce":
		port, ok := scan_port(rest)
		if !ok {
			return false
		}
		tcp_announce(i, port)
		return true
	case "connect":
		addr, _ := word(rest)
		ip, port, ok := scan_addr(addr)
		if !ok {
			return false
		}
		tcp_connect(i, ip, port)
		return true
	case "hangup":
		tcp_hangup(i)
		return true
	}
	return false
}

tcp_state_name :: proc "contextless" (s: Tcp_State) -> string {
	switch s {
	case .Closed:
		return "Closed"
	case .Listen:
		return "Listen"
	case .Syn_Sent:
		return "Syn_Sent"
	case .Syn_Received:
		return "Syn_Received"
	case .Established:
		return "Established"
	case .Fin_Wait_1:
		return "Fin_Wait_1"
	case .Fin_Wait_2:
		return "Fin_Wait_2"
	case .Close_Wait:
		return "Close_Wait"
	case .Last_Ack:
		return "Last_Ack"
	case .Time_Wait:
		return "Time_Wait"
	}
	return "Closed"
}

render_tconv :: proc "contextless" (sink: ^libodin.Sink, i: int, kind: i32) #no_bounds_check {
	c := &tcps[i]
	switch kind {
	case TCONV_LOCAL:
		put_ip(sink, MY_IP)
		libodin.put_str(sink, "!")
		libodin.put_uint(sink, u64(c.lport))
		libodin.put_str(sink, "\n")
	case TCONV_REMOTE:
		if c.state != .Closed && c.state != .Listen {
			put_ip(sink, c.raddr)
			libodin.put_str(sink, "!")
			libodin.put_uint(sink, u64(c.rport))
		}
		libodin.put_str(sink, "\n")
	case TCONV_STATUS:
		libodin.put_str(sink, tcp_state_name(c.state))
		libodin.put_str(sink, " queued ")
		libodin.put_uint(sink, u64(tcp_queued(i)))
		libodin.put_str(sink, "\n")
	}
}
