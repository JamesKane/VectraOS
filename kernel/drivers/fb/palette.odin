/*
The Vectra system palette, as the kernel sees it.

**The table itself lives in `sys/libpal` now, and both privilege levels read
it.** This file promised that `intuition` would expose the same table, so the
boot splash, the panic screen and the desktop are visibly the same machine. By
the time there was a desktop, three places had their own copy of it. Moving
the constants one directory sideways -- into the tree the kernel and ring 3
both already import -- is that promise kept rather than restated.

Every name below is the same name it always was, so nothing in the kernel had
to learn where the colours went. What is here is the aliasing and nothing else.
*/
package fb

import "vsys:libpal"

RGB :: libpal.RGB

// -- Structural surfaces -----------------------------------------------------

VOID :: libpal.VOID
SLATE_DEEP :: libpal.SLATE_DEEP
SLATE :: libpal.SLATE
MAGNESIUM_DARK :: libpal.MAGNESIUM_DARK
MAGNESIUM :: libpal.MAGNESIUM
MAGNESIUM_LIT :: libpal.MAGNESIUM_LIT
MAGNESIUM_HOT :: libpal.MAGNESIUM_HOT

// -- Copper trim -------------------------------------------------------------

COPPER_DARK :: libpal.COPPER_DARK
COPPER :: libpal.COPPER
COPPER_LIT :: libpal.COPPER_LIT

// -- Phosphor accents --------------------------------------------------------

AMBER :: libpal.AMBER
AMBER_DIM :: libpal.AMBER_DIM
AMBER_HOT :: libpal.AMBER_HOT

CYAN :: libpal.CYAN
CYAN_DIM :: libpal.CYAN_DIM

PHOSPHOR :: libpal.PHOSPHOR
PHOSPHOR_DIM :: libpal.PHOSPHOR_DIM

ALERT :: libpal.ALERT
ALERT_DIM :: libpal.ALERT_DIM

// -- And the two arithmetics that go with them -------------------------------
//
// A bevel gets its edges out of a face with `shade`. An indicator gets its lit
// and unlit states out of one colour with `mix`. Both are the table's own
// arithmetic rather than the surface's, so both moved with it. `pack` stayed
// behind, because packing is the one thing that depends on the mode the
// bootloader set -- see `libpal.xrgb` for the other side of that.

mix :: libpal.mix
shade :: libpal.shade
