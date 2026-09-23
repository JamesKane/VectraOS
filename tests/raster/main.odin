/*
raster -- `sys/libraster`'s operations, checked against pixels worked out by
hand, `docs/CHROME.md` brick 3.

The kernel's self-test spawns this program and reads the word it exits with.
The word is `ok` when every step held, or the name of the first that did not.
Each step paints into a small canvas in this program's own memory and reads
pixels back.
No window is opened, so a painter that is wrong is found here and not on the
glass.
*/
package rastertest

import "vsys:abi"
import "vsys:libraster"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
}

W :: 64
H :: 48
pix: [W * H]u32
scratch: [W * 2]u32

BLACK :: u32(0x000000)
WHITE :: u32(0xFFFFFF)
RED :: u32(0xFF0000)
BLUE :: u32(0x0000FF)

fresh :: proc "contextless" (v: u32) -> libraster.Canvas {
	for i in 0 ..< len(pix) {
		pix[i] = v
	}
	return libraster.canvas(raw_data(pix[:]), W, W, H)
}

chan :: proc "contextless" (v: u32, shift: uint) -> int {
	return int(v >> shift & 0xFF)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	// -- A fill paints its rectangle, clipped, and nothing else ---------------
	{
		c := fresh(BLACK)
		libraster.fill(&c, 10, 10, 5, 4, RED)
		want(libraster.get(&c, 10, 10) == RED && libraster.get(&c, 14, 13) == RED, "a fill paints its corners")
		want(libraster.get(&c, 15, 10) == BLACK && libraster.get(&c, 10, 14) == BLACK, "and nothing past them")
		libraster.fill(&c, W - 2, H - 2, 10, 10, BLUE)
		want(libraster.get(&c, W - 1, H - 1) == BLUE, "a fill off the edge is clipped, not refused")
	}

	// -- A blend is the arithmetic -------------------------------------------
	{
		half := libraster.blend(BLACK, WHITE, 128)
		want(chan(half, 16) == 128 && chan(half, 0) == 128, "white over black at 128 is 128 grey")
		want(libraster.blend(RED, BLUE, 0) == RED && libraster.blend(RED, BLUE, 255) == BLUE, "alpha 0 keeps, 255 replaces")
	}

	// -- A vertical gradient: top on the first row, bottom on the last -------
	{
		c := fresh(BLACK)
		libraster.vgrad(&c, 0, 0, W, 11, BLACK, WHITE)
		want(libraster.get(&c, 5, 0) == BLACK, "a gradient's first row is its top colour")
		want(libraster.get(&c, 5, 10) == WHITE, "and its last row its bottom colour")
		mid := chan(libraster.get(&c, 5, 5), 8)
		want(mid > 120 && mid < 136, "and its middle row halfway")
		want(libraster.get(&c, 5, 11) == BLACK, "and below it nothing")
	}

	// -- A radial disc: the centre its inner colour, the rim smooth ----------
	{
		c := fresh(BLACK)
		libraster.radial(&c, 20, 20, 8, WHITE, RED)
		want(libraster.get(&c, 20, 20) == WHITE, "a disc's centre is its inner colour")
		want(libraster.get(&c, 20, 30) == BLACK && libraster.get(&c, 30, 30) == BLACK, "and past its rim nothing")
		rim := libraster.get(&c, 28, 20)
		want(chan(rim, 16) > 128 && chan(rim, 0) < 128, "and its rim is near its outer colour")
	}

	// -- Noise: the same grain every time, varied, and bounded ---------------
	{
		c := fresh(0x808080)
		libraster.noise(&c, 0, 0, 16, 16, 6, 7)
		first := libraster.get(&c, 3, 4)
		seen_other := false
		for y in 0 ..< 16 {
			for x in 0 ..< 16 {
				v := libraster.get(&c, x, y)
				d := chan(v, 16) - 128
				want(d >= -6 && d <= 6, "noise stays inside its strength")
				want(chan(v, 16) == chan(v, 8) && chan(v, 8) == chan(v, 0), "and has no colour")
				if v != first {
					seen_other = true
				}
			}
		}
		want(seen_other, "and is not one flat value")
		c2 := fresh(0x808080)
		libraster.noise(&c2, 0, 0, 16, 16, 6, 7)
		want(libraster.get(&c2, 3, 4) == first, "and is the same grain when made again")
	}

	// -- Hairlines every step, at their alpha ---------------------------------
	{
		c := fresh(BLACK)
		libraster.hairline(&c, 0, 0, 12, 4, 3, WHITE, 255, true)
		want(libraster.get(&c, 0, 1) == WHITE && libraster.get(&c, 3, 1) == WHITE && libraster.get(&c, 9, 2) == WHITE, "a vertical hairline lies every third column")
		want(libraster.get(&c, 1, 1) == BLACK && libraster.get(&c, 2, 1) == BLACK, "and the columns between are left")
	}

	// -- A bevel lights the top left and shades the bottom right -------------
	{
		c := fresh(BLACK)
		libraster.bevel(&c, 4, 4, 10, 10, 2, WHITE, RED)
		want(libraster.get(&c, 4, 4) == WHITE && libraster.get(&c, 5, 8) == WHITE, "a bevel's top and left are lit")
		want(libraster.get(&c, 13, 13) == RED && libraster.get(&c, 12, 8) == RED, "and its bottom and right shaded")
		want(libraster.get(&c, 8, 8) == BLACK, "and its face is the caller's")
	}

	// -- An inset shadow darkens the edge more than the middle ---------------
	{
		c := fresh(WHITE)
		libraster.inset(&c, 0, 0, 20, 20, 4, 200)
		edge := chan(libraster.get(&c, 0, 10), 8)
		inner := chan(libraster.get(&c, 3, 10), 8)
		want(edge < inner && inner < 255, "an inset is darkest at its edge")
		want(libraster.get(&c, 10, 10) == WHITE, "and leaves its middle")
		want(chan(libraster.get(&c, 19, 10), 8) > edge, "and the light's side falls lighter than the shadow's")
	}

	// -- A blur spreads a point and keeps the ground ---------------------------
	{
		c := fresh(BLACK)
		libraster.put(&c, 20, 20, WHITE)
		libraster.blur(&c, 10, 10, 20, 20, 1, scratch[:])
		centre := chan(libraster.get(&c, 20, 20), 8)
		want(centre > 0 && centre < 255, "a blurred point is dimmer")
		want(chan(libraster.get(&c, 21, 20), 8) > 0, "and spreads to its neighbour")
		want(libraster.get(&c, 5, 5) == BLACK, "and outside the rectangle nothing moves")
	}

	// -- Coverage is alpha, per pixel -----------------------------------------
	{
		c := fresh(BLACK)
		mask := [4]u8{0, 128, 255, 64}
		libraster.coverage(&c, 2, 2, mask[:], 2, 2, WHITE)
		want(libraster.get(&c, 2, 2) == BLACK, "no coverage leaves the ground")
		want(chan(libraster.get(&c, 3, 2), 8) == 128, "half coverage is half the colour")
		want(libraster.get(&c, 2, 3) == WHITE, "full coverage is the colour")
	}

	// -- A 1-bit glyph: set bits in the ink, clear ones left ------------------
	{
		c := fresh(BLACK)
		rows := [2]u8{0x81, 0x18}
		libraster.bits(&c, 0, 0, rows[:], RED)
		want(libraster.get(&c, 0, 0) == RED && libraster.get(&c, 7, 0) == RED && libraster.get(&c, 3, 1) == RED, "a set bit is the ink")
		want(libraster.get(&c, 1, 0) == BLACK && libraster.get(&c, 0, 1) == BLACK, "and a clear one the ground")
	}

	// -- An outline fills by nonzero winding, its edges smooth -----------------
	{
		S :: libraster.SUB
		c := fresh(BLACK)
		// A square on pixel corners: every pixel inside it whole.
		sq := [4]libraster.Point{{4 * S, 4 * S}, {12 * S, 4 * S}, {12 * S, 12 * S}, {4 * S, 12 * S}}
		ends := [1]int{4}
		libraster.path(&c, sq[:], ends[:], WHITE, scratch[:])
		want(libraster.get(&c, 4, 4) == WHITE && libraster.get(&c, 11, 11) == WHITE, "a square on pixel corners fills its pixels whole")
		want(libraster.get(&c, 12, 8) == BLACK && libraster.get(&c, 3, 8) == BLACK, "and nothing outside it")

		// An edge half across a pixel covers half of it.
		c = fresh(BLACK)
		half := [4]libraster.Point{{4 * S, 4 * S}, {10 * S + S / 2, 4 * S}, {10 * S + S / 2, 8 * S}, {4 * S, 8 * S}}
		libraster.path(&c, half[:], ends[:], WHITE, scratch[:])
		edge := chan(libraster.get(&c, 10, 6), 8)
		want(edge > 110 && edge < 145, "an edge half across a pixel covers half of it")

		// A contour the other way inside the first cuts a hole.
		c = fresh(BLACK)
		ring := [8]libraster.Point{
			{2 * S, 2 * S}, {20 * S, 2 * S}, {20 * S, 20 * S}, {2 * S, 20 * S},
			{8 * S, 8 * S}, {8 * S, 14 * S}, {14 * S, 14 * S}, {14 * S, 8 * S},
		}
		rends := [2]int{4, 8}
		libraster.path(&c, ring[:], rends[:], WHITE, scratch[:])
		want(libraster.get(&c, 4, 10) == WHITE, "an outer contour fills")
		want(libraster.get(&c, 10, 10) == BLACK, "and one the other way inside it cuts a hole")

		// A diagonal edge is partly covered where it crosses a pixel.
		c = fresh(BLACK)
		tri := [3]libraster.Point{{0, 0}, {16 * S, 0}, {0, 16 * S}}
		tends := [1]int{3}
		libraster.path(&c, tri[:], tends[:], WHITE, scratch[:])
		d := chan(libraster.get(&c, 8, 7), 8)
		want(d > 40 && d < 215, "a diagonal edge is smooth, a pixel on it partly covered")
		want(libraster.get(&c, 2, 2) == WHITE && libraster.get(&c, 14, 14) == BLACK, "and inside it is whole, outside it untouched")
	}

	// -- A curve is flattened to its end ---------------------------------------
	{
		out: [libraster.CUBIC_STEPS]libraster.Point
		n := libraster.cubic(out[:], {0, 0}, {0, 100}, {100, 100}, {100, 0})
		want(n == libraster.CUBIC_STEPS, "a curve flattens to its steps")
		want(out[n - 1].x == 100 && out[n - 1].y == 0, "and its last point is its end")
		want(out[n / 2 - 1].y > 50, "and it bows toward its control points")
	}

	libuser.exits("ok")
}
