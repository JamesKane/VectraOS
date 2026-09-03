/*
What the kernel can reach first on this architecture, and what it is told
about the machine.

The console is the firmware's. An `ecall` puts a byte on the serial line
with no register mapped and no page table touched, which is why nothing
here builds the window arm64 needs. The 16550 the `virt` board has at
`0x1000_0000` waits for the day something wants it directly.

The device tree is the one word on the clock. Every hart shares a counter,
`time`, and the rate it counts at is a property in the tree and nowhere
else -- there is no register for it, as there is on arm64. `timebase` parses
just enough of the tree to find it. A tree it cannot parse leaves the rate
at zero, and the timer says it will not calibrate.
*/
package riscv64

Serial_Kind :: enum {
	None,
	Port_16550,
	Mmio_16550,
	Pl011,
	Firmware,
}

Serial_Desc :: struct {
	kind: Serial_Kind,
	base: uintptr,
}

serial_console :: proc "contextless" (hhdm, kernel_phys, kernel_virt: u64) -> Serial_Desc {
	_, _, _ = hhdm, kernel_phys, kernel_virt
	return Serial_Desc{kind = .Firmware}
}

serial_physical :: proc "contextless" () -> (uintptr, bool) {
	return 0, false
}

// -- The device tree ------------------------------------------------------------

@(private = "file") device_tree: rawptr
@(private = "file") timebase_hz: u64

set_device_tree :: proc "contextless" (dtb: rawptr) {
	device_tree = dtb
	timebase_hz = find_timebase(dtb)
}

// timebase is the rate of `time`, in ticks per second, or zero when the
// tree did not say.
timebase :: proc "contextless" () -> u64 {
	return timebase_hz
}

FDT_MAGIC :: u32(0xD00D_FEED)
FDT_BEGIN_NODE :: u32(1)
FDT_END_NODE :: u32(2)
FDT_PROP :: u32(3)
FDT_NOP :: u32(4)
FDT_END :: u32(9)

@(private = "file")
be32 :: proc "contextless" (p: rawptr, at: uintptr) -> u32 {
	b := ([^]u8)(uintptr(p) + at)
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

@(private = "file")
cstr_equal :: proc "contextless" (p: rawptr, at: uintptr, want: string) -> bool {
	b := ([^]u8)(uintptr(p) + at)
	for i in 0 ..< len(want) {
		if b[i] != want[i] {
			return false
		}
	}
	return b[len(want)] == 0
}

/*
find_timebase walks the flattened tree for `/cpus/timebase-frequency`.

The structure block is a stream of tokens: a node begins with its name, a
property carries a length and an offset into the strings block, and nodes
nest. The property lives directly under `/cpus`, so the walk keeps the depth
and the name of the current top-level node, and reads the one property that
matches at depth two. Big-endian throughout, because the format is.
*/
@(private = "file")
find_timebase :: proc "contextless" (dtb: rawptr) -> u64 #no_bounds_check {
	if dtb == nil || be32(dtb, 0) != FDT_MAGIC {
		return 0
	}
	struct_off := uintptr(be32(dtb, 8))
	strings_off := uintptr(be32(dtb, 12))
	struct_size := uintptr(be32(dtb, 36))

	at := struct_off
	end := struct_off + struct_size
	depth := 0
	in_cpus := false
	for at + 4 <= end {
		token := be32(dtb, at)
		at += 4
		switch token {
		case FDT_BEGIN_NODE:
			name_at := at
			// The name, NUL-terminated, padded to four bytes.
			n := uintptr(0)
			for ([^]u8)(uintptr(dtb) + name_at)[n] != 0 {
				n += 1
			}
			at = (name_at + n + 1 + 3) &~ 3
			depth += 1
			if depth == 2 {
				in_cpus = cstr_equal(dtb, name_at, "cpus")
			}
		case FDT_END_NODE:
			depth -= 1
			if depth < 2 {
				in_cpus = false
			}
		case FDT_PROP:
			length := uintptr(be32(dtb, at))
			name_off := uintptr(be32(dtb, at + 4))
			value_at := at + 8
			at = (value_at + length + 3) &~ 3
			if in_cpus && depth == 2 && length == 4 && cstr_equal(dtb, strings_off + name_off, "timebase-frequency") {
				return u64(be32(dtb, value_at))
			}
		case FDT_NOP:
		case FDT_END:
			return 0
		case:
			return 0
		}
	}
	return 0
}
