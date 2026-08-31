/*
intuition, first half -- the draw server `docs/DRAW.md` designed.

The compositor this directory is named for does not exist yet. What
stands here is the file it will one day serve from the inside: `/dev/draw`
as a protocol, six verbs on a `data` file, image zero the screen. When
compositing arrives it grows in this process, image zero quietly becomes
a window, and the protocol does not change. That test chose this home.

The tenant shape is `ramfs`'s, not `consrv`'s, because nothing here
parks. A draw command runs to completion -- the framebuffer takes a write
at its own pace and never waits for hardware -- so one serve loop answers
everything inline, and the server needs no fork, no worker, and no lock.

The tree is `docs/DRAW.md` section 4's:

    /data    the command stream, one session per fid
    /ctl     text lines in, the geometry /dev/fbctl reports out

A session's images live in a static pool, because ring 3 has no
allocator. The pool is eight images of 2048 pixels each, which is a
cursor and a glyph set's worth. The pool is a cap to raise, not a design:
a fid owns what it allocates, and a clunk gives it back.

The screen is reached the way `painter` reached it: `/dev/fb` at an
offset, one seek and one write per touched row. Every draw is clipped to
its destination first, so the file's own boundary rules are never the
error path a client sees.
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

// The image pool. Image zero is the screen and lives nowhere; these are
// the client's images, owned by the fid that allocated each.
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

// One row of screen bytes under construction. Sized for a 2048-pixel row,
// which covers every mode the framebuffer reports today.
ROW_CAP :: 8192
row: [ROW_CAP]u8

// The geometry, read from /dev/fbctl once at start. The bytes are served
// back on /ctl verbatim, and the four numbers steer every screen draw.
geo: [160]u8
geo_len: int
scr_w: int
scr_h: int
scr_pitch: int

// The framebuffer descriptor, open for the server's whole life.
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
numbers, or a depth other than 32 -- and 0x71 a post that failed. The
serve loop's three endings are `ramfs`'s, numbers and all.
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
	geo_len = int(n)

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
	return scr_w > 0 && scr_h > 0 && scr_pitch >= scr_w * 4 && scr_w * 4 <= ROW_CAP
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

// screen_row writes one prepared row of `w` pixels at (x, y): a seek and
// a write. The caller clipped already, so a refusal from the file is a
// real error rather than a boundary case.
screen_row :: proc "contextless" (x: int, y: int, w: int) -> bool {
	offset := u64(y) * u64(scr_pitch) + u64(x) * 4
	if libuser.seek(fb_fd, offset) < 0 {
		return false
	}
	return libuser.write_full(fb_fd, row[:w * 4])
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
			// Flush promises visibility. Every draw above went straight to
			// the glass, so the promise is already kept. When image zero
			// becomes a window, this verb becomes the damage mark.
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
		if !clip(&x, &y, &w, &h, &sx, &sy, scr_w, scr_h) {
			return vectra9.Errno(0)
		}
		for i in 0 ..< w {
			libdraw.put_u32(row[:], i * 4, color)
		}
		for line in 0 ..< h {
			if !screen_row(x, y + line, w) {
				return vectra9.EIO
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

	// The screen is a destination, never a source. Reading the glass back
	// is /dev/fb's job, and no client in the needs list wants it here.
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
		if !clip(&dx, &dy, &sw, &sh, &sx, &sy, scr_w, scr_h) {
			return vectra9.Errno(0)
		}
		for line in 0 ..< sh {
			base := (sy + line) * simg.w + sx
			// Pixel words are already the row's bytes -- see `run_load`.
			bytes := ([^]u8)(raw_data(pixels[sslot][base:]))
			copy(row[:sw * 4], bytes[:sw * 4])
			if !screen_row(dx, dy + line, sw) {
				return vectra9.EIO
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
	// The images before the slot. A fid on `data` owns whatever it allocated,
	// and the table is what says which fid that was.
	if libuser.fid_lookup(&fids, fid) == NODE_DATA {
		image_free_all(fid)
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
