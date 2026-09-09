/*
libapp -- the platform layer, `docs/DEVTOOLS.md` section 4's rung 2.

A program that wants the whole frame and none of the toolkit calls `open`, then
loops `frame`, `present` and `close`. `open` claims a window from `/srv/draw`,
resizes it, and attaches its pixel *store* directly -- the shared run the draw
server holds, mapped into the program by the id the window's `store` file names,
so a frame is a write into memory and not a stream of verbs. `frame` hands back
that memory, the seconds since the last frame, and the input drained since;
`present` composites what was painted; `close` gives it all back.

**A `libthread` program inside.** The one input that parks -- the pointer -- is
read on a thread of its own through a `sys/libthread` io proc, which posts each
movement to a channel. `frame` drains the channel without blocking, so a program
that is busy never waits on input and a program that is idle never spins on it.
This is `sys/libmui`'s window loop turned inside out: the toolkit owns the loop
and calls the program back; here the program owns the loop and calls this.

This first cut is the spine: a window, its store, the pointer, and a clock.
Sound, the pads, the keyboard's text and the GPU queue are the rungs above it,
each a field this record will grow. See `docs/DEVTOOLS.md` section 4.
*/
package libapp

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libthread"
import "vsys:libuser"

// The most pointer movements a frame may fall behind before the oldest are
// dropped. A program that calls `frame` every few milliseconds never fills it.
MOUSE_QUEUE :: 64

/*
App is a live window and everything a frame reads or writes: the files it holds,
the store mapped into this program, the pointer's channel, and the clock's last
reading. A program declares one, `open`s it, and passes it to every call.
*/
App :: struct {
	id:         int,
	data_fd:    int,
	ctl_fd:     int,
	store_fd:   int,
	mouse_fd:   int,
	time_fd:    int,
	audio_fd:   int,

	// The format `/dev/audio` plays: the rate in hertz, the channel count, and
	// the bits a sample carries, read once at `open`. `sound` writes samples in
	// this shape. Zero rate is a machine with no card, and `sound` a no-op.
	rate:       int,
	channels:   int,
	bits:       int,

	// The store, mapped by `shmalloc`'s id: `stride` words to a row, the client
	// area at `(cx, cy)` in it, `cw` by `ch`. The run is the whole screen's, so
	// none of these move for the window's life.
	store:      [^]u32,
	store_id:   u64, // the shared run's id, from the store file, handed to shmattach
	stride:     int,
	cx:         int,
	cy:         int,
	cw:         int,
	ch:         int,

	// The clock. `last_uptime` is the nanoseconds-since-boot the last `frame`
	// read, so the next one's `dt` is the difference.
	last_uptime: u64,

	// The pointer, its channel filled by `mouse_io` and drained by `frame`.
	mouse_chan: ^libthread.Chan,
	mouse_x:    int,
	mouse_y:    int,
	buttons:    u32,

	// Set by the io thread when the window's files end, which is the window
	// closing under the program. `frame` reports it as `quit`.
	quit:       bool,

	path:       [64]u8,
	line:       [96]u8,
	geo:        [96]u8,
}

/*
Frame is what a program reads and paints each turn: the pixels it owns, the
seconds since the last frame, and the pointer now. `pixels` is the client area,
`stride` words to a row -- a program writes `pixels[y*stride + x]` for `x` under
`width` and `y` under `height`. `quit` is the window going away.
*/
Frame :: struct {
	pixels:  []u32,
	width:   int,
	height:  int,
	stride:  int,
	dt:      f32,
	mouse_x: int,
	mouse_y: int,
	buttons: u32,
	quit:    bool,
}

/*
open claims a window, sizes it, attaches its store, and starts the pointer
thread. It runs inside `libthread`, because `frame`'s pointer thread does. False
at the first step that cannot be had, each named on standard error.
*/
open :: proc "contextless" (app: ^App, title: string, w: int, h: int) -> bool #no_bounds_check {
	app.data_fd = -1
	app.ctl_fd = -1
	app.store_fd = -1
	app.mouse_fd = -1
	app.time_fd = -1
	app.audio_fd = -1

	if libuser.mount("/srv/draw", "/mnt", abi.ORDER_BEFORE) < 0 {
		return refused("no draw server at /srv/draw")
	}
	nfd := libuser.open("/mnt/new", abi.O_RDONLY)
	if nfd < 0 {
		return refused("the server has no window to give")
	}
	nn := libuser.read(int(nfd), app.geo[:])
	_ = libuser.close(int(nfd))
	scan := 0
	mine, mok := libdraw.scan_int(app.geo[:max(int(nn), 0)], &scan)
	if !mok {
		return refused("the new window has no number")
	}
	app.id = mine

	fd := libuser.open(libdraw.win_path(app.path[:], "/mnt", mine, "data"), abi.O_WRONLY)
	if fd < 0 {
		return refused("the window's data file will not open")
	}
	app.data_fd = int(fd)

	ctl := libuser.open(libdraw.win_path(app.path[:], "/mnt", mine, "ctl"), abi.O_RDWR)
	if ctl < 0 {
		return refused("the window's ctl will not open")
	}
	app.ctl_fd = int(ctl)
	// The size the program asked for, and its name. The store is the whole
	// screen's whatever the window's size, so this only sets `cw`/`ch`.
	sat := copy(app.line[:], "size ")
	sat += put_int(app.line[sat:], w)
	app.line[sat] = ' '
	sat += 1
	sat += put_int(app.line[sat:], h)
	app.line[sat] = '\n'
	sat += 1
	_ = libuser.write(int(ctl), app.line[:sat])
	nat := copy(app.line[:], "name ")
	nat += copy(app.line[nat:], title)
	_ = libuser.write(int(ctl), app.line[:nat])
	// Closed, not held: a window's ctl is exclusive, and a program that kept it
	// would deny anyone else -- a `wctl` mover, or the stop that removes it --
	// the one holder it allows. The store is how a frame reaches the glass now,
	// not the ctl. `sys/libmui` closes it for the same reason.
	_ = libuser.close(int(ctl))
	app.ctl_fd = -1

	// The store: the id to attach, the stride, and where the client area sits.
	sfd := libuser.open(libdraw.win_path(app.path[:], "/mnt", mine, "store"), abi.O_RDWR)
	if sfd < 0 {
		return refused("the window has no store file")
	}
	app.store_fd = int(sfd)
	sn := libuser.read(int(sfd), app.geo[:])
	if !read_store(app, app.geo[:max(int(sn), 0)]) {
		return refused("the store file named no run to attach")
	}
	addr, aerr := libuser.shmattach(app.store_id)
	if aerr < 0 {
		return refused("the store's run would not attach")
	}
	app.store = ([^]u32)(addr)

	mfd := libuser.open(libdraw.win_path(app.path[:], "/mnt", mine, "mouse"), abi.O_RDONLY)
	if mfd >= 0 {
		app.mouse_fd = int(mfd)
	}

	// The clock, and its first reading, so the first `frame`'s `dt` is small.
	tfd := libuser.open("/dev/time", abi.O_RDONLY)
	if tfd >= 0 {
		app.time_fd = int(tfd)
		app.last_uptime = read_uptime(app)
	}

	// Sound, if the machine has a card. A read of `/dev/audio` is the format a
	// program's samples must take -- `rate channels bits`. No card is a rate of
	// zero and a `sound` that writes nowhere.
	afd := libuser.open("/dev/audio", abi.O_RDWR)
	if afd >= 0 {
		app.audio_fd = int(afd)
		fbuf: [32]u8
		fn := libuser.read(int(afd), fbuf[:])
		at := 0
		hz, hz_ok := libdraw.scan_int(fbuf[:max(int(fn), 0)], &at)
		chn, chn_ok := libdraw.scan_int(fbuf[:max(int(fn), 0)], &at)
		bits, bits_ok := libdraw.scan_int(fbuf[:max(int(fn), 0)], &at)
		if hz_ok && chn_ok && bits_ok {
			app.rate = hz
			app.channels = chn
			app.bits = bits
		}
	}

	app.mouse_chan = libthread.chancreate(size_of(u64), MOUSE_QUEUE)
	if app.mouse_chan != nil && app.mouse_fd >= 0 {
		_ = libthread.threadcreate(mouse_io, app)
	}
	return true
}

// pump gives the pointer thread the turn a busy frame loop otherwise never
// yields it. A frame loop paints, presents and calls this; `libthread` is
// cooperative, so a program that only ever paints would starve the io thread
// that parks on the pointer. This is the yield that lets it run, and where a
// vsync wait will go when there is a vblank to wait on.
pump :: proc "contextless" (app: ^App) {
	libthread.yield()
}

// read_store parses the `store` file's line -- `id stride cx cy cw ch` -- into
// the app. False if it did not name six numbers with a nonzero id.
@(private = "file")
read_store :: proc "contextless" (app: ^App, data: []u8) -> bool #no_bounds_check {
	at := 0
	id, id_ok := libdraw.scan_int(data, &at)
	stride, s_ok := libdraw.scan_int(data, &at)
	cx, cx_ok := libdraw.scan_int(data, &at)
	cy, cy_ok := libdraw.scan_int(data, &at)
	cw, cw_ok := libdraw.scan_int(data, &at)
	ch, ch_ok := libdraw.scan_int(data, &at)
	if !id_ok || !s_ok || !cx_ok || !cy_ok || !cw_ok || !ch_ok || id == 0 || stride <= 0 {
		return false
	}
	app.store_id = u64(id)
	app.stride = stride
	app.cx = cx
	app.cy = cy
	app.cw = cw
	app.ch = ch
	return true
}

/*
frame drains the pointer since the last turn, reads the clock, and hands back
the pixels to paint. It never blocks: a program in a tight loop sees the pointer
where it last stopped, and one that sleeps between frames catches every step the
channel held. The pixels are the client area of the store, addressed by the
stride the whole run has.
*/
frame :: proc "contextless" (app: ^App) -> Frame #no_bounds_check {
	// Every movement the io thread has posted, so the pointer is where it now
	// is rather than one step behind.
	if app.mouse_chan != nil {
		for {
			packed, got := libthread.nbrecvul(app.mouse_chan)
			if !got {
				break
			}
			app.mouse_x = int(packed & 0xFFFF)
			app.mouse_y = int((packed >> 16) & 0xFFFF)
			app.buttons = u32((packed >> 32) & 0xFF)
		}
	}

	dt: f32 = 0
	if app.time_fd >= 0 {
		now := read_uptime(app)
		if now > app.last_uptime {
			dt = f32(f64(now - app.last_uptime) / 1_000_000_000.0)
		}
		app.last_uptime = now
	}

	base := app.cy * app.stride + app.cx
	span := app.ch * app.stride
	return Frame {
		pixels = app.store[base:base + span],
		width = app.cw,
		height = app.ch,
		stride = app.stride,
		dt = dt,
		mouse_x = app.mouse_x,
		mouse_y = app.mouse_y,
		buttons = app.buttons,
		quit = app.quit,
	}
}

/*
present composites what the program painted. A write to the store names the
client rectangle to flush; this flushes the whole client area, which is the
frame a game paints each turn. `vsync` is a later rung -- there is no vblank to
wait on yet -- and is taken for the shape the loop will keep.
*/
present :: proc "contextless" (app: ^App, vsync: bool = true) #no_bounds_check {
	at := copy(app.line[:], "0 0 ")
	at += put_int(app.line[at:], app.cw)
	app.line[at] = ' '
	at += 1
	at += put_int(app.line[at:], app.ch)
	app.line[at] = '\n'
	at += 1
	_ = libuser.write(app.store_fd, app.line[:at])
}

/*
sound hands the next slice of audio to the device, in the shape `open` read:
interleaved signed sixteen-bit samples, `channels` to a frame, at `rate` a
second. It answers how many samples the device took. A machine with no card
takes none. The write drains at the rate, so a program that hands it a slice
each frame is paced by the sound as much as by the frame.
*/
sound :: proc "contextless" (app: ^App, samples: []i16) -> int #no_bounds_check {
	if app.audio_fd < 0 || len(samples) == 0 {
		return 0
	}
	bytes := ([^]u8)(raw_data(samples))[:len(samples) * 2]
	n := libuser.write(app.audio_fd, bytes)
	if n <= 0 {
		return 0
	}
	return int(n) / 2
}

// close gives the window and its store back. The io thread ends when the mouse
// file it reads is gone, which the close makes true; a program that exits after
// this takes the thread with it in any case.
close :: proc "contextless" (app: ^App) {
	if app.store != nil {
		_ = libuser.segdetach(uintptr(app.store))
		app.store = nil
	}
	if app.audio_fd >= 0 {_ = libuser.close(app.audio_fd)}
	if app.mouse_fd >= 0 {_ = libuser.close(app.mouse_fd)}
	if app.store_fd >= 0 {_ = libuser.close(app.store_fd)}
	if app.ctl_fd >= 0 {_ = libuser.close(app.ctl_fd)}
	if app.data_fd >= 0 {_ = libuser.close(app.data_fd)}
	if app.time_fd >= 0 {_ = libuser.close(app.time_fd)}
}

// -- The pointer thread -------------------------------------------------------

// mouse_io reads the window's pointer and posts each movement to the channel.
// A `libthread` thread of this program's own proc, reading through an io proc
// so the read parks without stopping the frame loop -- the shape `sys/libmui`'s
// window uses, so `threadexitsall` takes it down with the program. A read that
// ends is the window gone, which sets `quit` and stops the thread.
@(private = "file")
mouse_io :: proc "contextless" (arg: rawptr) #no_bounds_check {
	app := (^App)(arg)
	io := libthread.ioproc()
	if io == nil {
		return
	}
	line: [64]u8
	for {
		got := libthread.ioread(io, app.mouse_fd, line[:])
		if got <= 0 {
			app.quit = true
			return
		}
		x, y, b, ok := parse_mouse(line[:int(got)])
		if !ok {
			continue
		}
		packed := u64(u16(x)) | u64(u16(y)) << 16 | u64(u8(b)) << 32
		_ = libthread.nbsendul(app.mouse_chan, packed)
	}
}

// parse_mouse reads a `rio` mouse line -- `m x y buttons msec` -- into the
// pointer now. The coordinates are the window's own client area's.
@(private = "file")
parse_mouse :: proc "contextless" (data: []u8) -> (x: int, y: int, b: int, ok: bool) #no_bounds_check {
	if len(data) < 1 || data[0] != 'm' {
		return 0, 0, 0, false
	}
	at := 1
	xv, xok := libdraw.scan_int(data, &at)
	yv, yok := libdraw.scan_int(data, &at)
	bv, bok := libdraw.scan_int(data, &at)
	if !xok || !yok || !bok {
		return 0, 0, 0, false
	}
	return xv, yv, bv, true
}

// -- The clock ----------------------------------------------------------------

// read_uptime reads `/dev/time`'s fifth field, the nanoseconds since boot, for
// a frame's `dt`. A value file answers the whole line at any offset, so one
// read at zero is enough. The register fast path -- `rdtsc` and its kin -- is a
// later rung; this file is the calibration `docs/DEVTOOLS.md` section 4 keeps.
@(private = "file")
read_uptime :: proc "contextless" (app: ^App) -> u64 #no_bounds_check {
	buf: [96]u8
	n := libuser.read(app.time_fd, buf[:])
	if n <= 0 {
		return app.last_uptime
	}
	at := 0
	// sec nsec fastticks fasthz uptime -- the fifth is what a dt needs.
	for _ in 0 ..< 4 {
		_, ok := libdraw.scan_int(buf[:int(n)], &at)
		if !ok {
			return app.last_uptime
		}
	}
	up, ok := libdraw.scan_int(buf[:int(n)], &at)
	if !ok || up < 0 {
		return app.last_uptime
	}
	return u64(up)
}

// -- Small helpers ------------------------------------------------------------

// put_int writes an unsigned decimal into a buffer and answers its length.
@(private = "file")
put_int :: proc "contextless" (b: []u8, v: int) -> int #no_bounds_check {
	if v <= 0 {
		b[0] = '0'
		return 1
	}
	tmp: [20]u8
	n := 0
	x := v
	for x > 0 {
		tmp[n] = u8('0' + x % 10)
		x /= 10
		n += 1
	}
	for i in 0 ..< n {
		b[i] = tmp[n - 1 - i]
	}
	return n
}

// refused says on standard error why a window could not be had, and answers
// the false `open` returns.
@(private = "file")
refused :: proc "contextless" (why: string) -> bool {
	libuser.eprint("app: no window: ", why, "\n")
	return false
}
