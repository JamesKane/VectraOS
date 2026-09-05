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

**What a network needs and a loopback does not.** A segment sent and not
acknowledged is kept and sent again, so one the network drops still arrives. A
segment that comes early waits in a resequencer until the one before it does. A
segment whose address is not yet resolved waits in the stack's ARP hold and goes
out when the reply teaches us where. These live in `sys/libnet`, and the state
machine here drives them. The window this end advertises is a number the far
side reads, and does not yet hold a sender of ours back.

`docs/FLEET.md` step 0 wants congestion control on this. This is the state
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
	// What a network needs and a loopback does not. The segments sent and not
	// acknowledged, the ones that came early, and what the far end will take.
	retx:     libnet.Retx,
	reseq:    libnet.Resequencer,
	peer_win: u16,
}

/*
The round this stack is on, and how many rounds a segment waits before it is
sent again. A round is one pass of the ether thread's loop, and the device read bounds it.
So this is a coarse monotonic clock rather than a tick count.
`docs/DEVTOOLS.md` step 1 is where a real one arrives.
*/
now_round: u64
RETX_AFTER :: u64(2)

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
		libnet.reseq_drop(&tcps[i].reseq)
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
tcp_output sends one new segment: it takes the next sequence numbers, remembers
the segment for a retransmit, and puts it on the wire. The segment is built on
the stack rather than in the shared frame buffer. A loopback segment is handled
inside this call, and would otherwise overwrite the buffer it came from.
*/
tcp_output :: proc "contextless" (i: int, flags: u8, payload: []u8) #no_bounds_check {
	c := &tcps[i]
	seq := c.snd_nxt

	// SYN and FIN each take a sequence number, and so does every byte sent.
	// The count moves before the segment goes, because a loopback answers
	// inside the send.
	c.snd_nxt += libnet.retx_span(flags, len(payload))

	// Remembered before it is sent, so an answer that comes back inside this
	// call finds it there to acknowledge.
	_ = libnet.retx_push(&c.retx, seq, flags, payload, now_round)
	_ = tcp_emit(i, seq, flags, payload)
}

/*
tcp_resend puts one remembered segment on the wire again, with the sequence
number it had the first time. Nothing about the conversation moves: this is the
same segment, not a new one.
*/
tcp_resend :: proc "contextless" (i: int, slot: int) #no_bounds_check {
	e := &tcps[i].retx.entries[slot]
	// A send that could not reach the wire, because the far side's hardware
	// address is not yet known, does not count against the segment's tries.
	// It waits in the ARP hold and goes out when the reply teaches us the
	// address. Counting it would spend a connection's whole patience on the
	// first round-trip that resolves a cold address.
	if tcp_emit(i, e.seq, e.flags, e.data[:e.len]) {
		libnet.retx_sent(&tcps[i].retx, slot, now_round)
	}
}

/*
tcp_emit builds one segment with the sequence number it is given. `ip_output`
then decides whether it is delivered here or put on the card. The
segment is built on the stack: a loopback segment is handled inside that call,
and the shared frame buffer is `ip_output`'s.
*/
tcp_emit :: proc "contextless" (i: int, seq: u32, flags: u8, payload: []u8) -> bool #no_bounds_check {
	c := &tcps[i]
	seg: [TCP_HDR_MAX]u8 = ---
	t := libnet.Tcp {
		sport   = c.lport,
		dport   = c.rport,
		seq     = seq,
		ack     = c.rcv_nxt,
		flags   = flags,
		window  = u16(TCP_RQ - (c.tail - c.head)),
		payload = payload,
	}
	end := libnet.put_tcp(seg[:], 0, my_ip, c.raddr, t)
	return ip_output(c.raddr, libnet.IPPROTO_TCP, seg[:end])
}

/*
tcp_emit_synack sends the SYN and ACK again with the sequence number it first
had, without touching the retransmit timer or its count of tries. It answers a
SYN that arrived again while this end was still waiting to be acknowledged.
*/
tcp_emit_synack :: proc "contextless" (i: int) #no_bounds_check {
	_ = tcp_emit(i, tcps[i].snd_una, libnet.TCP_SYN | libnet.TCP_ACK, nil)
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
	t, ok := libnet.parse_tcp(seg, src, my_ip)
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
	wake_listen[listener] = true

	tcp_output(n, libnet.TCP_SYN | libnet.TCP_ACK, nil)
}

/*
tcp_step is the state machine. Every transition sets this end's state before it
sends anything. A segment for the loopback is handled inside the call that sends
it, and would otherwise find a conversation that had not moved yet.
*/
tcp_step :: proc "contextless" (i: int, t: libnet.Tcp) #no_bounds_check {
	c := &tcps[i]

	c.peer_win = t.window
	if t.flags & libnet.TCP_ACK != 0 && libnet.seq_le_u32(c.snd_una, t.ack) {
		c.snd_una = t.ack
		libnet.retx_ack(&c.retx, c.snd_una)
	}

	#partial switch c.state {
	case .Syn_Sent:
		if t.flags & libnet.TCP_SYN != 0 && t.flags & libnet.TCP_ACK != 0 {
			c.rcv_nxt = t.seq + 1
			c.state = .Established
			tcp_output(i, libnet.TCP_ACK, nil)
			// The connect that was held on this conversation can return now.
			wake_connect[i] = true
		}
		return

	case .Syn_Received:
		if t.flags & libnet.TCP_ACK != 0 {
			c.state = .Established
		} else if t.flags & libnet.TCP_SYN != 0 {
			// The far side is still asking, which means our answer was lost or
			// has not arrived yet. Send it again rather than waiting out the
			// retransmit timer, so a cold link settles in one round-trip.
			tcp_emit_synack(i)
			return
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

	/*
	The stream, in every state that has one. A segment that begins where the
	stream does is taken, and then whatever was held for it. An early segment
	waits in the resequencer until the one in front of it arrives. A segment
	that begins past the stream is early, and is held. One that begins before
	it has already been taken, and is only acknowledged again.
	*/
	if len(t.payload) > 0 {
		if t.seq == c.rcv_nxt {
			tcp_push(i, t.payload)
			c.rcv_nxt += u32(len(t.payload))
			// And the run the arrival just made contiguous.
			held: [libnet.SEG_MAX]u8 = ---
			for {
				n := libnet.reseq_take(&c.reseq, c.rcv_nxt, held[:])
				if n == 0 {
					break
				}
				tcp_push(i, held[:n])
				c.rcv_nxt += u32(n)
			}
			tcp_output(i, libnet.TCP_ACK, nil)
			wake_tcp[i] = true
		} else if libnet.seq_le_u32(c.rcv_nxt, t.seq) {
			_ = libnet.reseq_insert(&c.reseq, t.seq, t.payload)
			tcp_output(i, libnet.TCP_ACK, nil)
		} else {
			tcp_output(i, libnet.TCP_ACK, nil)
		}
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
		wake_tcp[i] = true
	}
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
/*
tcp_release frees a listener whose last open `listen` file was clunked. A
program that stops listening, or exits, then leaves no conversation matching
SYNs that nothing will accept. This is Plan 9's teardown of a listen
conversation when its files close: the conversation stops matching, and its slot
is free again. The wake flags clear first. A flag raised for the old
conversation must not answer a held read on the one that reuses the slot.
*/
tcp_release :: proc "contextless" (i: int) #no_bounds_check {
	wake_tcp[i] = false
	wake_listen[i] = false
	wake_connect[i] = false
	tcp_free(i)
}

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
		// Only as much as the far end will take, and only while there is
		// somewhere to remember the segment for a retransmit.
		room := libnet.send_room(c.snd_una, c.snd_nxt, window_of(c))
		if room <= 0 || libnet.retx_count(&c.retx) >= libnet.RETX_SLOTS {
			break
		}
		n := min(min(MSS, len(data) - at), room)
		if n <= 0 {
			break
		}
		tcp_output(i, libnet.TCP_PSH | libnet.TCP_ACK, data[at:at + n])
		at += n
	}
	return at > 0
}

/*
window_of is the far end's window, or one segment's worth before it names one. A
conversation the handshake established already knows a window, so this stands in
only for the moment before that.
*/
window_of :: proc "contextless" (c: ^Tcp_Conv) -> u16 {
	return c.peer_win == 0 ? u16(MSS) : c.peer_win
}

/*
tcp_tick is one round of the clock. A conversation whose segment waited too long
sends that segment again. This is the whole of what makes a
stream survive a network that drops one.
*/
tcp_tick :: proc "contextless" () #no_bounds_check {
	now_round += 1
	for i in 0 ..< MAX_TCP {
		c := &tcps[i]
		if !c.used || c.state == .Listen || c.state == .Closed {
			continue
		}
		if slot, due := libnet.retx_due(&c.retx, now_round, RETX_AFTER); due {
			tcp_resend(i, slot)
			continue
		}
		// A segment sent its last time and still unacknowledged means the far
		// end is not there. The conversation closes, so a caller waiting on it
		// is told rather than left holding a read for ever.
		if libnet.retx_lost(&c.retx) {
			c.state = .Closed
			c.fin_seen = true
			wake_tcp[i] = true
			// A connect that never got its answer fails here, rather than
			// leaving the write that started it held for ever.
			wake_connect[i] = true
		}
	}
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

/*
answer_connect answers the held `connect` write once the conversation settles.
Established answers the write, which is how a synchronous `dial` learns the
stream is ready. Anything else is a connect that did not open, and the write
fails so the caller is told rather than left waiting.
*/
answer_connect :: proc "contextless" (i: int) {
	req, ok := lib9p.held(&srv, rawptr(uintptr(i)), wants_connect)
	if !ok {
		return
	}
	if m, is_write := req.msg.(vectra9.Twrite); is_write && tcps[i].state == .Established {
		_ = lib9p.respond(req, vectra9.Rwrite{count = u32(len(m.data))})
		return
	}
	_ = lib9p.respond(req, vectra9.error_reply(vectra9.ETIMEDOUT))
}

wants_connect :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	i := int(uintptr(arg))
	#partial switch m in request^ {
	case vectra9.Twrite:
		node := libuser.fid_lookup(&fids, m.fid)
		conv, kind, ok := tconv_of(node)
		return ok && conv == i && kind == TCONV_CTL
	}
	return false
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

/*
The fate of a control line, which decides how the write that carried it is
answered. `Done` answers at once. `Connecting` holds the write until the
handshake finishes, so a `connect` is synchronous the way Plan 9's is. The
write returns when the conversation is established, and fails when it cannot
be. `Bad` is a line that did not parse or a command that could not run.
*/
Tcp_Ctl :: enum {
	Bad,
	Done,
	Connecting,
}

run_tcp_ctl :: proc "contextless" (i: int, text: string) -> Tcp_Ctl #no_bounds_check {
	verb, rest := word(text)
	switch verb {
	case "announce":
		port, ok := scan_port(rest)
		if !ok {
			return .Bad
		}
		tcp_announce(i, port)
		return .Done
	case "connect":
		addr, _ := word(rest)
		ip, port, ok := scan_addr(addr)
		if !ok {
			return .Bad
		}
		tcp_connect(i, ip, port)
		// A loopback handshake finishes inside the call. Anything else is still
		// in flight, and the write waits for it.
		#partial switch tcps[i].state {
		case .Established:
			return .Done
		case .Closed:
			return .Bad
		}
		return .Connecting
	case "hangup":
		tcp_hangup(i)
		return .Done
	}
	return .Bad
}

/*
The name each state answers under `status`. An array over the enum rather than a
switch, so a state added later fails to compile here instead of quietly
reporting itself as `Closed`.
*/
TCP_STATE_NAME := [Tcp_State]string {
	.Closed       = "Closed",
	.Listen       = "Listen",
	.Syn_Sent     = "Syn_Sent",
	.Syn_Received = "Syn_Received",
	.Established  = "Established",
	.Fin_Wait_1   = "Fin_Wait_1",
	.Fin_Wait_2   = "Fin_Wait_2",
	.Close_Wait   = "Close_Wait",
	.Last_Ack     = "Last_Ack",
	.Time_Wait    = "Time_Wait",
}

render_tconv :: proc "contextless" (sink: ^libodin.Sink, i: int, kind: i32) #no_bounds_check {
	c := &tcps[i]
	switch kind {
	case TCONV_LOCAL:
		put_ip(sink, my_ip)
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
		libodin.put_str(sink, TCP_STATE_NAME[c.state])
		libodin.put_str(sink, " queued ")
		libodin.put_uint(sink, u64(tcp_queued(i)))
		libodin.put_str(sink, "\n")
	}
}
