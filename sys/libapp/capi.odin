/*
capi -- `sys/libapp`'s C face, `docs/DEVTOOLS.md` section 4's "both languages,
one source."

The library is Odin, and this is the wall a C program calls it through: one
`proc "c"` per entry, exported under a `vapp_` name `sys/include/vectra/libapp.h`
declares. A C program links the Odin package (the mixed image `tests/cmix`
proves) and reaches it only here.

**`vapp_run` is the one a C program calls first.** A C `main` cannot call the
library directly: the frame loop runs inside `libthread`, and the Odin runtime
must be up before a slice is touched. So `vapp_run` starts the runtime and enters
the scheduler with a trampoline that calls back into the C worker, and never
returns. Everything the worker then calls has a runtime under it.

The `App` a C program holds is an opaque blob it never looks inside; `Frame`
becomes `VFrame`, a slice flattened to a pointer and a length, filled through an
out-pointer rather than returned by value, which is the one shape that crosses
the C ABI without a fight.
*/
package libapp

import "base:runtime"

import "vsys:libthread"

// The C `App` blob is this many bytes; `sys/include/vectra/libapp.h` matches it.
// A window's `App` must fit, or a C program's array is too small to hold one.
#assert(size_of(App) <= 512)

// VFrame is `Frame` for C: the pixels as a pointer and a count rather than an
// Odin slice, and fixed-width fields a header can name.
VFrame :: struct {
	pixels:      [^]u32,
	pixel_count: i64,
	width:       i32,
	height:      i32,
	stride:      i32,
	dt:          f32,
	mouse_x:     i32,
	mouse_y:     i32,
	buttons:     u32,
	quit:        b32,
}

// The C worker and its argument, kept here because `libthread.main` takes one
// `contextless` proc and this must reach it as a `proc "c"`. `vapp_run` is
// called once, so a package word is enough.
@(private = "file")
c_worker: proc "c" (arg: rawptr)
@(private = "file")
c_worker_arg: rawptr

@(private = "file")
trampoline :: proc "contextless" (arg: rawptr) {
	if c_worker != nil {
		c_worker(c_worker_arg)
	}
}

/*
vapp_run starts the runtime and the scheduler and hands control to a C worker.
A C `main` calls it once; it never returns. The worker runs on a `libthread`
thread with the runtime live, so it may call every other entry here.
*/
@(export, link_name = "vapp_run")
vapp_run :: proc "c" (fn: proc "c" (arg: rawptr), arg: rawptr) {
	context = {}
	#force_no_inline runtime._startup_runtime()
	c_worker = fn
	c_worker_arg = arg
	libthread.main(trampoline, nil)
}

// vapp_open claims and sizes a window and attaches its store. `title` is a C
// string, measured here into the Odin string `open` takes.
@(export, link_name = "vapp_open")
vapp_open :: proc "c" (app: ^App, title: cstring, w: i32, h: i32) -> b32 #no_bounds_check {
	p := ([^]u8)(rawptr(title))
	n := 0
	for p != nil && p[n] != 0 {
		n += 1
	}
	name := n > 0 ? string(p[:n]) : ""
	return b32(open(app, name, int(w), int(h)))
}

// vapp_frame drains the input and hands back the pixels through `out`, the
// out-pointer form of `frame` so no struct crosses the ABI by value.
@(export, link_name = "vapp_frame")
vapp_frame :: proc "c" (app: ^App, out: ^VFrame) {
	f := frame(app)
	out.pixels = raw_data(f.pixels)
	out.pixel_count = i64(len(f.pixels))
	out.width = i32(f.width)
	out.height = i32(f.height)
	out.stride = i32(f.stride)
	out.dt = f.dt
	out.mouse_x = i32(f.mouse_x)
	out.mouse_y = i32(f.mouse_y)
	out.buttons = f.buttons
	out.quit = b32(f.quit)
}

@(export, link_name = "vapp_present")
vapp_present :: proc "c" (app: ^App, vsync: b32) {
	present(app, bool(vsync))
}

// vapp_sound hands `count` interleaved samples to the device, and answers how
// many it took. `count` is samples, not frames: two to a stereo frame.
@(export, link_name = "vapp_sound")
vapp_sound :: proc "c" (app: ^App, samples: [^]i16, count: i32) -> i32 #no_bounds_check {
	if samples == nil || count <= 0 {
		return 0
	}
	return i32(sound(app, samples[:int(count)]))
}

// vapp_rate answers the samples-a-second the device plays, and vapp_channels
// how many to a frame -- what a program shapes its tone to.
@(export, link_name = "vapp_rate")
vapp_rate :: proc "c" (app: ^App) -> i32 {
	return i32(app.rate)
}

@(export, link_name = "vapp_channels")
vapp_channels :: proc "c" (app: ^App) -> i32 {
	return i32(app.channels)
}

@(export, link_name = "vapp_pump")
vapp_pump :: proc "c" (app: ^App) {
	pump(app)
}

@(export, link_name = "vapp_close")
vapp_close :: proc "c" (app: ^App) {
	close(app)
}

// vapp_threadexitsall ends the program, every thread of it, the way a C worker
// that is done -- or one that could not open a window -- leaves.
@(export, link_name = "vapp_threadexitsall")
vapp_threadexitsall :: proc "c" () {
	libthread.threadexitsall("")
}
