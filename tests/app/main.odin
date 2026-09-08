/*
apptest -- a `sys/libapp` client, `docs/DEVTOOLS.md` step 2.

The platform layer's spine, made a program: it opens a window, and each frame
fills the client area a ground colour and paints a marker square where the
pointer is, then presents. It runs until its window closes under it, or until a
safety cap of frames, then closes and exits. The self-test opens it, reads the
ground and the marker off the glass, injects a pointer move, and stops the
server so the window closes -- which is the C program of section 4 in Odin,
before the C one and the game.
*/
package main

import "base:runtime"

import "vsys:abi"
import "vsys:libapp"
import "vsys:libthread"

// The two colours the self-test reads off the glass, each one nothing else on
// this screen makes.
GROUND :: u32(0x0022_4466)
MARKER :: u32(0x00EE_8822)
MARK_SZ :: 16

// A cap, so a run the self-test never stops still ends rather than spins the
// glass for ever. Large, because the stop is the window closing, not the cap:
// tens of seconds at the pace below, long past when the self-test is done.
MAX_FRAMES :: 20000

// The marker is drawn this far down and right of the pointer, so it does not
// sit under the cursor sprite the self-test reads around.
MARK_OFF :: 28

threadmain :: proc "contextless" (arg: rawptr) {
	app: libapp.App
	if !libapp.open(&app, "apptest", 360, 240) {
		libthread.threadexitsall("noopen")
	}

	for _ in 0 ..< MAX_FRAMES {
		f := libapp.frame(&app)
		// The ground, every frame, so the marker's last place is rubbed out.
		for y in 0 ..< f.height {
			row := y * f.stride
			for x in 0 ..< f.width {
				f.pixels[row + x] = GROUND
			}
		}
		// The marker down-right of the pointer, clamped to the client area.
		mx := clamp(f.mouse_x + MARK_OFF, 0, max(f.width - MARK_SZ, 0))
		my := clamp(f.mouse_y + MARK_OFF, 0, max(f.height - MARK_SZ, 0))
		for y in 0 ..< MARK_SZ {
			row := (my + y) * f.stride
			for x in 0 ..< MARK_SZ {
				f.pixels[row + mx + x] = MARKER
			}
		}
		libapp.present(&app)
		// The window closing ends it -- the self-test's stop, which hangs the
		// window up so the pointer read the io thread parks on returns nothing.
		if f.quit {
			break
		}
		// Give the pointer thread its turn: a busy frame loop yields nowhere.
		libapp.pump(&app)
	}

	libapp.close(&app)
	libthread.threadexitsall("")
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()
	libthread.main(threadmain, nil)
}
