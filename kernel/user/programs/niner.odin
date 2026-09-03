/*
niner -- the first 9P server that is a program.

It makes a pipe, posts the client end in /srv, and then answers requests it
reads off the serve end. It answers version, attach, walk and open, and
forwards a write's payload to the console. It answers a read from its own
text, and the remove tells it to stop. The replies are built byte by byte
over the request, because a program this small carries no codec. The frame
layout is the 9P2000.L wire format, and docs/VECTRA9.md is the reference.

The frame lives in the data page at slot C, and a frame longer than the
slot, or shorter than a header, ends the program with a status the
self-test recognises as the wire going wrong.
*/
package programs

import "vsys:libuser"

@(private = "file") FRAME_MAX :: 256
@(private = "file") BROKEN :: u64(0x77)

@(private = "file")
get16 :: proc "contextless" (b: []u8, at: int) -> int {
	return int(b[at]) | int(b[at + 1]) << 8
}

@(private = "file")
get32 :: proc "contextless" (b: []u8, at: int) -> int {
	return int(b[at]) | int(b[at + 1]) << 8 | int(b[at + 2]) << 16 | int(b[at + 3]) << 24
}

@(private = "file")
put16 :: proc "contextless" (b: []u8, at: int, v: int) {
	b[at] = u8(v)
	b[at + 1] = u8(v >> 8)
}

@(private = "file")
put32 :: proc "contextless" (b: []u8, at: int, v: int) {
	b[at] = u8(v)
	b[at + 1] = u8(v >> 8)
	b[at + 2] = u8(v >> 16)
	b[at + 3] = u8(v >> 24)
}

@(private = "file")
put64 :: proc "contextless" (b: []u8, at: int, v: u64) {
	for i in 0 ..< 8 {
		b[at + i] = u8(v >> (8 * u64(i)))
	}
}

niner :: proc "contextless" (cells: ^Cells) -> ! {
	cells[0] = 0x4E494E454E494E45
	frame := slot(cells, 256, FRAME_MAX)

	ends := libuser.pipe()
	put(cells, 1, ends)
	serve := int(ends & 255)
	client := int(ends >> 8 & 255)

	name := libuser.create("/srv/niner", 1, 384)
	put(cells, 2, name)
	put(cells, 3, libuser.write(int(name), transmute([]u8)string("4")))
	put(cells, 4, libuser.close(int(name)))
	put(cells, 5, libuser.close(client))

	served := u64(0)
	for {
		if !libuser.read_full(serve, frame[:7]) {
			libuser.exit(BROKEN)
		}
		size := get32(frame, 0)
		if size > FRAME_MAX || size < 7 {
			libuser.exit(BROKEN)
		}
		if !libuser.read_full(serve, frame[7:size]) {
			libuser.exit(BROKEN)
		}

		reply := 0
		stop := false
		switch frame[4] {
		case 100: // Tversion: echo it, as Rversion
			frame[4] = 101
			reply = size
		case 104: // Tattach: a directory qid
			put32(frame, 0, 20)
			frame[4] = 105
			frame[7] = 0x80
			put32(frame, 8, 0)
			put64(frame, 12, 1)
			reply = 20
		case 110: // Twalk: one file qid per name asked for
			n := get16(frame, 15)
			frame[4] = 111
			put16(frame, 7, n)
			at := 9
			for _ in 0 ..< n {
				frame[at] = 0
				put32(frame, at + 1, 0)
				put64(frame, at + 5, 2)
				at += 13
			}
			reply = get16(frame, 7) * 13 + 9
			put32(frame, 0, reply)
		case 12: // Tlopen: the file qid, no iounit
			put32(frame, 0, 24)
			frame[4] = 13
			frame[7] = 0
			put32(frame, 8, 0)
			put64(frame, 12, 2)
			put32(frame, 20, 0)
			reply = 24
		case 118: // Twrite: the payload to the console, the count back
			count := get32(frame, 19)
			_ = libuser.write(1, frame[23:][:count])
			put32(frame, 7, count)
			put32(frame, 0, 11)
			frame[4] = 119
			reply = 11
		case 116: // Tread: our own words
			put32(frame, 0, 39)
			frame[4] = 117
			put32(frame, 7, 28)
			copy(frame[11:39], "these bytes came from ring 3")
			reply = 39
		case 120: // Tclunk
			put32(frame, 0, 7)
			frame[4] = 121
			reply = 7
		case 122: // Tremove: the last request
			put32(frame, 0, 7)
			frame[4] = 123
			reply = 7
			stop = true
		case: // Rlerror EOPNOTSUPP
			put32(frame, 0, 11)
			frame[4] = 7
			put32(frame, 7, 95)
			reply = 11
		}

		served += 1
		cells[6] = served
		if !libuser.write_full(serve, frame[:reply]) {
			libuser.exit(BROKEN)
		}
		if stop {
			libuser.exit(0)
		}
	}
}
