/*
PCI configuration space on the `virt` board: ECAM.

Enhanced configuration access is configuration space as memory. Every
function has 4 KiB of it, at `base + bus << 20 + device << 15 + function
<< 12`, and a register is a load or a store at its offset. The `virt`
board's ECAM window is at `0x40_1000_0000`, high in the address map, 256
MiB of it for 256 buses, and one bus is 1 MiB of it. Bus 0 is the one the
board's devices are on, and the one mapped.

The base is assumed, the way the GIC's is: it is in the device tree,
under the `pcie` node's `reg`, and nothing here reads the tree for it yet.
A wrong assumption reads `0xFFFF` as every vendor id, which `kernel/
drivers/pci` reports as an empty bus rather than trusting.
*/
package arm64

import "kernel:arch/neutral"

ECAM_PHYS :: uintptr(0x40_1000_0000)

// The window is `neutral/ecam.odin`'s: one bus of it, reached by the same
// loads and stores on both boards. Only the base is this port's.
PCI_CONFIG_MMIO_SIZE :: neutral.ECAM_BUS_SIZE
PCI_CONFIG_NAME :: neutral.ECAM_NAME

pci_config_physical_base :: proc "contextless" () -> uintptr {
	return ECAM_PHYS
}

pci_attach :: neutral.ecam_attach
pci_available :: neutral.ecam_available
pci_read32 :: neutral.ecam_read32
pci_write32 :: neutral.ecam_write32
