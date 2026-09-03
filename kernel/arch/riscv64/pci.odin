/*
PCI configuration space on the `virt` board: ECAM.

Enhanced configuration access is configuration space as memory. Every
function has 4 KiB of it, at `base + bus << 20 + device << 15 + function
<< 12`, and a register is a load or a store at its offset. The `virt`
board's window is at `0x3000_0000`, 256 MiB of it for 256 buses, and one
bus is 1 MiB of it. Bus 0 is the one the board's devices are on, and the
one mapped.

The base is assumed, the way the PLIC's is: it is in the device tree,
under the `pcie` node's `reg`, and nothing here reads the tree for it yet.
A wrong assumption reads `0xFFFF` as every vendor id, which `kernel/
drivers/pci` reports as an empty bus rather than trusting.
*/
package riscv64

import "base:intrinsics"

ECAM_PHYS :: uintptr(0x3000_0000)

// One bus of the window.
PCI_CONFIG_MMIO_SIZE :: u64(1 << 20)
PCI_CONFIG_NAME :: "ecam"

@(private = "file")
ecam: rawptr

pci_config_physical_base :: proc "contextless" () -> uintptr {
	return ECAM_PHYS
}

pci_attach :: proc "contextless" (virt: rawptr) {
	ecam = virt
}

pci_available :: proc "contextless" () -> bool {
	return ecam != nil
}

@(private = "file")
register :: proc "contextless" (bus, dev, fn: u8, offset: u16) -> ^u32 {
	at := uintptr(bus) << 20 | uintptr(dev & 31) << 15 | uintptr(fn & 7) << 12 | uintptr(offset & 0xFFC)
	return cast(^u32)(uintptr(ecam) + at)
}

// pci_read32 reads the aligned 32-bit register `offset` names, on bus 0.
pci_read32 :: proc "contextless" (bus, dev, fn: u8, offset: u16) -> u32 {
	if ecam == nil || bus != 0 {
		return 0xFFFF_FFFF
	}
	return intrinsics.volatile_load(register(bus, dev, fn, offset))
}

pci_write32 :: proc "contextless" (bus, dev, fn: u8, offset: u16, value: u32) {
	if ecam == nil || bus != 0 {
		return
	}
	intrinsics.volatile_store(register(bus, dev, fn, offset), value)
}
