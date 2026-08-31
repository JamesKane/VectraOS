/*
intuition -- the draw server `docs/DRAW.md` designed, with windows.

**Image zero is the session's window, not the screen.** That sentence was
the test this topology was chosen to pass, and it cost the protocol
nothing: the six verbs, their bodies and their rules are what they were,
and a client that drew to image zero before this milestone draws to its
own window now without changing a line.

A client cannot name the screen. It has no verb that reaches past its
window's edge, no way to learn where its window sits, and no way to ask
for another. That is the whole of the isolation, and it is one
translation and one clip in `run_fill` and `run_blit`.

The tenant shape is `ramfs`'s, not `consrv`'s, because nothing here
parks. A draw command runs to completion -- the framebuffer takes a write
at its own pace and never waits for hardware -- so one serve loop answers
everything inline, and the server needs no fork, no worker, and no lock.

The tree is `docs/DRAW.md` section 4's:

    /data    the command stream, one session per fid, one window per session
    /ctl     text lines in, the geometry of a window out

**`ctl` reports the window rather than the screen**, and that is the second
half of a client not knowing where it is. Every window is the same size, so
one report answers for all of them, and a client that reads it learns how
big it is and nothing about the glass.

A session's images live in a static pool, because ring 3 has no
allocator. The pool is eight images of 2048 pixels each, which is a
cursor and a glyph set's worth. The pool is a cap to raise, not a design:
a fid owns what it allocates, and a clunk gives it back.

**The screen is memory, not a file this server writes to.** `/dev/fb` is
opened for the namespace's sake and attached with `segattach`, and every
draw after that is a store. `docs/DRAW.md` section 7 argued the mapping a
milestone before it existed, and named its trigger: the day this server
touches whole frames every round.

That is the one privilege this process has over its clients, and section 2
is why it is not a feature the protocol owes them. A client sends commands.
The server, which *is* the compositor, holds the glass.

Every draw is still clipped to its destination first, so a client's mistake
is an answer rather than a store past the end of the screen. The bound is
this server's arithmetic now, where it used to be the file's.
*/
package intuition

import "base:runtime"

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_DATA :: i32(1)
NODE_CTL :: i32(2)

/*
The windows, and the placement policy that hands them out.

Two, side by side, full height. A session gets one when it opens `data` and
gives it back when the fid goes, which makes the assignment as automatic as
the image pool's and needs no protocol for it.

**A client cannot choose.** `docs/DRAW.md` section 5 names scope creep as the
failure mode the verb table guards, and a window a client places is a verb or a
`ctl` line that nothing yet needs. The day something does, it is a line on
`ctl` and not a seventh verb.

`MAX_WINDOWS` is a cap to raise rather than a design. Two is what the self-test
needs to prove that a second client cannot reach the first's pixels, which is
the only claim this file makes about isolation.
*/
MAX_WINDOWS :: 2

Window :: struct {
	owner: vectra9.Fid,
	x:     int,
	y:     int,
	w:     int,
	h:     int,
	used:  bool,
}

windows: [MAX_WINDOWS]Window

// The image pool. Image zero is the session's window and lives nowhere; these
// are the client's own images, owned by the fid that allocated each.
MAX_IMAGES :: 8
IMG_PIXELS :: 2048

Image :: struct {
	owner:  vectra9.Fid,
	id:     u32,
	w:      int,
	h:      int,
	used:   bool,
}

images: [MAX_IMAGES]Image
pixels: [MAX_IMAGES][IMG_PIXELS]u32

/*
The screen itself, once `segattach` answers.

A `[^]u32` rather than bytes, because every mode this server accepts is 32
bits per pixel and `read_geometry` refuses anything else at start. The pitch
is in bytes and is divided down once, so the per-row arithmetic is an index
rather than a multiply and a cast.
*/
glass: [^]u32
glass_stride: int

/*
The screen's geometry, read from `/dev/fbctl` once at start, and the window
geometry served on `/ctl` in its place.

Two reports, and the second is the only one a client sees. `/dev/fbctl` says
how big the glass is, which is what the placement arithmetic below needs.
`/ctl` says how big a window is, which is all a client needs and all it may
know.
*/
geo: [160]u8
geo_len: int
scr_w: int
scr_h: int
scr_pitch: int
win_w: int
win_h: int

// The framebuffer descriptor. Open for the server's whole life, because the
// attach is a claim on the file rather than a copy of it.
fb_fd: int



fids: libuser.Fid_Table

FRAME :: 1200
frame_in: [FRAME]u8
frame_out: [FRAME]u8
payload: [1024]u8

/*
_start opens the screen, learns its shape, and serves.

The exits each name their failure. 0x74 is a framebuffer that would not
open, 0x76 a geometry this server cannot draw on -- fewer than four
numbers, or a depth other than 32 -- 0x77 a screen that would not map,
and 0x71 a post that failed. The serve loop's three endings are `ramfs`'s,
numbers and all.
*/
@(export, link_name = "_start")
start :: proc "sysv" (data: uintptr, arg: u64, arg2: u64) {
	context = {}
	#force_no_inline runtime._startup_runtime()

	fd := libuser.open("/dev/fb", abi.O_WRONLY)
	if fd < 0 {
		libuser.exit(0x74)
	}
	fb_fd = int(fd)

	ctl := libuser.open("/dev/fbctl", abi.O_RDONLY)
	if ctl < 0 {
		libuser.exit(0x74)
	}
	n := libuser.read(int(ctl), geo[:])
	_ = libuser.close(int(ctl))
	if n <= 0 || !read_geometry(geo[:int(n)]) {
		libuser.exit(0x76)
	}

	// What `/ctl` answers from here on: the window's shape, not the screen's.
	// The screen's numbers stay in `scr_*`, where the placement uses them.
	geo_len = window_report(geo[:])

	// The mapping, and the reason this server has no write path left. A
	// failure here is fatal rather than a fallback: a second path to the same
	// pixels would be a second thing to keep correct, and the self-test could
	// not tell which one drew.
	base, aerr := libuser.segattach(fb_fd)
	if aerr < 0 {
		libuser.exit(0x77)
	}
	glass = ([^]u32)(base)
	glass_stride = scr_pitch / 4

	sfd, perr := libuser.post("/srv/draw")
	if perr < 0 {
		libuser.exit(0x71)
	}

	_, why := libuser.serve(sfd, handler, nil, frame_in[:], frame_out[:], payload[:])
	switch why {
	case .Removed:
		libuser.exit(0)
	case .Hangup:
		libuser.exit(0x68)
	case .Broken:
		libuser.exit(0x72)
	}
}

/*
read_geometry takes what `libdraw.parse_geometry` decodes and keeps only
a shape this server can draw on. The channel lines after the numbers are
not read -- one pixel format is the v1 rule, and a depth other than 32
is refused at start rather than mid-draw.
*/
read_geometry :: proc "contextless" (report: []u8) -> bool {
	w, h, pitch, depth, ok := libdraw.parse_geometry(report)
	if !ok || depth != 32 {
		return false
	}
	scr_w = w
	scr_h = h
	scr_pitch = pitch
	if scr_w <= 0 || scr_h <= 0 || scr_pitch < scr_w * 4 || scr_pitch % 4 != 0 {
		return false
	}

	// Columns, full height. Integer division leaves at most `MAX_WINDOWS - 1`
	// columns of pixels at the right edge unowned, which nothing draws to and
	// nothing may.
	win_w = scr_w / MAX_WINDOWS
	win_h = scr_h
	return win_w > 0
}

/*
window_report writes the geometry a client reads off `/ctl`.

The same four numbers `/dev/fbctl` uses, so `libdraw.parse_geometry` reads
either. The pitch is the window's own row in bytes, which is a number a client
never needs and would be wrong to act on: nothing here lets a client address
its window by offset.
*/
window_report :: proc "contextless" (out: []u8) -> int #no_bounds_check {
	at := 0
	at = put_report(out, at, "size ")
	at = put_number(out, at, win_w)
	at = put_report(out, at, " ")
	at = put_number(out, at, win_h)
	at = put_report(out, at, " ")
	at = put_number(out, at, win_w * 4)
	at = put_report(out, at, " 32\n")
	return at
}

@(private = "file")
put_report :: proc "contextless" (out: []u8, at: int, text: string) -> int #no_bounds_check {
	n := at
	for i in 0 ..< len(text) {
		if n >= len(out) {
			return n
		}
		out[n] = text[i]
		n += 1
	}
	return n
}

@(private = "file")
put_number :: proc "contextless" (out: []u8, at: int, value: int) -> int #no_bounds_check {
	digits: [20]u8
	n := 0
	v := u64(value)
	if v == 0 {
		digits[0] = '0'
		n = 1
	}
	for v > 0 {
		digits[n] = u8('0' + v % 10)
		v /= 10
		n += 1
	}
	out_at := at
	for i := n - 1; i >= 0; i -= 1 {
		if out_at >= len(out) {
			return out_at
		}
		out[out_at] = digits[i]
		out_at += 1
	}
	return out_at
}

// -- The windows --------------------------------------------------------------

/*
window_open gives this fid a window, or reports that there is none free.

Placement is the whole policy: column `i` of `MAX_WINDOWS`, full height. A
session that already holds one gets it back rather than a second, because a
second `Tlopen` on one fid is a client re-opening what it has.
*/
window_open :: proc "contextless" (owner: vectra9.Fid) -> bool #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		if windows[i].used && windows[i].owner == owner {
			return true
		}
	}
	for i in 0 ..< MAX_WINDOWS {
		if !windows[i].used {
			windows[i] = Window {
				owner = owner,
				x     = i * win_w,
				y     = 0,
				w     = win_w,
				h     = win_h,
				used  = true,
			}
			return true
		}
	}
	return false
}

// window_close gives one back, and is the other half of the session rule the
// image pool already keeps.
window_close :: proc "contextless" (owner: vectra9.Fid) #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		if windows[i].used && windows[i].owner == owner {
			windows[i] = Window{}
		}
	}
}

// window_of is which window a session draws into. Nil is a fid that opened
// nothing, which cannot reach a draw and is checked anyway.
window_of :: proc "contextless" (owner: vectra9.Fid) -> ^Window #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		if windows[i].used && windows[i].owner == owner {
			return &windows[i]
		}
	}
	return nil
}

// -- The images ---------------------------------------------------------------

image_find :: proc "contextless" (owner: vectra9.Fid, id: u32) -> int #no_bounds_check {
	for i in 0 ..< MAX_IMAGES {
		if images[i].used && images[i].owner == owner && images[i].id == id {
			return i
		}
	}
	return -1
}

// image_alloc takes a pool slot for this fid. A duplicate id, an id of
// zero, and a size past the slot are each the client's error. A full pool
// is the server's, and answers ENOSPC.
image_alloc :: proc "contextless" (owner: vectra9.Fid, id: u32, w: int, h: int) -> vectra9.Errno #no_bounds_check {
	if id == 0 || w <= 0 || h <= 0 || w * h > IMG_PIXELS {
		return vectra9.EINVAL
	}
	if image_find(owner, id) >= 0 {
		return vectra9.EINVAL
	}
	for i in 0 ..< MAX_IMAGES {
		if !images[i].used {
			images[i] = Image{owner = owner, id = id, w = w, h = h, used = true}
			return vectra9.Errno(0)
		}
	}
	return vectra9.ENOSPC
}

// image_free_all is the clunk's half of the session rule: what a fid
// allocated goes when the fid does.
image_free_all :: proc "contextless" (owner: vectra9.Fid) #no_bounds_check {
	for i in 0 ..< MAX_IMAGES {
		if images[i].used && images[i].owner == owner {
			images[i] = Image{}
		}
	}
}

// -- The screen ---------------------------------------------------------------

// screen_at is where row `y` starts in the mapped screen. The caller clipped
// already, so this never has a boundary to check.
screen_at :: proc "contextless" (y: int) -> [^]u32 #no_bounds_check {
	return glass[y * glass_stride:]
}

// clip trims a rectangle to a destination's bounds, moving a source
// origin by the same trim. Reports whether anything is left.
clip :: proc "contextless" (x: ^int, y: ^int, w: ^int, h: ^int, sx: ^int, sy: ^int, bw: int, bh: int) -> bool {
	if x^ < 0 {
		w^ += x^
		sx^ -= x^
		x^ = 0
	}
	if y^ < 0 {
		h^ += y^
		sy^ -= y^
		y^ = 0
	}
	if x^ + w^ > bw {
		w^ = bw - x^
	}
	if y^ + h^ > bh {
		h^ = bh - y^
	}
	return w^ > 0 && h^ > 0
}

// -- The verbs ----------------------------------------------------------------

/*
run_commands walks one write's worth of the stream and executes each
command, `docs/DRAW.md` section 5's rules exactly. A malformed command
fails the whole write, and what stood before it already drew. Fill and
blit clip to their destination. A load must fit its image whole, because
a load is transport rather than drawing.
*/
run_commands :: proc "contextless" (owner: vectra9.Fid, data: []u8) -> vectra9.Errno #no_bounds_check {
	at := 0
	for at < len(data) {
		if len(data) - at < libdraw.HEADER {
			return vectra9.EINVAL
		}
		size := int(libdraw.get_u16(data, at))
		if size < libdraw.HEADER || at + size > len(data) || data[at + 3] != 0 {
			return vectra9.EINVAL
		}
		verb := data[at + 2]
		body := data[at + libdraw.HEADER:at + size]

		err := vectra9.Errno(0)
		switch verb {
		case libdraw.ALLOC:
			err = run_alloc(owner, body)
		case libdraw.LOAD:
			err = run_load(owner, body)
		case libdraw.FILL:
			err = run_fill(owner, body)
		case libdraw.BLIT:
			err = run_blit(owner, body)
		case libdraw.FREE:
			err = run_free(owner, body)
		case libdraw.FLUSH:
			// Flush promises visibility, and every draw above went straight
			// to the glass through the window's clip. The promise is kept
			// before the verb arrives. It becomes the damage mark the day a
			// window has pixels of its own to be damaged -- see
			// `docs/DRAW.md` section 7 for the memory bound that is.
			if len(body) != 0 {
				err = vectra9.EINVAL
			}
		case:
			err = vectra9.EINVAL
		}
		if err != vectra9.Errno(0) {
			return err
		}
		at += size
	}
	return vectra9.Errno(0)
}

run_alloc :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) != 12 {
		return vectra9.EINVAL
	}
	id := libdraw.get_u32(body, 0)
	w := int(libdraw.get_u32(body, 4))
	h := int(libdraw.get_u32(body, 8))
	return image_alloc(owner, id, w, h)
}

run_load :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) < 20 {
		return vectra9.EINVAL
	}
	id := libdraw.get_u32(body, 0)
	x := int(libdraw.get_u32(body, 4))
	y := int(libdraw.get_u32(body, 8))
	w := int(libdraw.get_u32(body, 12))
	h := int(libdraw.get_u32(body, 16))
	slot := image_find(owner, id)
	if slot < 0 || w <= 0 || h <= 0 {
		return vectra9.EINVAL
	}
	img := &images[slot]
	if x < 0 || y < 0 || x + w > img.w || y + h > img.h {
		return vectra9.EINVAL
	}
	if len(body) - 20 != w * h * 4 {
		return vectra9.EINVAL
	}
	// The wire and the one build target are both little-endian, so a row
	// of payload is byte-identical to the pixel words. One copy per row,
	// no per-pixel decode.
	for line in 0 ..< h {
		base := (y + line) * img.w + x
		src := 20 + line * w * 4
		dst := ([^]u8)(raw_data(pixels[slot][base:]))
		copy(dst[:w * 4], body[src:src + w * 4])
	}
	return vectra9.Errno(0)
}

run_fill :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) != 24 {
		return vectra9.EINVAL
	}
	id := libdraw.get_u32(body, 0)
	x := int(libdraw.get_u32(body, 4))
	y := int(libdraw.get_u32(body, 8))
	w := int(libdraw.get_u32(body, 12))
	h := int(libdraw.get_u32(body, 16))
	color := libdraw.get_u32(body, 20)

	sx := 0
	sy := 0
	if id == 0 {
		win := window_of(owner)
		if win == nil {
			return vectra9.EBADF
		}
		// Clip in the window's own coordinates, then translate. The other
		// order would clip against the screen and let a client past its edge.
		if !clip(&x, &y, &w, &h, &sx, &sy, win.w, win.h) {
			return vectra9.Errno(0)
		}
		for line in 0 ..< h {
			dst := screen_at(win.y + y + line)
			for i in 0 ..< w {
				dst[win.x + x + i] = color
			}
		}
		return vectra9.Errno(0)
	}

	slot := image_find(owner, id)
	if slot < 0 {
		return vectra9.EINVAL
	}
	img := &images[slot]
	if !clip(&x, &y, &w, &h, &sx, &sy, img.w, img.h) {
		return vectra9.Errno(0)
	}
	for line in 0 ..< h {
		base := (y + line) * img.w + x
		for i in 0 ..< w {
			pixels[slot][base + i] = color
		}
	}
	return vectra9.Errno(0)
}

run_blit :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) != 32 {
		return vectra9.EINVAL
	}
	dst := libdraw.get_u32(body, 0)
	dx := int(libdraw.get_u32(body, 4))
	dy := int(libdraw.get_u32(body, 8))
	src := libdraw.get_u32(body, 12)
	sx := int(libdraw.get_u32(body, 16))
	sy := int(libdraw.get_u32(body, 20))
	sw := int(libdraw.get_u32(body, 24))
	sh := int(libdraw.get_u32(body, 28))

	// A window is a destination, never a source. Reading pixels back is
	// /dev/fb's job, and a client that could read image zero could read
	// whatever a window above it last drew there.
	if src == 0 {
		return vectra9.EINVAL
	}
	sslot := image_find(owner, src)
	if sslot < 0 || sw <= 0 || sh <= 0 {
		return vectra9.EINVAL
	}
	simg := &images[sslot]
	if sx < 0 || sy < 0 || sx + sw > simg.w || sy + sh > simg.h {
		return vectra9.EINVAL
	}

	if dst == 0 {
		win := window_of(owner)
		if win == nil {
			return vectra9.EBADF
		}
		if !clip(&dx, &dy, &sw, &sh, &sx, &sy, win.w, win.h) {
			return vectra9.Errno(0)
		}
		for line in 0 ..< sh {
			base := (sy + line) * simg.w + sx
			out := screen_at(win.y + dy + line)
			for i in 0 ..< sw {
				out[win.x + dx + i] = pixels[sslot][base + i]
			}
		}
		return vectra9.Errno(0)
	}

	dslot := image_find(owner, dst)
	if dslot < 0 {
		return vectra9.EINVAL
	}
	dimg := &images[dslot]
	if !clip(&dx, &dy, &sw, &sh, &sx, &sy, dimg.w, dimg.h) {
		return vectra9.Errno(0)
	}
	for line in 0 ..< sh {
		sbase := (sy + line) * simg.w + sx
		dbase := (dy + line) * dimg.w + dx
		for i in 0 ..< sw {
			pixels[dslot][dbase + i] = pixels[sslot][sbase + i]
		}
	}
	return vectra9.Errno(0)
}

run_free :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) != 4 {
		return vectra9.EINVAL
	}
	slot := image_find(owner, libdraw.get_u32(body, 0))
	if slot < 0 {
		return vectra9.EINVAL
	}
	images[slot] = Image{}
	return vectra9.Errno(0)
}


// fid_release is also the session teardown: a data fid takes its images
// with it, `docs/DRAW.md` section 4's rule.
fid_release :: proc "contextless" (fid: vectra9.Fid) {
	// The images and the window before the slot. A fid on `data` owns both,
	// and the table is what says which fid that was.
	if libuser.fid_lookup(&fids, fid) == NODE_DATA {
		image_free_all(fid)
		window_close(fid)
	}
	libuser.fid_release(&fids, fid)
}

// -- The tree -----------------------------------------------------------------

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if node == NODE_ROOT {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

name_of :: proc "contextless" (node: i32) -> string {
	switch node {
	case NODE_DATA:
		return "data"
	case NODE_CTL:
		return "ctl"
	}
	return ""
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	switch name {
	case ".":
		return from
	case "..":
		return NODE_ROOT
	}
	if from != NODE_ROOT {
		return -1
	}
	switch name {
	case "data":
		return NODE_DATA
	case "ctl":
		return NODE_CTL
	}
	return -1
}

// -- The handler --------------------------------------------------------------

handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state
	_ = s
	_ = tag

	if !libuser.default_reply(request, reply) {
		return
	}

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)

	case vectra9.Tattach:
		libuser.attach(&fids, m, reply, NODE_ROOT, qid_of)

	case vectra9.Twalk:
		libuser.walk(&fids, m, reply, step, qid_of)

	case vectra9.Tlopen:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		// A session is a fid on `data`, and a session is a window. There is
		// nowhere else for the assignment to happen: the fid exists from the
		// walk, and the first draw may be the next message.
		if node == NODE_DATA && !window_open(m.fid) {
			reply^ = vectra9.error_reply(vectra9.ENOSPC)
			return
		}
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Tread:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		if node == NODE_ROOT {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		if node == NODE_DATA {
			// The command stream is written, never read. What a session
			// drew is on the glass, and the glass is /dev/fb's to answer.
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		report := geo[:geo_len]
		if m.offset >= u64(len(report)) {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		start_at := int(m.offset)
		end := min(len(report), start_at + min(len(buf), int(m.count)))
		copy(buf[:end - start_at], report[start_at:end])
		reply^ = vectra9.Rread{data = buf[:end - start_at]}

	case vectra9.Twrite:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		switch node {
		case NODE_DATA:
			if err := run_commands(m.fid, m.data); err != vectra9.Errno(0) {
				reply^ = vectra9.error_reply(err)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case NODE_CTL:
			// The ctl convention holds the file open for the lines a later
			// milestone defines. None exist yet, so every line is unknown.
			reply^ = vectra9.error_reply(vectra9.EINVAL)
		case:
			reply^ = vectra9.error_reply(vectra9.EISDIR)
		}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := node == NODE_ROOT
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : (node == NODE_DATA ? 0o100222 : 0o100644),
			nlink   = dir ? 2 : 1,
			size    = node == NODE_CTL ? u64(geo_len) : 0,
			blksize = 512,
		}

	case vectra9.Tclunk:
		fid_release(m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		fid_release(m.fid)
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.node_of(&fids, m.fid, reply)
	if !ok {
		return
	}
	if node != NODE_ROOT {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}

	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	for child := i32(m.offset) + 1; child <= NODE_CTL; child += 1 {
		if vectra9.remaining(&c) < vectra9.dirent_size(name_of(child)) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(child),
				offset = u64(child),
				type = vectra9.DT_REG,
				name = name_of(child),
			},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
