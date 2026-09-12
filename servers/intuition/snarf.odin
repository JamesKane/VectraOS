/*
The snarf buffer, `docs/WORKBENCH.md` section 4: `rio`'s `/dev/snarf` served
here, one clipboard the whole desktop shares. It is a file at the server's
root, `snarf`, and a name in every window's directory too, so the bind that
puts a window's files over `/dev` -- `cmd/window`'s and `sys/libmui`'s -- makes
`/dev/snarf` this window's without a second bind. Whichever path reaches it,
it is the one buffer: the name in a window's directory has no window of its
own.

A write replaces it and pushes what was there onto a ten-deep history,
`snarfhist`, so a thing cut over is not lost. The bytes are a thing's own --
text, or a `sys/libdraw` image a program reads back as pixels -- so the buffer
is bytes and nothing parses them.

**It is capped, and the cap is small on purpose.** A cut is a selection, not a
file, and the buffer and its ten-deep history are static memory in a server
whose whole image must fit the loader's per-program budget (`docs/USER.md`'s
`MAX_PROGRAM_FRAMES`), beside a glyph atlas that is already megabytes. So the
buffer holds a line or a paragraph or a small image, and a write past the cap
keeps the first `SNARF_MAX` bytes and says it took the rest -- a client does
not spin trying to hand over more, and a program with more than that to pass
has a file and a path, not a clipboard. A larger buffer is a day the budget
grows.
*/
package intuition

SNARF_MAX :: 4096
SNARF_HISTORY :: 10

snarf_buf: [SNARF_MAX]u8
snarf_n: int

// The history, a ring: `snarf_head` counts pushes, and its low bits are the
// next slot. The count held is `min(snarf_head, SNARF_HISTORY)`, and the
// newest is the slot before `snarf_head`.
snarf_hist: [SNARF_HISTORY][SNARF_MAX]u8
snarf_hist_len: [SNARF_HISTORY]int
snarf_head: int

// snarf_push puts the current buffer onto the history, newest last. An empty
// buffer is not pushed: a first cut has nothing to lose, and a history of
// blanks is no history.
snarf_push :: proc "contextless" () #no_bounds_check {
	if snarf_n == 0 {
		return
	}
	slot := snarf_head % SNARF_HISTORY
	copy(snarf_hist[slot][:snarf_n], snarf_buf[:snarf_n])
	snarf_hist_len[slot] = snarf_n
	snarf_head += 1
}

/*
snarf_write takes one write. At offset zero it replaces the buffer, after
pushing the old contents onto the history; past zero it appends, so a thing
that arrives in several writes -- an image down a pipe -- lands whole and
pushes the old buffer exactly once. A write that would run past the cap keeps
what fits. The count returned is the whole write's, cap or no, so the client
is not asked to send the overflow again.
*/
snarf_write :: proc "contextless" (offset: u64, data: []u8) -> int #no_bounds_check {
	if offset == 0 {
		snarf_push()
		snarf_n = 0
	}
	// No holes: a write past the end lands at the end, which is also how the
	// second and later writes of one hand-over append.
	at := min(int(offset), snarf_n)
	take := min(len(data), SNARF_MAX - at)
	copy(snarf_buf[at:at + take], data[:take])
	snarf_n = at + take
	return len(data)
}

// snarf_read answers the buffer from `offset`, as much of it as fits in `out`.
snarf_read :: proc "contextless" (out: []u8, offset: u64) -> int #no_bounds_check {
	if offset >= u64(snarf_n) {
		return 0
	}
	from := int(offset)
	n := min(len(out), snarf_n - from)
	copy(out[:n], snarf_buf[from:from + n])
	return n
}

/*
snarfhist_read answers the history as one stream, newest first, each entry
followed by a newline. It is served by `offset` over that virtual
concatenation, so a reader that wants it all reads until it gets nothing, the
way every other file here is read.

It walks the ring each call rather than materialise the whole thing, because a
read asks for a bufferful and the history is read seldom. An image in the
history runs its bytes in with the newlines between text cuts, which is the
honest cost of one buffer for both kinds: the history is for getting a text
cut back, and an image cut is rare and whole in the buffer until the next one.
*/
snarfhist_read :: proc "contextless" (out: []u8, offset: u64) -> int #no_bounds_check {
	want := int(offset)
	pos := 0 // byte position in the virtual concatenation
	n := 0 // bytes written to out
	count := min(snarf_head, SNARF_HISTORY)
	for k in 0 ..< count {
		// Newest first: the slot before `snarf_head`, then the one before that.
		slot := ((snarf_head - 1 - k) % SNARF_HISTORY + SNARF_HISTORY) % SNARF_HISTORY
		elen := snarf_hist_len[slot]
		for i in 0 ..< elen {
			if pos >= want && n < len(out) {
				out[n] = snarf_hist[slot][i]
				n += 1
			}
			pos += 1
		}
		if pos >= want && n < len(out) {
			out[n] = '\n'
			n += 1
		}
		pos += 1
		if n >= len(out) {
			break
		}
	}
	return n
}
