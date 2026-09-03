/*
PCI configuration space, through the two ports every PC has had since 1992.

`0xCF8` takes an address -- bus, device, function and a register offset,
with the enable bit set -- and `0xCFC` reads or writes the 32 bits there.
q35 has an ECAM window as well, but its base is a register of the host
bridge that has to be read this way first, so this way is the only one
needed. 256 buses, 32 devices, 8 functions, 256 bytes each; the extended
space beyond 256 bytes is ECAM's alone and nothing here asks for it.

Nothing locks. The address and the data are two ports, and two cores that
interleaved them would read each other's registers. Configuration space is
read during boot, before a second core runs, and the day a driver probes it
later is the day this takes the lock `docs/HANDOFF.md` section 6 describes.
*/
package amd64

CONFIG_ADDRESS :: u16(0xCF8)
CONFIG_DATA :: u16(0xCFC)

// No register window to map: the ports are always there.
PCI_CONFIG_MMIO_SIZE :: u64(0)
PCI_CONFIG_NAME :: "ports 0xCF8/0xCFC"

pci_config_physical_base :: proc "contextless" () -> uintptr {
	return 0
}

pci_attach :: proc "contextless" (virt: rawptr) {
	_ = virt
}

pci_available :: proc "contextless" () -> bool {
	return true
}

@(private = "file")
config_address :: proc "contextless" (bus, dev, fn: u8, offset: u16) -> u32 {
	return 1 << 31 | u32(bus) << 16 | u32(dev & 31) << 11 | u32(fn & 7) << 8 | u32(offset & 0xFC)
}

// pci_read32 reads the aligned 32-bit register `offset` names.
pci_read32 :: proc "contextless" (bus, dev, fn: u8, offset: u16) -> u32 {
	outl(CONFIG_ADDRESS, config_address(bus, dev, fn, offset))
	return inl(CONFIG_DATA)
}

pci_write32 :: proc "contextless" (bus, dev, fn: u8, offset: u16, value: u32) {
	outl(CONFIG_ADDRESS, config_address(bus, dev, fn, offset))
	outl(CONFIG_DATA, value)
}
