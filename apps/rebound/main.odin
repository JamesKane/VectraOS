/*
rebound -- a game on `sys/libapp`, `docs/DEVTOOLS.md` step 2's playable one.

A ball falls and bounces; the mouse moves a paddle to send it back up. Miss it
and it starts again from the middle. It is `open`, a loop of `frame`, `present`
and `pump`, and `close` -- the platform layer used the way a game uses it, small
enough to read. The self-test starts it and closes it; a person plays it with
the pointer.

The motion is in real seconds: `frame`'s `dt` scales every step, so the ball
crosses the window at the same speed whatever the frame rate, and a slow frame
moves it further rather than slowing it down. `dt` is capped, so a stall makes
the ball jump a bounded distance rather than teleport through the paddle.
*/
package main

import "base:runtime"

import "vsys:abi"
import "vsys:libapp"
import "vsys:libthread"

// The chassis palette: deep slate ground, an amber ball, a cyan paddle.
GROUND :: u32(0x0010_1830)
BALL_INK :: u32(0x00FF_BF00)
PADDLE_INK :: u32(0x0040_C0FF)

BALL_R :: 6 // half the ball's square side
PADDLE_W :: 84
PADDLE_H :: 10
PADDLE_UP :: 26 // the paddle's distance from the bottom edge

// A cap, so a run nobody plays still ends rather than bounce for ever. The stop
// is the window closing; this is only the backstop.
MAX_FRAMES :: 200000

// fill paints one rectangle of the client area, clipped to it.
fill :: proc "contextless" (f: ^libapp.Frame, x: int, y: int, w: int, h: int, ink: u32) #no_bounds_check {
	x0 := clamp(x, 0, f.width)
	y0 := clamp(y, 0, f.height)
	x1 := clamp(x + w, 0, f.width)
	y1 := clamp(y + h, 0, f.height)
	for yy in y0 ..< y1 {
		row := yy * f.stride
		for xx in x0 ..< x1 {
			f.pixels[row + xx] = ink
		}
	}
}

threadmain :: proc "contextless" (arg: rawptr) {
	app: libapp.App
	if !libapp.open(&app, "rebound", 480, 360) {
		libthread.threadexitsall("noopen")
	}

	// The ball starts in the middle, going down and to the right, in pixels a
	// second. The paddle follows the pointer.
	bx: f32 = 240
	by: f32 = 120
	vx: f32 = 190
	vy: f32 = 165

	for _ in 0 ..< MAX_FRAMES {
		f := libapp.frame(&app)
		w := f.width
		h := f.height

		// The step, in seconds, capped so a stalled frame does not fling the
		// ball through the paddle.
		dt := f.dt
		if dt > 0.05 {
			dt = 0.05
		}

		// The paddle, centred on the pointer, kept inside the window.
		px := clamp(f.mouse_x - PADDLE_W / 2, 0, max(w - PADDLE_W, 0))
		py := h - PADDLE_UP

		// The ball moves, and turns at the walls.
		bx += vx * dt
		by += vy * dt
		if bx < BALL_R {
			bx = BALL_R
			vx = -vx
		}
		if bx > f32(w - BALL_R) {
			bx = f32(w - BALL_R)
			vx = -vx
		}
		if by < BALL_R {
			by = BALL_R
			vy = -vy
		}

		// The paddle, if the ball is falling onto it and over it.
		ibx := int(bx)
		if vy > 0 && int(by) + BALL_R >= py && int(by) + BALL_R <= py + PADDLE_H {
			if ibx >= px && ibx <= px + PADDLE_W {
				by = f32(py - BALL_R)
				vy = -vy
			}
		}

		// Missed: past the bottom, and it starts again from the middle.
		if by > f32(h + BALL_R) {
			bx = f32(w / 2)
			by = f32(h / 2)
			vy = -abs(vy)
		}

		// The frame: ground, paddle, ball.
		fill(&f, 0, 0, w, h, GROUND)
		fill(&f, px, py, PADDLE_W, PADDLE_H, PADDLE_INK)
		fill(&f, int(bx) - BALL_R, int(by) - BALL_R, BALL_R * 2, BALL_R * 2, BALL_INK)
		libapp.present(&app)

		if f.quit {
			break
		}
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
