/*
tcpq -- the three things TCP needs that a loopback does not.

A stream over a loopback is never lost, never reordered and never faster than
the far end can take it. A stream over a network is all three, and these are
what answer them:

    Retx         the segments sent and not yet acknowledged, so one can be
                 sent again when no acknowledgement comes
    Resequencer  the segments that arrived early, held until the one before
                 them arrives
    send_room    how much more the far end has said it will take

They are here rather than in `servers/netfs` because they are arithmetic over
buffers, with no card and no file in them. `tests/net` proves each against
sequences written out by hand. The state machine that drives them is the
server's.

**Time is counted in rounds, not ticks.** Ring 3 has no clock yet, and
`docs/DEVTOOLS.md` step 1 is where `/dev/time` arrives. Until then the caller
passes a number it increments once per pass of its own loop, and a timeout is a
count of those. It is coarse, and it is monotonic, which is what a retransmit
timer needs most.
*/
package libnet

// The most one held or unacknowledged segment carries. A stack with a larger
// segment size than this holds fewer of them, not smaller ones.
SEG_MAX :: 512

// -- The retransmit queue ------------------------------------------------------

RETX_SLOTS :: 8

Retx_Entry :: struct {
	used:    bool,
	seq:     u32,
	flags:   u8,
	len:     int,
	sent_at: u64,
	data:    [SEG_MAX]u8,
}

Retx :: struct {
	entries: [RETX_SLOTS]Retx_Entry,
}

/*
retx_span is how much of the sequence space one segment takes. That is its
bytes, and one more for a SYN or a FIN. Each of those is acknowledged as though
it were a byte.
*/
retx_span :: proc "contextless" (flags: u8, length: int) -> u32 {
	span := u32(length)
	if flags & TCP_SYN != 0 {
		span += 1
	}
	if flags & TCP_FIN != 0 {
		span += 1
	}
	return span
}

/*
retx_push remembers one segment until it is acknowledged. A segment that takes
no sequence space is not remembered, because nothing will ever acknowledge it:
a bare ACK is not retransmitted. Answers false when the queue is full, which a
caller treats as a reason to send no more until something is acknowledged.
*/
retx_push :: proc "contextless" (
	q: ^Retx,
	seq: u32,
	flags: u8,
	payload: []u8,
	now: u64,
) -> bool #no_bounds_check {
	if retx_span(flags, len(payload)) == 0 {
		return true
	}
	if len(payload) > SEG_MAX {
		return false
	}
	for i in 0 ..< RETX_SLOTS {
		e := &q.entries[i]
		if e.used {
			continue
		}
		e.used = true
		e.seq = seq
		e.flags = flags
		e.len = len(payload)
		e.sent_at = now
		for k in 0 ..< len(payload) {
			e.data[k] = payload[k]
		}
		return true
	}
	return false
}

/*
retx_ack drops every segment the far end has now acknowledged, which is every
one whose last sequence number is below `una`. A segment only partly
acknowledged is kept whole, because this stack sends a segment again rather
than the part of it that was missed.
*/
retx_ack :: proc "contextless" (q: ^Retx, una: u32) #no_bounds_check {
	for i in 0 ..< RETX_SLOTS {
		e := &q.entries[i]
		if !e.used {
			continue
		}
		end := e.seq + retx_span(e.flags, e.len)
		if seq_le_u32(end, una) {
			e.used = false
		}
	}
}

/*
retx_due answers the oldest segment that waited longer than `after` rounds with
no acknowledgement, which is the one to send again. Oldest first, so a
stream catches up in the order it was written.
*/
retx_due :: proc "contextless" (q: ^Retx, now: u64, after: u64) -> (int, bool) #no_bounds_check {
	best := -1
	for i in 0 ..< RETX_SLOTS {
		e := &q.entries[i]
		if !e.used || now < e.sent_at + after {
			continue
		}
		if best < 0 || e.sent_at < q.entries[best].sent_at {
			best = i
		}
	}
	return best, best >= 0
}

// retx_sent marks a segment as sent again now, so its timer runs from here.
retx_sent :: proc "contextless" (q: ^Retx, i: int, now: u64) #no_bounds_check {
	if i >= 0 && i < RETX_SLOTS {
		q.entries[i].sent_at = now
	}
}

// retx_count is how many segments are waiting to be acknowledged.
retx_count :: proc "contextless" (q: ^Retx) -> int #no_bounds_check {
	n := 0
	for i in 0 ..< RETX_SLOTS {
		if q.entries[i].used {
			n += 1
		}
	}
	return n
}

// seq_le_u32 compares two sequence numbers on the circle rather than the line,
// so a wrap does not read as a jump backwards.
seq_le_u32 :: proc "contextless" (a: u32, b: u32) -> bool {
	return i32(b - a) >= 0
}

// -- The resequencer -----------------------------------------------------------

RESEQ_SLOTS :: 4

Reseq_Entry :: struct {
	used: bool,
	seq:  u32,
	len:  int,
	data: [SEG_MAX]u8,
}

Resequencer :: struct {
	entries: [RESEQ_SLOTS]Reseq_Entry,
}

/*
reseq_insert holds a segment that arrived before the one in front of it. A
segment already held for that sequence is left alone. A full store answers
false, which drops the segment, and the far side will send it again.
*/
reseq_insert :: proc "contextless" (r: ^Resequencer, seq: u32, data: []u8) -> bool #no_bounds_check {
	if len(data) == 0 || len(data) > SEG_MAX {
		return false
	}
	for i in 0 ..< RESEQ_SLOTS {
		if r.entries[i].used && r.entries[i].seq == seq {
			return true
		}
	}
	for i in 0 ..< RESEQ_SLOTS {
		e := &r.entries[i]
		if e.used {
			continue
		}
		e.used = true
		e.seq = seq
		e.len = len(data)
		for k in 0 ..< len(data) {
			e.data[k] = data[k]
		}
		return true
	}
	return false
}

/*
reseq_take answers the held segment that begins exactly at `next`, copies it
into `out`, and forgets it. A caller runs it in a loop, advancing `next` by what
it answered, until it answers nothing. That is the run of segments an arrival
just made contiguous.
*/
reseq_take :: proc "contextless" (r: ^Resequencer, next: u32, out: []u8) -> int #no_bounds_check {
	for i in 0 ..< RESEQ_SLOTS {
		e := &r.entries[i]
		if !e.used || e.seq != next {
			continue
		}
		n := min(e.len, len(out))
		for k in 0 ..< n {
			out[k] = e.data[k]
		}
		e.used = false
		return n
	}
	return 0
}

// reseq_held is how many segments are waiting for the one in front of them.
reseq_held :: proc "contextless" (r: ^Resequencer) -> int #no_bounds_check {
	n := 0
	for i in 0 ..< RESEQ_SLOTS {
		if r.entries[i].used {
			n += 1
		}
	}
	return n
}

// reseq_drop forgets everything held, which a close does.
reseq_drop :: proc "contextless" (r: ^Resequencer) #no_bounds_check {
	for i in 0 ..< RESEQ_SLOTS {
		r.entries[i].used = false
	}
}

// -- The window ----------------------------------------------------------------

/*
send_room is how many more bytes the far end will take. That is its window, less
what is already sent and not yet acknowledged. A window smaller than what
is in flight answers zero rather than a negative, which stops the sender until
an acknowledgement makes room.
*/
send_room :: proc "contextless" (snd_una: u32, snd_nxt: u32, peer_window: u16) -> int {
	in_flight := int(snd_nxt - snd_una)
	room := int(peer_window) - in_flight
	if room < 0 {
		return 0
	}
	return room
}
