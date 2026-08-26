/*
The Vectra system palette -- "Cyberpunk Workstation 1994".

These are the only colours the kernel-side chrome is allowed to invent.
`intuition` will expose the same table through /ws/screen/palette so that the
boot splash, the panic screen, and the desktop are visibly the same machine.

Surfaces are brushed dark magnesium over deep slate; accents are the three
phosphor colours a CRT of that era could actually make bloom.
*/
package fb

RGB :: [3]u8

// -- Structural surfaces -----------------------------------------------------

VOID           :: RGB{0x07, 0x09, 0x0C} // Behind everything; true backdrop
SLATE_DEEP     :: RGB{0x0E, 0x13, 0x1A} // Desktop ground
SLATE          :: RGB{0x18, 0x1F, 0x28} // Recessed wells, sunken panels
MAGNESIUM_DARK :: RGB{0x22, 0x2A, 0x34} // Bevel shadow edge
MAGNESIUM      :: RGB{0x3C, 0x45, 0x51} // Face of a raised control
MAGNESIUM_LIT  :: RGB{0x60, 0x6C, 0x7A} // Bevel highlight edge
MAGNESIUM_HOT  :: RGB{0x84, 0x92, 0xA2} // Specular top edge on tall bevels

// -- Copper trim -------------------------------------------------------------

COPPER_DARK :: RGB{0x5E, 0x33, 0x16}
COPPER      :: RGB{0xB4, 0x6C, 0x32}
COPPER_LIT  :: RGB{0xE6, 0xA6, 0x62}

// -- Phosphor accents --------------------------------------------------------

AMBER      :: RGB{0xFF, 0xB0, 0x28} // Primary text; the terminal's own colour
AMBER_DIM  :: RGB{0x8A, 0x5C, 0x14} // Inactive labels, embossed shadow
AMBER_HOT  :: RGB{0xFF, 0xDC, 0x9A} // Highlighted / focused text

CYAN       :: RGB{0x38, 0xE0, 0xE8} // Data, values, links
CYAN_DIM   :: RGB{0x1A, 0x6E, 0x74}

PHOSPHOR   :: RGB{0x6C, 0xFF, 0x8A} // Healthy status, "OK"
PHOSPHOR_DIM :: RGB{0x2C, 0x74, 0x3C}

ALERT      :: RGB{0xF2, 0x46, 0x3A} // Faults, panics
ALERT_DIM  :: RGB{0x7A, 0x1E, 0x18}
