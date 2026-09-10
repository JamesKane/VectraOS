/*
PCI configuration space as memory: ECAM.

Enhanced configuration access is configuration space as memory. Every
function has 4 KiB of it, at `base + bus << 20 + device << 15 + function
<< 12`, and a register is a load or a store at its offset. 256 MiB of
window covers 256 buses, and one bus is 1 MiB of it. Bus 0 is the one the
`virt` boards' devices are on, and the one mapped.

The window's base is the board's, so each port keeps that one number and
binds the rest of its `pci_*` names here. A wrong base reads `0xFFFF` as
every vendor id, which `kernel/drivers/pci` reports as an empty bus rather
than trusting.
*/
package neutral

import "base:intrinsics"

// One bus of the window.
ECAM_BUS_SIZE :: u64(1 << 20)
ECAM_NAME :: "ecam"

@(private = "file")
ecam: rawptr

ecam_attach :: proc "contextless" (virt: rawptr) {
	ecam = virt
}

ecam_available :: proc "contextless" () -> bool {
	return ecam != nil
}

@(private = "file")
register :: proc "contextless" (bus, dev, fn: u8, offset: u16) -> ^u32 {
	at := uintptr(bus) << 20 | uintptr(dev & 31) << 15 | uintptr(fn & 7) << 12 | uintptr(offset & 0xFFC)
	return cast(^u32)(uintptr(ecam) + at)
}

// ecam_read32 reads the aligned 32-bit register `offset` names, on bus 0.
ecam_read32 :: proc "contextless" (bus, dev, fn: u8, offset: u16) -> u32 {
	if ecam == nil || bus != 0 {
		return 0xFFFF_FFFF
	}
	return intrinsics.volatile_load(register(bus, dev, fn, offset))
}

ecam_write32 :: proc "contextless" (bus, dev, fn: u8, offset: u16, value: u32) {
	if ecam == nil || bus != 0 {
		return
	}
	intrinsics.volatile_store(register(bus, dev, fn, offset), value)
}
