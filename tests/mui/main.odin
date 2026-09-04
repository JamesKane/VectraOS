/*
mui -- `sys/libmui`'s layout, exercised from ring 3.

The kernel's self-test spawns this program and reads the word it exits with.
The word is `ok` when every step held, or the name of the first that did not.
Each step builds a tree, lays it out, and checks the rectangles the library
computed against the same weighting rule worked here by hand. No pixel is
drawn. The claim under test is the one `docs/WORKBENCH.md` makes for the
toolkit. Weight places every gadget, never a number.

Three buttons share a column's height by their weights. A rigid label keeps its
width while the glue beside it soaks the slack. A nested group is laid inside
its parent's inset, which is what proves the walk recurses.
*/
package muitest

import "vsys:abi"
import "vsys:libmui"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

// eq reports whether two numbers match, and names the step when they do not.
main_check :: proc "contextless" (a: int, b: int, what: string) {
	if a != b {
		fail(what)
	}
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	t := libmui.default_theme

	// -- Three weighted buttons share a column --------------------------------
	//
	// Heights of 1:2:1 over 400 pixels of slack come out 100:200:100 on top of
	// each button's own smallest height. The y of each follows with a gap.
	{
		col := libmui.group(false)
		b1 := libmui.weigh(libmui.button("One"), 1)
		b2 := libmui.weigh(libmui.button("Two"), 2)
		b3 := libmui.weigh(libmui.button("Six"), 1)
		libmui.add(col, b1)
		libmui.add(col, b2)
		libmui.add(col, b3)
		libmui.fit(col, &t)
		libmui.lay(col, 0, 0, 200, 500, &t)

		// The smallest height of a three-letter button under the default theme.
		minh := libmui.FONT_H + 2 * t.vpad + 2 * t.bevel // 16 + 8 + 4 = 28
		main_check(minh, 28, "the button's own smallest height")

		// inner height 492, minus two gaps of 4, is 484 of room. The three
		// smallest heights are 84, so 400 is slack, shared 100:200:100.
		main_check(b1.h, 28 + 100, "the first button's height by weight")
		main_check(b2.h, 28 + 200, "the second button's height by weight")
		main_check(b3.h, 28 + 100, "the third button's height by weight")

		// The column sums back to the inner height with the gaps in place.
		main_check(b1.h + b2.h + b3.h + 2 * t.gap, 500 - 2 * t.pad, "the heights fill the column")

		// Each y sits below the last, a gap on.
		main_check(b1.y, t.pad, "the first button's top at the inset")
		main_check(b2.y, b1.y + b1.h + t.gap, "the second button below the first")
		main_check(b3.y, b2.y + b2.h + t.gap, "the third button below the second")
		main_check(b3.y + b3.h, 500 - t.pad, "the last button reaches the far inset")
	}

	// -- A rigid label keeps its width, the glue takes the slack --------------
	{
		row := libmui.group(true)
		name := libmui.text("Name") // rigid, four cells wide
		glue := libmui.space() // stretchy
		go := libmui.button("Go") // stretchy
		libmui.add(row, name)
		libmui.add(row, glue)
		libmui.add(row, go)
		libmui.fit(row, &t)
		libmui.lay(row, 0, 0, 300, 40, &t)

		// The label is exactly its text and never grows.
		main_check(name.w, 4 * libmui.FONT_W, "the rigid label keeps its width")
		main_check(name.weight, 0, "the rigid label carries no weight")

		// The button's own smallest width, two cells and the insets.
		gomin := 2 * libmui.FONT_W + 2 * t.hpad + 2 * t.bevel // 16 + 16 + 4 = 36
		main_check(gomin, 36, "the button's own smallest width")

		// inner width 292, minus two gaps, is 284 of room. The label and button
		// take 32 and 36 at rest. The 216 of slack splits evenly, 108 each.
		main_check(glue.w, 108, "the glue took its half of the slack")
		main_check(go.w, 36 + 108, "the button took its half of the slack")
		main_check(name.w + glue.w + go.w + 2 * t.gap, 300 - 2 * t.pad, "the row fills its width")
	}

	// -- A nested group is laid inside its parent's inset ---------------------
	{
		outer := libmui.group(false)
		inner := libmui.group(true)
		libmui.add(inner, libmui.text("A"))
		libmui.add(inner, libmui.text("B"))
		libmui.add(outer, inner)
		libmui.add(outer, libmui.text("tail"))
		libmui.fit(outer, &t)
		libmui.lay(outer, 0, 0, 200, 120, &t)

		// The inner group's own first child sits one further inset in on both
		// axes, which only happens if lay recursed into the group.
		main_check(inner.first.x, inner.x + t.pad, "the nested child is inset in x")
		main_check(inner.first.y, inner.y + t.pad, "the nested child is inset in y")
	}

	libuser.exits("ok")
}
